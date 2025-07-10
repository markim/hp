# GitHub Copilot Instructions for Hetzner Proxmox ZFS Automation

## Project Overview

This repository contains a comprehensive automation framework for installing Proxmox VE on Hetzner dedicated servers with advanced ZFS storage configuration. The system handles everything from rescue system preparation to bootable Proxmox installation with intelligent drive mirroring.

## Architecture Principles

### Modular Script Design
- **Main orchestrator**: `install.sh` coordinates all installation phases
- **Phase-based execution**: Each major task is a separate script in `/scripts/`
- **Configuration-driven**: Single configuration file controls all aspects
- **Logging**: Comprehensive logging to `/tmp/proxmox-install.log` throughout

### Error Handling Philosophy
- **Fail-fast**: `set -euo pipefail` in all scripts for immediate error detection
- **Graceful degradation**: Multiple fallback strategies for ZFS installation
- **User confirmation**: Destructive operations require explicit confirmation
- **Recovery options**: Network backups and detailed logging for troubleshooting

### ZFS Expertise Required
- **Pool vs Dataset Properties**: Critical distinction between pool creation options and dataset properties
- **Drive Analysis**: Intelligent grouping by size for automatic mirroring decisions
- **Label Management**: Proper clearing of ZFS labels during drive wiping
- **Import/Export**: Careful pool management during installation and reboot

## Key Technical Patterns

### 1. Kernel Compatibility Detection
```bash
# Pattern: Check kernel version against ZFS package compatibility
local kernel_version=$(uname -r | cut -d'-' -f1)
if [[ $major_version -gt 6 ]] || [[ $major_version -eq 6 && $minor_version -gt 5 ]]; then
    export USE_RESCUE_ZFS="yes"  # Use rescue system ZFS instead
fi
```

### 2. ZFS Property Separation
```bash
# CRITICAL: Pool properties vs Dataset properties
# Pool creation (only pool-level properties)
zpool create -o ashift=12 $pool_name $drives

# Dataset properties (applied after pool creation)
zfs set compression=lz4 $pool_name
zfs set atime=off $pool_name
```

### 3. Drive Analysis and Mirroring Logic
```bash
# Pattern: Group drives by size for intelligent mirroring
declare -A drive_groups
for drive in "${drives[@]}"; do
    local size_gb=$(get_drive_size_gb "$drive")
    drive_groups[$size_gb]+="$drive "
done

# Create mirrors for same-size pairs
if [[ ${#group_drives[@]} -eq 2 && "$AUTO_MIRROR" == "yes" ]]; then
    create_zfs_pool "$pool_name" "mirror" "${group_drives[@]}"
fi
```

### 4. Rescue System Adaptation
```bash
# Pattern: Adapt to Hetzner rescue system limitations
if [[ "${USE_RESCUE_ZFS:-no}" == "yes" ]]; then
    # Copy ZFS binaries from rescue system if packages fail
    cp /usr/sbin/zfs /tmp/zfs-rescue/
    cp /usr/sbin/zpool /tmp/zfs-rescue/
fi
```

### 5. Chroot Environment Management
```bash
# Pattern: Proper chroot setup for Proxmox installation
mount --bind /dev "$mount_point/dev"
mount --bind /proc "$mount_point/proc"
mount --bind /sys "$mount_point/sys"
chroot "$mount_point" /tmp/install-proxmox.sh
# Always cleanup
umount "$mount_point/dev" "$mount_point/proc" "$mount_point/sys"
```

## Configuration Management

### Central Configuration File
- **Location**: `config/server-config.conf`
- **Format**: Bash-sourceable key=value pairs
- **Arrays**: Use parentheses for array values: `EXCLUDE_DRIVES=("/dev/sda")`
- **Validation**: Scripts should validate required configuration before proceeding

### Environment Variables
- `USE_RESCUE_ZFS`: Controls ZFS installation strategy
- `FORCE_INSTALL`: Skip confirmations for automated runs
- `DEBUG`: Enable verbose logging
- `DRY_RUN`: Show operations without executing

## ZFS Domain Knowledge

### Pool Creation Best Practices
```bash
# Always use ashift=12 for 4K sectors
zpool create -o ashift=12 $pool_name $vdev_spec

# Separate pool options from dataset options
ZFS_POOL_OPTIONS=("ashift=12")
ZFS_DATASET_OPTIONS=("compression=lz4" "atime=off")
```

### Dataset Structure for Proxmox
```bash
# Standard Proxmox ZFS layout
rpool/ROOT                    # Root container (canmount=off)
rpool/ROOT/pve-1             # System root (mountpoint=/)
rpool/data                   # VM/Container storage
rpool/data/subvol-*          # Individual VM disks
```

