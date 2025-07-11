#!/bin/bash

# Proxmox Installation Script for Hetzner with ZFS
# This script installs Proxmox VE on the configured ZFS pools

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

# Debug ZFS state for troubleshooting
debug_zfs_state() {
    echo -e "${BLUE}=== ZFS DEBUG INFORMATION ===${NC}"
    
    echo -e "\n${YELLOW}ZFS Module Status:${NC}"
    lsmod | grep zfs || echo "ZFS module not loaded"
    
    echo -e "\n${YELLOW}ZFS Process Status:${NC}"
    ps aux | grep -E "(zfs|zpool|zdb)" | grep -v grep || echo "No ZFS processes found"
    
    echo -e "\n${YELLOW}ZFS Lock Status:${NC}"
    if [[ -d /var/lock/zfs ]]; then
        ls -la /var/lock/zfs/ || echo "No ZFS locks directory or no locks"
    else
        echo "No ZFS locks directory"
    fi
    
    echo -e "\n${YELLOW}ZFS Cache Files:${NC}"
    if [[ -f /etc/zfs/zpool.cache ]]; then
        echo "Cache file exists: $(ls -la /etc/zfs/zpool.cache)"
        echo "Cache content preview:"
        strings /etc/zfs/zpool.cache 2>/dev/null | grep -E "^/dev/" | head -5 || echo "No device paths in cache"
    else
        echo "No zpool.cache file found"
    fi
    
    echo -e "\n${YELLOW}Quick ZFS Test:${NC}"
    timeout 5 zpool list 2>&1 | head -3 || echo "ZFS commands hanging or failing"
    
    echo -e "\n${BLUE}=== END ZFS DEBUG ===${NC}"
}

# Debug function to help troubleshoot issues
debug_system_state() {
    echo -e "${BLUE}=== SYSTEM DEBUG INFORMATION ===${NC}"
    
    echo -e "\n${YELLOW}ZFS Module Status:${NC}"
    lsmod | grep zfs || echo "ZFS module not loaded"
    
    echo -e "\n${YELLOW}ZFS Pools:${NC}"
    timeout 10 zpool list 2>&1 || echo "zpool list failed or timed out"
    
    echo -e "\n${YELLOW}ZFS Pool Status for $ZFS_ROOT_POOL_NAME:${NC}"
    timeout 30 zpool status "$ZFS_ROOT_POOL_NAME" 2>&1 || echo "zpool status failed or timed out"
    
    echo -e "\n${YELLOW}Available Drives:${NC}"
    lsblk -d -o NAME,SIZE,TYPE,MODEL
    
    echo -e "\n${YELLOW}Drive Details:${NC}"
    for drive in /dev/sd* /dev/nvme*n*; do
        if [[ -b "$drive" ]]; then
            echo "$drive: $(lsblk -nd -o SIZE,MODEL "$drive" 2>/dev/null || echo 'unknown')"
        fi
    done
    
    echo -e "\n${YELLOW}Current Mounts:${NC}"
    mount | grep -E "(zfs|/mnt)"
    
    echo -e "\n${YELLOW}Process List (ZFS related):${NC}"
    ps aux | grep -E "(zfs|zpool)" | grep -v grep || echo "No ZFS processes found"
    
    echo -e "\n${BLUE}=== END DEBUG INFORMATION ===${NC}"
}

