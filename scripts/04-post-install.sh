#!/bin/bash

# Post-Installation Configuration Script for Proxmox on ZFS
# This script performs final configuration and cleanup after Proxmox installation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/server-config.conf
source "${SCRIPT_DIR}/config/server-config.conf"

# Source ZFS helper functions
# shellcheck source=./zfs-helpers.sh
source "${SCRIPT_DIR}/scripts/zfs-helpers.sh"h

# Post-Installation Configuration Script for Proxmox
# This script performs final configuration and cleanup

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
    
    # Force import all pools
    for pool in $(zpool import 2>&1 | grep "pool:" | awk '{print $2}'); do
        if ! zpool list "$pool" >/dev/null 2>&1; then
            zpool import -f "$pool" || true
        fi
    done
    
    # Set cachefile
    zpool set cachefile=/etc/zfs/zpool.cache rpool 2>/dev/null || true
    
    success "ZFS pools imported"
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

# Generate SSH keys
generate_ssh_keys() {
    info "Generating SSH host keys..."
    
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
    generate_ssh_keys
    configure_firewall
    set_root_password
    
    # Disable this script after first run
    systemctl disable proxmox-firstboot.service
    
    success "Proxmox first boot configuration completed!"
    
    echo
    echo "=== Installation Summary ==="
    echo "Proxmox VE has been successfully installed with ZFS storage."
    echo "Web interface will be available at: https://$(hostname -I | awk '{print $1}'):8006"
    echo "Default login: root"
    echo
    echo "Please reboot the system to complete the installation."
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
1. Reboot the system: reboot
2. Remove rescue system from boot order in Hetzner Robot
3. Access Proxmox web interface at: https://$(ip route get 1.1.1.1 | grep src | awk '{print $7}'):8006
4. Login with root and the password you set during installation

=== Important Notes ===
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
    
    # Check bootloader
    local root_drives
    root_drives=$(zpool status "$ZFS_ROOT_POOL_NAME" | grep -E '^\s+sd|^\s+nvme' | awk '{print "/dev/" $1}')
    
    for drive in $root_drives; do
        if ! chroot "$mount_point" grub-probe "$drive" >/dev/null 2>&1; then
            warning "GRUB may not be properly installed on $drive"
        fi
    done
    
    success "Installation verification completed"
}

# Final cleanup
final_cleanup() {
    info "Performing final cleanup..."
    
    # Clean up temporary files
    rm -f /tmp/drives_*.txt /tmp/drive_sizes.txt
    
    # Unmount any remaining filesystems
    umount /mnt/proxmox-iso 2>/dev/null || true
    umount /mnt/proxmox 2>/dev/null || true
    
    # Export ZFS pools for clean reboot
    zpool export "$ZFS_ROOT_POOL_NAME" 2>/dev/null || true
    
    success "Cleanup completed"
}

# Main function
main() {
    info "Starting post-installation configuration..."
    
    # Test and fix ZFS functionality if needed
    test_and_fix_zfs || error_exit "ZFS functionality test failed"
    
    # Mount root filesystem for configuration using helper function
    local root_fs="$ZFS_ROOT_POOL_NAME/ROOT/pve-1"
    local mount_point="/mnt/proxmox"
    
    safe_zfs_mount "$root_fs" "$mount_point" "yes" || error_exit "Failed to mount root filesystem for post-install"
    
    create_firstboot_script
    verify_installation
    backup_installation_info
    create_installation_summary
    final_cleanup
    
    success "Post-installation configuration completed!"
    echo
    echo -e "${GREEN}=== Installation Complete! ===${NC}"
    echo "Your Proxmox VE server is ready for reboot."
    echo
    echo "To complete the installation:"
    echo "1. Run: reboot"
    echo "2. Remove rescue system from Hetzner Robot"
    echo "3. Access Proxmox at: https://$(ip route get 1.1.1.1 | grep src | awk '{print $7}'):8006"
    echo
    echo "Installation log: /tmp/proxmox-install.log"
    echo "Installation summary: /tmp/installation-summary.txt"
}

main "$@"
