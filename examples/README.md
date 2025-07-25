# Network Configuration Examples

This directory contains standardized network configuration templates for Hetzner Proxmox installations.

## Available Configurations

### Routed Setup (Recommended)

- **`interfaces-routed-ipv4.conf`** - IPv4 only routed configuration
- **`interfaces-routed-dual.conf`** - IPv4 + IPv6 routed configuration

### Bridged Setup

- **`interfaces-bridged.conf`** - Traditional bridged configuration

## Routed vs Bridged

### Routed Setup ✅ (Recommended)

**Advantages:**
- No virtual MAC addresses required
- Better performance and lower latency
- Easier IP management
- Works out of the box with Hetzner routing

**Use when:**
- You want the simplest and most reliable setup
- You don't need layer 2 features
- You're using standard VMs

### Bridged Setup

**Advantages:**
- Direct layer 2 access
- Supports protocols requiring MAC addresses
- Can handle broadcast traffic

**Requirements:**
- Virtual MAC addresses from Hetzner Robot Panel
- More complex configuration
- Additional network setup steps

**Use when:**
- You need layer 2 functionality
- Running specialized network applications
- Migrating from physical servers that expect bridged networking

## Configuration Templates

### Template Variables

Replace these placeholders in the configuration files:

```bash
INTERFACE_NAME      # Your network interface (e.g., enp7s0, ens3)
MAIN_IPV4          # Your main IP address
MAIN_IPV4_GW       # Your gateway IP
ADDITIONAL_IP_1    # First additional IP
ADDITIONAL_IP_2    # Second additional IP
PRIVATE_IP_CIDR    # Private subnet gateway (e.g., 192.168.100.1/24)
PRIVATE_SUBNET     # Private subnet range (e.g., 192.168.100.0/24)
```

### Your Specific Values

For your server (65.21.233.152):

```bash
INTERFACE_NAME="enp7s0"         # Replace with actual interface
MAIN_IPV4="65.21.233.152"
MAIN_IPV4_GW="65.21.233.129"
ADDITIONAL_IP_1="65.21.233.139"
ADDITIONAL_IP_2="65.21.233.140"
PRIVATE_IP_CIDR="192.168.100.1/24"
PRIVATE_SUBNET="192.168.100.0/24"
```

## VM Network Configuration

### VMs with Additional Public IPs (Routed Setup)

```bash
# /etc/network/interfaces in VM
auto ens18
iface ens18 inet static
    address 65.21.233.139/32
    gateway 65.21.233.152  # Proxmox host IP
```

### VMs with Additional Public IPs (Bridged Setup)

```bash
# /etc/network/interfaces in VM
auto ens18
iface ens18 inet static
    address 65.21.233.139/26
    gateway 65.21.233.129   # Original gateway
    
# VM must use MAC: 00:50:56:00:6E:D9
```

### Private VMs (Both Setups)

```bash
# /etc/network/interfaces in VM
auto ens18
iface ens18 inet static
    address 192.168.100.10/24
    gateway 192.168.100.1   # Private bridge IP
    dns-nameservers 1.1.1.1 8.8.8.8
```

## Managing Additional IPs

Use the included management script:

```bash
# Add additional IP route (routed setup)
./manage-ips.sh add 65.21.233.139

# Remove additional IP route
./manage-ips.sh remove 65.21.233.139

# List configured additional IPs
./manage-ips.sh list

# Show network status
./manage-ips.sh status
```

#### For VMs using private subnet

```bash
# /etc/network/interfaces in VM
auto ens18
iface ens18 inet static
    address 192.168.100.10/24
    gateway 192.168.100.1  # Private subnet gateway
```

## Network Topology

```text
Internet
    |
    | Main IP (198.51.100.10/32)
    |
[Physical Interface]
    |
[vmbr0 Bridge] ---- Additional IPs routed here
    |
[vmbr1 Bridge] ---- Private subnet (192.168.100.0/24)
    |
[VMs/Containers]
```

## Security Considerations

- IP forwarding is enabled for proper routing
- iptables rules are configured for NAT on private subnet
- Connection tracking is enabled for firewall zones
- Source route protection is enabled

## Troubleshooting

### Check routing table

```bash
ip route show
```

### Check bridge status

```bash
brctl show
```

### Verify IP forwarding

```bash
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding
```

### Test connectivity from VM

```bash
# From VM to internet
ping 8.8.8.8

# From VM to host
ping 192.168.100.1
```
