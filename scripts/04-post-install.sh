#!/bin/bash

# Post-Installation Configuration Script for Proxmox on ZFS
# This script performs final configuration and cleanup after Proxmox installation

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

# Create post-installation script for first boot
create_firstboot_script() {
    info "Creating first boot configuration script..."
    
    local mount_point="/mnt/proxmox"
    
    cat > "$mount_point/usr/local/bin/proxmox-firstboot.sh" << 'EOF'
#!/bin/bash
# Proxmox First Boot Configuration

set -euo pipefail

LOG_FILE="/var/log/proxmox-firstboot.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

info() {
    log "INFO: $1"
}

success() {
    log "SUCCESS: $1"
}

# Import ZFS pools
import_zfs_pools() {
    info "Importing ZFS pools..."
    
    # Wait for ZFS module to be available
    local timeout=30
    local count=0
    while ! modinfo zfs >/dev/null 2>&1 && [ $count -lt $timeout ]; do
        info "Waiting for ZFS module to be available..."
        sleep 1
        ((count++))
    done
    
    if ! modinfo zfs >/dev/null 2>&1; then
        info "ZFS module not found, attempting to load..."
        modprobe zfs || true
    fi
    
    # Try to import all available pools
    info "Scanning for importable ZFS pools..."
    
    # First, try to import by scanning all devices
    local pools_to_import
    pools_to_import=$(zpool import 2>&1 | grep "pool:" | awk '{print $2}' || true)
    
    if [[ -n "$pools_to_import" ]]; then
        for pool in $pools_to_import; do
            if ! zpool list "$pool" >/dev/null 2>&1; then
                info "Importing ZFS pool: $pool"
                if zpool import -f "$pool" 2>/dev/null; then
                    info "Successfully imported pool: $pool"
                else
                    info "Failed to import pool: $pool, trying with force and all devices"
                    zpool import -f -a 2>/dev/null || true
                fi
            else
                info "Pool $pool already imported"
            fi
        done
    else
        info "No pools found for import, trying force import all"
        zpool import -f -a 2>/dev/null || true
    fi
    
    # Verify that the root pool is available
    if zpool list rpool >/dev/null 2>&1; then
        info "Root pool 'rpool' is available"
        
        # Set cachefile for persistence
        zpool set cachefile=/etc/zfs/zpool.cache rpool 2>/dev/null || true
        
        # Set other pools' cachefile too
        for pool in $(zpool list -H -o name 2>/dev/null); do
            if [[ "$pool" != "rpool" ]]; then
                zpool set cachefile=/etc/zfs/zpool.cache "$pool" 2>/dev/null || true
            fi
        done
    else
        info "Warning: Root pool 'rpool' not found, system may have boot issues"
    fi
    
    # Enable ZFS services
    systemctl enable zfs-import-cache.service 2>/dev/null || true
    systemctl enable zfs-import.target 2>/dev/null || true
    systemctl enable zfs-mount.service 2>/dev/null || true
    systemctl enable zfs.target 2>/dev/null || true
    
    success "ZFS pools imported and services enabled"
}

# Configure Proxmox repositories
configure_repositories() {
    info "Configuring Proxmox repositories..."
    
    # Disable enterprise repository if configured
    if [[ "${DISABLE_ENTERPRISE_REPO:-yes}" == "yes" ]]; then
        if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
            sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
        fi
        
        # Add no-subscription repository
        echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
    fi
    
    success "Repositories configured"
}

# Update system
update_system() {
    info "Updating system packages..."
    
    apt-get update
    apt-get upgrade -y
    
    success "System updated"
}

# Configure Proxmox storage
configure_storage() {
    info "Configuring Proxmox storage..."
    
    # Configure ZFS storage in Proxmox
    cat >> /etc/pve/storage.cfg << 'STORAGE_EOF'

zfspool: local-zfs
	pool rpool/data
	content vztmpl,vma,images,rootdir
	mountpoint /rpool/data

STORAGE_EOF

    success "Storage configured"
}

# Set root password
set_root_password() {
    info "Please set root password for Proxmox..."
    passwd root
}

# Copy SSH keys from rescue environment
copy_rescue_ssh_keys() {
    info "Copying SSH keys from rescue environment..."
    
    # Copy existing SSH host keys if they exist
    if [[ -d /etc/ssh ]]; then
        # Backup any existing keys in the new environment
        if [[ -d /etc/ssh ]]; then
            mkdir -p /etc/ssh/backup
            cp /etc/ssh/ssh_host_* /etc/ssh/backup/ 2>/dev/null || true
        fi
        
        # Copy rescue environment SSH keys
        cp /etc/ssh/ssh_host_* /etc/ssh/ 2>/dev/null || true
        
        # Copy authorized_keys if they exist
        if [[ -f /root/.ssh/authorized_keys ]]; then
            mkdir -p /root/.ssh
            cp /root/.ssh/authorized_keys /root/.ssh/
            chmod 600 /root/.ssh/authorized_keys
            chmod 700 /root/.ssh
        fi
        
        # Ensure proper permissions
        chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
        chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
    fi
    
    success "SSH keys copied from rescue environment"
}

# Generate SSH keys (fallback if rescue keys don't exist)
generate_ssh_keys() {
    info "Generating missing SSH host keys..."
    
    # Only generate keys that don't already exist
    ssh-keygen -A
    
    success "SSH keys generated"
}

# Configure firewall
configure_firewall() {
    info "Configuring basic firewall rules..."
    
    # Enable Proxmox firewall
    cat > /etc/pve/firewall/cluster.fw << 'FIREWALL_EOF'
[OPTIONS]
enable: 1

[RULES]
IN SSH(ACCEPT) -i vmbr0
IN 8006(ACCEPT) -i vmbr0
FIREWALL_EOF

    success "Firewall configured"
}

# Main first boot function
main() {
    info "Starting Proxmox first boot configuration..."
    
    import_zfs_pools
    configure_repositories
    update_system
    configure_storage
    copy_rescue_ssh_keys
    generate_ssh_keys
    configure_firewall
    set_root_password
    
    # Disable this script after first run
    systemctl disable proxmox-firstboot.service
    
    success "Proxmox first boot configuration completed!"
    
    echo
    echo "=== REBOOT REQUIRED ==="
    echo "The Proxmox installation is complete and requires a reboot to finish."
    echo "After reboot, access the web interface at: https://$(hostname -I | awk '{print $1}'):8006"
    echo "Default login: root"
    echo
    echo "IMPORTANT: Remove the rescue system from boot order in Hetzner Robot"
    echo "           before rebooting to ensure the new installation boots correctly."
    echo
    echo "To reboot now, run: reboot"
}

main "$@"
EOF

    chmod +x "$mount_point/usr/local/bin/proxmox-firstboot.sh"
    
    # Create systemd service for first boot
    cat > "$mount_point/etc/systemd/system/proxmox-firstboot.service" << EOF
[Unit]
Description=Proxmox First Boot Configuration
After=zfs.target network.target
Requires=zfs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/proxmox-firstboot.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Enable the service
    chroot "$mount_point" systemctl enable proxmox-firstboot.service
    
    success "First boot script created and enabled"
}

