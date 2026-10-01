# DomainDeployer

```text
    ____                        _         ____             _                       
   / __ \____  ____ ___  ____ _(_)___    / __ \___  ____  / /___  __  _____  _____ 
  / / / / __ \/ __ `__ \/ __ `/ / __ \  / / / / _ \/ __ \/ / __ \/ / / / _ \/ ___/ 
 / /_/ / /_/ / / / / / / /_/ / / / / / / /_/ /  __/ /_/ / / /_/ / /_/ /  __/ /     
/_____/\____/_/ /_/ /_/\__,_/_/_/ /_/ /_____/\___/ .___/_/\____/\__, /\___/_/      
                                                /_/            /____/              
```

```text
┌───────────────────────────────────────────────────────────────────────────────┐
│ APPLICATION  : DomainDeployer (Autonomous Infrastructure Orchestrator)        │
│ WHAT IT DOES : Multi-service provisioning tool for fresh Linux servers.       │
│                Automatically detects OS/VM architecture, configures           │
│                firewalls, and batch-installs Docker, Jenkins, PostgreSQL,     │
│                and Nginx with a single interactive terminal command.          │
├───────────────────────────────────────────────────────────────────────────────┤
│ SIMPLE GUIDE :                                                                │
│  1. Grant execution rights : chmod +x *.sh                                    │
│  2. Launch Terminal UI     : sudo ./orchestrator.sh                           │
│  3. Select services        : [Space] toggle, [a] all, [Enter] deploy          │
└───────────────────────────────────────────────────────────────────────────────┘
```

This repository provides an autonomous, cross-distro infrastructure orchestration suite for setting up essential DevOps services on fresh Linux Virtual Machines. All scripts automatically detect the Linux distribution (Debian/Ubuntu vs. RHEL/CentOS/Amazon Linux families), configure local firewalls, handle VM edge cases, and perform post-installation validation.

## Interactive Orchestrator (Recommended)

### `orchestrator.sh`
**Purpose:** Interactive Terminal UI (TUI) to multi-select and batch-deploy infrastructure services.
**Features:**
- **Terminal UI (TUI):** Built-in ANSI checkbox menu with zero external dependencies (no need to pre-install `whiptail` or `dialog`).
- **Multi-Selection:** Use `[Space]` or direct number keys `[1-5]` to select multiple services, `[a]` to select all, and `[Enter]` to trigger automated execution.
- **Execution Pipeline:** Sequential execution with live progress reporting, automated Nginx template detection (`ngnix.config`), error handling with pause/continue controls, and an end-of-run Summary Dashboard.

---

## Individual Scripts Overview

### 1. `install_docker.sh`
**Purpose:** Installs Docker Engine and Docker Compose.
**Features:**
- Removes conflicting old versions (e.g., `podman-docker`, `docker.io`).
- Automatically adds the official Docker GPG keys and repository.
- Enables and starts the Docker service.
- Grants the executing user passwordless access to run Docker commands by adding them to the `docker` group.

### 2. `install_postgres.sh`
**Purpose:** Installs PostgreSQL database server and configures it for remote access.
**Features:**
- Prompts for a secure password for the default `postgres` admin user before installation begins.
- Configures `postgresql.conf` to listen on all IP addresses (`listen_addresses = '*'`).
- Configures `pg_hba.conf` to allow password-based authentication (`scram-sha-256` / `md5`) from remote IP addresses.
- Restarts the service to apply network configurations and prints connection details.

### 3. `install_jenkins.sh`
**Purpose:** Installs Jenkins CI/CD server and Java dependencies.
**Features:**
- Installs Java 21 (OpenJDK) and Jenkins from the official Jenkins repositories.
- Automatically cleans up old/broken GPG keys and configures the correct repository.
- Opens port 8080 on the local firewall (`ufw` or `firewalld`).
- **CI/CD Ready:** Grants the `jenkins` user full passwordless `sudo` access and adds it to the `docker` group. This allows Jenkins pipelines to execute `sudo` and `docker` commands without permission errors.
- Waits for and outputs the Initial Admin Password upon completion.

### 4. `install_ngnix.sh` & `ngnix.config`
**Purpose:** Installs Nginx and deploys a reverse-proxy configuration.
**Features:**
- Installs Nginx and ensures the `sites-available` / `sites-enabled` architecture exists (even on RHEL/CentOS).
- Supports two modes of operation:
  - **Interactive Mode:** Prompts for domain, app name, and backend port to generate a standard reverse proxy configuration on the fly.
  - **Custom Config Mode:** Accepts a custom configuration file (like the provided `ngnix.config` template which routes traffic to different microservices like Frontend, API, and Auth) via command line.
- Backs up existing configurations before deploying.
- Verifies syntax (`nginx -t`) and performs an automated HTTP health check ping after reloading the service.

## Usage Instructions

1. **Make the scripts executable:**
   Before running any script for the first time, ensure it has execution permissions:
   ```bash
   chmod +x *.sh
   ```

2. **Run the Interactive Orchestrator (Recommended):**
   Launch the interactive Terminal UI to multi-select and batch deploy:
   ```bash
   sudo ./orchestrator.sh
   ```

3. **Or Run Individual Scripts Directly:**
   All scripts require root privileges to install packages and modify system configurations:
   ```bash
   sudo ./install_docker.sh
   sudo ./install_postgres.sh
   sudo ./install_jenkins.sh
   
   # For Nginx interactive mode:
   sudo ./install_ngnix.sh
   
   # For Nginx custom config mode:
   sudo ./install_ngnix.sh ./ngnix.config

   # For Jenkins Authentication Recovery:
   sudo ./Jenkins_Authentication_Recovery.sh
   ```

4. **VM and Cloud Considerations:**
   - **External Firewalls:** Ensure your cloud provider's Security Groups / Network Firewalls (e.g., AWS EC2 Security Groups, Azure NSGs) allow inbound traffic on the exposed ports (e.g., 80/8443 for Nginx, 8080 for Jenkins, 5432 for PostgreSQL).
   - **Internal Firewalls:** The scripts automatically configure local OS firewalls (`ufw` or `firewalld`) if active.
   - **Small VM Auto-Optimization:** Low-memory VMs (< 1.5GB RAM, such as AWS `t2.micro` or 1GB VPS instances) are automatically detected; Jenkins creates a swap file and tunes JVM heap size to prevent out-of-memory kernel termination.
   - **SELinux Policies:** On RHEL/CentOS/Rocky/Alma/Amazon Linux, reverse proxy network connect policies (`httpd_can_network_connect`) are automatically enabled.

## Supported Operating Systems & Architectures
- **Debian Family:** Ubuntu (18.04, 20.04, 22.04, 24.04), Debian (10, 11, 12), Linux Mint, Pop!_OS, Elementary OS, Kali
- **RHEL Family:** CentOS (7, 8, Stream 9), RHEL (7, 8, 9), Rocky Linux, AlmaLinux, Fedora
- **Cloud Distributions:** Amazon Linux 2 & Amazon Linux 2023, Oracle Linux (OL 7, 8, 9)
- **Architectures:** `x86_64` (`amd64`), `aarch64` (`arm64` / AWS Graviton / Apple Silicon VMs), `armhf`
