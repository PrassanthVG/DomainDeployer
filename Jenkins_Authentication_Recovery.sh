#!/bin/bash

# ==============================================================================
# Jenkins Authentication Recovery Tool
# Supports: Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux, Amazon Linux, Oracle
# ==============================================================================

set -e

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Pre-flight Root Check
if [ "$EUID" -ne 0 ]; then
    error "Please run this recovery script as root or using sudo: sudo $0"
fi

JENKINS_HOME="/var/lib/jenkins"
CONFIG="$JENKINS_HOME/config.xml"
BACKUP_DIR="/var/lib/jenkins-backup-$(date +%Y%m%d-%H%M%S)"

echo -e "${CYAN}========================================================================${NC}"
echo -e "${CYAN}                    Jenkins Authentication Recovery                     ${NC}"
echo -e "${CYAN}========================================================================${NC}\n"

# [1/7] Check Jenkins Service
info "[1/7] Checking Jenkins service status..."
if command -v systemctl > /dev/null 2>&1; then
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^jenkins\.service'; then
        if ! systemctl status jenkins > /dev/null 2>&1; then
            error "Jenkins service was not found in systemd units."
        fi
    fi
elif [ ! -f /etc/init.d/jenkins ]; then
    error "Jenkins service / init script was not found."
fi
success "Jenkins service identified."

# [2/7] Check Jenkins Directory & Config
info "[2/7] Checking Jenkins home directory and configuration..."
if [ ! -d "$JENKINS_HOME" ]; then
    error "Jenkins home directory ($JENKINS_HOME) does not exist."
fi

if [ ! -f "$CONFIG" ]; then
    error "Jenkins configuration file ($CONFIG) does not exist."
fi
success "Configuration found: $CONFIG"

# [3/7] Create Full Backup
info "[3/7] Creating configuration backup..."
mkdir -p "$BACKUP_DIR"
if cp -a "$CONFIG" "$BACKUP_DIR/config.xml.bak"; then
    # Also backup secrets if they exist
    if [ -d "$JENKINS_HOME/secrets" ]; then
        cp -a "$JENKINS_HOME/secrets" "$BACKUP_DIR/" 2>/dev/null || true
    fi
    success "Backup saved to: $BACKUP_DIR"
else
    error "Failed to create backup directory."
fi

# [4/7] Stop Jenkins
info "[4/7] Stopping Jenkins service..."
if command -v systemctl > /dev/null 2>&1; then
    systemctl stop jenkins
else
    service jenkins stop || true
fi
success "Jenkins service stopped."

# [5/7] Disable Jenkins Authentication in config.xml
info "[5/7] Modifying config.xml to disable authentication..."

if command -v python3 > /dev/null 2>&1; then
    # Preferred: Python XML-safe text replacement
    python3 - <<'PY'
from pathlib import Path
import sys

config_path = Path("/var/lib/jenkins/config.xml")
try:
    data = config_path.read_text(encoding="utf-8")
    if "<useSecurity>true</useSecurity>" in data:
        data = data.replace("<useSecurity>true</useSecurity>", "<useSecurity>false</useSecurity>")
        config_path.write_text(data, encoding="utf-8")
        print("SUCCESS: Authentication disabled via Python.")
    elif "<useSecurity>false</useSecurity>" in data:
        print("NOTICE: Authentication is already disabled.")
    else:
        print("WARNING: <useSecurity> tag was not found in config.xml.")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PY
else
    # Fallback: POSIX sed replacement (ensures script works on minimal VMs without python3)
    info "python3 not found. Falling back to sed stream editor..."
    if grep -q "<useSecurity>true</useSecurity>" "$CONFIG"; then
        sed -i.tmp 's|<useSecurity>true</useSecurity>|<useSecurity>false</useSecurity>|g' "$CONFIG"
        rm -f "$CONFIG.tmp"
        success "Authentication disabled via sed."
    elif grep -q "<useSecurity>false</useSecurity>" "$CONFIG"; then
        info "Authentication is already disabled."
    else
        warn "<useSecurity> tag not found in config.xml."
    fi
fi

# Fix ownership
chown -R jenkins:jenkins "$CONFIG" 2>/dev/null || true

# [6/7] Start Jenkins
info "[6/7] Starting Jenkins service..."
if command -v systemctl > /dev/null 2>&1; then
    systemctl start jenkins
else
    service jenkins start
fi

# [7/7] Wait and Verify Status
info "[7/7] Waiting for Jenkins service to become active..."
IS_ACTIVE=0
for i in {1..15}; do
    if command -v systemctl > /dev/null 2>&1; then
        if systemctl is-active --quiet jenkins; then
            IS_ACTIVE=1
            break
        fi
    elif service jenkins status > /dev/null 2>&1; then
        IS_ACTIVE=1
        break
    fi
    sleep 2
done

# Resolve Dynamic Host IP (Avoid hardcoded IP)
IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$IP_ADDRESS" ]; then
    IP_ADDRESS=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
fi
if [ -z "$IP_ADDRESS" ]; then
    IP_ADDRESS="localhost"
fi

if [ "$IS_ACTIVE" -eq 1 ]; then
    echo -e "\n${CYAN}========================================================================${NC}"
    success "JENKINS AUTHENTICATION DISABLED - RECOVERY READY"
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${YELLOW}Jenkins URL :${NC} http://${IP_ADDRESS}:8080"
    echo -e "${YELLOW}Backup Dir  :${NC} ${BACKUP_DIR}"
    echo -e "\n${BOLD}Next Steps:${NC}"
    echo -e " 1. Open the URL above in your browser (no login required)."
    echo -e " 2. Navigate to: ${CYAN}Manage Jenkins -> Security${NC}"
    echo -e " 3. Re-enable security realm, reset your admin password or API token."
    echo -e " 4. Save settings to secure your instance immediately."
    echo -e "${CYAN}========================================================================${NC}\n"
else
    echo -e "\n${RED}========================================================================${NC}"
    error "Jenkins failed to start after configuration edit."
    echo -e "To inspect detailed failure logs, run:"
    echo -e "  sudo journalctl -u jenkins -n 100 --no-pager"
    echo -e "\nTo restore from backup:"
    echo -e "  sudo cp $BACKUP_DIR/config.xml.bak $CONFIG"
    echo -e "  sudo systemctl restart jenkins"
    echo -e "${RED}========================================================================${NC}\n"
    exit 1
fi