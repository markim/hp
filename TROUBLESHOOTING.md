# Hetzner Proxmox Network Troubleshooting Guide

## CRITICAL ISSUES IDENTIFIED

Based on your IP configuration and the Hetzner tutorial, here are the likely causes of your connectivity loss:

### 1. **MISSING /32 SUBNET MASK ON PHYSICAL INTERFACE**
**Problem**: Using /24 or /26 instead of /32 on the physical interface
**Solution**: Physical interface MUST use /32 mask for Hetzner routed setup

```bash
# WRONG:
address 65.21.233.152/26

# CORRECT:
address 65.21.233.152/32
```

### 2. **MISSING POINTOPOINT CONFIGURATION**
**Problem**: Missing pointopoint gateway configuration
**Solution**: Add pointopoint directive to physical interface

```bash
auto INTERFACE_NAME
iface INTERFACE_NAME inet static
    address 65.21.233.152/32
    gateway 65.21.233.129
    pointopoint 65.21.233.129    # <- THIS IS CRITICAL
```

### 3. **MISSING ADDITIONAL IP ROUTES**
**Problem**: Additional IPs not routed through vmbr0
**Solution**: Add explicit routes for additional IPs

```bash
auto vmbr0
iface vmbr0 inet static
    address 65.21.233.152/32
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # THESE ROUTES ARE ESSENTIAL:
    up ip route add 65.21.233.139/32 dev vmbr0
    up ip route add 65.21.233.140/32 dev vmbr0
```

### 4. **IP FORWARDING NOT ENABLED**
**Problem**: IP forwarding disabled
**Solution**: Enable IP forwarding

```bash
# Check current status:
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding

# Enable permanently:
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
sysctl -p
```

### 5. **ZFS BOOT ISSUES**
**Problem**: ZFS root filesystem boot failures
**Symptoms**: System doesn't boot after installation
**Solutions**:
- Ensure proper ZFS pool import settings
- Check initramfs includes ZFS modules
- Verify bootloader configuration

## RECOVERY STEPS

### Step 1: Boot into Hetzner Rescue System
1. Boot server into rescue system
2. Mount your ZFS root pool:
```bash
zpool import -f rpool
zfs mount rpool/ROOT/pve-1
```

### Step 2: Fix Network Configuration
1. Mount the root filesystem
2. Edit `/etc/network/interfaces` with the corrected configuration
3. Ensure IP forwarding is enabled in `/etc/sysctl.conf`

### Step 3: Fix ZFS Boot (if needed)
```bash
# Update initramfs
chroot /path/to/mounted/root
update-initramfs -u -k all
update-grub
```

## NETWORK CONFIGURATION CHOICE

### Option A: Routed Setup (Recommended)
- Use corrected-interfaces.conf
- Requires proper /32 configuration
- Additional IPs routed through vmbr0
- More flexible for multiple IPs/subnets

### Option B: Bridged Setup
- Use corrected-interfaces-bridged.conf  
- Requires virtual MAC addresses from Hetzner Robot Panel
- Each additional IP needs its assigned MAC in VM config
- Simpler routing but requires MAC management

## TESTING CONNECTIVITY

After applying fixes:

```bash
# Test basic connectivity
ping -c 3 65.21.233.129   # Gateway
ping -c 3 8.8.8.8         # External IP

# Test routing
ip route show
ip addr show

# Test additional IP reachability from VMs
# (create test VMs with additional IPs)
```

## YOUR SPECIFIC CONFIGURATION

**Main IP**: 65.21.233.152/32
**Gateway**: 65.21.233.129  
**Additional IP 1**: 65.21.233.139 (MAC: 00:50:56:00:6E:D9)
**Additional IP 2**: 65.21.233.140 (MAC: 00:50:56:00:3A:D9)
**Network**: 65.21.233.128/26 (65.21.233.129-191)

All IPs are in the same subnet, so routing should work with the corrected configuration.
