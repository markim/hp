# Hetzner Proxmox ZFS Installation Automation

This repository contains scripts to automate the installation of Proxmox VE on Hetzner dedicated servers with ZFS storage configuration.

## Overview

The automation handles:
- Drive detection and ZFS pool configuration
- Automatic mirroring of same-size drives
- Network configuration preservation
- Proxmox VE installation with ZFS root
- Post-installation configuration

## Prerequisites

- Hetzner dedicated server booted into rescue system
- Root access to the rescue system
- Internet connectivity

## Quick Start

1. Boot your server into Hetzner rescue system
2. Download and run the main installation script:

```bash
wget https://raw.githubusercontent.com/yourusername/hetzner-proxmox-zfs/main/install.sh
chmod +x install.sh
./install.sh
```

## Manual Installation

If you prefer to run the process step by step:

1. **Prepare the system:**
   ```bash
   ./scripts/01-prepare-system.sh
   ```

2. **Configure ZFS pools:**
   ```bash
   ./scripts/02-setup-zfs.sh
   ```

3. **Install Proxmox:**
   ```bash
   ./scripts/03-install-proxmox.sh
   ```

4. **Configure system:**
   ```bash
   ./scripts/04-post-install.sh
   ```

## Configuration

Edit `config/server-config.conf` to customize:
- ZFS pool names and configurations
- Network settings
- Proxmox installation options

## Features

- **Automatic Drive Detection**: Identifies all available drives and their sizes
- **Smart Mirroring**: Automatically pairs drives of the same size for ZFS mirrors
- **Network Preservation**: Maintains existing network configuration
- **Unattended Installation**: Fully automated Proxmox installation
- **ZFS Best Practices**: Implements recommended ZFS settings for Proxmox

## Supported Configurations

- Single drive (no redundancy)
- Mirror (2 drives of same size)
- Multiple mirrors (pairs of same-size drives)
- Mixed configurations (mirrors + single drives)

## Safety Features

- Pre-installation drive backup prompts
- Configuration validation
- Rollback capabilities
- Detailed logging

## Troubleshooting

See `docs/troubleshooting.md` for common issues and solutions.

## License

MIT License - see LICENSE file for details.
