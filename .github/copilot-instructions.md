# Copilot Instructions for Hetzner Proxmox ZFS Installation

## Project Overview

This is a bash-based automation tool for installing Proxmox VE on Hetzner dedicated servers with ZFS storage. The architecture is a **sequential 4-script pipeline** designed for rescue system environments with potential kernel compatibility challenges.

## Critical Architecture Knowledge

### Script Execution Flow
**Must run in order**: `01-prepare-system.sh` → `02-setup-zfs.sh` → `03-install-proxmox.sh` → `04-post-install.sh`

- **01-prepare**: Handles ZFS kernel compatibility issues, package installation, drive detection
- **02-setup-zfs**: Implements intelligent drive grouping and automatic mirroring based on size
- **03-install**: Performs debootstrap installation with chroot management and GRUB configuration
- **04-post-install**: Creates first-boot services and preserves SSH keys from rescue environment

### ZFS Strategy - Size-Based Auto-Mirroring
```bash
# Core logic: Group drives by size, auto-mirror pairs ≥ MIN_MIRROR_SIZE
# 2x 1TB drives → 1 mirrored pool (rpool)
# 4x 2TB drives → 2 mirrored pools (rpool + data2)
# 2x 500GB + 1x 1TB → mirror (rpool) + single (data2)
```

### Kernel Compatibility Handling
The project handles ZFS/kernel version mismatches through multiple fallback strategies:
1. Standard Debian packages → Backports → Manual compilation → **Rescue system ZFS extraction**
2. Set `USE_RESCUE_ZFS="yes"` to bypass package installation and use existing rescue environment ZFS

## Configuration Patterns

### server-config.conf Structure
```bash
# Drive behavior
AUTO_MIRROR="yes"              # Enable size-based mirroring
MIN_MIRROR_SIZE="100"          # GB threshold for mirroring
EXCLUDE_DRIVES=("/dev/sda")    # Skip specific drives

# ZFS tuning (arrays for different contexts)
ZFS_POOL_OPTIONS=("ashift=12")                    # Pool creation only
ZFS_DATASET_OPTIONS=("compression=lz4")           # Applied to datasets
ZFS_ROOT_OPTIONS=("canmount=off" "mountpoint=none") # Root dataset specific
```

## Development Workflow

### Makefile Targets
```bash
make check          # Verify environment (root, packages)
make dry-run        # Show planned operations without execution
make info           # Display system/storage/network status
make backup         # Snapshot current config to timestamped backups/
```

### Testing Approach
- Use `DRY_RUN="yes"` in config for safe testing
- Scripts check `FORCE_INSTALL="yes"` to skip confirmations
- Each script logs to `/tmp/proxmox-install.log` with timestamp

### Error Handling Pattern
All scripts follow consistent error patterns:
```bash
set -euo pipefail                    # Strict mode
error_exit() { echo "${RED}ERROR: $1${NC}"; exit 1; }
success() { echo "${GREEN}✓ $1${NC}"; }
# Always log with: log "INFO: $message"
```

## Chroot Management

### Mount Strategy
Scripts 03 and 04 extensively use chroot for the new Proxmox installation:
```bash
# Standard chroot setup pattern
mount --bind /dev "$mount_point/dev"
mount --bind /proc "$mount_point/proc"  
mount --bind /sys "$mount_point/sys"
cp /etc/resolv.conf "$mount_point/etc/resolv.conf"
```

### SSH Key Preservation
04-post-install implements dual SSH key copying:
- **Rescue → Chroot**: `copy_rescue_ssh_keys_to_install()` - copies keys during installation
- **Chroot first-boot**: `copy_rescue_ssh_keys()` - handles keys within new environment

## Critical Dependencies

### External Services
- **Hetzner ISO mirror**: `https://hetzner:download@download.hetzner.com/bootimages/iso/proxmox-ve_8.3-1.iso`
- **Debian repository**: `http://deb.debian.org/debian` for debootstrap
- **Proxmox repos**: Script configures no-subscription by default

### Package Requirements
Core tools installed in 01-prepare: `debootstrap gdisk parted smartmontools zfsutils-linux`

## Common Debugging

### ZFS Issues
```bash
# Check if ZFS is working
zpool status && echo "ZFS functional"

# Reset broken ZFS state
zpool export -a; modprobe -r zfs; modprobe zfs
```

### Failed Installation Recovery
```bash
# Cleanup incomplete installation
umount /mnt/proxmox/{dev,proc,sys} 2>/dev/null || true
zpool export rpool 2>/dev/null || true
```

## Repository Conventions

- **Config**: Store examples in `config/server-config.conf.example`, actual config in `config/server-config.conf`
- **Logging**: All operations log to `/tmp/proxmox-install.log`
- **Temporary**: Scripts use `/tmp/drives_*gb.txt` for drive grouping state
- **Documentation**: Reference `docs/troubleshooting.md` for common fixes

## Key Files for Navigation
- `install.sh` - Main entry point with kernel compatibility detection
- `config/server-config.conf.example` - Shows all configuration scenarios
- `scripts/00-rescue-zfs.sh` - Handles complex ZFS extraction from rescue system
- `Makefile` - Provides all operational commands

- Never make a --resume type command, I want this to be run from the start every time
- Never create a test script, only the project scripts will be used
- Never make documentation.