#!/bin/bash

# ==============================================================================
# Autonomous Nginx Installer & Reverse Proxy Deployer
# Supports: Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux, Amazon Linux, Fedora
# Multi-mode: Custom Config (nginx.conf / ngnix.config) or Interactive Generator
# ==============================================================================

set -e
trap 'error "Nginx installation encountered an error on line $LINENO."' ERR

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

configure_selinux() {
    if command -v getenforce > /dev/null 2>&1; then
        local STATUS
        STATUS=$(getenforce 2>/dev/null || echo "Disabled")
        if [ "$STATUS" != "Disabled" ]; then
            info "SELinux is active ($STATUS). Enabling httpd network proxy connections..."
            setsebool -P httpd_can_network_connect 1 > /dev/null 2>&1 || true
            success "SELinux httpd_can_network_connect enabled."
        fi
    fi
}

# --- 1. Installation ---
install_nginx() {
    info "Checking for Nginx installation..."
    wait_for_package_locks

    if ! command -v nginx > /dev/null 2>&1; then
        if [[ "$OS" == "ubuntu" || "$OS" == "debian" || "$LIKE" == *"debian"* ]]; then
            info "Installing Nginx via APT..."
            apt-get update -y -q > /dev/null || true
            apt-get install -y -q nginx curl ufw > /dev/null
        elif [ "$OS" = "amzn" ]; then
            info "Installing Nginx on Amazon Linux..."
            if command -v amazon-linux-extras > /dev/null 2>&1; then
                amazon-linux-extras install -y nginx1 > /dev/null 2>&1 || true
            else
                dnf install -y -q nginx curl > /dev/null 2>&1 || yum install -y -q nginx curl > /dev/null
            fi
        elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" || "$OS" == "fedora" || "$LIKE" == *"rhel"* ]]; then
            info "Installing Nginx via YUM/DNF..."
            local PM=$([ -x "$(command -v dnf)" ] && echo "dnf" || echo "yum")
            $PM install -y -q epel-release > /dev/null 2>&1 || true
            $PM install -y -q nginx curl firewalld > /dev/null
        else
            error "Distribution '$OS' is not supported for automatic Nginx installation."
        fi
        success "Nginx successfully installed."
    else
        info "Nginx is already installed ($(nginx -v 2>&1))."
    fi

    # Ensure sites-available / sites-enabled architecture exists
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled

    # Ensure main nginx.conf includes sites-enabled
    if [ -f /etc/nginx/nginx.conf ] && ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
        info "Configuring /etc/nginx/nginx.conf to load sites-enabled configurations..."
        if grep -q "include.*conf\.d" /etc/nginx/nginx.conf; then
            sed -i '/include.*conf\.d\/\*\.conf;/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
        else
            # Insert before the closing bracket of the http block
            sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
        fi
    fi

    configure_selinux
}

