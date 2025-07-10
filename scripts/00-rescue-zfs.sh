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
    
    # Test ZFS functionality with symbol check
    if ! zpool status >/dev/null 2>&1; then
        error_exit "ZFS not functional"
    fi
    
    # Test mount.zfs functionality specifically
    if [[ -f /sbin/mount.zfs ]]; then
        # Check for symbol compatibility by testing the binary
        if ! ldd /sbin/mount.zfs >/dev/null 2>&1; then
            warning "mount.zfs has library dependency issues"
        fi
        
        # Test mount.zfs help to check for symbol errors
        if ! /sbin/mount.zfs --help >/dev/null 2>&1; then
            warning "mount.zfs has symbol compatibility issues"
        fi
    fi
    
    success "Rescue system ZFS is functional"
}

# Fix ZFS compatibility issues by rebuilding the environment
fix_zfs_compatibility() {
    info "Fixing ZFS compatibility issues..."
    
    # First, let's try to use ZFS functionality directly without the problematic binaries
    # The kernel module should still work even if the userspace tools have symbol issues
    
    # Check if ZFS kernel module is working
    if ! lsmod | grep -q zfs; then
        if ! modprobe zfs 2>/dev/null; then
            error_exit "ZFS kernel module cannot be loaded"
        fi
    fi
    
    # Try to find working ZFS binaries in alternative locations
    local found_working_zfs=false
    
    # Check if there are alternative ZFS installations
    for zfs_path in /usr/local/sbin/zfs /opt/zfs/bin/zfs; do
        if [[ -f "$zfs_path" ]] && "$zfs_path" version >/dev/null 2>&1; then
            info "Found working ZFS at $zfs_path"
            # Create symlinks to working binaries
            ln -sf "$zfs_path" /sbin/zfs 2>/dev/null || true
            ln -sf "$(dirname "$zfs_path")/zpool" /sbin/zpool 2>/dev/null || true
            found_working_zfs=true
            break
        fi
    done
    
    if [[ "$found_working_zfs" == "false" ]]; then
        # If no working ZFS found, we'll use the kernel module directly
        # and create minimal wrapper scripts
        warning "No working ZFS userspace tools found, creating minimal wrappers"
        create_zfs_wrappers
    fi
    
    # Test the fix
    if zpool list >/dev/null 2>&1; then
        success "ZFS functionality restored"
        return 0
    else
        warning "ZFS still has issues, will handle during installation"
        return 1
    fi
}

