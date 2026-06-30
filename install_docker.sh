#!/bin/bash

# ==============================================================================
# Autonomous Docker & Docker Compose Installer
# Supports: Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -e

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
        # Handle derivatives like Linux Mint
        if [ "$OS" = "linuxmint" ]; then OS="ubuntu"; fi
    else
        error "Unsupported or unidentifiable Linux distribution."
    fi
}

# --- Installation Modules ---

install_debian() {
    info "Detected Debian/Ubuntu-based system."
    
    info "Removing any conflicting old versions..."
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do 
        apt-get remove -y -q $pkg > /dev/null 2>&1 || true
    done

    info "Updating package lists..."
    apt-get update -y -q > /dev/null
    
    info "Installing prerequisites (ca-certificates, curl)..."
    apt-get install -y -q ca-certificates curl > /dev/null

    info "Adding Docker's official GPG key..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$OS/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    info "Adding Docker repository..."
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$OS \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    info "Updating package lists with Docker repo..."
    apt-get update -y -q > /dev/null

    info "Installing Docker Engine and Compose..."
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
}

install_rhel() {
    info "Detected RHEL/CentOS-based system."
    
    info "Removing any conflicting old versions..."
    if command -v dnf > /dev/null; then PM="dnf"; else PM="yum"; fi
    $PM remove -y -q docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine > /dev/null 2>&1 || true

    info "Installing yum-utils..."
    $PM install -y -q yum-utils > /dev/null

    info "Adding Docker repository..."
    # Rocky and AlmaLinux use the CentOS repo seamlessly
    $PM config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo > /dev/null

    info "Installing Docker Engine and Compose..."
    $PM install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
}

# --- Service & User Management ---
start_and_enable_docker() {
    info "Enabling Docker to start on boot..."
    systemctl enable docker.service > /dev/null
    systemctl enable containerd.service > /dev/null

    info "Starting Docker service..."
    systemctl start docker > /dev/null

    if systemctl is-active --quiet docker; then
        success "Docker service is successfully running!"
    else
        error "Docker installed, but failed to start. Check 'systemctl status docker' for details."
    fi
}

configure_user_permissions() {
    # Figure out the real user who ran the sudo command
    REAL_USER=${SUDO_USER:-$USER}
    
    if [ "$REAL_USER" != "root" ]; then
        info "Adding user '$REAL_USER' to the 'docker' group..."
        usermod -aG docker "$REAL_USER"
        
        echo -e "\n========================================================================"
        success "DOCKER INSTALLATION COMPLETE!"
        echo -e "========================================================================"
        echo -e "${YELLOW}Docker and Docker Compose are fully installed.${NC}"
        echo -e "To run docker commands without 'sudo', you must apply the new group membership.\n"
        echo -e "${CYAN}Please run the following command NOW, or log out and log back in:${NC}"
        echo -e "  su - $REAL_USER"
        echo -e "========================================================================\n"
    fi
}

# --- Main Execution Block ---
main() {
    echo -e "${CYAN}Starting Autonomous Docker Installation...${NC}"
    check_root
    detect_os

    case "$OS" in
        ubuntu|debian|linuxmint)
            install_debian
            ;;
        centos|rhel|rocky|almalinux|fedora)
            install_rhel
            ;;
        *)
            error "Distribution '$OS' is not strictly supported by this script."
            ;;
    esac

    start_and_enable_docker
    configure_user_permissions
}

# Run main function
main