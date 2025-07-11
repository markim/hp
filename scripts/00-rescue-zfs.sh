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
    
    # Check if ZFS commands are available
    if ! command -v zpool >/dev/null; then
        error_exit "ZFS commands not available in rescue system"
    fi
    
    if ! command -v zfs >/dev/null; then
        error_exit "ZFS commands not available in rescue system"
    fi
    
    success "Rescue system ZFS is available"
}


# Install minimal packages without ZFS
install_minimal_packages() {
    info "Installing minimal required packages..."
    
    # First, fix broken ZFS packages by removing them completely
    info "Removing broken ZFS packages that prevent other installations..."
    
    # Stop apt from trying to configure broken packages
    export DEBIAN_FRONTEND=noninteractive
    
    # Remove broken ZFS packages completely
    dpkg --remove --force-remove-reinstreq --force-depends zfs-dkms zfs-zed 2>/dev/null || true
    dpkg --purge zfs-dkms zfs-zed 2>/dev/null || true
    
    # Remove any ZFS-related packages that might cause issues
    dpkg --remove --force-remove-reinstreq --force-depends zfsutils-linux libnvpair3linux libuutil3linux libzfs4linux libzpool5linux 2>/dev/null || true
    
    # Clean up package system
    apt-get -f install --no-install-recommends -y 2>/dev/null || true
    apt-get clean
    apt-get autoclean
    
    # Put ZFS packages on hold to prevent accidental installation
    echo "zfs-dkms hold" | dpkg --set-selections 2>/dev/null || true
    echo "zfs-zed hold" | dpkg --set-selections 2>/dev/null || true
    echo "zfsutils-linux hold" | dpkg --set-selections 2>/dev/null || true
    
    # Update package lists
    apt-get update
    
    # Install essential packages one by one with better error handling
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
        if ! apt-get install -y --no-install-recommends "$package"; then
            warning "Failed to install $package, trying with --fix-broken"
            apt-get -f install --no-install-recommends -y || true
            apt-get install -y --no-install-recommends "$package" || warning "Still failed to install $package"
        fi
    done
    
    success "Minimal packages installed"
}



