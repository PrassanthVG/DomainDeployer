#!/bin/bash

# ==============================================================================
# Autonomous Jenkins CI/CD Server Installer
# Supports: Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux, Amazon Linux, Fedora
# ==============================================================================

set -e
trap 'error "Jenkins installation encountered an error on line $LINENO."' ERR

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run this script as root or using sudo: sudo $0"
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        LIKE=${ID_LIKE:-}
    else
        error "Unsupported or unidentifiable Linux distribution."
    fi
}

wait_for_package_locks() {
    if command -v fuser > /dev/null 2>&1; then
        local locks=("/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock" "/var/lib/apt/lists/lock" "/var/run/yum.pid" "/var/run/dnf.pid")
        for lock in "${locks[@]}"; do
            local wait_count=0
            while fuser "$lock" >/dev/null 2>&1; do
                if [ $wait_count -eq 0 ]; then
                    info "Waiting for package manager lock ($lock) to be released by background process..."
                fi
                sleep 2
                ((wait_count+=2))
                if [ $wait_count -ge 60 ]; then
                    warn "Package manager lock held for over 60s. Continuing..."
                    break
                fi
            done
        done
    fi
}

# --- Cloud / Small VM Memory & Swap Optimizer ---
optimize_memory_for_small_vms() {
    local TOTAL_RAM_MB
    TOTAL_RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    TOTAL_RAM_MB=${TOTAL_RAM_MB:-2048}

    if [ "$TOTAL_RAM_MB" -lt 1500 ]; then
        info "Small VM detected (${TOTAL_RAM_MB}MB RAM). Optimizing memory settings..."
        local TOTAL_SWAP_MB
        TOTAL_SWAP_MB=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')
        TOTAL_SWAP_MB=${TOTAL_SWAP_MB:-0}

        if [ "$TOTAL_SWAP_MB" -lt 1024 ] && [ ! -f /swapfile ]; then
            info "Configuring 1.5GB swap file to prevent Jenkins from triggering OOM-killer..."
            fallocate -l 1536M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1536 2>/dev/null || true
            if [ -f /swapfile ]; then
                chmod 600 /swapfile
                mkswap /swapfile > /dev/null 2>&1 || true
                swapon /swapfile > /dev/null 2>&1 || true
                if ! grep -q "/swapfile" /etc/fstab; then
                    echo "/swapfile none swap sw 0 0" >> /etc/fstab
                fi
                success "1.5GB swap space enabled."
            fi
        fi

        # Limit JVM Heap on 1GB instances so other services (Docker/Nginx) don't starve
        mkdir -p /etc/systemd/system/jenkins.service.d
        cat > /etc/systemd/system/jenkins.service.d/override.conf <<'EOF'
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Xms256m -Xmx512m"
EOF
        systemctl daemon-reload > /dev/null 2>&1 || true
    fi
}

check_port_conflict() {
    local PORT=8080
    local IN_USE=""
    if command -v ss > /dev/null 2>&1; then
        IN_USE=$(ss -tlpn 2>/dev/null | grep ":$PORT " || true)
    elif command -v netstat > /dev/null 2>&1; then
        IN_USE=$(netstat -tlpn 2>/dev/null | grep ":$PORT " || true)
    fi

    if [ -n "$IN_USE" ]; then
        warn "Port $PORT is currently in use:"
        echo "$IN_USE"
        warn "Jenkins may fail to bind to port 8080 unless the conflicting service is stopped."
    fi
}

# --- Installation Modules ---
install_debian() {
    info "Detected Debian/Ubuntu family ($OS)..."
    wait_for_package_locks

    info "Cleaning up obsolete repository lists if any..."
    rm -f /etc/apt/sources.list.d/jenkins.list

    info "Updating package lists..."
    apt-get update -y -q > /dev/null || true

    info "Installing prerequisites (Java 21, fontconfig, curl, gnupg, ufw)..."
    apt-get install -y -q openjdk-21-jre fontconfig wget curl gnupg ufw ca-certificates > /dev/null

    info "Fetching official Jenkins repository key..."
    mkdir -p /usr/share/keyrings
    if ! curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key -o /usr/share/keyrings/jenkins-keyring.asc 2>/dev/null; then
        if ! curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key -o /usr/share/keyrings/jenkins-keyring.asc 2>/dev/null; then
            curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io.key -o /usr/share/keyrings/jenkins-keyring.asc
        fi
    fi
    chmod a+r /usr/share/keyrings/jenkins-keyring.asc

    info "Adding Jenkins apt repository..."
    echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

    info "Updating package lists with Jenkins repo..."
    apt-get update -y -q > /dev/null

    info "Installing Jenkins package..."
    apt-get install -y -q jenkins > /dev/null

    info "Configuring firewall (Port 8080)..."
    if command -v ufw > /dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 8080/tcp > /dev/null || true
        ufw reload > /dev/null || true
    fi
}