# Clean up any hung ZFS processes and clear locks
cleanup_zfs_processes() {
    info "Cleaning up ZFS processes and locks..."
    
    # Kill any hung zpool or zfs processes
    for proc in zpool zfs zdb; do
        if pgrep -x "$proc" >/dev/null 2>&1; then
            warning "Found hung $proc processes, terminating..."
            pkill -9 "$proc" 2>/dev/null || true
            sleep 1
        fi
    done
    
    # Clear any ZFS locks that might be hanging
    if [[ -d /var/lock/zfs ]]; then
        warning "Clearing ZFS locks..."
        rm -f /var/lock/zfs/* 2>/dev/null || true
    fi
    
    # Force reload ZFS module if processes were killed
    local killed_processes=false
    if ! pgrep -x "zpool|zfs|zdb" >/dev/null 2>&1; then
        if lsmod | grep -q zfs; then
            info "Reloading ZFS module after cleanup..."
            modprobe -r zfs 2>/dev/null || true
            sleep 2
            modprobe zfs 2>/dev/null || warning "Could not reload ZFS module"
            killed_processes=true
        fi
    fi
    
    # Give the system a moment to stabilize after cleanup
    if [[ "$killed_processes" == "true" ]]; then
        info "Waiting for ZFS subsystem to stabilize..."
        sleep 3
    fi
    
    success "ZFS cleanup completed"
}

# Check if root pool exists
check_root_pool() {
    if ! zpool list "$ZFS_ROOT_POOL_NAME" >/dev/null 2>&1; then
        error_exit "Root ZFS pool '$ZFS_ROOT_POOL_NAME' not found. Please run 02-setup-zfs.sh first."
    fi
    success "Root ZFS pool '$ZFS_ROOT_POOL_NAME' found"
    
    # Additional debugging info
    info "ZFS pool status check..."
    if timeout 30 zpool status "$ZFS_ROOT_POOL_NAME" >/tmp/current_pool_status.log 2>&1; then
        info "Pool status retrieved successfully"
        # Show basic pool info
        local pool_health
        pool_health=$(grep "state:" /tmp/current_pool_status.log | awk '{print $2}' || echo "unknown")
        info "Pool health: $pool_health"
    else
        warning "Could not retrieve pool status within 30 seconds"
    fi
}

# Download Proxmox ISO
download_proxmox_iso() {
    local iso_path="/tmp/proxmox-ve.iso"
    
    if [[ -f "$iso_path" ]]; then
        info "Proxmox ISO already exists at $iso_path"
        return 0
    fi
    
    info "Downloading Proxmox VE ISO..."
    info "URL: $PROXMOX_ISO_URL"
    
    # Check if URL is accessible
    if ! curl -s --head "$PROXMOX_ISO_URL" | head -n 1 | grep -q "200 OK"; then
        warning "Could not access Proxmox ISO URL. Trying alternative..."
        
        # Try to find latest version
        local base_url="https://download.proxmox.com/iso"
        local latest_iso
        latest_iso=$(curl -s "$base_url/" | grep -oE 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -V | tail -1)
        
        if [[ -n "$latest_iso" ]]; then
            PROXMOX_ISO_URL="$base_url/$latest_iso"
            info "Using latest available ISO: $PROXMOX_ISO_URL"
        else
            error_exit "Could not find Proxmox ISO to download"
        fi
    fi
    
    # Download with progress bar
    wget --progress=bar:force:noscroll -O "$iso_path" "$PROXMOX_ISO_URL" || error_exit "Failed to download Proxmox ISO"
    
    success "Proxmox ISO downloaded to $iso_path"
}

# Mount Proxmox ISO
mount_proxmox_iso() {
    local iso_path="/tmp/proxmox-ve.iso"
    local mount_point="/mnt/proxmox-iso"
    
    info "Mounting Proxmox ISO..."
    
    # Check if already mounted and unmount if necessary
    if mountpoint -q "$mount_point" 2>/dev/null; then
        warning "ISO already mounted at $mount_point, unmounting first..."
        umount "$mount_point" || warning "Failed to unmount existing mount"
    fi
    
    mkdir -p "$mount_point"
    mount -o loop "$iso_path" "$mount_point" || error_exit "Failed to mount Proxmox ISO"
    
    success "Proxmox ISO mounted at $mount_point"
}

# Install base system using debootstrap
install_base_system() {
    info "Installing base Debian system..."
    
    # Ensure ZFS is functional before proceeding
    if ! zpool list >/dev/null 2>&1; then
        error_exit "ZFS is not functional. Please check ZFS installation."
    fi
    
    # Mount ZFS filesystem
    local root_fs="$ZFS_ROOT_POOL_NAME/ROOT/pve-1"
    local mount_point="/mnt/proxmox"
    
    mkdir -p "$mount_point"
    
    # Set the mountpoint property first
    zfs set mountpoint="$mount_point" "$root_fs" || error_exit "Failed to set ZFS mountpoint"
    
    # Try different mounting approaches
    if zfs mount "$root_fs" 2>/dev/null; then
        success "ZFS mounted using zfs mount command"
    elif mount -t zfs "$root_fs" "$mount_point" 2>/dev/null; then
        success "ZFS mounted using mount command"
    else
        # Last resort: try to mount with legacy mountpoint
        zfs set mountpoint=legacy "$root_fs"
        mount -t zfs "$root_fs" "$mount_point" || error_exit "Failed to mount root filesystem"
        success "ZFS mounted in legacy mode"
    fi
    
    # Verify mount was successful
    if ! mountpoint -q "$mount_point"; then
        error_exit "Mount verification failed - $mount_point is not mounted"
    fi
    
    success "Root filesystem mounted at $mount_point"
    
    # Install base system
    debootstrap --arch=amd64 bookworm "$mount_point" http://deb.debian.org/debian || error_exit "Failed to install base system"
    
    # Install essential tools that are needed for the installation
    info "Installing essential tools in chroot..."
    
    # Mount necessary filesystems for package installation
    mount --bind /dev "$mount_point/dev"
    mount --bind /proc "$mount_point/proc"
    mount --bind /sys "$mount_point/sys"
    
    # Copy DNS configuration for package downloads
    cp /etc/resolv.conf "$mount_point/etc/resolv.conf"
    
    # Install essential packages
    LANG=C LC_ALL=C chroot "$mount_point" apt-get update
    LANG=C LC_ALL=C DEBIAN_FRONTEND=noninteractive chroot "$mount_point" apt-get install -y wget curl gnupg2 ca-certificates locales
    
    # Unmount filesystems (will be remounted later in setup_chroot)
    umount "$mount_point/sys" || true
    umount "$mount_point/proc" || true
    umount "$mount_point/dev" || true
    
    success "Base system and essential tools installed"
}

# Configure chroot environment
setup_chroot() {
    local mount_point="/mnt/proxmox"
    
    info "Setting up chroot environment..."
    
    # Mount necessary filesystems
    mount --bind /dev "$mount_point/dev"
    mount --bind /dev/pts "$mount_point/dev/pts"
    mount --bind /proc "$mount_point/proc"
    mount --bind /sys "$mount_point/sys"
    
    # Copy DNS configuration
    cp /etc/resolv.conf "$mount_point/etc/resolv.conf"
    
    # Copy ZFS configuration to chroot environment
    if [[ -f /etc/zfs/zpool.cache ]]; then
        mkdir -p "$mount_point/etc/zfs"
        cp /etc/zfs/zpool.cache "$mount_point/etc/zfs/" || true
        info "ZFS cache copied to chroot"
    fi
    
    # Copy modprobe configuration for ZFS if it exists
    if [[ -f /etc/modprobe.d/zfs.conf ]]; then
        mkdir -p "$mount_point/etc/modprobe.d"
        cp /etc/modprobe.d/zfs.conf "$mount_point/etc/modprobe.d/" || true
    fi
    
    # Ensure ZFS modules directory exists in chroot
    local kernel_version
    kernel_version=$(chroot "$mount_point" uname -r 2>/dev/null || echo "unknown")
    if [[ "$kernel_version" != "unknown" ]]; then
        mkdir -p "$mount_point/lib/modules/$kernel_version/kernel/fs/zfs"
        info "ZFS module directory prepared for kernel $kernel_version"
    fi
    
    success "Chroot environment configured"
}

# Install Proxmox packages
install_proxmox_packages() {
    local mount_point="/mnt/proxmox"
    
    info "Installing Proxmox packages..."
    
    # Copy rescue ZFS installation script if available
    if [[ -f /tmp/zfs-rescue/install-rescue-zfs.sh ]]; then
        cp /tmp/zfs-rescue/install-rescue-zfs.sh "$mount_point/tmp/"
        # Also copy the ZFS binaries directory
        cp -r /tmp/zfs-rescue "$mount_point/tmp/"
    fi
    
    # Create script to run in chroot
    cat > "$mount_point/tmp/install-proxmox.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

# Set locale to avoid perl warnings during package installation
export LANG=C
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

# Add Proxmox repository
echo "deb [arch=amd64] http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list

# Add Proxmox repository key
wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg

# Update package list
apt-get update

# Install Proxmox kernel and packages
apt-get install -y \
    proxmox-ve \
    pve-manager \
    pve-qemu-kvm \
    pve-container \
    pve-firmware \
    postfix \
    open-iscsi \
    chrony

# Try to install ZFS utilities from packages first
echo "Installing ZFS utilities..."
zfs_package_success=false

if apt-get install -y zfsutils-linux 2>/dev/null; then
    echo "✓ ZFS utilities installed from packages"
    zfs_package_success=true
    
    # Test if ZFS is functional
    echo "Testing ZFS functionality..."
    if timeout 10 zfs version >/dev/null 2>&1; then
        echo "✓ ZFS package installation successful and functional"
    else
        echo "⚠ Warning: ZFS package installed but not functional, trying rescue system..."
        zfs_package_success=false
    fi
else
    echo "⚠ Warning: Could not install zfsutils-linux package"
fi

# Use rescue system ZFS if package installation failed or is not functional
if [[ "$zfs_package_success" != "true" ]]; then
    echo "Attempting to install ZFS from rescue system..."
    
    if [[ -f /tmp/install-rescue-zfs.sh ]]; then
        echo "Installing ZFS from rescue system..."
        if /tmp/install-rescue-zfs.sh; then
            echo "✓ Rescue system ZFS installed successfully"
        else
            echo "⚠ Warning: Rescue system ZFS installation failed"
            # Try to continue anyway
        fi
    elif [[ -f "$SCRIPT_DIR/scripts/00-rescue-zfs.sh" ]]; then
        echo "Installing ZFS from rescue script..."
        if "$SCRIPT_DIR/scripts/00-rescue-zfs.sh"; then
            echo "✓ Rescue system ZFS installed successfully"
        else
            echo "⚠ Warning: Rescue system ZFS installation failed"
            # Try to continue anyway
        fi
    else
        echo "⚠ Warning: No rescue system ZFS available"
        
        # Last resort: try to copy ZFS binaries from host if available
        if command -v zfs >/dev/null 2>&1; then
            echo "Copying ZFS binaries from host system..."
            mkdir -p /sbin /usr/sbin
            
            # Copy essential ZFS binaries
            for binary in zfs zpool zdb mount.zfs; do
                if command -v "$binary" >/dev/null 2>&1; then
                    cp "$(command -v "$binary")" "/sbin/" 2>/dev/null || \
                    cp "$(command -v "$binary")" "/usr/sbin/" 2>/dev/null || true
                fi
            done
            
            echo "ZFS binaries copied from host system"
        else
            echo "⚠ Warning: No ZFS installation method available, system may not boot properly"
        fi
    fi
fi

# Configure ZFS to import pools on boot
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs.target

# Remove os-prober (not needed on hypervisor)
apt-get remove -y os-prober || true
EOF

    chmod +x "$mount_point/tmp/install-proxmox.sh"
    chroot "$mount_point" /tmp/install-proxmox.sh || error_exit "Failed to install Proxmox packages"
    
    success "Proxmox packages installed"
}

# Configure system settings
configure_system() {
    local mount_point="/mnt/proxmox"
    
    info "Configuring system settings..."
    
    # Set hostname
    local hostname="${PROXMOX_HOSTNAME:-$(hostname)}"
    echo "$hostname" > "$mount_point/etc/hostname"
    
    # Configure hosts file
    cat > "$mount_point/etc/hosts" << EOF
127.0.0.1 localhost.localdomain localhost
$(ip route get 1.1.1.1 | grep src | awk '{print $7}') $hostname.$hostname $hostname

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
    
    # Configure timezone
    chroot "$mount_point" ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    
    # Configure locale - Set C locale first to avoid perl warnings
    echo "LANG=C" > "$mount_point/etc/default/locale"
    echo "LC_ALL=C" >> "$mount_point/etc/default/locale"
    
    # Generate the desired locale
    echo "$LOCALE UTF-8" > "$mount_point/etc/locale.gen"
    if chroot "$mount_point" locale-gen; then
        success "Locale generated successfully"
        # Now set the proper locale after generation
        echo "LANG=$LOCALE" > "$mount_point/etc/default/locale"
        echo "LC_ALL=" >> "$mount_point/etc/default/locale"
    else
        warning "Failed to generate locale, keeping C locale"
        echo "LANG=C" > "$mount_point/etc/default/locale"
    fi
    
    success "System settings configured"
}

# Configure network
configure_network() {
    local mount_point="/mnt/proxmox"
    
    info "Configuring network..."
    
    # Copy current network configuration if not specified
    if [[ -z "$NETWORK_INTERFACE" ]]; then
        # Try to preserve current network config
        if [[ -f /etc/network/interfaces ]]; then
            cp /etc/network/interfaces "$mount_point/etc/network/interfaces"
        else
            # Create basic network configuration
            local interface
            interface=$(ip route | grep default | awk '{print $5}' | head -1)
            local ip
            ip=$(ip addr show "$interface" | grep "inet " | awk '{print $2}' | head -1)
            local gateway
            gateway=$(ip route | grep default | awk '{print $3}' | head -1)
            
            cat > "$mount_point/etc/network/interfaces" << EOF
# network interface settings; autogenerated
auto lo
iface lo inet loopback

iface $interface inet manual

auto vmbr0
iface vmbr0 inet static
    address $ip
    gateway $gateway
    bridge-ports $interface
    bridge-stp off
    bridge-fd 0
EOF
        fi
    else
        # Use specified network configuration
        cat > "$mount_point/etc/network/interfaces" << EOF
# network interface settings
auto lo
iface lo inet loopback

iface $NETWORK_INTERFACE inet manual

auto vmbr0
iface vmbr0 inet static
    address $NETWORK_IP
    netmask $NETWORK_NETMASK
    gateway $NETWORK_GATEWAY
    bridge-ports $NETWORK_INTERFACE
    bridge-stp off
    bridge-fd 0
EOF
    fi
    
    # Configure DNS
    cat > "$mount_point/etc/resolv.conf" << EOF
nameserver $NETWORK_DNS1
nameserver $NETWORK_DNS2
EOF
    
    success "Network configured"
}

# Install and configure bootloader
configure_bootloader() {
    local mount_point="/mnt/proxmox"
    
    info "Configuring bootloader..."
    
    # Detect firmware type (UEFI vs Legacy BIOS)
    local firmware_type="legacy"
    local efi_partition="${EFI_PARTITION:-}"
    local grub_target="i386-pc"
    
    info "Detecting firmware type..."
    
    # Check configuration override first
    if [[ "${FIRMWARE_TYPE:-auto}" != "auto" ]]; then
        firmware_type="${FIRMWARE_TYPE}"
        info "Firmware type set by configuration: $firmware_type"
    elif [[ -d /sys/firmware/efi ]]; then
        firmware_type="uefi"
        info "UEFI firmware detected"
    else
        firmware_type="legacy"
        info "Legacy BIOS firmware detected"
    fi
    
    # Set GRUB target based on firmware type
    if [[ "$firmware_type" == "uefi" ]]; then
        grub_target="x86_64-efi"
        
        # Check for existing EFI system partition
        if [[ -z "$efi_partition" ]]; then
            local efi_partitions
            efi_partitions=$(lsblk -no NAME,FSTYPE,MOUNTPOINT | grep -E 'vfat.*(/boot/efi|/efi)' | awk '{print "/dev/" $1}' || echo "")
            
            if [[ -n "$efi_partitions" ]]; then
                efi_partition=$(echo "$efi_partitions" | head -1)
                info "Found existing EFI partition: $efi_partition"
            else
                # Look for vfat partitions that could be EFI
                efi_partitions=$(lsblk -no NAME,FSTYPE | grep vfat | awk '{print "/dev/" $1}' || echo "")
                if [[ -n "$efi_partitions" ]]; then
                    efi_partition=$(echo "$efi_partitions" | head -1)
                    warning "No mounted EFI partition found, using: $efi_partition"
                else
                    error_exit "UEFI system detected but no EFI partition found. Cannot install UEFI bootloader."
                fi
            fi
        else
            info "Using configured EFI partition: $efi_partition"
        fi
    fi
    
    # Install appropriate GRUB package
    info "Installing GRUB package for $firmware_type boot..."
    if [[ "$firmware_type" == "uefi" ]]; then
        if ! timeout 120 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y grub-efi-amd64" 2>&1; then
            warning "GRUB EFI installation may have failed or timed out, continuing..."
        else
            success "GRUB EFI package installed successfully"
        fi
        
        # Create EFI directory and mount EFI partition
        mkdir -p "$mount_point/boot/efi"
        if [[ -n "$efi_partition" ]]; then
            if ! mountpoint -q "$mount_point/boot/efi"; then
                mount "$efi_partition" "$mount_point/boot/efi" || error_exit "Failed to mount EFI partition"
                info "EFI partition mounted at $mount_point/boot/efi"
            fi
        fi
    else
        if ! timeout 120 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y grub-pc" 2>&1; then
            warning "GRUB installation may have failed or timed out, continuing..."
        else
            success "GRUB package installed successfully"
        fi
    fi
    
    # Configure GRUB debconf settings to prevent interactive prompts
    info "Configuring GRUB debconf settings..."
    if [[ "$firmware_type" == "uefi" ]]; then
        chroot "$mount_point" bash -c "echo 'grub-efi-amd64 grub2/update_nvram boolean true' | debconf-set-selections"
        chroot "$mount_point" bash -c "echo 'grub-efi-amd64 grub2/force_efi_extra_removable boolean true' | debconf-set-selections"
    else
        chroot "$mount_point" bash -c "echo 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections"
        chroot "$mount_point" bash -c "echo 'grub-pc grub-pc/install_devices multiselect' | debconf-set-selections"
    fi
    success "GRUB debconf settings configured"
    
    # Configure GRUB for ZFS
    info "Configuring GRUB for ZFS..."
    
    # Setup ZFS environment before GRUB operations
    info "Setting up ZFS environment for bootloader configuration..."
    fix_zfs_environment
    import_zfs_pool "$ZFS_ROOT_POOL_NAME"
    
    # Ensure we have the correct ZFS root dataset path
    local zfs_root_dataset="$ZFS_ROOT_POOL_NAME/ROOT/pve-1"
    
    # Backup original GRUB config if it exists
    if [[ -f "$mount_point/etc/default/grub" ]]; then
        cp "$mount_point/etc/default/grub" "$mount_point/etc/default/grub.backup"
    fi
    
    cat >> "$mount_point/etc/default/grub" << EOF

# ZFS Configuration
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="root=ZFS=$zfs_root_dataset boot=zfs"
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=false
GRUB_TIMEOUT=5
EOF
    
    # Also create a GRUB environment block to help with ZFS detection
    chroot "$mount_point" bash -c "grub-editenv /boot/grub/grubenv create 2>/dev/null || true"
    chroot "$mount_point" bash -c "grub-editenv /boot/grub/grubenv set zfs_root=$zfs_root_dataset 2>/dev/null || true"
    
    success "GRUB ZFS configuration added"
    
    # Create a script to configure GRUB with proper ZFS setup
    cat > "$mount_point/tmp/configure-grub.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Starting GRUB configuration..."
echo "Pool: $1"
echo "Drives: $2"
echo "Firmware: $3"
echo "GRUB Target: $4"

# Set environment variables for ZFS
export ZPOOL_VDEV_NAME_PATH=1
export DEBIAN_FRONTEND=noninteractive

# Function to run commands with timeout and better error reporting
run_with_timeout() {
    local timeout_duration=60
    local cmd="$1"
    echo "Running: $cmd"
    
    # Use timeout with kill signal fallback and redirect output
    if timeout --kill-after=10s "$timeout_duration" bash -c "$cmd" 2>&1; then
        echo "✓ Success: $cmd"
        return 0
    else
        echo "⚠ Command timed out after ${timeout_duration}s: $cmd"
        return 1
    fi
}

# Check if we can use rescue system ZFS
use_rescue_zfs() {
    echo "Checking for rescue system ZFS availability..."
    
    # Check if we have the rescue ZFS script
    local rescue_script="${SCRIPT_DIR}/scripts/00-rescue-zfs.sh"
    if [[ -f "$rescue_script" ]]; then
        echo "Installing rescue system ZFS..."
        if "$rescue_script"; then
            echo "✓ Rescue system ZFS installed successfully"
            return 0
        else
            echo "⚠ Rescue system ZFS installation failed"
        fi
    else
        echo "⚠ Rescue ZFS script not found at $rescue_script"
    fi
    
    return 1
}

# Fix ZFS module and pool import issues
fix_zfs_environment() {
    echo "Setting up ZFS environment..."
    
    # First, try to load ZFS module
    local zfs_loaded=false
    
    # Method 1: Try normal module loading
    if modprobe zfs 2>/dev/null; then
        echo "✓ ZFS module loaded successfully"
        zfs_loaded=true
    else
        echo "Warning: Could not load ZFS module from kernel, trying rescue system..."
        
        # Method 2: Try rescue system ZFS if available
        if use_rescue_zfs; then
            zfs_loaded=true
        else
            echo "⚠ Warning: ZFS module could not be loaded, GRUB may have issues"
        fi
    fi
    
    # Clean up any existing ZFS locks/processes that might interfere
    echo "Cleaning up ZFS environment..."
    pkill -9 zfs 2>/dev/null || true
    pkill -9 zpool 2>/dev/null || true
    rm -f /var/lock/zfs/* 2>/dev/null || true
    
    # Wait for cleanup
    sleep 2
    
    return 0
}

# Import pool with better error handling
import_zfs_pool() {
    local pool_name="$1"
    
    echo "Importing ZFS pool: $pool_name"
    
    # Check if pool is already imported
    if timeout 10 zpool list "$pool_name" >/dev/null 2>&1; then
        echo "✓ Pool $pool_name is already imported"
        return 0
    fi
    
    # Ensure ZFS module is loaded before attempting import
    if ! lsmod | grep -q "^zfs "; then
        echo "ZFS module not loaded, attempting to load..."
        if ! modprobe zfs 2>/dev/null; then
            echo "⚠ Warning: Failed to load ZFS module, pool import may fail"
        else
            echo "✓ ZFS module loaded successfully"
            # Give module time to initialize
            sleep 3
        fi
    fi
    
    # Try to import the pool
    echo "Pool not found, attempting import..."
    
    # Method 1: Simple import with longer timeout
    if timeout 60 zpool import -f "$pool_name" 2>/dev/null; then
        echo "✓ Pool imported successfully"
        return 0
    fi
    
    # Method 2: Import by looking for pools
    echo "Simple import failed, scanning for pools..."
    local available_pools
    if available_pools=$(timeout 60 zpool import 2>/dev/null | grep "pool:" | awk '{print $2}' | head -10); then
        if echo "$available_pools" | grep -q "^$pool_name$"; then
            echo "Found pool in scan, importing..."
            if timeout 60 zpool import -f "$pool_name" 2>/dev/null; then
                echo "✓ Pool imported after scan"
                return 0
            fi
        else
            echo "Available pools found: $available_pools"
            echo "Target pool $pool_name not found in scan"
        fi
    fi
    
    # Method 3: Import with directory scan (last resort)
    echo "Standard import failed, trying directory scan..."
    if timeout 60 zpool import -d /dev -f "$pool_name" 2>/dev/null; then
        echo "✓ Pool imported with directory scan"
        return 0
    fi
    
    echo "⚠ Warning: Could not import pool $pool_name, continuing without import"
    return 1
}

# Update initramfs to include ZFS
echo "Updating initramfs (this may take a few minutes)..."
if run_with_timeout "update-initramfs -u -k all 2>&1"; then
    echo "✓ Initramfs updated successfully"
else
    echo "⚠ Warning: Initramfs update failed or timed out, trying fallback..."
    # Try without all kernels
    if run_with_timeout "update-initramfs -u 2>&1"; then
        echo "✓ Initramfs updated with fallback method"
    else
        echo "⚠ Warning: All initramfs update attempts failed"
    fi
fi

# Update GRUB configuration with better ZFS handling
echo "Updating GRUB configuration..."

# Create a working GRUB configuration that bypasses filesystem detection issues
echo "Creating GRUB configuration..."
cat > /etc/default/grub << 'GRUB_EOF'
# GRUB configuration for ZFS - Proxmox installation
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Proxmox VE"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="root=ZFS=$1/ROOT/pve-1 boot=zfs"
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=false
GRUB_EOF

# Get kernel version for manual GRUB config
KERNEL_VERSION=""
for kernel_file in /boot/vmlinuz-*; do
    if [[ -f "$kernel_file" ]]; then
        KERNEL_VERSION=$(basename "$kernel_file" | sed 's/vmlinuz-//')
        echo "Found kernel: $KERNEL_VERSION"
        break
    fi
done

if [[ -z "$KERNEL_VERSION" ]]; then
    echo "⚠ Warning: No kernel found, detecting from package manager..."
    # Try to get kernel version from dpkg
    KERNEL_VERSION=$(dpkg -l | grep linux-image | head -1 | awk '{print $2}' | sed 's/linux-image-//' || echo "")
    if [[ -n "$KERNEL_VERSION" ]]; then
        echo "Found kernel from packages: $KERNEL_VERSION"
    else
        echo "⚠ Warning: Could not detect kernel version, using fallback"
        KERNEL_VERSION="6.8.12-11-pve"  # Fallback to known Proxmox kernel
    fi
fi

# Create minimal GRUB configuration manually to avoid filesystem detection issues
mkdir -p /boot/grub
cat > /boot/grub/grub.cfg << MANUAL_GRUB_EOF
set timeout=5
set default=0

menuentry "Proxmox VE" {
    linux /boot/vmlinuz-$KERNEL_VERSION root=ZFS=$1/ROOT/pve-1 boot=zfs quiet
    initrd /boot/initrd.img-$KERNEL_VERSION
}

menuentry "Proxmox VE (Recovery)" {
    linux /boot/vmlinuz-$KERNEL_VERSION root=ZFS=$1/ROOT/pve-1 boot=zfs single
    initrd /boot/initrd.img-$KERNEL_VERSION
}
MANUAL_GRUB_EOF

echo "✓ GRUB configuration created manually with kernel: $KERNEL_VERSION"

# Try to update GRUB configuration (but don't fail if it doesn't work since we have manual config)
if run_with_timeout "update-grub 2>&1"; then
    echo "✓ GRUB configuration updated via update-grub"
elif run_with_timeout "grub-mkconfig -o /boot/grub/grub.cfg 2>&1"; then
    echo "✓ GRUB configuration created via grub-mkconfig"
else
    echo "⚠ Warning: Standard GRUB update failed, using manual configuration"
fi

# Install GRUB to boot devices
firmware_type="$3"
grub_target="$4"

if [[ "$firmware_type" == "uefi" ]]; then
    echo "Installing GRUB for UEFI boot..."
    
    # Install GRUB to EFI system partition
    if run_with_timeout "grub-install --target=$grub_target --efi-directory=/boot/efi --bootloader-id=proxmox --recheck 2>&1"; then
        echo "✓ GRUB EFI installed successfully"
        
        # Create fallback boot entry for removable media
        if run_with_timeout "grub-install --target=$grub_target --efi-directory=/boot/efi --bootloader-id=proxmox --removable 2>&1"; then
            echo "✓ GRUB EFI fallback entry created"
        else
            echo "⚠ Warning: Could not create GRUB EFI fallback entry"
        fi
        
        echo "✓ UEFI GRUB configuration completed successfully"
        exit 0
    else
        echo "⚠ Error: GRUB EFI installation failed"
        exit 1
    fi
else
    echo "Installing GRUB for Legacy BIOS boot to drives: $2"
    failed_drives=0
    installed_drives=0

    for drive in $2; do
        # Clean up drive path
        drive=$(echo "$drive" | sed 's/[[:space:]]*$//')
        if [[ -n "$drive" && -b "$drive" ]]; then
            echo "Installing GRUB to $drive..."
            
            # Method 1: Try with --skip-fs-probe to avoid filesystem detection issues
            if run_with_timeout "grub-install --target=$grub_target --boot-directory=/boot --force --skip-fs-probe $drive 2>&1"; then
                echo "✓ GRUB installed successfully to $drive (skip-fs-probe)"
                ((installed_drives++))
            # Method 2: Try with --allow-floppy for compatibility
            elif run_with_timeout "grub-install --target=$grub_target --boot-directory=/boot --force --allow-floppy $drive 2>&1"; then
                echo "✓ GRUB installed successfully to $drive (allow-floppy)"
                ((installed_drives++))
            # Method 3: Try with --no-floppy
            elif run_with_timeout "grub-install --target=$grub_target --boot-directory=/boot --force --no-floppy $drive 2>&1"; then
                echo "✓ GRUB installed successfully to $drive (no-floppy)"
                ((installed_drives++))
            # Method 4: Last resort - basic install without probing
            elif timeout 30 grub-install --target=$grub_target --force --skip-fs-probe --no-floppy $drive 2>/dev/null; then
                echo "✓ GRUB installed successfully to $drive (basic)"
                ((installed_drives++))
            else
                echo "⚠ Warning: Failed to install GRUB to $drive"
                ((failed_drives++))
            fi
        else
            echo "⚠ Skipping invalid drive: '$drive'"
        fi
    done

    echo "GRUB installation summary:"
    echo "- Successfully installed to $installed_drives drive(s)"
    echo "- Failed on $failed_drives drive(s)"

    if [[ $installed_drives -gt 0 ]]; then
        echo "✓ Legacy BIOS GRUB configuration completed! Successfully installed to $installed_drives drive(s)"
        exit 0
    else
        echo "⚠ Error: GRUB installation failed on all drives"
        exit 1
    fi
fi
EOF

    chmod +x "$mount_point/tmp/configure-grub.sh"
    
    # Get the list of drives in the root pool
    info "Detecting drives in root pool..."
    local root_drives=""
    
    # Clean up any hung ZFS processes before detection
    cleanup_zfs_processes
    
    # Function to run ZFS commands with timeout
    run_zfs_command() {
        local cmd="$1"
        local timeout_duration=30
        info "Running: $cmd (timeout: ${timeout_duration}s)"
        
        # Run command in background to get PID for cleanup if needed
        if timeout --kill-after=5s "$timeout_duration" bash -c "$cmd" 2>/dev/null; then
            return 0
        else
            warning "Command timed out after ${timeout_duration}s: $cmd"
            
            # Clean up any hung processes from this command
            local cmd_name
            cmd_name=$(echo "$cmd" | awk '{print $1}')
            if pgrep -f "$cmd_name" >/dev/null 2>&1; then
                warning "Killing hung $cmd_name processes..."
                pkill -9 -f "$cmd_name" 2>/dev/null || true
                sleep 1
            fi
            
            return 1
        fi
    }
    
    # Verify ZFS is functional before attempting drive detection
    info "Verifying ZFS functionality..."
    local zfs_attempts=0
    local max_attempts=3
    
    while [[ $zfs_attempts -lt $max_attempts ]]; do
        if timeout 10 zpool list >/dev/null 2>&1; then
            success "ZFS is functional"
            break
        else
            ((zfs_attempts++))
            warning "ZFS commands not responding (attempt $zfs_attempts/$max_attempts)"
            
            if [[ $zfs_attempts -lt $max_attempts ]]; then
                warning "Attempting ZFS recovery..."
                cleanup_zfs_processes
                
                # Try to load ZFS module
                modprobe zfs 2>/dev/null || warning "Could not load ZFS module"
                sleep 2
            else
                error_exit "ZFS is not functional after $max_attempts attempts. Cannot detect drives for GRUB installation."
            fi
        fi
    done
    
    # Method 1: Try to get drives from cache first (fastest method)
    info "Trying ZFS cache method..."
    if [[ -f /etc/zfs/zpool.cache ]]; then
        # Try to read drive info from cache without running zfs commands
        local cache_drives
        # Add timeout to prevent hanging on cache file operations
        if cache_drives=$(timeout 10 bash -c "strings /etc/zfs/zpool.cache 2>/dev/null | grep -E '^/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+)$' | sort -u | tr '\n' ' '" 2>/dev/null); then
            if [[ -n "$cache_drives" ]]; then
                root_drives="$cache_drives"
                info "Found drives from ZFS cache: $root_drives"
            else
                info "ZFS cache file processed but no drives found"
            fi
        else
            warning "ZFS cache processing timed out or failed, trying alternative methods"
        fi
    else
        info "No ZFS cache file found"
    fi
    
    if [[ -z "$root_drives" ]]; then
        # Method 2: Look for drives with /dev/ prefix using zpool status
        info "Trying zpool status method..."
        if run_zfs_command "zpool status '$ZFS_ROOT_POOL_NAME' >/tmp/zpool_status.tmp 2>&1"; then
            if [[ -f /tmp/zpool_status.tmp ]]; then
                root_drives=$(timeout 5 bash -c "grep -E '^\s+/dev/' /tmp/zpool_status.tmp | awk '{print \$1}' | tr '\n' ' '" 2>/dev/null || echo "")
                if [[ -n "$root_drives" ]]; then
                    info "Found drives with /dev/ prefix: $root_drives"
                else
                    info "zpool status completed but no /dev/ drives found"
                fi
            else
                warning "zpool status did not create output file"
            fi
        else
            warning "zpool status command failed or timed out"
        fi
    fi
    
    if [[ -z "$root_drives" ]]; then
        info "No /dev/ prefixed drives found, trying alternative methods..."
        # Method 3: Look for nvme/sd drives without /dev/ prefix and add it
        if [[ -f /tmp/zpool_status.tmp ]]; then
            root_drives=$(timeout 5 bash -c "grep -E '^\s+(nvme[0-9]+n[0-9]+|sd[a-z]+)' /tmp/zpool_status.tmp | awk '{print \"/dev/\" \$1}' | tr '\n' ' '" 2>/dev/null || echo "")
            if [[ -n "$root_drives" ]]; then
                info "Found drives without /dev/ prefix: $root_drives"
            else
                info "No nvme/sd drives found in zpool status output"
            fi
        else
            info "No zpool status output file available for processing"
        fi
    fi
    
    if [[ -z "$root_drives" ]]; then
        info "Trying zpool list method..."
        # Method 4: Try zpool list -v
        if run_zfs_command "zpool list -v '$ZFS_ROOT_POOL_NAME' >/tmp/zpool_list.tmp 2>&1"; then
            if [[ -f /tmp/zpool_list.tmp ]]; then
                root_drives=$(timeout 5 bash -c "grep -E '^\s+/dev/' /tmp/zpool_list.tmp | awk '{print \$1}' | tr '\n' ' '" 2>/dev/null || echo "")
                if [[ -n "$root_drives" ]]; then
                    info "Found drives using zpool list: $root_drives"
                else
                    info "zpool list completed but no /dev/ drives found"
                fi
            else
                warning "zpool list did not create output file"
            fi
        else
            warning "zpool list command failed or timed out"
        fi
    fi
    
    if [[ -z "$root_drives" ]]; then
        info "Trying zpool list with device name detection..."
        # Method 5: Try zpool list -v with device name detection
        if [[ -f /tmp/zpool_list.tmp ]]; then
            root_drives=$(timeout 5 bash -c "grep -E '^\s+(nvme[0-9]+n[0-9]+|sd[a-z]+)' /tmp/zpool_list.tmp | awk '{print \"/dev/\" \$1}' | tr '\n' ' '" 2>/dev/null || echo "")
            if [[ -n "$root_drives" ]]; then
                info "Found drives using zpool list without /dev/: $root_drives"
            else
                info "No nvme/sd drives found in zpool list output"
            fi
        else
            info "No zpool list output file available for processing"
        fi
    fi
    
    if [[ -z "$root_drives" ]]; then
        warning "Could not detect drives from ZFS commands, attempting manual detection..."
        # Method 6: Try to get drives from zpool cache
        if [[ -f /etc/zfs/zpool.cache ]]; then
            info "Checking zpool cache..."
            if run_zfs_command "zdb -C '$ZFS_ROOT_POOL_NAME' >/tmp/zdb_output.tmp 2>&1"; then
                if [[ -f /tmp/zdb_output.tmp ]]; then
                    root_drives=$(timeout 5 bash -c "grep -oE '\"/dev/[^\"]+' /tmp/zdb_output.tmp | sed 's/\"//g' | tr '\n' ' '" 2>/dev/null || echo "")
                    if [[ -n "$root_drives" ]]; then
                        info "Found drives from zpool cache: $root_drives"
                    else
                        info "zdb completed but no drives found in cache"
                    fi
                else
                    warning "zdb did not create output file"
                fi
            else
                warning "zdb command failed or timed out"
            fi
        else
            info "No zpool cache file available for zdb analysis"
        fi
    fi
    
    if [[ -z "$root_drives" ]]; then
        # Last resort: try to find the drives manually
        warning "All ZFS detection methods failed, using system drive detection..."
        root_drives=$(lsblk -nd -o NAME,TYPE | grep disk | awk '{print "/dev/" $1}' | head -2 | tr '\n' ' ')
        info "Using system drives: $root_drives"
        
        # Also try checking the original config for drives used in setup
        if [[ -f /tmp/drives_used_for_zfs.txt ]]; then
            info "Checking ZFS setup log for drives..."
            local config_drives
            config_drives=$(cat /tmp/drives_used_for_zfs.txt 2>/dev/null | tr '\n' ' ')
            if [[ -n "$config_drives" ]]; then
                info "Found drives from ZFS setup log: $config_drives"
                root_drives="$config_drives"
            fi
        fi
    fi
    
    # Clean up temporary files
    rm -f /tmp/zpool_status.tmp /tmp/zpool_list.tmp /tmp/zdb_output.tmp
    
    info "Root pool drives detected: $root_drives"
    
    # Validate that we have drives
    if [[ -z "$root_drives" ]]; then
        error_exit "No drives found for GRUB installation. Cannot proceed with bootloader configuration."
    fi
    
    # Run GRUB configuration in chroot with better error handling
    info "Starting GRUB configuration process..."
    info "This may take several minutes - please wait..."
    
    # Set a longer timeout for the complete GRUB configuration process
    if timeout --kill-after=30s 300s chroot "$mount_point" /tmp/configure-grub.sh "$ZFS_ROOT_POOL_NAME" "$root_drives" "$firmware_type" "$grub_target" 2>&1; then
        success "GRUB configuration completed successfully"
    else
        warning "GRUB configuration script failed or timed out after 5 minutes, attempting manual recovery..."
        
        # Ensure chroot environment is still set up
        mount --bind /dev "$mount_point/dev" 2>/dev/null || true
        mount --bind /proc "$mount_point/proc" 2>/dev/null || true
        mount --bind /sys "$mount_point/sys" 2>/dev/null || true
        
        # Manual GRUB installation as fallback
        info "Performing manual GRUB configuration..."
        
        # Ensure chroot environment is still set up
        mount --bind /dev "$mount_point/dev" 2>/dev/null || true
        mount --bind /proc "$mount_point/proc" 2>/dev/null || true
        mount --bind /sys "$mount_point/sys" 2>/dev/null || true
        
        # Set up ZFS environment in chroot
        chroot "$mount_point" bash -c "export DEBIAN_FRONTEND=noninteractive; modprobe zfs 2>/dev/null || echo 'ZFS module load failed'"
        
        # Try to import pool with better error handling
        chroot "$mount_point" bash -c "timeout 30 zpool import -f '$ZFS_ROOT_POOL_NAME' 2>/dev/null || echo 'Pool import failed or timed out'"
        
        # Verify ZFS dataset exists and is accessible
        if chroot "$mount_point" bash -c "timeout 10 zfs list '$ZFS_ROOT_POOL_NAME/ROOT/pve-1' >/dev/null 2>&1"; then
            info "ZFS dataset verified successfully"
        else
            warning "ZFS dataset verification failed, but continuing with GRUB installation"
        fi
        
        info "Updating initramfs manually..."
        if ! timeout 120 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive update-initramfs -u -k all"; then
            warning "Initramfs update timed out or failed, trying single kernel update"
            if ! timeout 60 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive update-initramfs -u"; then
                warning "All initramfs update attempts failed"
            fi
        fi
        
        info "Updating GRUB configuration manually..."
        
        # Create a working GRUB config manually if update-grub fails
        if ! timeout 60 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive update-grub"; then
            warning "GRUB configuration update failed, creating manual config"
            
            # Create minimal GRUB configuration
            chroot "$mount_point" bash -c "
            mkdir -p /boot/grub
            cat > /boot/grub/grub.cfg << 'GRUB_EOF'
set timeout=5
set default=0

menuentry \"Proxmox VE\" {
    linux /boot/vmlinuz root=ZFS=$ZFS_ROOT_POOL_NAME/ROOT/pve-1 boot=zfs quiet
    initrd /boot/initrd.img
}

menuentry \"Proxmox VE (Recovery)\" {
    linux /boot/vmlinuz root=ZFS=$ZFS_ROOT_POOL_NAME/ROOT/pve-1 boot=zfs single
    initrd /boot/initrd.img
}
GRUB_EOF
            "
            success "Manual GRUB configuration created"
        fi
        
        # Install GRUB to each drive individually with multiple methods
        for drive in $root_drives; do
            drive=$(echo "$drive" | sed 's/[[:space:]]*$//')
            if [[ -n "$drive" && -b "$drive" ]]; then
                info "Installing GRUB to $drive manually..."
                if [[ "$firmware_type" == "uefi" ]]; then
                    if timeout 60 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive grub-install --target=$grub_target --efi-directory=/boot/efi --bootloader-id=proxmox --recheck $drive"; then
                        success "GRUB EFI installed to $drive"
                    else
                        warning "Failed to install GRUB EFI to $drive - system may not boot from this drive"
                    fi
                else
                    # Try multiple methods for Legacy BIOS GRUB installation
                    local grub_success=false
                    
                    # Method 1: Skip filesystem probe
                    if timeout 60 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive grub-install --target=$grub_target --boot-directory=/boot --force --skip-fs-probe $drive" 2>/dev/null; then
                        success "GRUB installed to $drive (skip-fs-probe)"
                        grub_success=true
                    # Method 2: Allow floppy compatibility
                    elif timeout 60 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive grub-install --target=$grub_target --boot-directory=/boot --force --allow-floppy $drive" 2>/dev/null; then
                        success "GRUB installed to $drive (allow-floppy)"
                        grub_success=true
                    # Method 3: No floppy
                    elif timeout 60 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive grub-install --target=$grub_target --boot-directory=/boot --force --no-floppy $drive" 2>/dev/null; then
                        success "GRUB installed to $drive (no-floppy)"
                        grub_success=true
                    # Method 4: Direct from rescue system
                    elif timeout 60 bash -c "DEBIAN_FRONTEND=noninteractive grub-install --target=$grub_target --boot-directory=$mount_point/boot --force --skip-fs-probe $drive" 2>/dev/null; then
                        success "GRUB installed to $drive (direct from rescue)"
                        grub_success=true
                    fi
                    
                    if [[ "$grub_success" != "true" ]]; then
                        warning "Failed to install GRUB to $drive with all methods - system may not boot from this drive"
                    fi
                fi
            fi
        done
        
        # Verify GRUB installation
        info "Verifying GRUB installation..."
        local grub_verified=false
        
        for drive in $root_drives; do
            drive=$(echo "$drive" | sed 's/[[:space:]]*$//')
            if [[ -n "$drive" && -b "$drive" ]]; then
                if dd if="$drive" bs=512 count=1 2>/dev/null | grep -q "GRUB" 2>/dev/null; then
                    success "GRUB signature verified on $drive"
                    grub_verified=true
                else
                    warning "No GRUB signature found on $drive"
                fi
            fi
        done
        
        if [[ "$grub_verified" == "true" ]]; then
            success "Manual GRUB configuration completed successfully"
        else
            warning "Manual GRUB configuration completed but GRUB signatures not detected"
        fi
    fi
    
    success "Bootloader configured"
}

# Configure SSH
configure_ssh() {
    local mount_point="/mnt/proxmox"
    
    if [[ "$ENABLE_SSH" == "yes" ]]; then
        info "Configuring SSH..."
        
        chroot "$mount_point" systemctl enable ssh
        
        # Configure SSH for security
        cat >> "$mount_point/etc/ssh/sshd_config" << EOF

# Additional security settings
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
        
        success "SSH configured"
    fi
}

# Cleanup chroot
cleanup_chroot() {
    local mount_point="/mnt/proxmox"
    
    info "Cleaning up chroot environment..."
    
    # Kill any processes that might be keeping mounts busy
    local chroot_pids
    chroot_pids=$(lsof +D "$mount_point" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || echo "")
    if [[ -n "$chroot_pids" ]]; then
        warning "Found processes using chroot directory, terminating..."
        echo "$chroot_pids" | xargs -r kill -TERM 2>/dev/null || true
        sleep 2
        echo "$chroot_pids" | xargs -r kill -KILL 2>/dev/null || true
        sleep 1
    fi
    
    # Force unmount with retries - but don't fail the script if it doesn't work
    local max_retries=3
    local retry_count=0
    
    # Unmount in reverse order with retries
    for mount_path in "$mount_point/dev/pts" "$mount_point/dev" "$mount_point/proc" "$mount_point/sys"; do
        retry_count=0
        while [[ $retry_count -lt $max_retries ]]; do
            if mountpoint -q "$mount_path" 2>/dev/null; then
                if umount "$mount_path" 2>/dev/null; then
                    break
                else
                    ((retry_count++))
                    if [[ $retry_count -eq $max_retries ]]; then
                        warning "Could not unmount $mount_path after $max_retries attempts, forcing..."
                        umount -f -l "$mount_path" 2>/dev/null || true
                    else
                        sleep 1
                    fi
                fi
            else
                break
            fi
        done
    done
    
    # Unmount main ZFS filesystem - don't fail if this doesn't work since post-install will handle it
    retry_count=0
    while [[ $retry_count -lt $max_retries ]]; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            if umount "$mount_point" 2>/dev/null; then
                info "Unmounted $mount_point successfully"
                break
            else
                ((retry_count++))
                if [[ $retry_count -eq $max_retries ]]; then
                    warning "Could not unmount $mount_point - post-install script will handle this"
                    # Don't force unmount here, let post-install deal with it
                    break
                else
                    sleep 2
                fi
            fi
        else
            break
        fi
    done
    
    # Unmount ISO
    if mountpoint -q /mnt/proxmox-iso 2>/dev/null; then
        umount /mnt/proxmox-iso || umount -f /mnt/proxmox-iso 2>/dev/null || true
    fi
    
    success "Cleanup completed (some mounts may remain for post-install)"
}

# Main function
main() {
    # Check for debug flag
    if [[ "${1:-}" == "--debug" ]]; then
        debug_system_state
        debug_zfs_state
        exit 0
    fi
    
    info "Starting Proxmox installation..."
    
    # Verify prerequisites
    if ! command -v debootstrap >/dev/null 2>&1; then
        error_exit "debootstrap is not installed. Please run 01-prepare-system.sh first."
    fi
    
    # Setup error handling for critical failures
    local installation_failed=false
    
    # Execute installation steps with error handling
    if ! check_root_pool; then
        error_exit "Root pool check failed. Please run 02-setup-zfs.sh first."
    fi
    
    download_proxmox_iso
    mount_proxmox_iso
    install_base_system
    setup_chroot
    
    if ! install_proxmox_packages; then
        warning "Proxmox package installation had issues, but continuing..."
        installation_failed=true
    fi
    
    configure_system
    configure_network
    
    if ! configure_bootloader; then
        warning "Bootloader configuration had issues, system may not boot properly"
        installation_failed=true
    fi
    
    configure_ssh
    cleanup_chroot
    
    if [[ "$installation_failed" == "true" ]]; then
        warning "Installation completed with some issues. Please check the log for details."
        echo
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${YELLOW}  INSTALLATION COMPLETED WITH ISSUES  ${NC}"
        echo -e "${YELLOW}========================================${NC}"
        echo
        echo -e "${RED}Some components may not function correctly.${NC}"
        echo -e "${BLUE}Please review the installation log before proceeding.${NC}"
    else
        success "Proxmox installation completed!"
        echo
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}  PROXMOX INSTALLATION COMPLETED!     ${NC}"
        echo -e "${GREEN}========================================${NC}"
    fi
    
    echo
    echo -e "${BLUE}Next steps:${NC}"
    echo -e "${BLUE}1.${NC} Run the post-installation script:"
    echo -e "   ${YELLOW}./scripts/04-post-install.sh${NC}"
    echo
    echo -e "${BLUE}2.${NC} After post-install completes, you will need to:"
    echo -e "   ${YELLOW}reboot${NC}"
    echo
    echo -e "${BLUE}3.${NC} The system should boot into Proxmox VE"
    echo -e "   Access the web interface at: ${YELLOW}https://$(ip route get 1.1.1.1 | grep src | awk '{print $7}'):8006${NC}"
    echo
    echo -e "${GREEN}Installation log available at: ${YELLOW}/tmp/proxmox-install.log${NC}"
    echo
}

main "$@"