# Create installation summary
create_installation_summary() {
    info "Creating installation summary..."
    
    local summary_file="/tmp/installation-summary.txt"
    
    cat > "$summary_file" << EOF
=== Proxmox VE Installation Summary ===
Date: $(date)
Hostname: ${PROXMOX_HOSTNAME:-$(hostname)}
ZFS Root Pool: $ZFS_ROOT_POOL_NAME

=== ZFS Configuration ===
$(zpool list)

$(zpool status)

=== ZFS Datasets ===
$(zfs list)

=== Network Configuration ===
Current IP: $(ip route get 1.1.1.1 | grep src | awk '{print $7}')
Interface: $(ip route | grep default | awk '{print $5}' | head -1)
Gateway: $(ip route | grep default | awk '{print $3}' | head -1)

=== Next Steps ===
1. **REBOOT REQUIRED**: Run 'reboot' to complete the installation
2. **IMPORTANT**: Remove rescue system from boot order in Hetzner Robot BEFORE rebooting
3. Access Proxmox web interface at: https://$(ip route get 1.1.1.1 | grep src | awk '{print $7}'):8006
4. Login with root and the password you set during installation

=== CRITICAL: Reboot Instructions ===
- The installation is NOT complete until you reboot
- SSH keys from rescue environment have been preserved
- Remove rescue system from Hetzner Robot boot order first
- Then run: reboot

=== Important Notes ===
- **REBOOT IS REQUIRED** to complete the installation
- SSH keys from rescue environment have been preserved
- The system will complete configuration on first boot
- SSH is enabled for remote access
- ZFS pools are configured with compression and optimal settings
- Proxmox is configured with no-subscription repository

=== Backup Information ===
Network configuration backup: /tmp/network-backup/
Installation log: /tmp/proxmox-install.log
EOF

    success "Installation summary created at $summary_file"
    cat "$summary_file"
}

