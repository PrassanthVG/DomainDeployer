#!/bin/bash

# ==============================================================================
# Autonomous PostgreSQL Installer
# Supports: Ubuntu, Debian, CentOS, RHEL
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

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    error "Unsupported Linux distribution."
fi

# --- 1. Prompt for Password Before Starting ---
echo -e "${CYAN}========================================================================${NC}"
echo -e "${YELLOW}Please define a password for the default 'postgres' database admin user.${NC}"
echo -e "${CYAN}========================================================================${NC}"
while true; do
    read -s -p "Enter Password: " DB_PASS1
    echo
    read -s -p "Confirm Password: " DB_PASS2
    echo
    if [ "$DB_PASS1" = "$DB_PASS2" ] && [ -n "$DB_PASS1" ]; then
        DB_PASSWORD=$DB_PASS1
        success "Password captured securely."
        break
    else
        warn "Passwords do not match or are empty. Please try again."
    fi
done
echo -e "${CYAN}========================================================================${NC}\n"

# --- 2. Installation ---
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    info "Detected Debian/Ubuntu. Installing PostgreSQL..."
    apt-get update -y -q > /dev/null
    apt-get install -y -q postgresql postgresql-contrib > /dev/null
    
    # Locate configuration files dynamically for Ubuntu/Debian
    PG_VERSION=$(ls /etc/postgresql/ | sort -V | tail -n 1)
    PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
    HBA_CONF="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
    info "Detected RHEL/CentOS. Installing PostgreSQL..."
    PM=$([ -x "$(command -v dnf)" ] && echo "dnf" || echo "yum")
    $PM install -y -q postgresql-server postgresql-contrib > /dev/null
    
    info "Initializing database cluster..."
    postgresql-setup --initdb > /dev/null
    
    PG_CONF="/var/lib/pgsql/data/postgresql.conf"
    HBA_CONF="/var/lib/pgsql/data/pg_hba.conf"
else
    error "OS not strictly supported by this script."
fi

# --- 3. Start Service to Set Password ---
info "Ensuring PostgreSQL service is running..."
systemctl enable postgresql > /dev/null
systemctl start postgresql > /dev/null

# --- 4. Set the User Password ---
info "Setting password for the 'postgres' user..."
# We use sudo -u postgres psql to access the local socket without needing a password yet
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${DB_PASSWORD}';" > /dev/null
success "Password updated successfully."

# --- 5. Configure Network Listeners ---
info "Configuring PostgreSQL to listen on all IP addresses..."

# Append listen_addresses to the bottom of the conf file (overrides earlier entries)
echo "listen_addresses = '*'" >> "$PG_CONF"

info "Updating pg_hba.conf to allow remote password authentication..."
# Allow remote connections from any IP using password encryption
echo "host    all             all             0.0.0.0/0               scram-sha-256" >> "$HBA_CONF"
# Fallback to md5 for older clients just in case
echo "host    all             all             0.0.0.0/0               md5" >> "$HBA_CONF"

# --- 6. Apply Network Changes ---
info "Restarting PostgreSQL to apply network configurations..."
systemctl restart postgresql > /dev/null

# --- Verification ---
if systemctl is-active --quiet postgresql; then
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
    echo -e "\n========================================================================"
    success "POSTGRESQL INSTALLATION COMPLETE!"
    echo -e "========================================================================"
    echo -e "${YELLOW}Host / IP Address :${NC} ${IP_ADDRESS}"
    echo -e "${YELLOW}Port              :${NC} 5432"
    echo -e "${YELLOW}Database User     :${NC} postgres"
    echo -e "${YELLOW}Password          :${NC} [Hidden for security]"
    echo -e "========================================================================"
    warn "The database is now accepting connections from ANY IP (0.0.0.0/0)."
    warn "Ensure your firewall only allows trusted connections to port 5432."
else
    error "PostgreSQL failed to restart after configuration changes."
fi