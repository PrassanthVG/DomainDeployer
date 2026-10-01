#!/bin/bash

# ==============================================================================
# Autonomous Deployment Orchestrator - Interactive Terminal UI (TUI)
# Repository: PrassanthVG/DomainDeployer
# Handles: All VM architectures, cloud providers, and edge-case exceptions
# ==============================================================================

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/domain_deployer"

# --- Styling & Colors ---
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# UTF-8 vs ASCII Fallback Check
if [[ "${LANG:-}" =~ [Uu][Tt][Ff]-?8 ]] || [[ "${LC_ALL:-}" =~ [Uu][Tt][Ff]-?8 ]]; then
    CHECK_MARK="✔"
    CROSS_MARK="✖"
    ARROW_MARK="❯"
    BULLET_MARK="●"
else
    CHECK_MARK="X"
    CROSS_MARK="!"
    ARROW_MARK=">"
    BULLET_MARK="*"
fi

# --- Pre-flight System & VM Diagnostics ---
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR]${NC} Administrative privileges required to configure system services."
        echo -e "Please run the orchestrator with sudo: ${CYAN}sudo ./orchestrator.sh${NC}\n"
        exit 1
    fi
}

detect_vm_environment() {
    # 1. OS Detection
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        VM_OS_NAME="${PRETTY_NAME:-$ID}"
        VM_OS_ID="$ID"
    else
        VM_OS_NAME="Generic Linux"
        VM_OS_ID="unknown"
    fi

    # 2. Architecture
    VM_ARCH=$(uname -m 2>/dev/null || echo "unknown")

    # 3. Systemd / Init System
    if pidof systemd > /dev/null 2>&1 || [ -d /run/systemd/system ]; then
        VM_INIT="systemd"
    else
        VM_INIT="non-systemd"
    fi

    # 4. RAM and Swap
    VM_RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    VM_RAM_MB=${VM_RAM_MB:-0}
    VM_SWAP_MB=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')
    VM_SWAP_MB=${VM_SWAP_MB:-0}

    # 5. Free Disk Space on / (in GB)
    VM_DISK_FREE_GB=$(df -BG / 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
    VM_DISK_FREE_GB=${VM_DISK_FREE_GB:-0}

    # 6. Cloud Provider Hint
    VM_CLOUD="Local / Virtual Machine"
    if [ -f /sys/class/dmi/id/product_name ]; then
        local PROD
        PROD=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
        if [[ "$PROD" =~ Amazon|EC2 ]]; then VM_CLOUD="AWS EC2"; fi
        if [[ "$PROD" =~ Microsoft|Virtual ]]; then VM_CLOUD="Azure VM"; fi
        if [[ "$PROD" =~ Google ]]; then VM_CLOUD="Google Cloud (GCP)"; fi
        if [[ "$PROD" =~ DigitalOcean ]]; then VM_CLOUD="DigitalOcean Droplet"; fi
    fi
}

run_vm_diagnostics_report() {
    echo -e "${CYAN}┌───────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${WHITE}${BOLD}                           VM SYSTEM DIAGNOSTICS                               ${NC}${CYAN}│${NC}"
    echo -e "${CYAN}├───────────────────────────────────────────────────────────────────────────────┤${NC}"
    printf " ${CYAN}│${NC} %-18s : ${WHITE}%-54s${NC} ${CYAN}│${NC}\n" "Operating System" "$VM_OS_NAME ($VM_ARCH)"
    printf " ${CYAN}│${NC} %-18s : ${WHITE}%-54s${NC} ${CYAN}│${NC}\n" "Cloud Platform" "$VM_CLOUD"
    printf " ${CYAN}│${NC} %-18s : ${WHITE}%-54s${NC} ${CYAN}│${NC}\n" "Memory (RAM / Swap)" "${VM_RAM_MB}MB RAM / ${VM_SWAP_MB}MB Swap"
    printf " ${CYAN}│${NC} %-18s : ${WHITE}%-54s${NC} ${CYAN}│${NC}\n" "Root Disk Free" "${VM_DISK_FREE_GB} GB Available"
    printf " ${CYAN}│${NC} %-18s : ${WHITE}%-54s${NC} ${CYAN}│${NC}\n" "Service Manager" "$VM_INIT"
    echo -e "${CYAN}└───────────────────────────────────────────────────────────────────────────────┘${NC}"

    # Space & RAM warnings
    if [ "$VM_DISK_FREE_GB" -lt 2 ] 2>/dev/null; then
        echo -e "${YELLOW}[WARNING] Low disk space (${VM_DISK_FREE_GB}GB). Package installations may fail.${NC}"
    fi

    if [ "$VM_RAM_MB" -lt 1200 ] 2>/dev/null && [ "$VM_SWAP_MB" -lt 512 ] 2>/dev/null; then
        echo -e "${YELLOW}[NOTICE] Low RAM (${VM_RAM_MB}MB). Jenkins installer will automatically optimize swap.${NC}"
    fi
    echo ""
}

# --- Service Catalog Definition ---
SERVICE_NAMES=(
    "Docker Engine & Docker Compose"
    "Jenkins CI/CD Server (Java 21)"
    "PostgreSQL Database Server"
    "Nginx Reverse Proxy"
    "Jenkins Authentication Recovery"
)

# Canonical scripts with fallback handling for typos
SERVICE_SCRIPTS=(
    "install_docker.sh"
    "install_jenkins.sh"
    "install_postgres.sh"
    "install_ngnix.sh"
    "Jenkins_Authentication_Recovery.sh"
)

SERVICE_DESCRIPTIONS=(
    "Official Docker Engine, Compose plugin, group permissions (Multi-Arch)"
    "Java 21 LTS, Jenkins service, sudoers & docker group rights, port 8080"
    "PostgreSQL 14-16 server, remote access configuration, port 5432"
    "Reverse proxy, automated sites-enabled, SELinux proxying, health check"
    "Emergency rescue tool: disables auth in config.xml with automated backup"
)

TOTAL_SERVICES=${#SERVICE_NAMES[@]}
SELECTED=(0 0 0 0 0)
CURSOR=0

# Clean up cursor and terminal state on exit
cleanup() {
    tput cnorm 2>/dev/null || printf "\033[?25h"
    echo -e "${NC}"
}
trap cleanup EXIT INT TERM

# --- Key Capture Function ---
read_key() {
    local key=""
    local rest=""
    IFS= read -rsn1 key 2>/dev/null
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 -t 0.05 rest 2>/dev/null
        key+="$rest"
    fi
    printf "%s" "$key"
}

# --- TUI Drawing Functions ---
draw_header() {
    clear
    # 1. Branding ASCII Logo
    echo -e "${CYAN}"
    cat << 'EOF'
    ____                        _         ____             _                       
   / __ \____  ____ ___  ____ _(_)___    / __ \___  ____  / /___  __  _____  _____ 
  / / / / __ \/ __ `__ \/ __ `/ / __ \  / / / / _ \/ __ \/ / __ \/ / / / _ \/ ___/ 
 / /_/ / /_/ / / / / / / /_/ / / / / / / /_/ /  __/ /_/ / / /_/ / /_/ /  __/ /     
/_____/\____/_/ /_/ /_/\__,_/_/_/ /_/ /_____/\___/ .___/_/\____/\__, /\___/_/      
                                                /_/            /____/              
EOF
    echo -e "${NC}"

    # 2. Application Identity & Simple Guide Box
    echo -e "${CYAN}┌───────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${WHITE}${BOLD} APPLICATION  :${NC} ${GREEN}${BOLD}DomainDeployer (Autonomous Infrastructure Orchestrator)       ${NC}${CYAN}│${NC}"
    echo -e "${CYAN}│${WHITE}${BOLD} WHAT IT DOES :${NC} Multi-service provisioning tool for fresh Linux servers.       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}                Automatically detects OS/VM architecture, configures           ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}                firewalls, and batch-installs Docker, Jenkins, PostgreSQL,     ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}                and Nginx with a single interactive terminal command.          ${CYAN}│${NC}"
    echo -e "${CYAN}├───────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${YELLOW}${BOLD} SIMPLE GUIDE :                                                                ${NC}${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  1. Grant execution rights : ${CYAN}chmod +x *.sh${NC}                                    ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  2. Launch Terminal UI     : ${CYAN}sudo ./orchestrator.sh${NC}                           ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  3. Select services        : ${WHITE}[Space]${NC} toggle, ${WHITE}[a]${NC} all, ${WHITE}[Enter]${NC} deploy          ${CYAN}│${NC}"
    echo -e "${CYAN}└───────────────────────────────────────────────────────────────────────────────┘${NC}"

    # 3. System Diagnostics Report
    run_vm_diagnostics_report
    echo -e " ${BOLD}Select the infrastructure services to install on this machine:${NC}\n"
}

draw_menu() {
    for i in $(seq 0 $((TOTAL_SERVICES - 1))); do
        local is_selected=${SELECTED[$i]}
        local is_cursor=$([ $i -eq $CURSOR ] && echo 1 || echo 0)

        local checkbox=""
        if [ "$is_selected" -eq 1 ]; then
            checkbox="${GREEN}[${BOLD}${CHECK_MARK}${NC}${GREEN}]${NC}"
        else
            checkbox="${DIM}[ ]${NC}"
        fi

        local pointer="  "
        local title_color="${WHITE}"
        local desc_color="${DIM}"

        if [ "$is_cursor" -eq 1 ]; then
            pointer="${CYAN}${BOLD}${ARROW_MARK} ${NC}"
            title_color="${CYAN}${BOLD}"
            desc_color="${YELLOW}"
        fi

        echo -e "${pointer}${checkbox} ${BOLD}$((i + 1)). ${title_color}${SERVICE_NAMES[$i]}${NC}"
        echo -e "       ${desc_color}↳ Script: ${SERVICE_SCRIPTS[$i]} | ${SERVICE_DESCRIPTIONS[$i]}${NC}"
        echo ""
    done

    echo -e "${CYAN}─────────────────────────────────────────────────────────────────────────────────${NC}"
    echo -e " ${BOLD}Keyboard Controls:${NC}"
    echo -e "   ${CYAN}[↑ / k]${NC} Up     ${CYAN}[↓ / j]${NC} Down    ${CYAN}[Space]${NC} Toggle Item    ${CYAN}[1-5]${NC} Toggle Item #"
    echo -e "   ${CYAN}[a]${NC}     All    ${CYAN}[Enter]${NC} Deploy  ${CYAN}[q / Esc]${NC} Cancel"
    echo -e "${CYAN}─────────────────────────────────────────────────────────────────────────────────${NC}"

    local count=0
    for s in "${SELECTED[@]}"; do
        if [ "$s" -eq 1 ]; then ((count++)); fi
    done

    if [ "$count" -eq 0 ]; then
        echo -e " Current selection: ${YELLOW}None${NC} (Select at least 1 service to proceed)"
    else
        echo -e " Current selection: ${GREEN}${BOLD}${count} service(s) selected${NC}"
    fi
}

# --- Interactive TUI Event Loop ---
run_interactive_menu() {
    tput civis 2>/dev/null || printf "\033[?25l"

    while true; do
        draw_header
        draw_menu

        local key
        key=$(read_key)

        case "$key" in
            # Arrow Up or 'k' or 'K'
            $'\x1b[A'|k|K)
                if [ $CURSOR -gt 0 ]; then
                    ((CURSOR--))
                else
                    CURSOR=$((TOTAL_SERVICES - 1))
                fi
                ;;

            # Arrow Down or 'j' or 'J'
            $'\x1b[B'|j|J)
                if [ $CURSOR -lt $((TOTAL_SERVICES - 1)) ]; then
                    ((CURSOR++))
                else
                    CURSOR=0
                fi
                ;;

            # Spacebar - Toggle current item
            " ")
                if [ ${SELECTED[$CURSOR]} -eq 1 ]; then
                    SELECTED[$CURSOR]=0
                else
                    SELECTED[$CURSOR]=1
                fi
                ;;

            # Direct Number Toggle (1-5)
            1|2|3|4|5)
                local idx=$((key - 1))
                if [ $idx -lt $TOTAL_SERVICES ]; then
                    CURSOR=$idx
                    if [ ${SELECTED[$idx]} -eq 1 ]; then
                        SELECTED[$idx]=0
                    else
                        SELECTED[$idx]=1
                    fi
                fi
                ;;

            # 'a' or 'A' - Toggle All
            a|A)
                local any_unselected=0
                for s in "${SELECTED[@]}"; do
                    if [ "$s" -eq 0 ]; then any_unselected=1; break; fi
                done
                for i in $(seq 0 $((TOTAL_SERVICES - 1))); do
                    SELECTED[$i]=$any_unselected
                done
                ;;

            # Enter Key - Confirm and Execute
            ""|$'\n')
                local selected_count=0
                for s in "${SELECTED[@]}"; do
                    if [ "$s" -eq 1 ]; then ((selected_count++)); fi
                done

                if [ $selected_count -eq 0 ]; then
                    echo -e "\n${YELLOW}[!] Please select at least one service before proceeding.${NC}"
                    sleep 1.2
                else
                    break
                fi
                ;;

            # 'q' or 'Q' or Esc - Quit
            q|Q|$'\x1b')
                cleanup
                echo -e "\n${YELLOW}Orchestration cancelled by user. No actions were performed.${NC}\n"
                exit 0
                ;;
        esac
    done

    cleanup
}