install_rhel() {
    info "Detected RHEL/CentOS/Fedora family ($OS)..."
    wait_for_package_locks

    PM=$([ -x "$(command -v dnf)" ] && echo "dnf" || echo "yum")

    info "Cleaning up old Jenkins repository configurations..."
    rm -f /etc/yum.repos.d/jenkins.repo

    info "Installing prerequisites (Java 21, fontconfig, wget)..."
    if [ "$OS" = "amzn" ]; then
        $PM install -y -q java-21-amazon-corretto fontconfig wget curl firewalld > /dev/null 2>&1 || \
        $PM install -y -q java-21-openjdk fontconfig wget curl > /dev/null
    else
        $PM install -y -q java-21-openjdk fontconfig wget curl firewalld > /dev/null
    fi

    info "Adding Jenkins RPM repository..."
    wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo -q

    info "Importing official Jenkins RPM key..."
    rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2026.key 2>/dev/null || \
    rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key 2>/dev/null || \
    rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io.key

    info "Installing Jenkins package..."
    $PM install -y -q jenkins > /dev/null

    info "Configuring Firewalld (Port 8080)..."
    if command -v firewall-cmd > /dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --permanent --zone=public --add-port=8080/tcp > /dev/null || true
            firewall-cmd --reload > /dev/null || true
        fi
    fi
}

configure_jenkins_permissions() {
    info "Configuring passwordless root access for the 'jenkins' CI/CD user..."
    mkdir -p /etc/sudoers.d
    echo "jenkins ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/jenkins.tmp
    chmod 0440 /etc/sudoers.d/jenkins.tmp

    # Validate syntax before moving into production
    if command -v visudo > /dev/null 2>&1; then
        if visudo -cf /etc/sudoers.d/jenkins.tmp > /dev/null 2>&1; then
            mv /etc/sudoers.d/jenkins.tmp /etc/sudoers.d/jenkins
        else
            rm -f /etc/sudoers.d/jenkins.tmp
            warn "visudo syntax check failed; skipped sudoers modification."
        fi
    else
        mv /etc/sudoers.d/jenkins.tmp /etc/sudoers.d/jenkins
    fi

    # Ensure docker group exists and add jenkins
    if ! getent group docker > /dev/null 2>&1; then
        groupadd docker 2>/dev/null || true
    fi

    usermod -aG docker jenkins 2>/dev/null || true

    if [ -e /var/run/docker.sock ]; then
        chown root:docker /var/run/docker.sock 2>/dev/null || true
        chmod 660 /var/run/docker.sock 2>/dev/null || true
    fi
}

start_and_enable_jenkins() {
    info "Starting Jenkins service..."
    if command -v systemctl > /dev/null 2>&1; then
        systemctl daemon-reload > /dev/null 2>&1 || true
        systemctl enable jenkins > /dev/null 2>&1 || true
        systemctl restart jenkins
    else
        service jenkins restart || true
    fi
}

get_initial_password() {
    info "Waiting for initial admin password generation..."
    local PASS_FILE="/var/lib/jenkins/secrets/initialAdminPassword"
    for i in {1..20}; do
        if [ -f "$PASS_FILE" ]; then break; fi
        sleep 2
    done

    local IP_ADDRESS
    IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$IP_ADDRESS" ]; then IP_ADDRESS="127.0.0.1"; fi

    if [ -f "$PASS_FILE" ]; then
        local ADMIN_PASS
        ADMIN_PASS=$(cat "$PASS_FILE")
        echo -e "\n========================================================================"
        success "JENKINS CI/CD INSTALLATION COMPLETE!"
        echo -e "========================================================================"
        echo -e "${YELLOW}Access Jenkins URL :${NC} http://${IP_ADDRESS}:8080"
        echo -e "${YELLOW}Admin Password     :${NC} ${ADMIN_PASS}"
        echo -e "========================================================================\n"
    else
        warn "Jenkins service started, but initial admin password was not ready in 40s."
        echo -e "Retrieve it manually when Jenkins finishes loading:"
        echo -e "  sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
    fi
}

# --- Main Entry Point ---
main() {
    echo -e "${CYAN}Starting Autonomous Jenkins Installation...${NC}"
    check_root
    detect_os
    check_port_conflict
    optimize_memory_for_small_vms

    case "$OS" in
        ubuntu|debian|linuxmint|pop|elementary|kali|raspbian)
            install_debian
            ;;
        centos|rhel|rocky|almalinux|fedora|amzn|ol)
            install_rhel
            ;;
        *)
            if [[ "$LIKE" == *"debian"* ]]; then
                install_debian
            elif [[ "$LIKE" == *"rhel"* ]] || [[ "$LIKE" == *"fedora"* ]]; then
                install_rhel
            else
                error "Linux distribution '$OS' is not supported by this script."
            fi
            ;;
    esac

    configure_jenkins_permissions
    start_and_enable_jenkins
    get_initial_password
}

main "$@"