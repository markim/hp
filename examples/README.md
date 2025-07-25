# Example Network Configurations

This directory contains example network configurations for different Hetzner server setups.

## Routed Network Setup (Recommended)

The routed setup is recommended by Hetzner for Proxmox installations. It provides better flexibility and doesn't require virtual MAC addresses.

### Features

- Main IP configured with /32 mask on physical interface
- Bridge (vmbr0) configured for routing additional IPs
- Private subnet bridge (vmbr1) for VM communication
- IPv6 support with proper routing
- IP forwarding enabled for guest systems

### Configuration Files

- `interfaces-routed-ipv4.conf` - IPv4 only routed setup
- `interfaces-routed-dual.conf` - IPv4 + IPv6 routed setup
- `interfaces-bridged.conf` - Traditional bridged setup (requires virtual MACs)

## Usage Examples

### Adding Additional IPs

For a routed setup, additional IPs are configured as routes in vmbr0:

```bash
# Add IPv4 additional IP
./manage-ips.sh add 203.0.113.10

# Add IPv6 additional IP  
./manage-ips.sh add 2001:db8::10

# List configured IPs
./manage-ips.sh list
```

### VM Network Configuration

#### For VMs using additional IPs

```bash
# /etc/network/interfaces in VM
auto ens18
iface ens18 inet static
    address 203.0.113.10/32
    gateway 198.51.100.10  # Main IP of the host
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
