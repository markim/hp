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
    postfix \
    open-iscsi \
    chrony

# Try to install ZFS utilities from packages first
if ! apt-get install -y zfsutils-linux 2>/dev/null; then
    echo "Warning: Could not install zfsutils-linux package"
    
    # Use rescue system ZFS if package installation fails
    if [[ -f /tmp/install-rescue-zfs.sh ]]; then
        echo "Installing ZFS from rescue system..."
        /tmp/install-rescue-zfs.sh
    else
        echo "Error: No ZFS installation method available"
        exit 1
    fi
else
    echo "ZFS utilities installed from packages"
    
    # Check for symbol compatibility issues
    if ! /sbin/mount.zfs --help >/dev/null 2>&1; then
        echo "Warning: Package ZFS has compatibility issues, using rescue system ZFS"
        if [[ -f /tmp/install-rescue-zfs.sh ]]; then
            /tmp/install-rescue-zfs.sh
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
    
    # Install GRUB
    info "Installing GRUB package..."
    if ! timeout 120 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y grub-pc" 2>&1; then
        warning "GRUB installation may have failed or timed out, continuing..."
    else
        success "GRUB package installed successfully"
    fi
    
    # Configure GRUB defaults to prevent interactive prompts
    info "Configuring GRUB debconf settings..."
    chroot "$mount_point" bash -c "echo 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections"
    chroot "$mount_point" bash -c "echo 'grub-pc grub-pc/install_devices multiselect' | debconf-set-selections"
    success "GRUB debconf settings configured"
    
    # Configure GRUB for ZFS
    info "Configuring GRUB for ZFS..."
    cat >> "$mount_point/etc/default/grub" << EOF

# ZFS Configuration
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="root=ZFS=$ZFS_ROOT_POOL_NAME/ROOT/pve-1"
EOF
    success "GRUB ZFS configuration added"
    
    # Create a script to configure GRUB with proper ZFS setup
    cat > "$mount_point/tmp/configure-grub.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Starting GRUB configuration..."
echo "Pool: $1"
echo "Drives: $2"

# Set environment variables for ZFS
export ZPOOL_VDEV_NAME_PATH=1
export DEBIAN_FRONTEND=noninteractive

