#!/usr/bin/bash
# Helper script for managing additional IPs in Proxmox routed network setup

set -e

# Define colors for output
CLR_RED="\033[1;31m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_CYAN="\033[1;36m"
CLR_RESET="\033[m"

INTERFACES_FILE="/etc/network/interfaces"
BACKUP_DIR="/etc/network/backups"

show_usage() {
    echo -e "${CLR_CYAN}Proxmox Additional IP Management${CLR_RESET}"
    echo "Helper script for managing additional IPs in routed network setup"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  add <ip>        Add an additional IP to the routed setup"
    echo "  remove <ip>     Remove an additional IP from the setup"
    echo "  list           List currently configured additional IPs"
    echo "  backup         Create a backup of network configuration"
    echo "  restore        Restore from the latest backup"
    echo "  status         Show network configuration status"
    echo ""
    echo "Examples:"
    echo "  $0 add 203.0.113.10"
    echo "  $0 add 192.0.2.20"
    echo "  $0 remove 203.0.113.10"
    echo "  $0 list"
    echo ""
    echo "Notes:"
    echo "  • IPs are automatically configured with /32 mask for routed setup"
    echo "  • IPv6 addresses are supported"
    echo "  • Network interface is restarted after changes"
    echo "  • Automatic backup is created before modifications"
    echo ""
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${CLR_RED}This script must be run as root${CLR_RESET}"
        exit 1
    fi
}

# Check if Proxmox is installed
check_proxmox() {
    if ! command -v pveversion >/dev/null 2>&1; then
        echo -e "${CLR_YELLOW}Warning: Proxmox VE does not appear to be installed${CLR_RESET}"
    fi
}

# Create backup directory
ensure_backup_dir() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        echo -e "${CLR_GREEN}Created backup directory: $BACKUP_DIR${CLR_RESET}"
    fi
}

# Create backup of network configuration
create_backup() {
    ensure_backup_dir
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="$BACKUP_DIR/interfaces_$timestamp"
    
    if [[ -f "$INTERFACES_FILE" ]]; then
        cp "$INTERFACES_FILE" "$backup_file"
        echo -e "${CLR_GREEN}Backup created: $backup_file${CLR_RESET}"
    else
        echo -e "${CLR_RED}Network interfaces file not found: $INTERFACES_FILE${CLR_RESET}"
        exit 1
    fi
}