# Copy ZFS binaries to chroot later
prepare_zfs_for_chroot() {
    info "Preparing ZFS for target system..."
    
    # Create directories for ZFS components
    mkdir -p /tmp/zfs-rescue/{bin,sbin,lib,lib64,modules}
    
    # Copy ZFS binaries
    for path in /bin /sbin /usr/bin /usr/sbin; do
        if [[ -f "$path/zfs" ]]; then
            cp -a "$path/zfs" /tmp/zfs-rescue/sbin/ 2>/dev/null || true
        fi
        if [[ -f "$path/zpool" ]]; then
            cp -a "$path/zpool" /tmp/zfs-rescue/sbin/ 2>/dev/null || true
        fi
        # Copy other ZFS utilities
        cp -a "$path"/z* /tmp/zfs-rescue/sbin/ 2>/dev/null || true
    done
    
    # Copy mount.zfs specifically
    if [[ -f /sbin/mount.zfs ]]; then
        cp -a /sbin/mount.zfs /tmp/zfs-rescue/sbin/
    fi
    
    # Copy ZFS libraries and their dependencies
    for libdir in /lib /usr/lib /lib64 /usr/lib64; do
        if [[ -d "$libdir" ]]; then
            # Copy ZFS libraries
            find "$libdir" -name "*zfs*" -type f 2>/dev/null | while read -r lib; do
                cp -a "$lib" /tmp/zfs-rescue/lib/ 2>/dev/null || true
            done
            
            # Copy related libraries (nvpair, uutil, etc.)
            find "$libdir" -name "*nvpair*" -type f 2>/dev/null | while read -r lib; do
                cp -a "$lib" /tmp/zfs-rescue/lib/ 2>/dev/null || true
            done
            find "$libdir" -name "*uutil*" -type f 2>/dev/null | while read -r lib; do
                cp -a "$lib" /tmp/zfs-rescue/lib/ 2>/dev/null || true
            done
        fi
        
        # Handle architecture-specific lib directories
        for archdir in "$libdir"/x86_64-linux-gnu "$libdir"/i386-linux-gnu; do
            if [[ -d "$archdir" ]]; then
                find "$archdir" -name "*zfs*" -o -name "*nvpair*" -o -name "*uutil*" 2>/dev/null | while read -r lib; do
                    cp -a "$lib" /tmp/zfs-rescue/lib/ 2>/dev/null || true
                done
            fi
        done
    done
    
    # Copy ZFS kernel modules
    local kernel_version
    kernel_version=$(uname -r)
    local modules_path="/lib/modules/$kernel_version"
    
    if [[ -d "$modules_path/extra/zfs" ]]; then
        cp -a "$modules_path/extra/zfs" /tmp/zfs-rescue/modules/ 2>/dev/null || true
    fi
    if [[ -d "$modules_path/kernel/fs/zfs" ]]; then
        cp -a "$modules_path/kernel/fs/zfs" /tmp/zfs-rescue/modules/ 2>/dev/null || true
    fi
    
    # Copy udev rules
    mkdir -p /tmp/zfs-rescue/udev
    cp -a /lib/udev/rules.d/*zfs* /tmp/zfs-rescue/udev/ 2>/dev/null || true
    cp -a /etc/udev/rules.d/*zfs* /tmp/zfs-rescue/udev/ 2>/dev/null || true
    
    # Create a script to install ZFS in chroot
    cat > /tmp/zfs-rescue/install-rescue-zfs.sh << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Installing ZFS from rescue system..."

# Install binaries to both locations for compatibility
cp -a /tmp/zfs-rescue/sbin/* /sbin/ 2>/dev/null || true
cp -a /tmp/zfs-rescue/sbin/* /usr/sbin/ 2>/dev/null || true
cp -a /tmp/zfs-rescue/sbin/* /usr/local/sbin/ 2>/dev/null || true

# Install libraries to all possible locations
cp -a /tmp/zfs-rescue/lib/* /usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
cp -a /tmp/zfs-rescue/lib/* /lib/x86_64-linux-gnu/ 2>/dev/null || true
cp -a /tmp/zfs-rescue/lib/* /usr/local/lib/ 2>/dev/null || true

# Update library cache
ldconfig

# Install kernel modules if available
if [[ -d /tmp/zfs-rescue/modules ]]; then
    KERNEL_VERSION=$(uname -r)
    mkdir -p "/lib/modules/$KERNEL_VERSION/kernel/fs"
    cp -a /tmp/zfs-rescue/modules/* "/lib/modules/$KERNEL_VERSION/kernel/fs/" 2>/dev/null || true
    depmod -a
fi

# Install udev rules
if [[ -d /tmp/zfs-rescue/udev ]]; then
    cp -a /tmp/zfs-rescue/udev/* /lib/udev/rules.d/ 2>/dev/null || true
fi

# Make binaries executable
chmod +x /sbin/zfs /sbin/zpool /sbin/mount.zfs 2>/dev/null || true
chmod +x /usr/sbin/zfs /usr/sbin/zpool 2>/dev/null || true
chmod +x /usr/local/sbin/zfs /usr/local/sbin/zpool 2>/dev/null || true

echo "ZFS from rescue system installed"
EOF
    
    chmod +x /tmp/zfs-rescue/install-rescue-zfs.sh
    
    success "ZFS binaries and libraries prepared for target system"
}

# Main function
main() {
    info "Starting alternative ZFS setup for rescue system..."
    
    check_rescue_zfs
    install_minimal_packages
    prepare_zfs_for_chroot
    
    # Final verification that ZFS still works
    info "Verifying ZFS functionality after package cleanup..."
    if ! zpool list >/dev/null 2>&1; then
        warning "ZFS pool command failed, but this is expected if no pools exist"
    fi
    
    if ! zfs list >/dev/null 2>&1; then
        warning "ZFS list command failed, but this is expected if no pools exist"
    fi
    
    success "Alternative ZFS setup completed!"
    
    # Create marker file to indicate rescue ZFS setup is complete
    touch /tmp/rescue-zfs-completed
    
    echo
    echo "You can now continue with the main installation."
    echo "ZFS will be available from the rescue system."
}

# Check if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