# --- Fallback Mode for Non-Interactive Shells / Pipes ---
run_fallback_menu() {
    echo -e "\n${CYAN}=== Available Services (Non-Interactive Mode) ===${NC}"
    for i in $(seq 0 $((TOTAL_SERVICES - 1))); do
        echo -e "  $((i + 1))) ${SERVICE_NAMES[$i]} (${SERVICE_SCRIPTS[$i]})"
    done
    echo ""
    read -p "Enter numbers to install (e.g. 1 2 4) or 'all': " choice

    if [ "$choice" = "all" ]; then
        for i in $(seq 0 $((TOTAL_SERVICES - 1))); do SELECTED[$i]=1; done
    else
        for num in $choice; do
            if [[ "$num" =~ ^[1-5]$ ]]; then
                SELECTED[$((num - 1))]=1
            fi
        done
    fi
}

# --- Robust Service Execution Pipeline ---
execute_services() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}${BOLD}                       STARTING DEPLOYMENT PIPELINE                            ${NC}${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════════════╝${NC}\n"

    mkdir -p "$LOG_DIR"

    local QUEUE_INDICES=()
    for i in $(seq 0 $((TOTAL_SERVICES - 1))); do
        if [ ${SELECTED[$i]} -eq 1 ]; then
            QUEUE_INDICES+=("$i")
        fi
    done

    local TOTAL_QUEUE=${#QUEUE_INDICES[@]}

    echo -e "${BOLD}Queued for execution (${TOTAL_QUEUE} service(s)):${NC}"
    for idx in "${QUEUE_INDICES[@]}"; do
        echo -e "  ${GREEN}${BULLET_MARK}${NC} ${BOLD}${SERVICE_NAMES[$idx]}${NC} (${SERVICE_SCRIPTS[$idx]})"
    done
    echo ""
    read -p "Press [Enter] to begin deployment, or Ctrl+C to abort... " confirm
    echo ""

    local SUMMARY_NAME=()
    local SUMMARY_STATUS=()
    local SUMMARY_TIME=()
    local SUMMARY_LOG=()

    local STEP=1

    for idx in "${QUEUE_INDICES[@]}"; do
        local name="${SERVICE_NAMES[$idx]}"
        local script="${SERVICE_SCRIPTS[$idx]}"
        local full_path="$SCRIPT_DIR/$script"

        # Handle typo aliases if script not found under primary name
        if [ ! -f "$full_path" ]; then
            if [ "$script" = "install_ngnix.sh" ] && [ -f "$SCRIPT_DIR/install_nginx.sh" ]; then
                full_path="$SCRIPT_DIR/install_nginx.sh"
            fi
        fi

        local LOG_FILE="$LOG_DIR/$(date +%Y%m%d_%H%M%S)_${script%.sh}.log"

        echo -e "\n${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e " ${BOLD}[Step ${STEP}/${TOTAL_QUEUE}] Executing: ${WHITE}${name}${NC}"
        echo -e " Script : ${full_path}"
        echo -e " Log    : ${LOG_FILE}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}\n"

        if [ ! -f "$full_path" ]; then
            echo -e "${RED}[ERROR] Script not found: $full_path${NC}"
            SUMMARY_NAME+=("$name")
            SUMMARY_STATUS+=("${RED}NOT FOUND${NC}")
            SUMMARY_TIME+=("0s")
            SUMMARY_LOG+=("N/A")
            ((STEP++))
            continue
        fi

        chmod +x "$full_path"

        local START_TIME
        START_TIME=$(date +%s)
        local EXIT_CODE=0

        # Special handling for Nginx template detection
        if [[ "$script" =~ ngn?ix ]]; then
            local TEMPLATE=""
            if [ -f "$SCRIPT_DIR/nginx.conf" ]; then
                TEMPLATE="$SCRIPT_DIR/nginx.conf"
            elif [ -f "$SCRIPT_DIR/ngnix.config" ]; then
                TEMPLATE="$SCRIPT_DIR/ngnix.config"
            fi

            if [ -n "$TEMPLATE" ]; then
                echo -e "${YELLOW}[!] Reverse Proxy Template Detected:${NC} $TEMPLATE"
                read -p "    Deploy using this template file? [Y/n]: " use_tmpl
                use_tmpl=${use_tmpl:-Y}
                if [[ "$use_tmpl" =~ ^[Yy]$ ]]; then
                    bash "$full_path" "$TEMPLATE" 2>&1 | tee -a "$LOG_FILE" || EXIT_CODE=${PIPESTATUS[0]}
                else
                    bash "$full_path" 2>&1 | tee -a "$LOG_FILE" || EXIT_CODE=${PIPESTATUS[0]}
                fi
            else
                bash "$full_path" 2>&1 | tee -a "$LOG_FILE" || EXIT_CODE=${PIPESTATUS[0]}
            fi
        else
            bash "$full_path" 2>&1 | tee -a "$LOG_FILE" || EXIT_CODE=${PIPESTATUS[0]}
        fi

        local END_TIME
        END_TIME=$(date +%s)
        local DURATION=$((END_TIME - START_TIME))

        SUMMARY_NAME+=("$name")
        SUMMARY_TIME+=("${DURATION}s")
        SUMMARY_LOG+=("$LOG_FILE")

        if [ $EXIT_CODE -eq 0 ]; then
            echo -e "\n${GREEN}${BOLD}${CHECK_MARK} [Step ${STEP}/${TOTAL_QUEUE}] Successfully completed ${name} in ${DURATION}s.${NC}"
            SUMMARY_STATUS+=("${GREEN}SUCCESS${NC}")
        else
            echo -e "\n${RED}${BOLD}${CROSS_MARK} [Step ${STEP}/${TOTAL_QUEUE}] FAILED: ${name} exited with error code ${EXIT_CODE}.${NC}"
            echo -e "Review log details at: ${CYAN}$LOG_FILE${NC}"
            SUMMARY_STATUS+=("${RED}FAILED (Exit $EXIT_CODE)${NC}")

            if [ $STEP -lt $TOTAL_QUEUE ]; then
                echo ""
                read -p "Do you want to continue running the remaining selected tasks? [y/N]: " cont_choice
                if [[ ! "$cont_choice" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Deployment halted by user.${NC}"
                    break
                fi
            fi
        fi

        ((STEP++))
    done

    # --- Summary Dashboard Report ---
    echo -e "\n\n${CYAN}╔═══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}${BOLD}                         ORCHESTRATION SUMMARY REPORT                          ${NC}${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════════════╝${NC}\n"

    printf " %-34s | %-18s | %-10s\n" "Service Name" "Status" "Duration"
    echo -e " -----------------------------------+--------------------+------------"

    for i in "${!SUMMARY_NAME[@]}"; do
        printf " %-34s | %-27b | %-10s\n" "${SUMMARY_NAME[$i]}" "${SUMMARY_STATUS[$i]}" "${SUMMARY_TIME[$i]}"
    done
    echo ""
    echo -e "Execution logs saved to: ${CYAN}$LOG_DIR/${NC}\n"
}

# --- Main Entry Point ---
main() {
    check_root
    detect_vm_environment

    if [ -t 0 ]; then
        run_interactive_menu
    else
        run_fallback_menu
    fi

    execute_services
}

main "$@"
