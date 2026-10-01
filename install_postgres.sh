#!/bin/bash

# ==============================================================================
# Autonomous PostgreSQL Installer & Remote Access Configurator
# Supports: Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux, Amazon Linux, Fedora
# ==============================================================================

set -e
trap 'error "PostgreSQL installation aborted on line $LINENO. Check network or repository settings."' ERR

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

# --- Pre-flight Checks ---
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
        error "Unsupported or unidentifiable Linux distribution (/etc/os-release not found)."
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

check_port_conflict() {
    local PORT=5432
    local IN_USE=""
    if command -v ss > /dev/null 2>&1; then
        IN_USE=$(ss -tlpn 2>/dev/null | grep ":$PORT " || true)
    elif command -v netstat > /dev/null 2>&1; then
        IN_USE=$(netstat -tlpn 2>/dev/null | grep ":$PORT " || true)
    fi

    if [ -n "$IN_USE" ]; then
        warn "Port $PORT is already in use by another service:"
        echo "$IN_USE"
        warn "If PostgreSQL is already installed, this script will update its configuration."
    fi
}

# --- Password Setup Prompt ---
capture_password() {
    # If DB_PASSWORD environment variable is already provided (e.g. non-interactive script), use it
    if [ -n "${DB_PASSWORD:-}" ]; then
        info "Database password provided via environment variable."
        return 0
    fi

    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${YELLOW}${BOLD}Please define a password for the default 'postgres' database admin user.${NC}"
    echo -e "${CYAN}========================================================================${NC}"

    while true; do
        read -s -p "Enter Password: " DB_PASS1
        echo
        read -s -p "Confirm Password: " DB_PASS2
        echo
        if [ "$DB_PASS1" = "$DB_PASS2" ] && [ -n "$DB_PASS1" ]; then
            DB_PASSWORD="$DB_PASS1"
            success "Password captured securely."
            break
        else
            warn "Passwords do not match or are empty. Please try again."
        fi
    done
    echo -e "${CYAN}========================================================================${NC}\n"
}

# --- Installation Modules ---
install_debian() {
    info "Detected Debian/Ubuntu family ($OS)..."
    wait_for_package_locks

    info "Updating package lists..."
    apt-get update -y -q > /dev/null || true

    info "Installing PostgreSQL server and contrib packages..."
    apt-get install -y -q postgresql postgresql-contrib curl ufw > /dev/null

    # Locate configuration files dynamically
    PG_VERSION=$(ls -1 /etc/postgresql/ 2>/dev/null | sort -V | tail -n 1)
    if [ -z "$PG_VERSION" ]; then
        error "Could not locate PostgreSQL installation directory in /etc/postgresql/"
    fi

    PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
    HBA_CONF="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
    PG_SERVICE="postgresql"
}

install_rhel() {
    info "Detected RHEL/CentOS/Fedora family ($OS)..."
    wait_for_package_locks

    PM=$([ -x "$(command -v dnf)" ] && echo "dnf" || echo "yum")

    info "Installing PostgreSQL server via $PM..."
    $PM install -y -q postgresql-server postgresql-contrib > /dev/null

    # Initialize DB cluster if not already initialized
    info "Checking database cluster initialization..."
    if [ -x /usr/bin/postgresql-setup ]; then
        /usr/bin/postgresql-setup --initdb > /dev/null 2>&1 || true
    elif [ -x /usr/bin/postgresql-initdb ]; then
        /usr/bin/postgresql-initdb > /dev/null 2>&1 || true
    fi

    # Locate config files for RHEL
    if [ -f /var/lib/pgsql/data/postgresql.conf ]; then
        PG_CONF="/var/lib/pgsql/data/postgresql.conf"
        HBA_CONF="/var/lib/pgsql/data/pg_hba.conf"
    else
        PG_CONF=$(find /var/lib/pgsql/ -name "postgresql.conf" 2>/dev/null | head -n 1)
        HBA_CONF=$(find /var/lib/pgsql/ -name "pg_hba.conf" 2>/dev/null | head -n 1)
    fi

    PG_SERVICE="postgresql"
}

# --- Configuration & Network Setup ---
configure_postgresql() {
    info "Locating configuration files..."
    if [ ! -f "$PG_CONF" ] || [ ! -f "$HBA_CONF" ]; then
        error "PostgreSQL configuration files could not be located ($PG_CONF, $HBA_CONF)."
    fi

    info "Configuring postgresql.conf listen_addresses..."
    # Idempotent replacement of listen_addresses
    if grep -q "^[# ]*listen_addresses" "$PG_CONF"; then
        sed -i "s/^[# ]*listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"
    else
        echo "listen_addresses = '*'" >> "$PG_CONF"
    fi

    info "Configuring pg_hba.conf for remote password access..."
    # Idempotent addition to pg_hba.conf
    if ! grep -q "0.0.0.0/0.*scram-sha-256" "$HBA_CONF" && ! grep -q "0.0.0.0/0.*md5" "$HBA_CONF"; then
        cat >> "$HBA_CONF" <<'EOF'

# --- Autonomous Deployment Remote Access Rules ---
host    all             all             0.0.0.0/0               scram-sha-256
host    all             all             0.0.0.0/0               md5
host    all             all             ::/0                    scram-sha-256
host    all             all             ::/0                    md5
EOF
    fi
}

configure_firewall() {
    info "Configuring firewall for PostgreSQL (Port 5432)..."
    if command -v ufw > /dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 5432/tcp > /dev/null || true
        ufw reload > /dev/null || true
        success "UFW port 5432 opened."
    elif command -v firewall-cmd > /dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --zone=public --add-port=5432/tcp > /dev/null || true
        firewall-cmd --reload > /dev/null || true
        success "Firewalld port 5432 opened."
    else
        info "No active local firewall found (UFW/Firewalld). Skipping local rule."
    fi
}

start_and_set_password() {
    info "Starting PostgreSQL service ($PG_SERVICE)..."
    if command -v systemctl > /dev/null 2>&1; then
        systemctl enable "$PG_SERVICE" > /dev/null 2>&1 || true
        systemctl restart "$PG_SERVICE"
    else
        service "$PG_SERVICE" restart || true
    fi

    info "Setting password for 'postgres' user..."
    # Escape single quotes in password to prevent SQL syntax errors
    ESCAPED_PW=$(echo "$DB_PASSWORD" | sed "s/'/''/g")
    sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$ESCAPED_PW';" > /dev/null
    success "Admin user password updated successfully."
}

# --- Main Flow ---
main() {
    echo -e "${CYAN}Starting Autonomous PostgreSQL Setup...${NC}"
    check_root
    detect_os
    check_port_conflict
    capture_password

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

    configure_postgresql
    start_and_set_password
    configure_firewall

    # Get primary IP
    IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$IP_ADDRESS" ]; then IP_ADDRESS="127.0.0.1"; fi

    echo -e "\n========================================================================"
    success "POSTGRESQL INSTALLATION & REMOTE CONFIGURATION COMPLETE!"
    echo -e "========================================================================"
    echo -e "${YELLOW}Host / IP Address :${NC} ${IP_ADDRESS}"
    echo -e "${YELLOW}Port              :${NC} 5432"
    echo -e "${YELLOW}Database User     :${NC} postgres"
    echo -e "${YELLOW}Password          :${NC} [Hidden for security]"
    echo -e "========================================================================"
    echo -e "${CYAN}[NOTE]${NC} Accepting remote connections on port 5432. Ensure your cloud"
    echo -e "       Security Group (AWS/Azure/GCP) allows traffic on port 5432 if needed."
    echo -e "========================================================================\n"
}

main "$@"