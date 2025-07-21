#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Banner
echo -e "${BLUE}"
echo "==============================================="
echo "     Build Deploy (Oreon Build System)"
echo "          Quick Setup for EL9"
echo "==============================================="
echo -e "${NC}"

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    log_error "This script should NOT be run as root for security reasons."
    log_info "Please run as a regular user with sudo privileges."
    exit 1
fi

# Check if user has sudo access
if ! sudo -n true 2>/dev/null; then
    log_error "This script requires sudo privileges. Please ensure your user can run sudo commands."
    exit 1
fi

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to get user input with default
get_input() {
    local prompt="$1"
    local default="$2"
    local variable_name="$3"
    
    if [[ -n "$default" ]]; then
        read -p "$prompt [$default]: " input
        eval "$variable_name=\"\${input:-$default}\""
    else
        read -p "$prompt: " input
        eval "$variable_name=\"$input\""
    fi
}

# Function to get secret input
get_secret_input() {
    local prompt="$1"
    local variable_name="$2"
    
    read -s -p "$prompt: " input
    echo
    eval "$variable_name=\"$input\""
}

# Detect system info
log_info "Detecting system information..."
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_NAME="$NAME"
    OS_VERSION="$VERSION_ID"
else
    log_error "Cannot detect OS version. This script is designed for EL 9."
    exit 1
fi

log_info "Detected: $OS_NAME $OS_VERSION"

# Verify EL 9
if [[ "$ID" != "almalinux" ]] || [[ "$VERSION_ID" != "9"* ]]; then
    log_warning "This script is optimized for EL 9. Continue anyway? (y/N)"
    read -r continue_anyway
    if [[ "$continue_anyway" != "y" && "$continue_anyway" != "Y" ]]; then
        log_info "Deployment cancelled."
        exit 0
    fi
fi

# Check prerequisites and install if missing
log_info "Checking prerequisites..."

# Install Python3 and pip if not present
if ! command_exists python3; then
    log_info "Installing Python3..."
    sudo dnf install -y python3 python3-pip
fi

# Install git if not present
if ! command_exists git; then
    log_info "Installing git..."
    sudo dnf install -y git
fi

# Install Ansible if not present
if ! command_exists ansible-playbook; then
    log_info "Installing Ansible..."
    python3 -m pip install --user ansible
    # Add user pip bin to PATH if not already there
    export PATH="$HOME/.local/bin:$PATH"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi

# Verify Ansible version
ANSIBLE_VERSION=$(ansible --version | head -n1 | awk '{print $3}' | cut -d'.' -f1-2)
if [[ $(echo "$ANSIBLE_VERSION < 2.10" | bc -l 2>/dev/null || echo "1") -eq 1 ]]; then
    log_warning "Ansible version $ANSIBLE_VERSION detected. Version 2.10+ recommended."
fi

# Get deployment directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log_info "Working in directory: $SCRIPT_DIR"

# Install Ansible requirements
log_info "Installing Ansible requirements..."
ansible-galaxy install -r requirements.yml

# Collect configuration
echo
log_info "Configuration Setup"
echo "===================="
log_info "We need some basic configuration. Press Enter to use defaults where provided."
echo

# Basic configuration
get_input "ALBS Server Address/Hostname" "localhost" "ALBS_ADDRESS"
get_input "Frontend Base URL" "http://$ALBS_ADDRESS:8080" "FRONTEND_BASEURL"

# GitHub OAuth configuration
echo
log_info "GitHub OAuth Configuration (Required for authentication)"
log_info "If you don't have these yet, visit: https://github.com/settings/developers"
log_info "Create a new OAuth App with:"
log_info "  Homepage URL: $FRONTEND_BASEURL"
log_info "  Callback URL: $FRONTEND_BASEURL/api/v1/auth/github/callback"
echo

get_input "GitHub OAuth Client ID" "" "GITHUB_CLIENT"
get_secret_input "GitHub OAuth Client Secret" "GITHUB_CLIENT_SECRET"

# Database configuration
echo
log_info "Database Configuration"
get_input "PostgreSQL Password" "password" "POSTGRES_PASSWORD"
get_input "PostgreSQL Database" "albs_db" "POSTGRES_DB"
get_input "PostgreSQL User" "postgres" "POSTGRES_USER"