# Backup critical information
backup_installation_info() {
    info "Backing up installation information..."
    
    local backup_dir="/tmp/installation-backup"
    mkdir -p "$backup_dir"
    
    # Backup ZFS configuration
    zpool list > "$backup_dir/zpool-list.txt"
    zpool status > "$backup_dir/zpool-status.txt"
    zfs list > "$backup_dir/zfs-list.txt"
    
    # Backup network information
    ip addr show > "$backup_dir/network-interfaces.txt"
    ip route show > "$backup_dir/network-routes.txt"
    
    # Copy important config files
    cp /etc/network/interfaces "$backup_dir/" 2>/dev/null || true
    
    success "Installation information backed up to $backup_dir"
}

# Verify installation
verify_installation() {
    info "Verifying installation..."
    
    # Check ZFS pools
    if ! zpool list "$ZFS_ROOT_POOL_NAME" >/dev/null 2>&1; then
        error_exit "Root ZFS pool not found"
    fi
    
    # Check if Proxmox is installed in chroot
    local mount_point="/mnt/proxmox"
    if [[ ! -f "$mount_point/usr/bin/pvesh" ]]; then
        error_exit "Proxmox not properly installed"
    fi
    
    # Check for essential Proxmox files
    local essential_files=(
        "$mount_point/etc/pve"
        "$mount_point/usr/share/proxmox-ve"
        "$mount_point/usr/bin/qm"
        "$mount_point/usr/bin/pct"
    )
    
    for file in "${essential_files[@]}"; do
        if [[ ! -e "$file" ]]; then
            warning "Essential Proxmox component missing: $file"
        fi
    done
    
    # Check bootloader installation (with better error handling)
    info "Checking bootloader installation..."
    local root_drives
    root_drives=$(zpool status "$ZFS_ROOT_POOL_NAME" 2>/dev/null | grep -E '^\s+(sd|nvme|ada)' | awk '{print "/dev/" $1}' | sort -u)
    
    if [[ -z "$root_drives" ]]; then
        warning "Could not determine root drives from ZFS pool status"
    else
        for drive in $root_drives; do
            # Check if drive exists
            if [[ ! -b "$drive" ]]; then
                warning "Drive $drive not found as block device"
                continue
            fi
            
            # Check for GRUB installation with better error handling
            if ! chroot "$mount_point" grub-probe "$drive" >/dev/null 2>&1; then
                warning "GRUB may not be properly installed on $drive"
                
                # Try to verify GRUB files exist
                if [[ -f "$mount_point/boot/grub/grub.cfg" ]]; then
                    info "GRUB configuration file exists"
                else
                    warning "GRUB configuration file missing"
                fi
            else
                success "GRUB appears to be properly installed on $drive"
            fi
        done
    fi
    
    # Check if ZFS root filesystem is properly configured
    local root_fs="$ZFS_ROOT_POOL_NAME/ROOT/pve-1"
    if zfs list "$root_fs" >/dev/null 2>&1; then
        success "ZFS root filesystem exists and is accessible"
    else
        warning "ZFS root filesystem may not be properly configured"
    fi
    
    # Check kernel and initramfs
    if [[ -d "$mount_point/boot" ]] && ls "$mount_point"/boot/vmlinuz-* >/dev/null 2>&1; then
        success "Kernel images found in /boot"
    else
        warning "No kernel images found in /boot"
    fi
    
    if [[ -d "$mount_point/boot" ]] && ls "$mount_point"/boot/initrd.img-* >/dev/null 2>&1; then
        success "Initramfs images found in /boot"
    else
        warning "No initramfs images found in /boot"
    fi
    
    success "Installation verification completed"
}