### Drive Preparation Sequence
```bash
# Complete drive wiping sequence
umount "${drive}"* 2>/dev/null || true
zpool labelclear "$drive" 2>/dev/null || true
wipefs -a "$drive" 2>/dev/null || true
sgdisk --zap-all "$drive" 2>/dev/null || true
dd if=/dev/zero of="$drive" bs=1M count=100 2>/dev/null || true
```

## Network Preservation Patterns

### Backup Current Configuration
```bash
# Always backup before changes
mkdir -p /tmp/network-backup
cp /etc/network/interfaces /tmp/network-backup/
ip addr show > /tmp/network-backup/current-ip-config.txt
ip route show > /tmp/network-backup/current-routes.txt
```

### Bridge Configuration for Proxmox
```bash
# Standard Proxmox bridge setup
auto vmbr0
iface vmbr0 inet static
    address $current_ip
    gateway $current_gateway
    bridge-ports $physical_interface
    bridge-stp off
    bridge-fd 0
```

## Error Recovery Strategies

### ZFS Installation Fallbacks
1. **Standard packages**: `apt-get install zfsutils-linux`
2. **Backports**: Install from bookworm-backports
3. **Manual compilation**: Download and compile OpenZFS
4. **Rescue system**: Use pre-installed ZFS from rescue environment

### Bootloader Recovery
```bash
# Install GRUB to all drives in root pool
local root_drives=$(zpool status "$ZFS_ROOT_POOL_NAME" | grep -E '^\s+sd|^\s+nvme')
for drive in $root_drives; do
    chroot "$mount_point" grub-install "$drive"
done
```

## Testing and Validation

### Pre-Installation Checks
- Memory requirements (>1GB for ZFS)
- Disk space in /tmp for downloads
- Internet connectivity for packages
- Drive accessibility and sizes

### Post-Installation Verification
```bash
# Verify ZFS functionality
zpool list "$ZFS_ROOT_POOL_NAME"
zpool status
zfs list

# Verify Proxmox installation
test -f "$mount_point/usr/bin/pvesh"
```

## Build System Integration

### Makefile Targets
- `make install`: Full automated installation
- `make prepare`: System preparation only
- `make zfs`: ZFS setup only
- `make check`: Validate system requirements
- `make clean`: Cleanup temporary files

### Individual Script Execution
Scripts can be run independently but must be executed in order:
1. `01-prepare-system.sh` - System and package preparation
2. `02-setup-zfs.sh` - ZFS pool and dataset creation
3. `03-install-proxmox.sh` - Proxmox installation via debootstrap
4. `04-post-install.sh` - Final configuration and cleanup

## Common Debugging Scenarios

### ZFS Module Issues
- Check kernel compatibility with available packages
- Verify rescue system ZFS availability
- Use alternative installation methods (backports, manual)

### Pool Creation Failures
- Verify drives are properly wiped
- Check for existing ZFS labels
- Ensure no mounted filesystems on target drives

### Network Configuration Problems
- Verify backup files exist in `/tmp/network-backup/`
- Check bridge configuration syntax
- Validate IP address and gateway settings

### Bootloader Issues
- Ensure GRUB installed on all pool drives
- Verify ZFS module loading in initramfs
- Check root filesystem specification in GRUB config

## Code Style Guidelines

### Bash Scripting Standards
- Use `set -euo pipefail` for strict error handling
- Quote all variables: `"$variable"`
- Use arrays for multiple items: `drives=("${drives[@]}")`
- Prefer `[[ ]]` over `[ ]` for conditionals

### Logging Conventions
```bash
info "Starting operation..."      # Blue info messages
warning "Non-fatal issue..."      # Yellow warnings  
success "Operation completed"     # Green success
error_exit "Fatal error"          # Red error + exit
```

### Function Organization
- Check functions: Validate preconditions
- Action functions: Perform main operations
- Cleanup functions: Handle post-operation cleanup
- Main function: Orchestrate overall flow

## When Working on This Codebase

1. **Understand ZFS deeply** - This is not a simple filesystem
2. **Test incrementally** - Changes can destroy data
3. **Preserve network config** - Server must remain accessible
4. **Handle kernel compatibility** - Rescue systems may have newer kernels
5. **Log everything** - Complex operations need detailed logging
6. **Provide fallbacks** - Multiple strategies for each critical operation
7. **Validate thoroughly** - Check every assumption about system state

## External Dependencies

- **Hetzner rescue system**: Debian-based environment
- **ZFS packages**: Debian bookworm repositories + backports
- **Proxmox packages**: Official Proxmox repository
- **Network tools**: Standard Debian networking utilities
- **Build tools**: For potential ZFS compilation

Remember: This automation handles destructive operations on expensive hardware. Every change should be carefully considered and thoroughly tested.