# RabbitMQ configuration
get_input "RabbitMQ User" "admin" "RABBITMQ_USER"
get_input "RabbitMQ Password" "password" "RABBITMQ_PASS"

# Pulp configuration
get_input "Pulp Password" "password" "PULP_PASSWORD"

# Connection settings
if [[ "$ALBS_ADDRESS" == "localhost" ]]; then
    USE_LOCAL_CONNECTION="true"
else
    log_info "Remote deployment detected. Do you want to use local connection? (y/N)"
    read -r use_local
    if [[ "$use_local" == "y" || "$use_local" == "Y" ]]; then
        USE_LOCAL_CONNECTION="true"
    else
        USE_LOCAL_CONNECTION="false"
    fi
fi

# Generate vars.yml
log_info "Generating configuration file (vars.yml)..."

cat > vars.yml << EOF
---
# Basic configuration
albs_address: $ALBS_ADDRESS
frontend_baseurl: $FRONTEND_BASEURL
use_local_connection: $USE_LOCAL_CONNECTION

# GitHub OAuth
github_client: $GITHUB_CLIENT
github_client_secret: $GITHUB_CLIENT_SECRET

# Database configuration
postgres_password: $POSTGRES_PASSWORD
postgres_db: $POSTGRES_DB
postgres_user: $POSTGRES_USER

# RabbitMQ configuration
rabbitmq_user: $RABBITMQ_USER
rabbitmq_pass: $RABBITMQ_PASS

# Pulp configuration
pulp_password: $PULP_PASSWORD

# Auto-generated secrets
albs_jwt_secret: $(openssl rand -hex 32)
alts_jwt_secret: $(openssl rand -hex 32)
rabbitmq_erlang_cookie: $(openssl rand -hex 16)

# Default settings
use_already_cloned_repos: false
ansible_interpreter_path: auto
pgp_keys: []
EOF

log_success "Configuration file created: vars.yml"

# Confirm deployment
echo
log_warning "Ready to deploy ALBS with the following configuration:"
echo "  Server Address: $ALBS_ADDRESS"
echo "  Frontend URL: $FRONTEND_BASEURL"
echo "  Connection Type: $([ "$USE_LOCAL_CONNECTION" == "true" ] && echo "Local" || echo "Remote")"
echo "  Database: $POSTGRES_DB (user: $POSTGRES_USER)"
echo
read -p "Continue with deployment? (Y/n): " confirm_deploy
if [[ "$confirm_deploy" == "n" || "$confirm_deploy" == "N" ]]; then
    log_info "Deployment cancelled. Configuration saved in vars.yml"
    exit 0
fi

# Start deployment
log_info "Starting ALBS deployment..."

# Step 1: Prepare Alma9 VM
log_info "Step 1: Preparing AlmaLinux 9 environment..."
if ansible-playbook -i inventories/one_vm -v -e "@vars.yml" playbooks/prepare_alma9_one_vm.yml; then
    log_success "AlmaLinux 9 preparation completed"
else
    log_error "AlmaLinux 9 preparation failed"
    exit 1
fi

# Step 2: Deploy ALBS
log_info "Step 2: Deploying ALBS services..."
if ansible-playbook -i inventories/one_vm -v -e "@vars.yml" playbooks/albs_on_one_vm.yml; then
    log_success "ALBS deployment completed"
else
    log_error "ALBS deployment failed"
    exit 1
fi

# Final success message
echo
echo -e "${GREEN}"
echo "==============================================="
echo "     Buildsys Deployment Completed Successfully!"
echo "==============================================="
echo -e "${NC}"

log_success "ALBS is now running and accessible at: $FRONTEND_BASEURL"
echo
log_info "Next Steps:"
echo "  1. Open your browser and navigate to: $FRONTEND_BASEURL"
echo "  2. Log in using your GitHub account"
echo "  3. Start building packages!"
echo
log_info "Useful Commands:"
echo "  - Check services: docker ps"
echo "  - View logs: docker logs <container_name>"
echo "  - Restart services: docker-compose restart"
echo
log_info "Configuration files:"
echo "  - Main config: vars.yml"
echo "  - Inventory: inventories/one_vm/"
echo
log_warning "Important: Keep your vars.yml file secure as it contains sensitive tokens!"

# Optionally show running containers
if command_exists docker; then
    echo
    log_info "Currently running containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
fi

echo
log_success "Deployment complete! Enjoy your new ALBS instance!" 
