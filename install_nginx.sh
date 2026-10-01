#!/bin/bash
# ==============================================================================
# Nginx Installer Alias (handles 'nginx' vs 'ngnix' typo seamlessly)
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/install_ngnix.sh" "$@"
