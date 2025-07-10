#!/bin/bash

# Alternative ZFS Installation for Incompatible Kernels
# This script uses the rescue system's ZFS installation instead of trying to install packages

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a /tmp/proxmox-install.log
}

error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    log "ERROR: $1"
    exit 1
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
    log "SUCCESS: $1"
}

info() {
    echo -e "${BLUE}ℹ $1${NC}"
    log "INFO: $1"
}

warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
    log "WARNING: $1"
}

# Check if we're in a rescue system with ZFS already available
check_rescue_zfs() {
    info "Checking rescue system ZFS availability..."
    
    # Check if ZFS is available
    if ! command -v zpool >/dev/null; then
        error_exit "ZFS commands not available in rescue system"
    fi
    
    # Check if ZFS module is loaded or loadable
    if ! lsmod | grep -q zfs && ! modprobe zfs 2>/dev/null; then
        error_exit "ZFS module not available"
    fi
    
    # Test ZFS functionality
    if ! zpool status >/dev/null 2>&1; then
        error_exit "ZFS not functional"
    fi
    
    success "Rescue system ZFS is functional"
}

# Install minimal packages without ZFS
install_minimal_packages() {
    info "Installing minimal required packages..."
    
    # Clean up any broken ZFS packages
    apt-get remove --purge -y zfs-dkms zfs-zed 2>/dev/null || true
    apt-get autoremove -y || true
    
    # Update package lists
    apt-get update
    
    # Install essential packages
    local packages=(
        "debootstrap"
        "gdisk" 
        "parted"
        "wget"
        "curl"
        "pv"
        "smartmontools"
        "lsscsi"
        "hdparm"
        "nvme-cli"
    )
    
    for package in "${packages[@]}"; do
        info "Installing $package..."
        apt-get install -y "$package" || error_exit "Failed to install $package"
    done
    
    success "Minimal packages installed"
}

# Copy ZFS binaries to chroot later
prepare_zfs_for_chroot() {
    info "Preparing ZFS for target system..."
    
    # Create directory for ZFS binaries
    mkdir -p /tmp/zfs-rescue
    
    # Copy ZFS binaries
    cp -a /sbin/zfs /tmp/zfs-rescue/ 2>/dev/null || true
    cp -a /sbin/zpool /tmp/zfs-rescue/ 2>/dev/null || true
    cp -a /usr/sbin/zfs* /tmp/zfs-rescue/ 2>/dev/null || true
    cp -a /usr/sbin/zpool* /tmp/zfs-rescue/ 2>/dev/null || true
    
    # Copy ZFS libraries
    mkdir -p /tmp/zfs-rescue/lib
    cp -a /lib/*/libzfs* /tmp/zfs-rescue/lib/ 2>/dev/null || true
    cp -a /usr/lib/*/libzfs* /tmp/zfs-rescue/lib/ 2>/dev/null || true
    
    success "ZFS binaries prepared for target system"
}

# Main function
main() {
    info "Starting alternative ZFS setup for rescue system..."
    
    check_rescue_zfs
    install_minimal_packages
    prepare_zfs_for_chroot
    
    success "Alternative ZFS setup completed!"
    echo
    echo "You can now continue with the main installation."
    echo "ZFS will be available from the rescue system."
}

# Check if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
