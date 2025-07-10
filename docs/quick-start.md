# Quick Start Guide

## Prerequisites

1. **Hetzner dedicated server** booted into rescue system
2. **Root access** to the rescue system
3. **Internet connectivity** for downloading packages and Proxmox ISO

## One-Command Installation

For a fully automated installation with default settings:

```bash
wget -O - https://raw.githubusercontent.com/yourusername/hetzner-proxmox-zfs/main/install.sh | bash
```

## Manual Step-by-Step Installation

### 1. Download the Scripts

```bash
git clone https://github.com/yourusername/hetzner-proxmox-zfs.git
cd hetzner-proxmox-zfs
```

### 2. Review Configuration (Optional)

Edit the configuration file to customize your installation:

```bash
nano config/server-config.conf
```

**Key settings to review:**

- `AUTO_MIRROR="yes"` - Automatically mirror same-size drives
- `MIN_MIRROR_SIZE="100"` - Minimum drive size (GB) for mirroring
- `PROXMOX_HOSTNAME=""` - Leave empty to use current hostname
- `EXCLUDE_DRIVES=()` - Drives to exclude from ZFS setup

### 3. Run the Installation

Make the script executable and run it:

```bash
chmod +x install.sh
./install.sh
```

The script will:
1. **Prepare the system** - Install ZFS and required packages
2. **Detect drives** - Analyze available storage devices
3. **Configure ZFS** - Set up pools with automatic mirroring
4. **Install Proxmox** - Download and install Proxmox VE
5. **Configure system** - Set up networking and bootloader

### 4. Reboot and Complete

After installation completes:

```bash
reboot
```

1. **Remove rescue system** from boot order in Hetzner Robot
2. **Wait for boot** (first boot takes longer for final configuration)
3. **Access Proxmox** web interface at `https://YOUR_SERVER_IP:8006`

## What the Installation Does

### Drive Configuration

The script automatically:
- **Detects all available drives** and their sizes
- **Groups drives by size** for optimal mirroring
- **Creates ZFS mirrors** for same-size drive pairs
- **Sets up single pools** for unpaired drives
- **Configures optimal ZFS settings** (compression, atime, etc.)

### Example Configurations

**2 identical drives (e.g., 2x 1TB):**
- Creates 1 mirrored pool: `rpool` (mirror of both drives)

**4 identical drives (e.g., 4x 2TB):**
- Creates 2 mirrored pools: `rpool` (mirror of first pair), `data2` (mirror of second pair)

**Mixed drive sizes (e.g., 2x 500GB + 1x 1TB):**
- Creates 1 mirrored pool: `rpool` (mirror of 500GB drives)
- Creates 1 single pool: `data2` (1TB drive)

### Network Configuration

The script preserves your current network configuration by:
- **Backing up** existing network settings
- **Creating a bridge** (vmbr0) for VM networking
- **Maintaining** your current IP address and routing

## Post-Installation

### First Login

1. **Access web interface:** `https://YOUR_SERVER_IP:8006`
2. **Username:** `root`
3. **Password:** Set during first boot configuration

### Initial Setup

The system performs additional configuration on first boot:
- **Imports ZFS pools** and sets up caching
- **Configures Proxmox storage** for VM disks and containers
- **Updates package repositories** to no-subscription version
- **Generates SSH keys** for secure access
- **Sets up basic firewall** rules

### Verification

Check that everything is working:

```bash
# Check ZFS pools
zpool list
zpool status

# Check Proxmox services
systemctl status pveproxy
systemctl status pvedaemon

# Check available storage
pvesh get /storage
```

## Customization Options

### Drive Selection

To exclude specific drives from ZFS setup, edit the configuration:

```bash
# Exclude specific drives
EXCLUDE_DRIVES=("/dev/sda" "/dev/nvme0n1")
```

### Network Settings

To use specific network configuration instead of auto-detection:

```bash
NETWORK_INTERFACE="eth0"
NETWORK_IP="192.168.1.100/24"
NETWORK_GATEWAY="192.168.1.1"
```

### ZFS Settings

Customize ZFS pool settings:

```bash
ZFS_COMPRESSION="lz4"      # or "gzip", "zstd"
ZFS_ATIME="off"           # Disable access time updates
AUTO_MIRROR="yes"         # Enable automatic mirroring
MIN_MIRROR_SIZE="100"     # Minimum size for mirrors (GB)
```

## Safety Features

### Pre-Installation Checks

The script includes multiple safety checks:
- **Confirms destructive operations** before proceeding
- **Backs up network configuration** before changes
- **Validates ZFS functionality** before use
- **Checks system requirements** (RAM, disk space)

### Recovery Options

If something goes wrong:
- **Installation logs** are saved to `/tmp/proxmox-install.log`
- **Network backup** is saved to `/tmp/network-backup/`
- **ZFS pools can be imported** manually if needed
- **Boot from rescue system** to recover

## Troubleshooting

### Common Issues

**"No suitable drives found":**
- Check that drives aren't mounted: `lsblk`
- Verify EXCLUDE_DRIVES setting in config

**"Failed to download Proxmox ISO":**
- Check internet connectivity: `ping google.com`
- Update PROXMOX_ISO_URL in configuration

**"ZFS module not loaded":**
- Update packages: `apt-get update`
- Install ZFS: `apt-get install zfsutils-linux`

### Getting Help

For detailed troubleshooting, see `docs/troubleshooting.md`.

For support, check:
- Installation logs: `/tmp/proxmox-install.log`
- System logs: `journalctl -u proxmox-firstboot`
- ZFS status: `zpool status`

## Next Steps

After successful installation:

1. **Configure storage** pools for VMs and containers
2. **Set up backups** using Proxmox Backup Server
3. **Create your first VM** or container
4. **Configure networking** for VM isolation
5. **Set up monitoring** and alerting

For detailed guides, visit the [Proxmox documentation](https://pve.proxmox.com/pve-docs/).
