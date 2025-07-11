#!/bin/bash

# System Preparation Script for Hetzner Proxmox ZFS Installation
# This script prepares the rescue system for ZFS and Proxmox installation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/server-config.conf
source "${SCRIPT_DIR}/config/server-config.conf"

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

# Update package manager
update_system() {
    # Skip update if rescue ZFS setup was already run (which updates packages)
    if [[ -f /tmp/rescue-zfs-completed ]]; then
        info "Package manager already updated by rescue ZFS setup"
        return 0
    fi
    
    info "Updating package manager..."
    apt-get update || error_exit "Failed to update package manager"
    success "Package manager updated"
}

# Install required packages
install_packages() {
    info "Installing required packages..."
    
    # Skip package installation if rescue ZFS setup was already run (which installs packages)
    if [[ -f /tmp/rescue-zfs-completed ]]; then
        info "Required packages already installed by rescue ZFS setup"
        success "All required packages installed"
        return 0
    fi
    
    # Install all basic packages at once for efficiency
    local basic_packages=(
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
    
    # Check which packages need to be installed
    local packages_to_install=()
    for package in "${basic_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            packages_to_install+=("$package")
        fi
    done
    
    # Install all missing packages at once
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        info "Installing packages: ${packages_to_install[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages_to_install[@]}" || error_exit "Failed to install packages"
    else
        info "All basic packages already installed"
    fi
    
    # Always use rescue system ZFS - never install ZFS packages
    info "Using rescue system ZFS (never installing ZFS packages)"
    
    success "All required packages installed"
}

# Load ZFS module
load_zfs_module() {
    # Always use rescue ZFS - skip module loading if already completed
    if [[ -f /tmp/rescue-zfs-completed ]]; then
        info "ZFS already available from rescue system setup"
        return 0
    fi
    
    info "Loading ZFS module from rescue system..."
    
    # Check if ZFS module is already loaded
    if lsmod | grep -q zfs; then
        info "ZFS module already loaded"
        return 0
    fi
    
    # Try to load ZFS module
    if modprobe zfs 2>/dev/null; then
        success "ZFS module loaded successfully"
        return 0
    fi
    
    # If modprobe fails, try alternative approaches
    warning "Standard ZFS module loading failed, trying alternatives..."
    
    # Check if ZFS utilities are working despite module issues
    if command -v zpool >/dev/null && zpool status >/dev/null 2>&1; then
        info "ZFS utilities are functional"
        return 0
    fi
    
    # Try loading individual ZFS modules
    local zfs_modules=("spl" "zavl" "znvpair" "zunicode" "zcommon" "icp" "zlua" "zzstd" "zfs")
    for module in "${zfs_modules[@]}"; do
        modprobe "$module" 2>/dev/null || true
    done
    
    # Final check
    if lsmod | grep -q zfs || (command -v zpool >/dev/null && zpool status >/dev/null 2>&1); then
        success "ZFS modules loaded (alternative method)"
        return 0
    fi
    
    error_exit "Failed to load ZFS module. The rescue system ZFS may not be properly configured."
}

# Detect and display system information
detect_system_info() {
    info "Detecting system information..."
    
    # Only show detailed info if not already shown by rescue ZFS setup
    if [[ -f /tmp/rescue-zfs-completed ]]; then
        info "System information already displayed by rescue ZFS setup"
        return 0
    fi
    
    echo "=== System Information ==="
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "Memory: $(free -h | grep 'Mem:' | awk '{print $2}')"
    echo "CPU Cores: $(nproc)"
    echo
    
    echo "=== Network Configuration ==="
    ip route get 1.1.1.1 | grep src | awk '{print "Primary IP: " $7}'
    echo
    
    echo "=== Storage Devices ==="
    lsblk -d -o NAME,SIZE,MODEL,SERIAL | grep -v loop
    echo
    
    success "System information detected"
}

# Backup current network configuration
backup_network_config() {
    info "Backing up network configuration..."
    local backup_dir="/tmp/network-backup"
    mkdir -p "$backup_dir"
    
    # Backup network interfaces
    if [[ -f /etc/network/interfaces ]]; then
        cp /etc/network/interfaces "$backup_dir/" || true
    fi
    
    # Backup systemd network configs
    if [[ -d /etc/systemd/network ]]; then
        cp -r /etc/systemd/network "$backup_dir/" || true
    fi
    
    # Save current IP configuration
    ip addr show > "$backup_dir/current-ip-config.txt"
    ip route show > "$backup_dir/current-routes.txt"
    
    # Save DNS configuration
    if [[ -f /etc/resolv.conf ]]; then
        cp /etc/resolv.conf "$backup_dir/" || true
    fi
    
    success "Network configuration backed up to $backup_dir"
}

# Check available drives
check_drives() {
    info "Analyzing available drives..."
    
    # Get list of all block devices
    local drives=()
    while IFS= read -r drive; do
        drives+=("$drive")
    done < <(lsblk -nd -o NAME | grep -E '^(sd|nvme|vd)' | sed 's/^/\/dev\//')
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        error_exit "No suitable drives found"
    fi
    
    echo "=== Available Drives ==="
    for drive in "${drives[@]}"; do
        # Check if drive is excluded
        local excluded=false
        for excluded_drive in "${EXCLUDE_DRIVES[@]}"; do
            if [[ "$drive" == "$excluded_drive" ]]; then
                excluded=true
                break
            fi
        done
        
        if [[ "$excluded" == "true" ]]; then
            echo "❌ $drive (excluded in configuration)"
            continue
        fi
        
        local size model serial
        size=$(lsblk -nd -o SIZE "$drive" | tr -d ' ')
        model=$(lsblk -nd -o MODEL "$drive" | tr -d ' ' | sed 's/^$/Unknown/')
        
        # Try to get serial number
        if [[ "$drive" =~ nvme ]]; then
            serial=$(nvme id-ctrl "$drive" 2>/dev/null | grep -i serial | awk '{print $3}' || echo "Unknown")
        else
            serial=$(smartctl -i "$drive" 2>/dev/null | grep -i "serial number" | awk '{print $3}' || echo "Unknown")
        fi
        
        echo "✓ $drive - Size: $size, Model: $model, Serial: $serial"
        
        # Check drive health
        if smartctl -H "$drive" 2>/dev/null | grep -q "PASSED"; then
            echo "  Health: PASSED"
        else
            echo "  Health: Unknown/Failed"
        fi
    done
    echo
    
    success "Drive analysis completed"
}

# Verify ZFS compatibility
verify_zfs_compatibility() {
    info "Verifying ZFS compatibility..."
    
    # Check ZFS version
    local zfs_version
    zfs_version=$(zfs version 2>/dev/null | head -1 | awk '{print $2}' || echo "Unknown")
    info "ZFS version: $zfs_version"
    
    # Test ZFS pool creation (dry run)
    info "Testing ZFS functionality..."
    if zpool list > /dev/null 2>&1; then
        success "ZFS is functional"
    else
        error_exit "ZFS is not working properly"
    fi
}

# Check system requirements
check_system_requirements() {
    info "Checking system requirements..."
    
    # Check available memory (ZFS requires at least 1GB)
    local mem_gb
    mem_gb=$(free -g | grep 'Mem:' | awk '{print $2}')
    if [[ $mem_gb -lt 1 ]]; then
        error_exit "Insufficient memory. ZFS requires at least 1GB RAM"
    fi
    success "Memory requirement met ($mem_gb GB available)"
    
    # Check available disk space for temporary files
    local free_space
    free_space=$(df /tmp | tail -1 | awk '{print $4}')
    if [[ $free_space -lt 1048576 ]]; then  # 1GB in KB
        error_exit "Insufficient space in /tmp for installation files"
    fi
    success "Temporary space requirement met"
}

# Main function
main() {
    info "Starting system preparation..."
    
    update_system
    install_packages
    load_zfs_module
    detect_system_info
    backup_network_config
    check_drives
    verify_zfs_compatibility
    check_system_requirements
    
    success "System preparation completed successfully!"
    echo
    echo "Next steps:"
    echo "1. Review the detected drives above"
    echo "2. Modify config/server-config.conf if needed"
    echo "3. Run: ./scripts/02-setup-zfs.sh"
}

main "$@"