# --- 2. Configuration Setup ---
setup_configuration() {
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local INPUT_CONFIG="$1"

    # Auto-detect config files if not specified explicitly
    if [ -z "$INPUT_CONFIG" ]; then
        if [ -f "$SCRIPT_DIR/ngnix.config" ]; then
            INPUT_CONFIG="$SCRIPT_DIR/ngnix.config"
        elif [ -f "$SCRIPT_DIR/nginx.conf" ]; then
            INPUT_CONFIG="$SCRIPT_DIR/nginx.conf"
        fi
    fi

    echo -e "\n${CYAN}=== Nginx Deployment Configuration ===${NC}"

    if [ -n "$INPUT_CONFIG" ] && [ -f "$INPUT_CONFIG" ]; then
        info "Using configuration template: $INPUT_CONFIG"
        APP_NAME=$(basename "$INPUT_CONFIG" | sed 's/\.[^.]*$//')
        CONFIG_SRC="$INPUT_CONFIG"

        # Attempt to detect listen port from config file
        DETECTED_PORT=$(grep -E '^\s*listen\s+' "$INPUT_CONFIG" | head -n 1 | awk '{print $2}' | tr -d ';')
        EXPOSED_PORT=${DETECTED_PORT:-80}
        info "Detected exposed port from config: $EXPOSED_PORT"
        DOMAIN="custom-template"
    else
        info "Interactive Mode: Configuring reverse proxy..."
        read -p "Enter App Name (e.g., my_app): " APP_NAME
        APP_NAME=${APP_NAME:-my_app}

        read -p "Enter Domain Name or Public IP (e.g., 192.168.1.100): " DOMAIN
        if [ -z "$DOMAIN" ]; then error "Domain/IP cannot be empty."; fi

        read -p "Enter Internal Backend Port (e.g., 3000): " APP_PORT
        if [ -z "$APP_PORT" ]; then error "Backend Port cannot be empty."; fi

        EXPOSED_PORT=80
        CONFIG_SRC=""
    fi

    CONFIG_DEST="/etc/nginx/sites-available/$APP_NAME.conf"

    # Backup existing configuration
    BACKUP_FILE=""
    if [ -f "$CONFIG_DEST" ]; then
        BACKUP_FILE="$CONFIG_DEST.backup.$(date +%Y%m%d_%H%M%S)"
        info "Backing up existing configuration to $BACKUP_FILE..."
        cp "$CONFIG_DEST" "$BACKUP_FILE"
    fi

    # Deploy file
    if [ -n "$CONFIG_SRC" ]; then
        cp "$CONFIG_SRC" "$CONFIG_DEST"
    else
        cat > "$CONFIG_DEST" <<EOF
server {
    listen $EXPOSED_PORT;
    server_name $DOMAIN;

    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF
    fi

    # Enable site
    ln -sf "$CONFIG_DEST" "/etc/nginx/sites-enabled/"

    # Remove conflicting default configuration on port 80 if our config uses port 80
    if [ "$EXPOSED_PORT" -eq 80 ]; then
        rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi
}

# --- 3. Firewall Configuration ---
configure_firewall() {
    info "Configuring firewall for port $EXPOSED_PORT..."
    if command -v ufw > /dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$EXPOSED_PORT"/tcp > /dev/null || true
        ufw reload > /dev/null || true
        success "UFW allowed port $EXPOSED_PORT."
    elif command -v firewall-cmd > /dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --zone=public --add-port="$EXPOSED_PORT"/tcp > /dev/null || true
        firewall-cmd --reload > /dev/null || true
        success "Firewalld allowed port $EXPOSED_PORT."
    fi
}

# --- 4. Validation & Service Restart ---
validate_and_restart() {
    info "Validating Nginx configuration syntax..."
    if nginx -t; then
        success "Nginx syntax is valid."
        if command -v systemctl > /dev/null 2>&1; then
            systemctl enable nginx > /dev/null 2>&1 || true
            systemctl restart nginx
        else
            service nginx restart
        fi
        success "Nginx service restarted successfully."
    else
        error "Nginx configuration test failed!"
        if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
            warn "Rolling back to previous backup: $BACKUP_FILE"
            cp "$BACKUP_FILE" "$CONFIG_DEST"
            nginx -t && systemctl restart nginx
        fi
        exit 1
    fi
}

# --- 5. Health Check ---
perform_health_check() {
    echo -e "\n${CYAN}=== Performing Health Check ===${NC}"
    sleep 2

    local TARGET="http://127.0.0.1:$EXPOSED_PORT"
    info "Pinging $TARGET/health..."

    local HTTP_STATUS
    HTTP_STATUS=$(curl -o /dev/null -s -w "%{http_code}\n" --max-time 5 "$TARGET/health" 2>/dev/null || echo "000")

    if [ "$HTTP_STATUS" -eq 200 ]; then
        success "Health Check: Endpoint /health is HEALTHY (HTTP 200)."
    elif [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 400 ]; then
        success "Health Check: Received HTTP $HTTP_STATUS."
    elif [ "$HTTP_STATUS" -eq 502 ]; then
        warn "Health Check: Received HTTP 502 Bad Gateway."
        echo "       Nginx is active, but your upstream backend application on localhost might be stopped."
    else
        info "Health Check: Server responded with status $HTTP_STATUS on port $EXPOSED_PORT."
    fi
}

# --- Main Entry Point ---
main() {
    echo -e "${CYAN}Starting Autonomous Nginx Setup...${NC}"
    check_root
    detect_os

    install_nginx
    setup_configuration "$1"
    configure_firewall
    validate_and_restart
    perform_health_check

    local IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$IP_ADDRESS" ]; then IP_ADDRESS="127.0.0.1"; fi

    echo -e "\n========================================================================"
    success "NGINX REVERSE PROXY DEPLOYMENT COMPLETE!"
    echo -e "========================================================================"
    echo -e "${YELLOW}Site Name   :${NC} $APP_NAME"
    echo -e "${YELLOW}Public URL  :${NC} http://${IP_ADDRESS}:${EXPOSED_PORT}"
    echo -e "${YELLOW}Config Path :${NC} $CONFIG_DEST"
    echo -e "========================================================================\n"
}

main "$@"