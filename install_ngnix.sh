#!/bin/bash

# ==============================================================================
# Autonomous Nginx Installer & Deployer
# Supports passing a custom config file OR interactive template generation
# ==============================================================================

set -e

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Pre-flight Checks ---
if [ "$EUID" -ne 0 ]; then
    error "Please run this script as root or using sudo."
fi

# Detect OS to handle package managers correctly
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    error "Unsupported Linux distribution."
fi

# --- 1. Installation ---
info "Checking for Nginx..."
if ! command -v nginx > /dev/null; then
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        info "Installing Nginx via APT..."
        apt-get update -y -q > /dev/null
        apt-get install -y -q nginx curl ufw > /dev/null
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
        info "Installing Nginx via YUM/DNF..."
        PM=$([ -x "$(command -v dnf)" ] && echo "dnf" || echo "yum")
        $PM install -y -q epel-release > /dev/null || true
        $PM install -y -q nginx curl firewalld > /dev/null
    else
        error "OS not strictly supported for auto-install."
    fi
    success "Nginx installed."
else
    info "Nginx is already installed. Skipping installation."
fi

# Ensure necessary directories exist (especially for RHEL/CentOS systems)
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled
# If RHEL, ensure nginx.conf includes sites-enabled
if grep -q "conf.d" /etc/nginx/nginx.conf && ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
    sed -i '/include \/etc\/nginx\/conf\.d\/\*\.conf;/a \    include \/etc\/nginx\/sites-enabled\/\*;' /etc/nginx/nginx.conf
fi

# --- 2. Input & Configuration ---
CUSTOM_CONFIG=$1

echo -e "\n${CYAN}=== Nginx Deployment Configuration ===${NC}"

if [ -n "$CUSTOM_CONFIG" ] && [ -f "$CUSTOM_CONFIG" ]; then
    info "Custom configuration file detected: $CUSTOM_CONFIG"
    APP_NAME=$(basename "$CUSTOM_CONFIG" .conf)
    
    # We won't know the exact domain/port from a blind file, so we ask for the firewall port
    read -p "What external port does this config expose? (Default: 80): " EXPOSED_PORT
    EXPOSED_PORT=${EXPOSED_PORT:-80}
    DOMAIN="custom-domain" # Placeholder for output
else
    info "Interactive Mode: Let's configure your reverse proxy."
    read -p "Enter App Name (e.g., murugan-ai): " APP_NAME
    APP_NAME=${APP_NAME:-my_app}

    read -p "Enter Domain Name or Public IP (e.g., 192.168.1.100): " DOMAIN
    if [ -z "$DOMAIN" ]; then error "Domain/IP cannot be empty."; fi

    read -p "Enter Internal App Port to route to (e.g., 8000): " APP_PORT
    if [ -z "$APP_PORT" ]; then error "App Port cannot be empty."; fi
    
    EXPOSED_PORT=80
fi

# --- 3. Backup Existing Config ---
CONFIG_DEST="/etc/nginx/sites-available/$APP_NAME.conf"
if [ -f "$CONFIG_DEST" ]; then
    BACKUP_NAME="$CONFIG_DEST.backup.$(date +%Y%m%d_%H%M%S)"
    info "Backing up existing configuration to $BACKUP_NAME"
    cp "$CONFIG_DEST" "$BACKUP_NAME"
fi

# --- 4. Deploy Configuration ---
if [ -n "$CUSTOM_CONFIG" ] && [ -f "$CUSTOM_CONFIG" ]; then
    cp "$CUSTOM_CONFIG" "$CONFIG_DEST"
else
    info "Generating standard reverse-proxy configuration..."
    cat > "$CONFIG_DEST" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
fi

# --- 5. Enable Site ---
info "Enabling site configuration..."
ln -sf "$CONFIG_DEST" "/etc/nginx/sites-enabled/"
# Remove default nginx welcome page to prevent conflicts on port 80
rm -f /etc/nginx/sites-enabled/default

# --- 6. Firewall Configuration ---
info "Configuring firewall for port $EXPOSED_PORT..."
if command -v ufw > /dev/null && ufw status | grep -q "active"; then
    ufw allow "$EXPOSED_PORT"/tcp > /dev/null
    ufw reload > /dev/null || true
elif systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --zone=public --add-port="$EXPOSED_PORT"/tcp > /dev/null
    firewall-cmd --reload > /dev/null
else
    warn "No active firewall (UFW/Firewalld) detected. Skipping firewall rules."
fi

# --- 7. Test and Restart ---
info "Testing Nginx configuration..."
if nginx -t; then
    success "Configuration syntax is okay."
    systemctl enable nginx > /dev/null
    systemctl restart nginx
    success "Nginx restarted successfully."
else
    error "Nginx configuration test failed! Check the output above. Rolling back is manual."
fi

# --- 8. Health Check ---
echo -e "\n${CYAN}=== Performing Health Check ===${NC}"
# Wait 2 seconds for Nginx to fully spin up
sleep 2

if [ "$DOMAIN" != "custom-domain" ]; then
    TARGET="http://$DOMAIN:$EXPOSED_PORT"
else
    TARGET="http://localhost:$EXPOSED_PORT"
fi

info "Pinging $TARGET..."
HTTP_STATUS=$(curl -o /dev/null -s -w "%{http_code}\n" --max-time 5 "$TARGET")

if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 400 ]; then
    success "Health Check Passed! Received HTTP $HTTP_STATUS."
elif [ "$HTTP_STATUS" -eq 502 ]; then
    warn "Health Check: Received 502 Bad Gateway."
    echo "       Nginx is running, but your backend service on port $APP_PORT might be down."
else
    warn "Health Check returned HTTP $HTTP_STATUS (or timed out). Verify your DNS or backend app."
fi

echo -e "\n========================================================================"
success "DEPLOYMENT COMPLETE"
echo -e "========================================================================"
echo -e "${YELLOW}Site Name    :${NC} $APP_NAME"
if [ -z "$CUSTOM_CONFIG" ]; then
    echo -e "${YELLOW}Routing      :${NC} $DOMAIN -> localhost:$APP_PORT"
fi
echo -e "${YELLOW}Config Path  :${NC} $CONFIG_DEST"
echo -e "========================================================================\n"