# Copy SSH keys from rescue environment to installation
copy_rescue_ssh_keys_to_install() {
    info "Copying SSH keys from rescue environment to installation..."
    
    local mount_point="/mnt/proxmox"
    
    # Ensure SSH directory exists in the installation
    mkdir -p "$mount_point/etc/ssh"
    mkdir -p "$mount_point/root/.ssh"
    
    # Copy SSH host keys from rescue environment to installation
    if [[ -d /etc/ssh ]]; then
        info "Copying SSH host keys..."
        
        # Copy all SSH host keys
        for key_file in /etc/ssh/ssh_host_*; do
            if [[ -f "$key_file" ]]; then
                cp "$key_file" "$mount_point/etc/ssh/" || warning "Failed to copy $key_file"
            fi
        done
        
        # Set proper permissions for private keys
        chmod 600 "$mount_point"/etc/ssh/ssh_host_*_key 2>/dev/null || true
        chmod 644 "$mount_point"/etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
        
        success "SSH host keys copied"
    else
        warning "No SSH directory found in rescue environment"
    fi
    
    # Copy authorized_keys if they exist
    if [[ -f /root/.ssh/authorized_keys ]]; then
        info "Copying authorized_keys..."
        cp /root/.ssh/authorized_keys "$mount_point/root/.ssh/" || warning "Failed to copy authorized_keys"
        
        # Set proper permissions
        chmod 700 "$mount_point/root/.ssh"
        chmod 600 "$mount_point/root/.ssh/authorized_keys"
        
        success "Authorized keys copied"
    else
        warning "No authorized_keys found in rescue environment"
    fi
    
    # Copy SSH client configuration if it exists
    if [[ -f /etc/ssh/ssh_config ]]; then
        cp /etc/ssh/ssh_config "$mount_point/etc/ssh/" || true
    fi
    
    if [[ -f /etc/ssh/sshd_config ]]; then
        cp /etc/ssh/sshd_config "$mount_point/etc/ssh/" || true
    fi
    
    success "SSH keys and configuration copied from rescue environment"
}

# Final cleanup
final_cleanup() {
    info "Performing final cleanup..."
    
    # Clean up temporary files
    rm -f /tmp/drives_*.txt /tmp/drive_sizes.txt
    
    # Unmount any remaining filesystems
    umount /mnt/proxmox-iso 2>/dev/null || true
    
    local mount_point="/mnt/proxmox"
    
    # Clean up chroot mounts first (these might be left over from script 03)
    info "Cleaning up any remaining chroot mounts..."
    for mount in dev/pts dev proc sys; do
        if mountpoint -q "$mount_point/$mount" 2>/dev/null; then
            info "Unmounting $mount_point/$mount..."
            umount "$mount_point/$mount" 2>/dev/null || umount -f "$mount_point/$mount" 2>/dev/null || true
        fi
    done
    
    # Kill any processes that might be using the mount point
    info "Checking for processes using $mount_point..."
    
    # Install psmisc if fuser is not available (for process cleanup)
    if ! command -v fuser >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        info "Installing psmisc for process cleanup..."
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y psmisc >/dev/null 2>&1 || true
    fi
    
    if command -v fuser >/dev/null 2>&1; then
        fuser -km "$mount_point" 2>/dev/null || true
        sleep 2
    elif command -v lsof >/dev/null 2>&1; then
        # Kill processes using the mount point
        local pids
        pids=$(lsof +D "$mount_point" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)
        if [[ -n "$pids" ]]; then
            info "Killing processes using $mount_point: $pids"
            echo "$pids" | xargs -r kill -9 2>/dev/null || true
            sleep 2
        fi
    fi
    
    # Sync and wait for any pending I/O
    sync
    sleep 1
    
    # Try to unmount the ZFS filesystem with multiple attempts
    if mountpoint -q "$mount_point" 2>/dev/null; then
        info "Unmounting $mount_point for clean reboot..."
        
        # First attempt - normal unmount
        if umount "$mount_point" 2>/dev/null; then
            success "Unmounted $mount_point successfully"
        else
            warning "Normal unmount failed, trying lazy unmount..."
            if umount -l "$mount_point" 2>/dev/null; then
                success "Lazy unmount of $mount_point successful"
            else
                warning "Lazy unmount failed, trying force unmount..."
                if umount -f "$mount_point" 2>/dev/null; then
                    success "Force unmount of $mount_point successful"
                else
                    warning "Could not unmount $mount_point - ZFS will handle this on reboot"
                fi
            fi
        fi
    fi
    
    # Wait a moment before trying to export pools
    sleep 2
    
    # Try to set ZFS filesystem to legacy mount to help with export
    info "Setting ZFS filesystem to legacy mount for clean export..."
    zfs set mountpoint=legacy "$ZFS_ROOT_POOL_NAME/ROOT/pve-1" 2>/dev/null || true
    
    # Export ZFS pools for clean reboot
    info "Exporting ZFS pools for clean reboot..."
    
    # Export main pool
    if zpool export "$ZFS_ROOT_POOL_NAME" 2>/dev/null; then
        success "Exported $ZFS_ROOT_POOL_NAME successfully"
    else
        # Try force export if normal export fails
        if zpool export -f "$ZFS_ROOT_POOL_NAME" 2>/dev/null; then
            success "Force exported $ZFS_ROOT_POOL_NAME successfully"
        else
            warning "Could not export $ZFS_ROOT_POOL_NAME - pools will auto-import on reboot"
        fi
    fi
    
    # Export any additional pools
    for pool in $(zpool list -H -o name 2>/dev/null | grep -v "^$ZFS_ROOT_POOL_NAME$"); do
        info "Exporting additional pool: $pool"
        if zpool export "$pool" 2>/dev/null; then
            success "Exported $pool successfully"
        else
            zpool export -f "$pool" 2>/dev/null || warning "Could not export $pool"
        fi
    done
    
    success "Cleanup completed - system ready for reboot"
}

