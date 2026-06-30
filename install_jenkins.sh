#!/bin/bash

# ==============================================================================
# Autonomous Jenkins Installer
# Supports: Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -e
trap 'error "Command failed on line $LINENO. If you are on a VM, ensure network and firewall configurations allow these operations."' ERR

# --- Color Configuration for CLI Interface ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Helper Functions ---
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Pre-flight Checks ---
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run this script as root or using sudo."
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        error "Unsupported or unidentifiable Linux distribution."
    fi
}

# --- Installation Modules ---

install_debian() {
    info "Detected Debian/Ubuntu-based system."
    
    info "Cleaning up old Jenkins repository configuration..."
    rm -f /etc/apt/sources.list.d/jenkins.list
    
    info "Updating package lists..."
    apt-get update -y -q > /dev/null || true
    
    info "Installing prerequisites (Java 21, wget, curl, gnupg)..."
    apt-get install -y -q openjdk-21-jre wget curl gnupg ufw > /dev/null

    info "Adding Jenkins repository key (2026)..."
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null

    info "Adding Jenkins apt repository..."
    echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

    info "Updating package lists with Jenkins repo..."
    apt-get update -y -q > /dev/null

    info "Installing Jenkins..."
    apt-get install -y -q jenkins > /dev/null
    
    info "Configuring UFW Firewall (Opening port 8080)..."
    if command -v ufw > /dev/null; then
        ufw allow 8080/tcp > /dev/null || true
        ufw reload > /dev/null || true
    fi
}

install_rhel() {
    info "Detected RHEL/CentOS-based system."
    
    info "Cleaning up old Jenkins repository configuration..."
    rm -f /etc/yum.repos.d/jenkins.repo
    
    info "Installing prerequisites (Java 21, wget)..."
    if command -v dnf > /dev/null; then
        PM="dnf"
    else
        PM="yum"
    fi
    $PM install -y -q java-21-openjdk wget firewalld > /dev/null

    info "Adding Jenkins repository..."
    wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo -q

    info "Importing Jenkins key (2026)..."
    rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2026.key

    info "Installing Jenkins..."
    $PM install -y -q jenkins > /dev/null
    
    info "Configuring Firewalld (Opening port 8080)..."
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --zone=public --add-port=8080/tcp > /dev/null || true
        firewall-cmd --reload > /dev/null || true
    else
        systemctl start firewalld || true
        systemctl enable firewalld || true
        firewall-cmd --permanent --zone=public --add-port=8080/tcp > /dev/null || true
        firewall-cmd --reload > /dev/null || true
    fi
}

# --- Service Management ---
start_and_enable_jenkins() {
    info "Enabling Jenkins to start on boot..."
    systemctl enable jenkins > /dev/null

    info "Starting Jenkins service..."
    systemctl start jenkins > /dev/null

    # Verify service is running
    if systemctl is-active --quiet jenkins; then
        success "Jenkins service is successfully running!"
    else
        error "Jenkins installed, but failed to start. Check 'systemctl status jenkins' for details."
    fi
}

configure_jenkins_permissions() {
    info "Configuring passwordless root access for the 'jenkins' user..."
    
    # Create the sudoers drop-in file for Jenkins
    echo "jenkins ALL=(ALL) NOPASSWD: ALL" | tee /etc/sudoers.d/jenkins > /dev/null
    
    # Ensure correct permissions on the sudoers file
    chmod 0440 /etc/sudoers.d/jenkins
    
    # Ensure docker group exists (in case Jenkins is installed before Docker)
    if ! getent group docker > /dev/null 2>&1; then
        groupadd docker || true
    fi

    info "Adding 'jenkins' user to 'docker' group..."
    usermod -aG docker jenkins || true
    
    # If docker socket already exists, ensure permissions are correct
    if [ -e /var/run/docker.sock ]; then
        chown root:docker /var/run/docker.sock || true
        chmod 660 /var/run/docker.sock || true
    fi

    # Restart Jenkins so the daemon process picks up the new docker group membership
    info "Restarting Jenkins to apply group permissions..."
    systemctl restart jenkins > /dev/null || true
    
    success "Jenkins user has been granted full passwordless root access and Docker permissions."
}

get_initial_password() {
    info "Waiting for Jenkins to generate the initial admin password (this can take a few seconds)..."
    
    # Wait up to 30 seconds for the password file to be created
    for i in {1..15}; do
        if [ -f /var/lib/jenkins/secrets/initialAdminPassword ]; then
            break
        fi
        sleep 2
    done

    if [ -f /var/lib/jenkins/secrets/initialAdminPassword ]; then
        ADMIN_PASS=$(cat /var/lib/jenkins/secrets/initialAdminPassword)
        IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')
        if [ -z "$IP_ADDRESS" ]; then IP_ADDRESS="127.0.0.1"; fi
        
        echo -e "\n========================================================================"
        success "JENKINS INSTALLATION COMPLETE!"
        echo -e "========================================================================"
        echo -e "${YELLOW}Access Jenkins URL :${NC} http://${IP_ADDRESS}:8080"
        echo -e "${YELLOW}Admin Password     :${NC} ${ADMIN_PASS}"
        echo -e "========================================================================\n"
    else
        warn "Installation finished, but the initial admin password file wasn't found immediately."
        echo -e "You can retrieve it later by running:\n  sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
    fi
}

# --- Main Execution Block ---
main() {
    echo -e "${CYAN}Starting Autonomous Jenkins Installation...${NC}"
    check_root
    detect_os

    case "$OS" in
        ubuntu|debian)
            install_debian
            ;;
        centos|rhel|rocky|almalinux|fedora)
            install_rhel
            ;;
        *)
            error "Distribution '$OS' is not strictly supported by this script."
            ;;
    esac

    start_and_enable_jenkins
    configure_jenkins_permissions
    get_initial_password
}

# Run main function
main