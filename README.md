# Autonomous Deployment Scripts

This directory contains a collection of autonomous deployment scripts for setting up essential infrastructure and dependencies on fresh Linux Virtual Machines. 

These scripts are designed to be robust, automatically detect the underlying operating system (Debian/Ubuntu vs. RHEL/CentOS families), handle prerequisites, manage firewalls, and perform necessary post-installation configurations.

## Scripts Overview

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
- Installs Java 17 and Jenkins from the official Jenkins repositories.
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
   chmod +x install_*.sh
   ```

2. **Run as Root/Sudo:**
   All scripts require root privileges to install packages and modify system configurations. Run them as follows:
   ```bash
   sudo ./install_docker.sh
   sudo ./install_postgres.sh
   sudo ./install_jenkins.sh
   
   # For Nginx interactive mode:
   sudo ./install_ngnix.sh
   
   # For Nginx custom config mode:
   sudo ./install_ngnix.sh ./ngnix.config
   ```

3. **VM and Cloud Considerations:**
   - **External Firewalls:** Ensure your cloud provider's Security Groups / Network Firewalls (e.g., AWS EC2 Security Groups, Azure NSGs) allow inbound traffic on the exposed ports (e.g., 80/8443 for Nginx, 8080 for Jenkins, 5432 for PostgreSQL).
   - **Internal Firewalls:** The scripts will attempt to configure local OS firewalls (`ufw` or `firewalld`) automatically if they are active.

## Supported Operating Systems
- **Debian-based:** Ubuntu, Debian, Linux Mint
- **RHEL-based:** CentOS, RHEL, Rocky Linux, AlmaLinux (and Fedora for Jenkins)