# Validate IP address
validate_ip() {
    local ip="$1"
    
    # IPv4 validation
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra parts <<< "$ip"
        for part in "${parts[@]}"; do
            if [[ $part -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    
    # IPv6 validation (basic)
    if [[ $ip =~ ^[0-9a-fA-F:]+$ ]] && [[ $ip == *":"* ]]; then
        return 0
    fi
    
    return 1
}

# Find vmbr0 bridge configuration section
find_vmbr0_section() {
    local start_line
    local end_line
    
    start_line=$(grep -n "^auto vmbr0" "$INTERFACES_FILE" | cut -d: -f1)
    if [[ -z "$start_line" ]]; then
        echo -e "${CLR_RED}Error: vmbr0 bridge not found in network configuration${CLR_RESET}"
        exit 1
    fi
    
    # Find the end of the vmbr0 section (next 'auto' or 'iface' line or end of file)
    end_line=$(tail -n +$((start_line + 1)) "$INTERFACES_FILE" | grep -n "^auto\|^iface" | head -n1 | cut -d: -f1)
    if [[ -n "$end_line" ]]; then
        end_line=$((start_line + end_line))
    else
        end_line=$(wc -l < "$INTERFACES_FILE")
    fi
    
    echo "$start_line $end_line"
}

# Add additional IP route
add_ip() {
    local ip="$1"
    
    if [[ -z "$ip" ]]; then
        echo -e "${CLR_RED}Error: IP address is required${CLR_RESET}"
        show_usage
        exit 1
    fi
    
    if ! validate_ip "$ip"; then
        echo -e "${CLR_RED}Error: Invalid IP address format${CLR_RESET}"
        exit 1
    fi
    
    # Check if IP already exists
    if grep -q "ip route add $ip" "$INTERFACES_FILE"; then
        echo -e "${CLR_YELLOW}IP $ip is already configured${CLR_RESET}"
        exit 0
    fi
    
    echo -e "${CLR_BLUE}Adding additional IP: $ip${CLR_RESET}"
    
    # Create backup
    create_backup
    
    # Find vmbr0 section
    local section_info
    section_info=$(find_vmbr0_section)
    local start_line
    local end_line
    start_line=$(echo "$section_info" | cut -d' ' -f1)
    end_line=$(echo "$section_info" | cut -d' ' -f2)
    
    # Determine if it's IPv4 or IPv6
    local route_cmd
    if [[ $ip == *":"* ]]; then
        route_cmd="    up ip -6 route add $ip/128 dev vmbr0"
    else
        route_cmd="    up ip route add $ip/32 dev vmbr0"
    fi
    
    # Insert the route command before the end of vmbr0 section
    sed -i "${end_line}i\\$route_cmd" "$INTERFACES_FILE"
    
    echo -e "${CLR_GREEN}Added route for IP: $ip${CLR_RESET}"
    
    # Restart networking
    restart_networking
}

# Remove additional IP route
remove_ip() {
    local ip="$1"
    
    if [[ -z "$ip" ]]; then
        echo -e "${CLR_RED}Error: IP address is required${CLR_RESET}"
        show_usage
        exit 1
    fi
    
    # Check if IP exists in configuration
    if ! grep -q "ip route add $ip\|ip -6 route add $ip" "$INTERFACES_FILE"; then
        echo -e "${CLR_YELLOW}IP $ip is not configured${CLR_RESET}"
        exit 0
    fi
    
    echo -e "${CLR_BLUE}Removing additional IP: $ip${CLR_RESET}"
    
    # Create backup
    create_backup
    
    # Remove the route line
    sed -i "/ip route add $ip\/32\|ip -6 route add $ip\/128/d" "$INTERFACES_FILE"
    
    echo -e "${CLR_GREEN}Removed route for IP: $ip${CLR_RESET}"
    
    # Restart networking
    restart_networking
}

# List configured additional IPs
list_ips() {
    echo -e "${CLR_BLUE}Currently configured additional IPs:${CLR_RESET}"
    echo ""
    
    local ipv4_routes
    local ipv6_routes
    
    ipv4_routes=$(grep "up ip route add" "$INTERFACES_FILE" | sed 's/.*add \([^/]*\).*/\1/' | sort)
    ipv6_routes=$(grep "up ip -6 route add" "$INTERFACES_FILE" | sed 's/.*add \([^/]*\).*/\1/' | sort)
    
    if [[ -n "$ipv4_routes" ]]; then
        echo -e "${CLR_GREEN}IPv4 addresses:${CLR_RESET}"
        echo "$ipv4_routes" | while read -r ip; do
            echo "  • $ip"
        done
        echo ""
    fi
    
    if [[ -n "$ipv6_routes" ]]; then
        echo -e "${CLR_GREEN}IPv6 addresses:${CLR_RESET}"
        echo "$ipv6_routes" | while read -r ip; do
            echo "  • $ip"
        done
        echo ""
    fi
    
    if [[ -z "$ipv4_routes" && -z "$ipv6_routes" ]]; then
        echo -e "${CLR_YELLOW}No additional IPs configured${CLR_RESET}"
    fi
}

# Show network status
show_status() {
    echo -e "${CLR_BLUE}Network Configuration Status:${CLR_RESET}"
    echo ""
    
    # Show bridge information
    if command -v brctl >/dev/null 2>&1; then
        echo -e "${CLR_GREEN}Bridge Information:${CLR_RESET}"
        brctl show
        echo ""
    fi
    
    # Show routing table
    echo -e "${CLR_GREEN}IPv4 Routing Table:${CLR_RESET}"
    ip route show | grep -E "vmbr|dev.*scope"
    echo ""
    
    # Show IPv6 routing if available
    if ip -6 route show 2>/dev/null | grep -q .; then
        echo -e "${CLR_GREEN}IPv6 Routing Table:${CLR_RESET}"
        ip -6 route show | grep -E "vmbr|dev.*scope"
        echo ""
    fi
    
    # Show interface status
    echo -e "${CLR_GREEN}Bridge Interface Status:${CLR_RESET}"
    ip addr show vmbr0 2>/dev/null || echo "vmbr0 not found"
}

# Restart networking service
restart_networking() {
    echo -e "${CLR_YELLOW}Restarting networking...${CLR_RESET}"
    
    if systemctl is-active --quiet networking; then
        systemctl restart networking
    else
        /etc/init.d/networking restart
    fi
    
    # Wait a moment for interfaces to come up
    sleep 2
    
    echo -e "${CLR_GREEN}Networking restarted${CLR_RESET}"
}

# Restore from backup
restore_backup() {
    ensure_backup_dir
    
    # Find latest backup
    local latest_backup
    latest_backup=$(ls -t "$BACKUP_DIR"/interfaces_* 2>/dev/null | head -n1)
    
    if [[ -z "$latest_backup" ]]; then
        echo -e "${CLR_RED}No backups found in $BACKUP_DIR${CLR_RESET}"
        exit 1
    fi
    
    echo -e "${CLR_BLUE}Latest backup: $latest_backup${CLR_RESET}"
    echo -e "${CLR_YELLOW}This will restore the network configuration and restart networking${CLR_RESET}"
    
    read -p "Continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Restore cancelled."
        exit 0
    fi
    
    cp "$latest_backup" "$INTERFACES_FILE"
    echo -e "${CLR_GREEN}Configuration restored from backup${CLR_RESET}"
    
    restart_networking
}

# Main execution
main() {
    local command="$1"
    
    case "$command" in
        add)
            check_root
            check_proxmox
            add_ip "$2"
            ;;
        remove)
            check_root
            check_proxmox
            remove_ip "$2"
            ;;
        list)
            list_ips
            ;;
        backup)
            check_root
            create_backup
            ;;
        restore)
            check_root
            restore_backup
            ;;
        status)
            show_status
            ;;
        help|--help|-h|"")
            show_usage
            ;;
        *)
            echo -e "${CLR_RED}Unknown command: $command${CLR_RESET}"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
