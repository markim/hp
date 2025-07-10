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

# Update package manager
update_system() {
    info "Updating package manager..."
    apt-get update || error_exit "Failed to update package manager"
    success "Package manager updated"
}

# Install required packages
install_packages() {
    info "Installing required packages..."
    
    # First install basic packages
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
    
    for package in "${basic_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            info "Installing $package..."
            apt-get install -y "$package" || error_exit "Failed to install $package"
        else
            info "$package already installed"
        fi
    done
    
    # Handle ZFS installation separately due to potential kernel compatibility issues
    if [[ "${USE_RESCUE_ZFS:-no}" == "yes" ]]; then
        info "Skipping ZFS package installation (using rescue system ZFS)"
    else
        install_zfs_packages
    fi
    
    success "All required packages installed"
}

# Install ZFS packages with kernel compatibility handling
install_zfs_packages() {
    info "Installing ZFS packages..."
    
    # Check current kernel version
    local kernel_version
    kernel_version=$(uname -r | cut -d'-' -f1)
    local major_version
    major_version=$(echo "$kernel_version" | cut -d'.' -f1)
    local minor_version
    minor_version=$(echo "$kernel_version" | cut -d'.' -f2)
    
    info "Current kernel: $kernel_version"
    
    # Check if kernel is too new for Debian 12 ZFS
    if [[ $major_version -gt 6 ]] || [[ $major_version -eq 6 && $minor_version -gt 2 ]]; then
        warning "Kernel $kernel_version may be too new for Debian 12 ZFS packages"
        info "Attempting alternative ZFS installation methods..."
        
        # Try installing from backports first
        if install_zfs_backports; then
            return 0
        fi
        
        # If backports fail, try manual installation
        if install_zfs_manual; then
            return 0
        fi
        
        error_exit "Could not install ZFS packages compatible with kernel $kernel_version"
    else
        # Standard installation for compatible kernels
        install_zfs_standard
    fi
}

# Install ZFS from standard Debian repositories
install_zfs_standard() {
    info "Installing ZFS from standard repositories..."
    
    # Remove any broken ZFS packages first
    apt-get remove --purge -y zfs-dkms zfs-zed 2>/dev/null || true
    
    # Clean package cache
    apt-get clean
    apt-get update
    
    # Install ZFS packages
    DEBIAN_FRONTEND=noninteractive apt-get install -y zfsutils-linux || error_exit "Failed to install ZFS packages"
    
    success "ZFS installed from standard repositories"
}

# Try installing ZFS from backports
install_zfs_backports() {
    info "Attempting ZFS installation from backports..."
    
    # Add backports repository
    echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/backports.list
    apt-get update
    
    # Try installing from backports
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -t bookworm-backports zfsutils-linux 2>/dev/null; then
        success "ZFS installed from backports"
        return 0
    else
        warning "ZFS installation from backports failed"
        rm -f /etc/apt/sources.list.d/backports.list
        apt-get update
        return 1
    fi
}

# Manual ZFS installation for newer kernels
install_zfs_manual() {
    info "Attempting manual ZFS installation..."
    
    # Remove any existing ZFS packages
    apt-get remove --purge -y zfs-dkms zfs-zed zfsutils-linux 2>/dev/null || true
    
    # Download and install newer ZFS packages
    local zfs_version="2.2.2"
    local temp_dir="/tmp/zfs-install"
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    # Try downloading from OpenZFS releases
    if wget "https://github.com/openzfs/zfs/releases/download/zfs-${zfs_version}/zfs-${zfs_version}.tar.gz" 2>/dev/null; then
        info "Downloaded ZFS source, attempting compilation..."
        
        # Install build dependencies
        apt-get install -y build-essential autoconf automake libtool gawk alien fakeroot dkms libblkid-dev uuid-dev libudev-dev libssl-dev zlib1g-dev libaio-dev libattr1-dev libelf-dev linux-headers-$(uname -r) python3 python3-dev python3-setuptools python3-cffi libffi-dev python3-packaging git libcurl4-openssl-dev debhelper-compat
        
        # Extract and build
        tar -xzf "zfs-${zfs_version}.tar.gz"
        cd "zfs-${zfs_version}"
        
        ./configure --enable-systemd
        make -j$(nproc) deb-utils deb-kmod
        
        # Install the built packages
        dpkg -i *.deb
        
        success "ZFS compiled and installed from source"
        return 0
    else
        warning "Could not download ZFS source"
        return 1
    fi
}

# Fallback: Use ZFS from live environment
use_rescue_zfs() {
    info "Using ZFS from rescue environment..."
    
    # The rescue system likely already has ZFS loaded
    if lsmod | grep -q zfs; then
        info "ZFS module already loaded in rescue system"
        
        # Install minimal userspace tools
        apt-get install -y --no-install-recommends zfs-initramfs
        
        success "Using rescue system ZFS"
        return 0
    else
        return 1
    fi
}

# Load ZFS module
load_zfs_module() {
    info "Loading ZFS module..."
    
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
    
    error_exit "Failed to load ZFS module. The kernel may be incompatible with available ZFS packages."
}

# Detect and display system information
detect_system_info() {
    info "Detecting system information..."
    
    echo "=== System Information ==="
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "Memory: $(free -h | grep 'Mem:' | awk '{print $2}')"
    echo "CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
    echo "CPU Cores: $(nproc)"
    echo
    
    echo "=== Network Configuration ==="
    ip addr show | grep -E '^[0-9]+:|inet ' | grep -v '127.0.0.1'
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
        if [[ " ${EXCLUDE_DRIVES[*]} " =~ " ${drive} " ]]; then
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
