#!/bin/bash

# ==============================================================================
# Autonomous Docker & Docker Compose Installer
# Supports: Ubuntu, Debian, Linux Mint, Pop!_OS, CentOS, RHEL, Rocky, Alma, Fedora, Amazon Linux
# Multi-Arch: x86_64 (amd64), aarch64 (arm64), armhf
# ==============================================================================

set -e
trap 'error "Docker installation encountered an error on line $LINENO."' ERR

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

    # Determine CPU architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            DOCKER_ARCH="amd64"
            ;;
        aarch64|arm64)
            DOCKER_ARCH="arm64"
            ;;
        armv7l|armhf)
            DOCKER_ARCH="armhf"
            ;;
        *)
            DOCKER_ARCH="amd64"
            ;;
    esac
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

# --- Installation Modules ---
install_debian() {
    info "Detected Debian/Ubuntu family ($OS, $DOCKER_ARCH)..."
    wait_for_package_locks

    info "Removing conflicting or obsolete packages..."
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do 
        apt-get remove -y -q "$pkg" > /dev/null 2>&1 || true
    done

    info "Updating package lists..."
    apt-get update -y -q > /dev/null || true

    info "Installing prerequisites..."
    apt-get install -y -q ca-certificates curl gnupg > /dev/null

    # Resolve distro name for Docker repo URL
    local DOCKER_DISTRO="ubuntu"
    if [ "$OS" = "debian" ] || [[ "$LIKE" == *"debian"* && "$LIKE" != *"ubuntu"* ]]; then
        DOCKER_DISTRO="debian"
    fi

    # Resolve codename safely across all derivatives
    local CODENAME="${VERSION_CODENAME:-}"
    if [ -z "$CODENAME" ] && [ -n "${UBUNTU_CODENAME:-}" ]; then
        CODENAME="$UBUNTU_CODENAME"
    fi
    if [ -z "$CODENAME" ]; then
        CODENAME=$(lsb_release -cs 2>/dev/null || true)
    fi
    if [ -z "$CODENAME" ]; then
        if [ "$DOCKER_DISTRO" = "debian" ]; then CODENAME="bookworm"; else CODENAME="jammy"; fi
    fi

    info "Adding Docker GPG key..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$DOCKER_DISTRO/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    info "Configuring Docker repository ($DOCKER_DISTRO / $CODENAME)..."
    echo \
      "deb [arch=$DOCKER_ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$DOCKER_DISTRO \
      $CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    info "Updating package lists with Docker repository..."
    apt-get update -y -q > /dev/null

    info "Installing Docker Engine and Compose plugin..."
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
}

install_rhel() {
    info "Detected RHEL/CentOS/Fedora family ($OS)..."
    wait_for_package_locks

    PM=$([ -x "$(command -v dnf)" ] && echo "dnf" || echo "yum")

    info "Removing conflicting or obsolete packages..."
    $PM remove -y -q docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman > /dev/null 2>&1 || true

    if [ "$OS" = "amzn" ]; then
        info "Configuring Docker on Amazon Linux..."
        if command -v amazon-linux-extras > /dev/null 2>&1; then
            amazon-linux-extras install -y docker > /dev/null 2>&1 || true
        else
            $PM install -y -q docker > /dev/null 2>&1 || true
        fi
        # Install Docker Compose standalone binary for Amazon Linux
        mkdir -p /usr/local/lib/docker/cli-plugins
        curl -sSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$ARCH" -o /usr/local/lib/docker/cli-plugins/docker-compose 2>/dev/null || true
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose 2>/dev/null || true
    elif [ "$OS" = "fedora" ]; then
        info "Configuring Docker repo for Fedora..."
        $PM install -y -q dnf-plugins-core > /dev/null 2>&1 || true
        $PM config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo > /dev/null
        $PM install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
    else
        info "Configuring Docker repo for CentOS/RHEL/Rocky/Alma..."
        $PM install -y -q dnf-plugins-core yum-utils > /dev/null 2>&1 || true
        $PM config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo > /dev/null
        $PM install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
    fi
}

start_and_enable_docker() {
    info "Enabling and starting Docker service..."
    if command -v systemctl > /dev/null 2>&1; then
        systemctl daemon-reload > /dev/null 2>&1 || true
        systemctl enable docker.service > /dev/null 2>&1 || true
        systemctl enable containerd.service > /dev/null 2>&1 || true
        systemctl restart docker > /dev/null 2>&1 || true
    else
        service docker restart > /dev/null 2>&1 || true
    fi

    # Verify
    if command -v docker > /dev/null 2>&1; then
        success "Docker Engine installed: $(docker --version)"
    else
        error "Docker binary not found after installation."
    fi
}

configure_user_permissions() {
    local REAL_USER=${SUDO_USER:-$USER}

    # Ensure docker group exists
    if ! getent group docker > /dev/null 2>&1; then
        groupadd docker || true
    fi

    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        info "Adding user '$REAL_USER' to the 'docker' group..."
        usermod -aG docker "$REAL_USER" || true

        echo -e "\n========================================================================"
        success "DOCKER INSTALLATION COMPLETE!"
        echo -e "========================================================================"
        echo -e "${YELLOW}Docker and Docker Compose are fully installed.${NC}"
        echo -e "To run docker commands without 'sudo', update your current session:"
        echo -e "  ${CYAN}newgrp docker${NC}  or  ${CYAN}su - $REAL_USER${NC}"
        echo -e "========================================================================\n"
    fi
}

main() {
    echo -e "${CYAN}Starting Autonomous Docker & Compose Installation...${NC}"
    check_root
    detect_os

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

    start_and_enable_docker
    configure_user_permissions
}

main "$@"