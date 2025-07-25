# Enhanced Proxmox VE Installation Guide for Hetzner

This guide provides step-by-step instructions for installing Proxmox VE on Hetzner dedicated servers with advanced features like drive selection and routed network topology.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation Methods](#installation-methods)
3. [Local Installation](#local-installation)
4. [Remote Installation](#remote-installation)
5. [Network Configuration](#network-configuration)
6. [Post-Installation](#post-installation)
7. [Managing Additional IPs](#managing-additional-ips)
8. [Troubleshooting](#troubleshooting)

## Prerequisites

### Hetzner Requirements

- Dedicated server from Hetzner (AX, EX, or SX series)
- Access to Hetzner Robot Panel
- At least 2 drives of the same size for ZFS RAID
- Minimum 8GB RAM (16GB+ recommended)

### Network Information Needed

- Main IP address and subnet
- Gateway IP address
- Additional IP addresses (if any)
- IPv6 information (if using)

### Before Starting

1. **Activate Rescue System**
   - Login to Hetzner Robot Panel
   - Go to your server's "Rescue" tab
   - Select "Linux" rescue system
   - Optionally add your SSH public key
   - Click "Activate rescue system"

2. **Reset Server**
   - Go to "Reset" tab
   - Check "Execute an automatic hardware reset"
   - Click "Send"
   - Wait 5-10 minutes for rescue system to boot

## Installation Methods

### Method 1: Remote Installation (Recommended)

Execute from your local machine to install on a remote Hetzner server:

```bash
# Download and run remote installation script
curl -sSL https://raw.githubusercontent.com/markim/hp/main/remote-install.sh | bash -s -- proxmox.80px.com

# Or with custom SSH settings
curl -sSL https://raw.githubusercontent.com/markim/hp/main/remote-install.sh | bash -s -- -u root -p 22 198.51.100.10
```

### Method 2: Direct Installation

Execute directly on the Hetzner rescue system:

```bash
# SSH to your server first
ssh root@proxmox.80px.com

# Then run the installation script
bash <(curl -sSL https://raw.githubusercontent.com/markim/hp/main/install.sh)
```

## Local Installation

When running the installation script directly on the server:

### Step 1: Drive Selection

The script will automatically detect available drives and group them by size:

```
Available drives grouped by size:
Group 1: Size: 1.8T
  Drives: /dev/nvme0n1 /dev/nvme1n1

Group 2: Size: 7.3T  
  Drives: /dev/sda /dev/sdb /dev/sdc /dev/sdd
```

**Selection Process:**
1. Choose the drive size group you want to use
2. Select specific drives from that group
3. Confirm your selection

**Recommendations:**
- Use NVMe drives for better performance
- Select at least 2 drives for ZFS RAID redundancy
- Ensure drives are the same size for optimal ZFS performance

### Step 2: RAID Level Selection

Based on the number of drives selected:

- **2 drives**: RAID-1 (mirror) recommended
- **3 drives**: RAIDZ1 (RAID-5 equivalent) recommended  
- **4+ drives**: RAIDZ2 (RAID-6 equivalent) recommended

### Step 3: Network Configuration

The script auto-detects network settings and prompts for confirmation:

```
Detected Network Information:
Interface: enp7s0
Main IPv4: 198.51.100.10/27
Gateway: 198.51.100.1
MAC Address: aa:bb:cc:dd:ee:ff
IPv6: 2001:db8::2/64
```

**Configuration Options:**
- Hostname and FQDN
- Email address
- Timezone
- Private subnet for VMs
- Root password

### Step 4: Installation Process

The script will:
1. Download latest Proxmox VE ISO
2. Create auto-installation configuration
3. Install Proxmox via QEMU virtualization
4. Configure routed network topology
5. Apply security settings
6. Install essential packages

## Remote Installation

Using the remote installation script provides additional benefits:

### Features

- **Connection Testing**: Verifies SSH connectivity before starting
- **Rescue Mode Detection**: Confirms server is in rescue mode
- **Progress Monitoring**: Shows installation progress in real-time
- **Error Handling**: Provides detailed error messages

### Usage Examples

```bash
# Basic remote installation
./remote-install.sh proxmox.80px.com

# With custom SSH user and port
./remote-install.sh -u root -p 22 192.168.1.100

# Using SSH key authentication
./remote-install.sh -k ~/.ssh/hetzner_key proxmox.example.com

# Interactive mode (prompts for all settings)
./remote-install.sh
```

## Network Configuration

The installation uses Hetzner's recommended **routed network topology**.

### Routed Setup Benefits

- No virtual MAC addresses required
- Better performance and flexibility
- Support for multiple IP subnets
- Easier management of additional IPs
- IPv6 support included

### Network Bridges Created

1. **vmbr0**: Routes additional public IPs
   - Connected to physical interface
   - Uses main IP for routing
   - Additional IPs routed through this bridge

2. **vmbr1**: Private subnet for VM communication
   - NAT configuration for internet access
   - Default subnet: 192.168.100.0/24
   - Gateway: 192.168.100.1

### IP Forwarding

The system automatically configures:
- IPv4 forwarding: `net.ipv4.ip_forward=1`
- IPv6 forwarding: `net.ipv6.conf.all.forwarding=1`
- Connection tracking for firewall zones
- iptables rules for NAT and masquerading

## Post-Installation

After installation completes:

### 1. System Reboot

The server will automatically reboot into the new Proxmox installation.

### 2. Web Interface Access

Access the Proxmox web interface:
- URL: `https://YOUR_MAIN_IP:8006`
- Username: `root`
- Password: (the password you set during installation)

### 3. Initial Configuration

**Recommended first steps:**

```bash
# Update package lists
apt update

# Install additional tools
apt install -y curl wget vim htop

# Configure backups
pveam update

# Set up storage pools if needed
```

### 4. Security Hardening

**SSH Configuration:**
```bash
# Change SSH port (optional)
sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config
systemctl restart ssh

# Disable root password authentication (if using keys)
sed -i 's/#PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
```

**Firewall Setup:**
```bash
# Configure Proxmox firewall through web interface
# Or use iptables/nftables for custom rules
```

## Managing Additional IPs

Use the included IP management script for adding/removing additional IPs:

### Adding Additional IPs

```bash
# Add IPv4 additional IP
./manage-ips.sh add 203.0.113.10

# Add IPv6 additional IP
./manage-ips.sh add 2001:db8::10

# List configured IPs
./manage-ips.sh list
```

### VM Configuration for Additional IPs

**For VMs using additional public IPs:**

```bash
# /etc/network/interfaces in VM
auto ens18
iface ens18 inet static
    address 203.0.113.10/32
    gateway 198.51.100.10  # Host main IP

# IPv6 example
iface ens18 inet6 static
    address 2001:db8::10/128
    gateway 2001:db8::3     # Bridge IPv6 address
```

**For VMs using private subnet:**

```bash
# /etc/network/interfaces in VM
auto ens18
iface ens18 inet static
    address 192.168.100.10/24
    gateway 192.168.100.1
    dns-nameservers 8.8.8.8 1.1.1.1
```

### Removing Additional IPs

```bash
# Remove specific IP
./manage-ips.sh remove 203.0.113.10

# Check configuration
./manage-ips.sh status
```

## Troubleshooting

### Installation Issues

**Problem: Drive selection fails**
```bash
# Check available drives
lsblk -d
fdisk -l

# Verify drives are not mounted
mount | grep -E '/dev/(sd|nvme)'
```

**Problem: Network detection fails**
```bash
# Check network interfaces
ip link show
ip addr show

# Verify internet connectivity
ping -c 3 8.8.8.8
```

**Problem: Installation hangs**
```bash
# Check QEMU process
ps aux | grep qemu

# Check installation logs
tail -f qemu_output.log
```

### Network Issues

**Problem: VM cannot reach internet**
```bash
# Check IP forwarding
sysctl net.ipv4.ip_forward

# Verify iptables rules
iptables -t nat -L

# Check routing
ip route show
```

**Problem: Additional IP not working**
```bash
# Verify route is configured
ip route show | grep "your.additional.ip"

# Check bridge status
brctl show

# Test from host
ping your.additional.ip
```

### Performance Issues

**Problem: Slow ZFS performance**
```bash
# Check ZFS ARC settings
cat /proc/spl/kstat/zfs/arcstats

# Adjust ARC size if needed
echo "options zfs zfs_arc_max=$((16 * 1024**3))" >> /etc/modprobe.d/zfs.conf
update-initramfs -u
```

**Problem: High I/O wait**
```bash
# Check disk usage
iotop

# Monitor ZFS pools
zpool iostat 2

# Check for scrub/resilver operations
zpool status
```

### Recovery Options

**Restore network configuration:**
```bash
# Restore from backup
./manage-ips.sh restore

# Or manually edit
cp /etc/network/interfaces.backup /etc/network/interfaces
systemctl restart networking
```

**Boot from rescue system:**
1. Activate rescue system in Robot Panel
2. Reset server
3. Access via SSH to troubleshoot

## Support

For issues specific to this enhanced installation script:
- Check the troubleshooting section above
- Review installation logs
- Test network connectivity step by step

For general Proxmox support:
- [Proxmox VE Documentation](https://pve.proxmox.com/pve-docs/)
- [Proxmox Community Forum](https://forum.proxmox.com/)
- [Hetzner Community Tutorials](https://community.hetzner.com/tutorials)

## Advanced Configuration

### Custom Storage Configuration

After installation, you can add additional storage:

```bash
# Add local storage
pvesm add dir local-backup --path /mnt/backup

# Add NFS storage
pvesm add nfs shared-nfs --server 192.168.1.100 --export /exports/proxmox

# Configure Ceph (for clusters)
pveceph init --network 192.168.100.0/24
```

### Clustering Setup

To join multiple Proxmox nodes:

```bash
# On first node (create cluster)
pvecm create CLUSTER-NAME

# On additional nodes (join cluster)
pvecm add FIRST-NODE-IP
```

### Backup Configuration

Configure automated backups:

```bash
# Create backup schedule via web interface
# Or use CLI
vzdump VMID --compress gzip --storage local-backup
```
