# Enhanced Proxmox VE Installation Script for Hetzner

An updated version of the ariadata/proxmox-hetzner script with additional features:

## 🚀 Features

- **🔧 Drive Selection**: Choose which drives of the same size to install Proxmox to
- **🌐 Routed Network Topology**: Implements Hetzner's recommended routed network configuration
- **📡 Remote Execution**: Execute installation commands via SSH from a remote machine
- **🔍 Automated Detection**: Automatically detects available drives and network configuration
- **💾 ZFS RAID Configuration**: Supports various ZFS RAID levels (RAID-0, RAID-1, RAID-10, RAIDZ1, RAIDZ2)
- **📋 IP Management**: Helper scripts for managing additional IPs in routed setup
- **🛡️ Security Hardening**: Applies recommended security settings automatically

## 📁 Project Structure

```text
hp/
├── install.sh              # Main installation script
├── remote-install.sh        # Remote execution script
├── manage-ips.sh           # Additional IP management helper
├── README.md               # This file
├── INSTALLATION_GUIDE.md   # Detailed installation guide
├── Makefile               # Build automation
└── examples/
    ├── README.md          # Network configuration examples
    ├── interfaces-routed-ipv4.conf   # IPv4 routed setup
    ├── interfaces-routed-dual.conf   # IPv4+IPv6 routed setup
    └── interfaces-bridged.conf       # Traditional bridged setup
```

## 🚀 Quick Start

### Remote Installation (Recommended)

Execute from your local machine to install on a remote Hetzner server:

```bash
# Download and run remote installation
curl -sSL https://raw.githubusercontent.com/markim/hp/main/remote-install.sh | bash -s -- proxmox.80px.com

# Or with SSH options
curl -sSL https://raw.githubusercontent.com/markim/hp/main/remote-install.sh | bash -s -- -u root -p 22 198.51.100.10
```

### Direct Installation

Execute directly on the Hetzner rescue system:

```bash
# SSH to your server first
ssh root@proxmox.80px.com

# Then run the installation script
bash <(curl -sSL https://raw.githubusercontent.com/markim/hp/main/install.sh)
```

### Using Make Commands

```bash
# Clone the repository
git clone https://github.com/markim/hp.git
cd hp

# Local installation
make install

# Remote installation
make remote-install SERVER=proxmox.80px.com

# Check script syntax
make check-syntax

# View examples
make examples
```

## 🌐 Network Configuration

The script implements Hetzner's routed network topology as documented in their [official guide](https://community.hetzner.com/tutorials/install-and-configure-proxmox_ve#step-2---network-configuration).

### Routed Setup Features

- **Physical Interface**: Configured with main IP (/32 mask) for optimal routing
- **Bridge vmbr0**: Routes traffic for additional public IPs without virtual MACs
- **Bridge vmbr1**: Private subnet for VM communication with NAT
- **IPv6 Support**: Full dual-stack configuration when available
- **IP Forwarding**: Automatically enabled for proper guest routing

### Network Topology

```text
Internet
    │
    │ Main IP (198.51.100.10/32)
    │
[Physical Interface]
    │
[vmbr0 Bridge] ──── Additional IPs routed here
    │
[vmbr1 Bridge] ──── Private subnet (192.168.100.0/24)
    │
[VMs/Containers]
```

## 📋 Managing Additional IPs

Use the included IP management script:

```bash
# Add additional IPv4 IP
./manage-ips.sh add 203.0.113.10

# Add additional IPv6 IP  
./manage-ips.sh add 2001:db8::10

# List configured IPs
./manage-ips.sh list

# Remove an IP
./manage-ips.sh remove 203.0.113.10

# Show network status
./manage-ips.sh status
```

## 🔧 VM Configuration Examples

### VM with Additional Public IP

```bash
# /etc/network/interfaces in VM
auto ens18
iface ens18 inet static
    address 203.0.113.10/32
    gateway 198.51.100.10  # Host main IP
```

### VM with Private Subnet

```bash
# /etc/network/interfaces in VM
auto ens18
iface ens18 inet static
    address 192.168.100.10/24
    gateway 192.168.100.1  # Private subnet gateway
    dns-nameservers 8.8.8.8 1.1.1.1
```

## 📋 Requirements

### Hetzner Server Requirements

- **Server Types**: AX Series, EX Series, or SX Series dedicated servers
- **Storage**: At least 2 drives of the same size for ZFS RAID
- **Memory**: Minimum 8GB RAM (16GB+ recommended for production)
- **Network**: Rescue system access via Hetzner Robot Panel

### Software Requirements

The installation script automatically installs required packages:
- `proxmox-auto-install-assistant` - For automated installation
- `qemu-system-x86_64` - For virtualized installation
- `ovmf` - UEFI firmware support
- `sshpass` - For remote configuration
- `bridge-utils` - Network bridge management

## 🛠️ Installation Process

### 1. Drive Selection

- **Automatic Detection**: Scans and groups drives by size
- **Interactive Selection**: Choose specific drives for installation
- **RAID Configuration**: Select appropriate RAID level based on drive count

### 2. Network Detection

- **Auto-Discovery**: Detects network interface and configuration
- **Validation**: Confirms detected settings with user
- **IPv6 Support**: Automatically configures dual-stack when available

### 3. System Installation

- **Automated Process**: Downloads latest Proxmox ISO and installs via QEMU
- **Zero-Touch**: No VNC interaction required
- **Progress Monitoring**: Real-time feedback during installation

### 4. Post-Installation Configuration

- **Network Setup**: Configures routed topology with proper IP forwarding
- **Security Hardening**: Applies recommended security settings
- **Package Updates**: Updates system and installs essential tools

## 🔍 Troubleshooting

### Common Issues

**Drive Selection Fails**
```bash
# Check available drives
lsblk -d
# Ensure drives are not in use
umount /dev/sdX*
```

**Network Detection Issues**
```bash
# Verify network interface
ip link show
# Test connectivity
ping -c 3 8.8.8.8
```

**VM Cannot Access Internet**
```bash
# Check IP forwarding
sysctl net.ipv4.ip_forward
# Verify NAT rules
iptables -t nat -L
```

### Support Resources

- 📖 [Detailed Installation Guide](INSTALLATION_GUIDE.md)
- 🌐 [Network Examples](examples/README.md)
- 🏠 [Proxmox Documentation](https://pve.proxmox.com/pve-docs/)
- 💬 [Hetzner Community](https://community.hetzner.com/tutorials)

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Test your changes thoroughly
4. Submit a pull request with detailed description

### Development Setup

```bash
# Clone and setup
git clone https://github.com/markim/hp.git
cd hp

# Setup development environment
make dev-setup

# Run tests
make test

# Check syntax
make check-syntax
```

## 📄 License

This project is released under the MIT License. See the original [ariadata/proxmox-hetzner](https://github.com/ariadata/proxmox-hetzner) project for the base implementation.

## 🙏 Acknowledgments

- Original script by [ariadata](https://github.com/ariadata/proxmox-hetzner)
- Hetzner's network configuration documentation
- Proxmox VE community and documentation

---

**⚠️ Important**: This script is designed for Hetzner dedicated servers. Always test in a non-production environment first and ensure you have backups of any important data before running the installation.
