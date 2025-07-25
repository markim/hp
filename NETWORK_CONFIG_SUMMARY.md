# Network Configuration Summary

This document provides a clear summary of the standardized network configurations for your Hetzner Proxmox server.

## Your Server Details

- **Main IP**: 65.21.233.152
- **Subnet**: /26 (255.255.255.192)
- **Gateway**: 65.21.233.129
- **Broadcast**: 65.21.233.191
- **Additional IP 1**: 65.21.233.139 (MAC: 00:50:56:00:6E:D9)
- **Additional IP 2**: 65.21.233.140 (MAC: 00:50:56:00:3A:D9)

## Configuration Files

### Primary Configurations

1. **`corrected-interfaces.conf`** - Your routed setup (RECOMMENDED)
2. **`corrected-interfaces-bridged.conf`** - Your bridged setup (requires virtual MACs)

### Template Files

1. **`examples/interfaces-routed-ipv4.conf`** - Generic routed template
2. **`examples/interfaces-bridged.conf`** - Generic bridged template

## Setup Choice

### Option 1: Routed Setup (RECOMMENDED)

**File**: `corrected-interfaces.conf`

**Advantages**:
- No virtual MAC addresses needed
- Better performance
- Easier management
- Works out of the box

**VM Configuration**:
- Bridge: vmbr0
- IP: 65.21.233.139/32 or 65.21.233.140/32
- Gateway: 65.21.233.152 (Proxmox host)

### Option 2: Bridged Setup

**File**: `corrected-interfaces-bridged.conf`

**Requirements**:
- Virtual MAC addresses from Hetzner Robot Panel
- Each additional IP must use its assigned MAC

**VM Configuration**:
- Bridge: vmbr0
- IP: 65.21.233.139/26 or 65.21.233.140/26
- Gateway: 65.21.233.129 (original gateway)
- MAC: Must match Hetzner assignment

## Installation Process

1. Boot into Hetzner rescue system
2. Run the installation script: `./install.sh`
3. The script will detect your network and create the appropriate configuration
4. For manual configuration, copy the appropriate config file to `/etc/network/interfaces`

## Post-Installation

### Adding Additional IPs (Routed Setup)

```bash
# Add route for additional IP
ip route add 65.21.233.139/32 dev vmbr0

# Make permanent by adding to /etc/network/interfaces:
# up ip route add 65.21.233.139/32 dev vmbr0
```

### VM Creation

1. Create VM in Proxmox web interface
2. Set network to appropriate bridge (vmbr0 for public, vmbr1 for private)
3. Configure VM's network settings according to setup type
4. For bridged setup: Set VM MAC address to match Hetzner assignment

## Troubleshooting

### Common Issues

1. **No network after installation**
   - Check interface name in configuration file
   - Verify routes are added correctly
   - Restart networking: `systemctl restart networking`

2. **Additional IPs not working**
   - Verify routes are configured: `ip route show`
   - Check iptables rules: `iptables -L -n`
   - For bridged: Verify MAC addresses match

3. **VMs cannot reach internet**
   - Check NAT rules for private bridge
   - Verify IP forwarding: `sysctl net.ipv4.ip_forward`
   - Check firewall settings

### Network Verification

```bash
# Check interface configuration
ip addr show

# Check routing table
ip route show

# Test connectivity
ping -c 3 65.21.233.129  # Gateway
ping -c 3 8.8.8.8        # Internet

# Check bridge status
brctl show
```

## Files Summary

- `install.sh` - Main installation script
- `corrected-interfaces.conf` - Your routed configuration
- `corrected-interfaces-bridged.conf` - Your bridged configuration
- `manage-ips.sh` - IP management helper
- `examples/` - Template configurations
- `README.md` - General documentation
- `INSTALLATION_GUIDE.md` - Detailed installation steps
- `TROUBLESHOOTING.md` - Common issues and solutions