# Main function
main() {
    info "Starting post-installation configuration..."
    
    # Verify ZFS is working
    if ! command -v zpool >/dev/null 2>&1; then
        error_exit "ZFS utilities not available. Please ensure ZFS is properly installed."
    fi
    
    # Check if root pool exists
    if ! zpool list "$ZFS_ROOT_POOL_NAME" >/dev/null 2>&1; then
        error_exit "Root ZFS pool '$ZFS_ROOT_POOL_NAME' not found. Installation may have failed."
    fi
    
    info "ZFS root pool '$ZFS_ROOT_POOL_NAME' found and accessible"
    
    # Mount root filesystem for configuration
    local root_fs="$ZFS_ROOT_POOL_NAME/ROOT/pve-1"
    local mount_point="/mnt/proxmox"
    
    mkdir -p "$mount_point"
    
    # Check if already mounted from previous script
    if mountpoint -q "$mount_point"; then
        info "Mount point already mounted from previous script"
    else
        # Try to mount the ZFS filesystem
        info "Mounting ZFS root filesystem for post-install configuration..."
        
        # First ensure the pool is imported
        if ! zpool list "$ZFS_ROOT_POOL_NAME" >/dev/null 2>&1; then
            info "Importing ZFS pool $ZFS_ROOT_POOL_NAME..."
            zpool import -f "$ZFS_ROOT_POOL_NAME" 2>/dev/null || error_exit "Failed to import ZFS pool $ZFS_ROOT_POOL_NAME"
        fi
        
        # Set mountpoint and try to mount
        if ! zfs set mountpoint="$mount_point" "$root_fs" 2>/dev/null; then
            warning "Could not set ZFS mountpoint, trying alternative mount method"
        fi
        
        if ! zfs mount "$root_fs" 2>/dev/null; then
            info "Direct ZFS mount failed, trying manual mount..."
            if ! mount -t zfs "$root_fs" "$mount_point" 2>/dev/null; then
                # Try importing the pool first
                info "Mount failed, attempting to import pool and retry..."
                zpool import -f "$ZFS_ROOT_POOL_NAME" 2>/dev/null || true
                sleep 2
                
                # Retry mount after import
                if ! mount -t zfs "$root_fs" "$mount_point"; then
                    error_exit "Failed to mount root filesystem for post-install: $root_fs"
                fi
            fi
        fi
        success "Root filesystem mounted successfully"
    fi
    
    # Verify the mount is working and contains a Proxmox installation
    if [[ ! -d "$mount_point/usr" ]] || [[ ! -d "$mount_point/etc" ]]; then
        error_exit "Mounted filesystem does not appear to contain a valid Proxmox installation"
    fi
    
    copy_rescue_ssh_keys_to_install
    create_firstboot_script
    verify_installation
    backup_installation_info
    create_installation_summary
    final_cleanup
    
    success "Post-installation configuration completed!"
    echo
    echo -e "${RED}=== REBOOT REQUIRED ===${NC}"
    echo -e "${YELLOW}⚠ The installation is NOT complete until you reboot!${NC}"
    echo
    echo -e "${GREEN}=== Installation Complete! ===${NC}"
    echo "Your Proxmox VE server is ready for reboot."
    echo
    echo -e "${BLUE}To complete the installation:${NC}"
    echo "1. ${RED}FIRST:${NC} Remove rescue system from Hetzner Robot boot order"
    echo "2. ${GREEN}THEN:${NC} Run: reboot"
    echo "3. Access Proxmox at: https://$(ip route get 1.1.1.1 | grep src | awk '{print $7}'):8006"
    echo
    echo -e "${BLUE}SSH Keys:${NC} Rescue environment SSH keys have been preserved"
    echo -e "${BLUE}Logs:${NC} Installation log: /tmp/proxmox-install.log"
    echo -e "${BLUE}Summary:${NC} Installation summary: /tmp/installation-summary.txt"
    echo
    echo -e "${RED}Remember: Reboot is required to complete the installation!${NC}"
}

main "$@"