# Function to run commands with timeout and better error reporting
run_with_timeout() {
    local timeout_duration=90
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

# Make sure ZFS modules are loaded
echo "Loading ZFS modules..."
if ! modprobe zfs 2>/dev/null; then
    echo "Warning: Could not load ZFS module, trying to continue..."
fi

# Import the pool if not already imported
echo "Checking ZFS pool status..."
if ! zpool list "$1" >/dev/null 2>&1; then
    echo "Importing ZFS pool $1..."
    if ! timeout 30 zpool import -f "$1" 2>/dev/null; then
        echo "Warning: Pool import failed or timed out, continuing..."
    fi
else
    echo "✓ Pool $1 is already imported"
fi

# Configure GRUB defaults for non-interactive mode
echo "Configuring GRUB debconf settings..."
echo 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections
echo 'grub-pc grub-pc/install_devices multiselect' | debconf-set-selections
echo "✓ GRUB debconf configured"

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

# Update GRUB configuration  
echo "Updating GRUB configuration..."
if run_with_timeout "update-grub 2>&1"; then
    echo "✓ GRUB configuration updated"
else
    echo "⚠ Warning: GRUB configuration update failed or timed out, trying manual method..."
    # Try manual grub config generation
    if run_with_timeout "grub-mkconfig -o /boot/grub/grub.cfg 2>&1"; then
        echo "✓ GRUB configuration created manually"
    else
        echo "⚠ Warning: All GRUB configuration attempts failed"
    fi
fi

# Install GRUB to boot devices
echo "Installing GRUB to drives: $2"
failed_drives=0
installed_drives=0

for drive in $2; do
    # Clean up drive path
    drive=$(echo "$drive" | sed 's/[[:space:]]*$//')
    if [[ -n "$drive" && -b "$drive" ]]; then
        echo "Installing GRUB to $drive..."
        if run_with_timeout "grub-install --target=i386-pc --force $drive 2>&1"; then
            echo "✓ GRUB installed successfully to $drive"
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
    echo "✓ GRUB configuration completed! Successfully installed to $installed_drives drive(s)"
    exit 0
else
    echo "⚠ Error: GRUB installation failed on all drives"
    exit 1
fi
EOF
    
    chmod +x "$mount_point/tmp/configure-grub.sh"
    
    # Get the list of drives in the root pool
    info "Detecting drives in root pool..."
    local root_drives
    
    # Function to run ZFS commands with timeout
    run_zfs_command() {
        local cmd="$1"
        local timeout_duration=30
        info "Running: $cmd (timeout: ${timeout_duration}s)"
        
        if timeout "$timeout_duration" bash -c "$cmd" 2>/dev/null; then
            return 0
        else
            warning "Command timed out after ${timeout_duration}s: $cmd"
            return 1
        fi
    }
    
    # Verify ZFS is functional before attempting drive detection
    info "Verifying ZFS functionality..."
    if ! timeout 10 zpool list >/dev/null 2>&1; then
        warning "ZFS commands are not responding, trying to load modules..."
        modprobe zfs || warning "Could not load ZFS module"
        
        if ! timeout 10 zpool list >/dev/null 2>&1; then
            error_exit "ZFS is not functional. Cannot detect drives for GRUB installation."
        fi
    fi
    success "ZFS is functional"
    
    # Method 1: Look for drives with /dev/ prefix using zpool status
    info "Trying zpool status method..."
    if run_zfs_command "zpool status '$ZFS_ROOT_POOL_NAME' >/tmp/zpool_status.tmp 2>&1"; then
        root_drives=$(grep -E '^\s+/dev/' /tmp/zpool_status.tmp | awk '{print $1}' | tr '\n' ' ')
        info "Found drives with /dev/ prefix: $root_drives"
    else
        warning "zpool status command failed or timed out"
    fi
    
    if [[ -z "$root_drives" ]]; then
        info "No /dev/ prefixed drives found, trying alternative methods..."
        # Method 2: Look for nvme/sd drives without /dev/ prefix and add it
        if [[ -f /tmp/zpool_status.tmp ]]; then
            root_drives=$(grep -E '^\s+(nvme[0-9]+n[0-9]+|sd[a-z]+)' /tmp/zpool_status.tmp | awk '{print "/dev/" $1}' | tr '\n' ' ')
            info "Found drives without /dev/ prefix: $root_drives"
        fi
    fi
    
    if [[ -z "$root_drives" ]]; then
        info "Trying zpool list method..."
        # Method 3: Try zpool list -v
        if run_zfs_command "zpool list -v '$ZFS_ROOT_POOL_NAME' >/tmp/zpool_list.tmp 2>&1"; then
            root_drives=$(grep -E '^\s+/dev/' /tmp/zpool_list.tmp | awk '{print $1}' | tr '\n' ' ')
            info "Found drives using zpool list: $root_drives"
        fi
    fi
    
    if [[ -z "$root_drives" ]]; then
        info "Trying zpool list with device name detection..."
        # Method 4: Try zpool list -v with device name detection
        if [[ -f /tmp/zpool_list.tmp ]]; then
            root_drives=$(grep -E '^\s+(nvme[0-9]+n[0-9]+|sd[a-z]+)' /tmp/zpool_list.tmp | awk '{print "/dev/" $1}' | tr '\n' ' ')
            info "Found drives using zpool list without /dev/: $root_drives"
        fi
    fi
    
    if [[ -z "$root_drives" ]]; then
        warning "Could not detect drives from ZFS commands, attempting manual detection..."
        # Method 5: Try to get drives from zpool cache
        if [[ -f /etc/zfs/zpool.cache ]]; then
            info "Checking zpool cache..."
            if run_zfs_command "zdb -C '$ZFS_ROOT_POOL_NAME' >/tmp/zdb_output.tmp 2>&1"; then
                root_drives=$(grep -oE '"/dev/[^"]+' /tmp/zdb_output.tmp | sed 's/"//g' | tr '\n' ' ')
                info "Found drives from zpool cache: $root_drives"
            fi
        fi
    fi
    
    if [[ -z "$root_drives" ]]; then
        # Last resort: try to find the drives manually
        warning "All ZFS detection methods failed, using system drive detection..."
        root_drives=$(lsblk -nd -o NAME,TYPE | grep disk | awk '{print "/dev/" $1}' | head -2 | tr '\n' ' ')
        info "Using system drives: $root_drives"
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
    if timeout --kill-after=30s 300s chroot "$mount_point" /tmp/configure-grub.sh "$ZFS_ROOT_POOL_NAME" "$root_drives" 2>&1; then
        success "GRUB configuration completed successfully"
    else
        warning "GRUB configuration script failed or timed out after 5 minutes, attempting manual recovery..."
        
        # Ensure chroot environment is still set up
        mount --bind /dev "$mount_point/dev" 2>/dev/null || true
        mount --bind /proc "$mount_point/proc" 2>/dev/null || true
        mount --bind /sys "$mount_point/sys" 2>/dev/null || true
        
        # Manual GRUB installation as fallback
        info "Performing manual GRUB configuration..."
        chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive modprobe zfs || true"
        chroot "$mount_point" bash -c "timeout 30 zpool import -f '$ZFS_ROOT_POOL_NAME' || true"
        
        info "Updating initramfs manually..."
        if ! timeout 120 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive update-initramfs -u -k all"; then
            warning "Initramfs update timed out or failed"
        fi
        
        info "Updating GRUB configuration manually..."
        if ! timeout 60 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive update-grub"; then
            warning "GRUB configuration update timed out or failed"
        fi
        
        # Install GRUB to each drive individually
        for drive in $root_drives; do
            drive=$(echo "$drive" | sed 's/[[:space:]]*$//')
            if [[ -n "$drive" && -b "$drive" ]]; then
                info "Installing GRUB to $drive manually..."
                if timeout 60 chroot "$mount_point" bash -c "DEBIAN_FRONTEND=noninteractive grub-install --target=i386-pc --force $drive"; then
                    success "GRUB installed to $drive"
                else
                    warning "Failed to install GRUB to $drive - system may not boot from this drive"
                fi
            fi
        done
        
        warning "Manual GRUB configuration completed with potential issues"
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
    
    # Unmount filesystems
    umount "$mount_point/dev/pts" || true
    umount "$mount_point/dev" || true
    umount "$mount_point/proc" || true
    umount "$mount_point/sys" || true
    umount "$mount_point" || true
    
    # Unmount ISO
    umount /mnt/proxmox-iso || true
    
    success "Cleanup completed"
}

# Main function
main() {
    # Check for debug flag
    if [[ "${1:-}" == "--debug" ]]; then
        debug_system_state
        exit 0
    fi
    
    info "Starting Proxmox installation..."
    
    check_root_pool
    download_proxmox_iso
    mount_proxmox_iso
    install_base_system
    setup_chroot
    install_proxmox_packages
    configure_system
    configure_network
    configure_bootloader
    configure_ssh
    cleanup_chroot
    
    success "Proxmox installation completed!"
    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  PROXMOX INSTALLATION COMPLETED!     ${NC}"
    echo -e "${GREEN}========================================${NC}"
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
