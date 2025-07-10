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

# Check if root pool exists
check_root_pool() {
    if ! zpool list "$ZFS_ROOT_POOL_NAME" >/dev/null 2>&1; then
        error_exit "Root ZFS pool '$ZFS_ROOT_POOL_NAME' not found. Please run 02-setup-zfs.sh first."
    fi
    success "Root ZFS pool '$ZFS_ROOT_POOL_NAME' found"
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
    
    success "Base system installed"
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

# Add Proxmox repository
echo "deb [arch=amd64] http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list

# Add Proxmox repository key
wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg

# Update package list
apt-get update

# Install Proxmox kernel and packages
DEBIAN_FRONTEND=noninteractive apt-get install -y \
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
    
    # Configure locale
    echo "$LOCALE UTF-8" > "$mount_point/etc/locale.gen"
    chroot "$mount_point" locale-gen
    echo "LANG=$LOCALE" > "$mount_point/etc/default/locale"
    
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
    chroot "$mount_point" apt-get install -y grub-pc
    
    # Configure GRUB for ZFS
    cat >> "$mount_point/etc/default/grub" << EOF

# ZFS Configuration
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="root=ZFS=$ZFS_ROOT_POOL_NAME/ROOT/pve-1"
EOF
    
    # Update GRUB configuration
    chroot "$mount_point" update-grub
    
    # Install GRUB to all drives in root pool
    local root_drives
    root_drives=$(zpool status "$ZFS_ROOT_POOL_NAME" | grep -E '^\s+sd|^\s+nvme' | awk '{print "/dev/" $1}')
    
    for drive in $root_drives; do
        info "Installing GRUB to $drive"
        chroot "$mount_point" grub-install "$drive" || warning "Failed to install GRUB to $drive"
    done
    
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
    echo "Next step: Run ./scripts/04-post-install.sh"
}

main "$@"
