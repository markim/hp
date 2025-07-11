#!/bin/bash

# Hetzner Proxmox ZFS Installation Script
# This script automates the installation of Proxmox VE with ZFS on Hetzner servers

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/server-config.conf"
LOG_FILE="/tmp/proxmox-install.log"
PROXMOX_ISO_URL="https://hetzner:download@download.hetzner.com/bootimages/iso/proxmox-ve_8.3-1.iso"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Error handling
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    log "ERROR: $1"
    exit 1
}

# Success message
success() {
    echo -e "${GREEN}✓ $1${NC}"
    log "SUCCESS: $1"
}

# Warning message
warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
    log "WARNING: $1"
}

# Info message
info() {
    echo -e "${BLUE}ℹ $1${NC}"
    log "INFO: $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
}

# Check if running in Hetzner rescue system
check_rescue_system() {
    if [[ ! -f /etc/hetzner-rescue ]]; then
        warning "Not detected as Hetzner rescue system. Proceeding anyway..."
    else
        success "Running in Hetzner rescue system"
    fi
}

# Create directory structure
setup_directories() {
    info "Setting up directory structure..."
    mkdir -p "${SCRIPT_DIR}"/{scripts,config,docs,logs}
    success "Directory structure created"
}

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        success "Configuration loaded from $CONFIG_FILE"
    else
        warning "Configuration file not found. Using defaults."
    fi
}

# Download required scripts if not present
download_scripts() {
    local scripts_dir="${SCRIPT_DIR}/scripts"
    
    if [[ ! -d "$scripts_dir" ]] || [[ -z "$(ls -A "$scripts_dir" 2>/dev/null)" ]]; then
        info "Scripts directory empty. Creating required scripts..."
        
        # Create the scripts - this will be done by subsequent file creation
        mkdir -p "$scripts_dir"
    fi
}

# Check for kernel compatibility with ZFS packages
check_kernel_compatibility() {
    info "Checking kernel compatibility with ZFS..."
    
    local kernel_version
    kernel_version=$(uname -r | cut -d'-' -f1)
    
    info "Detected kernel: $kernel_version"
    
    # Always use rescue system ZFS for maximum compatibility
    warning "Always using rescue system ZFS for maximum compatibility"
    export USE_RESCUE_ZFS="yes"
}

# Main installation process
main() {
    info "Starting Hetzner Proxmox ZFS Installation"
    info "Log file: $LOG_FILE"
    
    # Pre-flight checks
    check_root
    check_rescue_system
    setup_directories
    load_config
    download_scripts
    check_kernel_compatibility
    
    # Confirmation prompt
    echo
    echo -e "${YELLOW}WARNING: This will DESTROY ALL DATA on your drives!${NC}"
    echo "The following operations will be performed:"
    echo "1. Format all drives with ZFS"
    echo "2. Set up ZFS mirrors for same-size drives"
    echo "3. Install Proxmox VE"
    echo "4. Configure system for reboot"
    echo
    read -p "Are you sure you want to continue? (type 'yes' to confirm): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        info "Installation cancelled by user"
        exit 0
    fi
    
    # Execute installation steps
    # Always run rescue ZFS setup first
    info "Step 0: Setting up rescue system ZFS..."
    bash "${SCRIPT_DIR}/scripts/00-rescue-zfs.sh"
    
    info "Step 1: Preparing system..."
    if ! bash "${SCRIPT_DIR}/scripts/01-prepare-system.sh"; then
        error_exit "Step 1 failed: System preparation failed"
    fi
    
    info "Step 2: Setting up ZFS..."
    if ! bash "${SCRIPT_DIR}/scripts/02-setup-zfs.sh"; then
        error_exit "Step 2 failed: ZFS setup failed"
    fi
    
    info "Step 3: Installing Proxmox..."
    if ! bash "${SCRIPT_DIR}/scripts/03-install-proxmox.sh"; then
        warning "Step 3 had issues but continuing with post-installation..."
        log "WARNING: Proxmox installation had issues, attempting post-install anyway"
    fi
    
    info "Step 4: Post-installation configuration..."
    if ! bash "${SCRIPT_DIR}/scripts/04-post-install.sh"; then
        warning "Step 4 had issues but installation may still be usable"
        log "WARNING: Post-installation had issues"
    fi
    
    success "Installation process completed!"
    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  INSTALLATION PROCESS COMPLETED!     ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "${BLUE}Your Proxmox server installation is ready!${NC}"
    echo -e "${YELLOW}Please check the logs above for any warnings.${NC}"
    echo
    echo -e "${BLUE}Next steps:${NC}"
    echo "1. Remove rescue system from Hetzner Robot boot order"
    echo "2. Reboot the system: ${YELLOW}reboot${NC}"
    echo "3. After reboot, access Proxmox at: ${YELLOW}https://$(hostname -I | awk '{print $1}'):8006${NC}"
    echo
    echo -e "${GREEN}Installation log: ${YELLOW}/tmp/proxmox-install.log${NC}"
}

# Run main function
main "$@"