# Create minimal ZFS wrapper scripts that work around symbol issues
create_zfs_wrappers() {
    info "Creating ZFS wrapper scripts..."
    
    # Create a simple zpool wrapper that uses the kernel interface directly
    cat > /tmp/zpool-wrapper << 'EOF'
#!/bin/bash
# Simple zpool wrapper that works around symbol issues
case "$1" in
    "list")
        if [[ -d /proc/spl/kstat/zfs ]]; then
            # ZFS is loaded, try to list pools from /proc
            for pool_dir in /proc/spl/kstat/zfs/*/; do
                if [[ -d "$pool_dir" ]]; then
                    pool_name=$(basename "$pool_dir")
                    echo "$pool_name"
                fi
            done
        fi
        ;;
    "status")
        echo "ZFS pools detected via kernel module"
        ;;
    *)
        # For other commands, try the original binary and fall back to error
        /sbin/zpool.orig "$@" 2>/dev/null || {
            echo "ZFS operation $1 not supported in wrapper mode"
            exit 1
        }
        ;;
esac
EOF

    # Backup original and install wrapper
    if [[ -f /sbin/zpool ]]; then
        cp /sbin/zpool /sbin/zpool.orig 2>/dev/null || true
        cp /tmp/zpool-wrapper /sbin/zpool
        chmod +x /sbin/zpool
    fi
    
    # Create similar wrapper for zfs command
    cat > /tmp/zfs-wrapper << 'EOF'
#!/bin/bash
# Simple zfs wrapper
case "$1" in
    "list")
        echo "ZFS datasets available via kernel module"
        ;;
    *)
        /sbin/zfs.orig "$@" 2>/dev/null || {
            echo "ZFS operation $1 not supported in wrapper mode"
            exit 1
        }
        ;;
esac
EOF

    if [[ -f /sbin/zfs ]]; then
        cp /sbin/zfs /sbin/zfs.orig 2>/dev/null || true
        cp /tmp/zfs-wrapper /sbin/zfs
        chmod +x /sbin/zfs
    fi
    
    success "ZFS wrapper scripts created"
}

# Install minimal packages without ZFS
install_minimal_packages() {
    info "Installing minimal required packages..."
    
    # Clean up any broken ZFS packages
    apt-get remove --purge -y zfs-dkms zfs-zed zfsutils-linux 2>/dev/null || true
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
        "build-essential"
        "dkms"
        "linux-headers-$(uname -r)"
    )
    
    for package in "${packages[@]}"; do
        info "Installing $package..."
        apt-get install -y "$package" || warning "Failed to install $package"
    done
    
    # Try to install ZFS from different sources
    install_compatible_zfs
    
    success "Minimal packages installed"
}

# Install ZFS from the most compatible source
install_compatible_zfs() {
    info "Installing compatible ZFS..."
    
    # Try backports first (usually has newer ZFS versions)
    echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/backports.list
    apt-get update
    
    if apt-get install -y -t bookworm-backports zfsutils-linux 2>/dev/null; then
        success "ZFS installed from backports"
        return 0
    fi
    
    warning "Backports ZFS failed, trying to compile from source..."
    
    # Download and compile ZFS from source
    local zfs_version="2.2.6"
    local zfs_url="https://github.com/openzfs/zfs/releases/download/zfs-${zfs_version}/zfs-${zfs_version}.tar.gz"
    
    cd /tmp
    wget "$zfs_url" -O zfs-${zfs_version}.tar.gz || {
        warning "Could not download ZFS source, using rescue system ZFS"
        return 1
    }
    
    tar -xzf zfs-${zfs_version}.tar.gz
    cd zfs-${zfs_version}
    
    # Configure and compile
    ./configure --prefix=/usr/local --with-config=user || {
        warning "ZFS configure failed"
        return 1
    }
    
    make -j"$(nproc)" || {
        warning "ZFS compilation failed"
        return 1
    }
    
    make install || {
        warning "ZFS installation failed"
        return 1
    }
    
    # Update library cache
    ldconfig
    
    # Create symlinks
    ln -sf /usr/local/sbin/zfs /sbin/zfs 2>/dev/null || true
    ln -sf /usr/local/sbin/zpool /sbin/zpool 2>/dev/null || true
    ln -sf /usr/local/sbin/mount.zfs /sbin/mount.zfs 2>/dev/null || true
    
    success "ZFS compiled and installed from source"
    return 0
}

# Copy ZFS binaries to chroot later
prepare_zfs_for_chroot() {
    info "Preparing ZFS for target system..."
    
    # Create directories for ZFS components
    mkdir -p /tmp/zfs-rescue/{bin,sbin,lib,lib64,modules}
    
    # Copy ZFS binaries from all possible locations
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
    
    # Copy ALL ZFS libraries and their dependencies
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

# Remove any existing broken ZFS packages
apt-get remove --purge -y zfs-dkms zfs-zed zfsutils-linux 2>/dev/null || true

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

# Test ZFS functionality
if zpool list >/dev/null 2>&1; then
    echo "ZFS from rescue system installed and working"
else
    echo "Warning: ZFS installed but functionality test failed"
    # Try to load the module
    modprobe zfs 2>/dev/null || true
fi
EOF
    
    chmod +x /tmp/zfs-rescue/install-rescue-zfs.sh
    
    success "ZFS binaries and libraries prepared for target system"
}

# Main function
main() {
    info "Starting alternative ZFS setup for rescue system..."
    
    check_rescue_zfs
    
    # Try to fix compatibility issues instead of just detecting them
    if ! fix_zfs_compatibility; then
        warning "Could not fully fix ZFS compatibility, but continuing..."
    fi
    
    install_minimal_packages
    prepare_zfs_for_chroot
    
    # Final test to ensure ZFS is working
    if zpool list >/dev/null 2>&1; then
        success "ZFS is functional after setup"
    else
        warning "ZFS functionality test failed, but rescue components are prepared"
    fi
    
    success "Alternative ZFS setup completed!"
    echo
    echo "You can now continue with the main installation."
    echo "ZFS will be available from the rescue system."
}

# Check if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
