#!/usr/bin/bash
set -e
cd /root

# Define colors for output
CLR_RED="\033[1;31m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_CYAN="\033[1;36m"
CLR_RESET="\033[m"

clear

# Ensure the script is run as root
if [[ $EUID != 0 ]]; then
    echo -e "${CLR_RED}Please run this script as root.${CLR_RESET}"
    exit 1
fi

echo -e "${CLR_GREEN}=== Enhanced Proxmox VE Installation Script ===${CLR_RESET}"
echo -e "${CLR_CYAN}Features: Drive Selection, Routed Network, Remote Execution${CLR_RESET}"
echo ""

# Function to detect available drives and group by size
detect_drives() {
    echo -e "${CLR_BLUE}Detecting available drives...${CLR_RESET}"
    
    # Get drive information
    lsblk -dpno NAME,SIZE,TYPE | grep disk > /tmp/drives.txt
    
    # Group drives by size
    declare -A drives_by_size
    while IFS= read -r line; do
        drive=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        
        if [[ -n "${drives_by_size[$size]}" ]]; then
            drives_by_size[$size]="${drives_by_size[$size]} $drive"
        else
            drives_by_size[$size]="$drive"
        fi
    done < /tmp/drives.txt
    
    echo -e "${CLR_YELLOW}Available drives grouped by size:${CLR_RESET}"
    local group_num=1
    for size in "${!drives_by_size[@]}"; do
        echo -e "${CLR_GREEN}Group $group_num:${CLR_RESET} Size: $size"
        echo "  Drives: ${drives_by_size[$size]}"
        ((group_num++))
    done
    echo ""
}

# Function to select drives for installation
select_drives() {
    echo -e "${CLR_BLUE}Drive Selection${CLR_RESET}"
    echo "Select drives for Proxmox installation:"
    
    # Get unique sizes
    local sizes
    mapfile -t sizes < <(lsblk -dpno SIZE,TYPE | grep disk | awk '{print $1}' | sort -u)
    local size_num=1
    
    echo "Available drive sizes:"
    for size in "${sizes[@]}"; do
        local drives_of_size
        mapfile -t drives_of_size < <(lsblk -dpno NAME,SIZE,TYPE | grep disk | grep "$size" | awk '{print $1}')
        echo -e "${CLR_GREEN}$size_num)${CLR_RESET} Size: $size (${#drives_of_size[@]} drives available)"
        echo "   Drives: ${drives_of_size[*]}"
        ((size_num++))
    done
    echo ""
    
    read -p "Select drive size group (1-$((size_num-1))): " selected_size_num
    
    # Get drives for selected size
    local selected_size="${sizes[$((selected_size_num-1))]}"
    mapfile -t AVAILABLE_DRIVES < <(lsblk -dpno NAME,SIZE,TYPE | grep disk | grep "$selected_size" | awk '{print $1}')
    
    echo -e "${CLR_YELLOW}Available drives of size $selected_size:${CLR_RESET}"
    for i in "${!AVAILABLE_DRIVES[@]}"; do
        echo "$((i+1)). ${AVAILABLE_DRIVES[$i]}"
    done
    echo ""
    
    if [[ ${#AVAILABLE_DRIVES[@]} -lt 2 ]]; then
        echo -e "${CLR_RED}Error: At least 2 drives are required for ZFS RAID${CLR_RESET}"
        exit 1
    fi
    
    # Select specific drives
    echo "Select drives for installation (space-separated numbers, e.g., '1 2' for first two drives):"
    read -p "Drive numbers: " -a selected_indices
    
    SELECTED_DRIVES=()
    for index in "${selected_indices[@]}"; do
        SELECTED_DRIVES+=("${AVAILABLE_DRIVES[$((index-1))]}")
    done
    
    echo -e "${CLR_GREEN}Selected drives:${CLR_RESET} ${SELECTED_DRIVES[*]}"
    
    # Confirm selection
    read -p "Confirm drive selection? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborting installation."
        exit 1
    fi
}

# Function to select ZFS RAID level
select_raid_level() {
    echo -e "${CLR_BLUE}ZFS RAID Level Selection${CLR_RESET}"
    echo "Available RAID levels:"
    echo "1. RAID-0 (No redundancy, maximum performance)"
    echo "2. RAID-1 (Mirror, recommended for 2 drives)"
    echo "3. RAID-10 (Striped mirrors, requires 4+ drives)"
    echo "4. RAIDZ1 (RAID-5 equivalent, requires 3+ drives)"
    echo "5. RAIDZ2 (RAID-6 equivalent, requires 4+ drives)"
    echo ""
    
    local num_drives=${#SELECTED_DRIVES[@]}
    
    if [[ $num_drives -eq 2 ]]; then
        echo -e "${CLR_YELLOW}With 2 drives, RAID-1 (mirror) is recommended.${CLR_RESET}"
        ZFS_RAID="raid1"
    elif [[ $num_drives -eq 3 ]]; then
        echo -e "${CLR_YELLOW}With 3 drives, RAIDZ1 is recommended.${CLR_RESET}"
        read -p "Select RAID level (1=RAID-0, 2=RAID-1, 4=RAIDZ1) [4]: " raid_choice
        case ${raid_choice:-4} in
            1) ZFS_RAID="raid0" ;;
            2) ZFS_RAID="raid1" ;;
            4) ZFS_RAID="raidz1" ;;
            *) ZFS_RAID="raidz1" ;;
        esac
    elif [[ $num_drives -ge 4 ]]; then
        echo -e "${CLR_YELLOW}With $num_drives drives, multiple RAID levels are available.${CLR_RESET}"
        read -p "Select RAID level (1=RAID-0, 2=RAID-1, 3=RAID-10, 4=RAIDZ1, 5=RAIDZ2) [5]: " raid_choice
        case ${raid_choice:-5} in
            1) ZFS_RAID="raid0" ;;
            2) ZFS_RAID="raid1" ;;
            3) ZFS_RAID="raid10" ;;
            4) ZFS_RAID="raidz1" ;;
            5) ZFS_RAID="raidz2" ;;
            *) ZFS_RAID="raidz2" ;;
        esac
    else
        echo -e "${CLR_RED}Error: Invalid number of drives selected${CLR_RESET}"
        exit 1
    fi
    
    echo -e "${CLR_GREEN}Selected RAID level:${CLR_RESET} $ZFS_RAID"
}

# Function to get network configuration
get_network_config() {
    echo -e "${CLR_BLUE}Network Configuration Detection${CLR_RESET}"
    
    # Auto-detect network interface
    DEFAULT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$DEFAULT_INTERFACE" ]; then
        DEFAULT_INTERFACE=$(udevadm info -e | grep -m1 -A 20 ^P.*eth0 | grep ID_NET_NAME_PATH | cut -d'=' -f2)
    fi
    
    # Get all available interfaces
    AVAILABLE_INTERFACES=$(ip -d link show | grep -v "lo:" | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | tr '\n' ' ')
    
    echo -e "${CLR_YELLOW}Available network interfaces:${CLR_RESET} $AVAILABLE_INTERFACES"
    read -e -p "Network interface name: " -i "$DEFAULT_INTERFACE" INTERFACE_NAME
    
    # Get network information
    MAIN_IPV4_CIDR=$(ip address show "$INTERFACE_NAME" | grep global | grep "inet " | xargs | cut -d" " -f2)
    MAIN_IPV4=$(echo "$MAIN_IPV4_CIDR" | cut -d'/' -f1)
    MAIN_IPV4_GW=$(ip route | grep default | xargs | cut -d" " -f3)
    MAC_ADDRESS=$(ip link show "$INTERFACE_NAME" | awk '/ether/ {print $2}')
    IPV6_CIDR=$(ip address show "$INTERFACE_NAME" | grep global | grep "inet6 " | xargs | cut -d" " -f2 || true)
    MAIN_IPV6=$(echo "$IPV6_CIDR" | cut -d'/' -f1)
    
    # Calculate IPv6 bridge address for routed setup
    if [ -n "$IPV6_CIDR" ]; then
        IPV6_PREFIX=$(echo "$IPV6_CIDR" | cut -d'/' -f1 | cut -d':' -f1-4)
        BRIDGE_IPV6="${IPV6_PREFIX}::3/64"
    else
        BRIDGE_IPV6=""
    fi
    
    echo -e "${CLR_YELLOW}Detected Network Configuration:${CLR_RESET}"
    echo "Interface: $INTERFACE_NAME"
    echo "Main IPv4: $MAIN_IPV4_CIDR"
    echo "Gateway: $MAIN_IPV4_GW"
    echo "MAC Address: $MAC_ADDRESS"
    echo "IPv6: $IPV6_CIDR"
    echo ""
    
    # Get additional configuration
    read -e -p "Hostname: " -i "proxmox-hetzner" HOSTNAME
    read -e -p "Domain (FQDN): " -i "proxmox.example.com" FQDN
    read -e -p "Email: " -i "admin@example.com" EMAIL
    read -e -p "Timezone: " -i "Europe/Berlin" TIMEZONE
    read -e -p "Private subnet for VMs: " -i "192.168.100.0/24" PRIVATE_SUBNET
    
    # Calculate private subnet gateway
    PRIVATE_CIDR=$(echo "$PRIVATE_SUBNET" | cut -d'/' -f1 | rev | cut -d'.' -f2- | rev)
    PRIVATE_IP="${PRIVATE_CIDR}.1"
    SUBNET_MASK=$(echo "$PRIVATE_SUBNET" | cut -d'/' -f2)
    PRIVATE_IP_CIDR="${PRIVATE_IP}/${SUBNET_MASK}"
    
    # Get root password
    while [[ -z "$NEW_ROOT_PASSWORD" ]]; do
        read -s -p "New root password: " NEW_ROOT_PASSWORD
        echo ""
        if [[ -z "$NEW_ROOT_PASSWORD" ]]; then
            echo -e "${CLR_RED}Password cannot be empty!${CLR_RESET}"
        fi
    done
    
    echo ""
    echo -e "${CLR_GREEN}Network configuration completed.${CLR_RESET}"
}

# Function to prepare packages
prepare_packages() {
    echo -e "${CLR_BLUE}Installing required packages...${CLR_RESET}"
    
    # Add Proxmox repository
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" | tee /etc/apt/sources.list.d/pve.list
    curl -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
    
    # Update and install packages
    apt clean && apt update
    apt install -yq proxmox-auto-install-assistant xorriso ovmf wget sshpass
    
    echo -e "${CLR_GREEN}Packages installed successfully.${CLR_RESET}"
}

# Function to get latest Proxmox VE ISO
get_latest_proxmox_iso() {
    echo -e "${CLR_BLUE}Downloading latest Proxmox VE ISO...${CLR_RESET}"
    
    local base_url="https://enterprise.proxmox.com/iso/"
    local latest_iso
    latest_iso=$(curl -s "$base_url" | grep -oP 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -V | tail -n1)
    
    if [[ -n "$latest_iso" ]]; then
        PROXMOX_ISO_URL="${base_url}${latest_iso}"
        wget -O pve.iso "$PROXMOX_ISO_URL"
        echo -e "${CLR_GREEN}Downloaded: $latest_iso${CLR_RESET}"
    else
        echo -e "${CLR_RED}Failed to find Proxmox VE ISO!${CLR_RESET}"
        exit 1
    fi
}

# Function to create auto-installation answer file
create_answer_file() {
    echo -e "${CLR_BLUE}Creating auto-installation configuration...${CLR_RESET}"
    
    # Build disk list for answer file (convert /dev/xxx to vdX for virtio)
    local disk_list=""
    local virt_disk_idx=97  # ASCII 'a'
    for drive in "${SELECTED_DRIVES[@]}"; do
        local virt_disk
        virt_disk="vd$(printf "\\$(printf '%03o' "$virt_disk_idx")")"
        disk_list="$disk_list\"/dev/$virt_disk\", "
        ((virt_disk_idx++))
    done
    disk_list="[${disk_list%, }]"  # Remove trailing comma and add brackets
    
    cat <<EOF > answer.toml
[global]
    keyboard = "en-us"
    country = "us"
    fqdn = "$FQDN"
    mailto = "$EMAIL"
    timezone = "$TIMEZONE"
    root_password = "$NEW_ROOT_PASSWORD"
    reboot_on_error = false

[network]
    source = "from-dhcp"

[disk-setup]
    filesystem = "zfs"
    zfs.raid = "$ZFS_RAID"
    disk_list = $disk_list

EOF
    echo -e "${CLR_GREEN}Auto-installation configuration created.${CLR_RESET}"
}

# Function to create auto-install ISO
create_autoinstall_iso() {
    echo -e "${CLR_BLUE}Creating auto-installation ISO...${CLR_RESET}"
    
    proxmox-auto-install-assistant prepare-iso pve.iso \
        --fetch-from iso \
        --answer-file answer.toml \
        --output pve-autoinstall.iso
    
    echo -e "${CLR_GREEN}Auto-installation ISO created.${CLR_RESET}"
}

# Function to check UEFI support
is_uefi_mode() {
    [ -d /sys/firmware/efi ]
}

# Function to install Proxmox via QEMU
install_proxmox() {
    echo -e "${CLR_BLUE}Starting Proxmox VE installation...${CLR_RESET}"
    echo -e "${CLR_YELLOW}This process will take 5-10 minutes. Please wait...${CLR_RESET}"
    
    # Prepare UEFI options
    if is_uefi_mode; then
        UEFI_OPTS="-bios /usr/share/ovmf/OVMF.fd"
        echo -e "${CLR_GREEN}UEFI mode detected.${CLR_RESET}"
    else
        UEFI_OPTS=""
        echo -e "${CLR_YELLOW}Legacy BIOS mode.${CLR_RESET}"
    fi
    
    # Build QEMU drive options for selected drives
    local drive_opts=""
    local virt_disk_idx=97  # ASCII 'a'
    for drive in "${SELECTED_DRIVES[@]}"; do
        local virt_disk
        virt_disk="vd$(printf "\\$(printf '%03o' "$virt_disk_idx")")"
        drive_opts="$drive_opts -drive file=$drive,format=raw,media=disk,if=virtio"
        ((virt_disk_idx++))
    done
    
    # Run QEMU installation
    qemu-system-x86_64 \
        -enable-kvm $UEFI_OPTS \
        -cpu host -smp 4 -m 4096 \
        -boot d -cdrom ./pve-autoinstall.iso \
        $drive_opts \
        -no-reboot -display none > /dev/null 2>&1
    
    echo -e "${CLR_GREEN}Proxmox VE installation completed.${CLR_RESET}"
}

# Function to boot installed Proxmox with SSH forwarding
boot_with_ssh() {
    echo -e "${CLR_BLUE}Booting installed Proxmox with SSH access...${CLR_RESET}"
    
    # Prepare UEFI options
    if is_uefi_mode; then
        UEFI_OPTS="-bios /usr/share/ovmf/OVMF.fd"
    else
        UEFI_OPTS=""
    fi
    
    # Build QEMU drive options
    local drive_opts=""
    local virt_disk_idx=97  # ASCII 'a'
    for drive in "${SELECTED_DRIVES[@]}"; do
        local virt_disk
        virt_disk="vd$(printf "\\$(printf '%03o' "$virt_disk_idx")")"
        drive_opts="$drive_opts -drive file=$drive,format=raw,media=disk,if=virtio"
        ((virt_disk_idx++))
    done
    
    # Start QEMU in background with SSH port forwarding
    nohup qemu-system-x86_64 -enable-kvm $UEFI_OPTS \
        -cpu host -device e1000,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::5555-:22 \
        -smp 4 -m 4096 \
        $drive_opts \
        > qemu_output.log 2>&1 &
    
    QEMU_PID=$!
    echo -e "${CLR_GREEN}QEMU started with PID: $QEMU_PID${CLR_RESET}"
    
    # Wait for SSH to become available
    echo -e "${CLR_YELLOW}Waiting for SSH to become available...${CLR_RESET}"
    for i in {1..60}; do
        if nc -z localhost 5555 2>/dev/null; then
            echo -e "${CLR_GREEN}SSH is now available on port 5555.${CLR_RESET}"
            return 0
        fi
        echo -n "."
        sleep 5
    done
    
    echo -e "${CLR_RED}SSH did not become available within 5 minutes.${CLR_RESET}"
    return 1
}

# Function to create network configuration templates
create_network_templates() {
    echo -e "${CLR_BLUE}Creating network configuration templates...${CLR_RESET}"
    
    mkdir -p template_files
    
    # Create routed network interfaces configuration (recommended for Hetzner)
    cat > template_files/interfaces <<EOF
# Hetzner Proxmox VE - Routed Network Configuration
# This is the RECOMMENDED setup for Hetzner dedicated servers
# Generated automatically by install script

source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# Physical interface - routed setup with point-to-point
auto $INTERFACE_NAME
iface $INTERFACE_NAME inet static
    address $MAIN_IPV4/32
    pointopoint $MAIN_IPV4_GW
    gateway $MAIN_IPV4_GW

EOF

    # Add IPv6 configuration if available
    if [ -n "$IPV6_CIDR" ]; then
        cat >> template_files/interfaces <<EOF
# IPv6 for main interface
iface $INTERFACE_NAME inet6 static
    address $MAIN_IPV6/128
    gateway fe80::1

EOF
    fi
    
    # Add bridge configuration for routed setup
    cat >> template_files/interfaces <<EOF
# Main bridge - routed setup for additional IPs
auto vmbr0
iface vmbr0 inet static
    address $MAIN_IPV4/32
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-maxwait 0
    # Add routes for additional IPs:
    # up ip route add ADDITIONAL_IP/32 dev vmbr0

EOF

    # Add IPv6 bridge if available
    if [ -n "$BRIDGE_IPV6" ]; then
        cat >> template_files/interfaces <<EOF
# IPv6 for bridge
iface vmbr0 inet6 static
    address $BRIDGE_IPV6

EOF
    fi
    
    # Add private subnet bridge
    cat >> template_files/interfaces <<EOF
# Private subnet bridge for internal VMs
auto vmbr1
iface vmbr1 inet static
    address $PRIVATE_IP_CIDR
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '$PRIVATE_SUBNET' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '$PRIVATE_SUBNET' -o vmbr0 -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1

EOF

    # Create hosts file
    cat > template_files/hosts <<EOF
127.0.0.1 localhost.localdomain localhost
$MAIN_IPV4 $FQDN $HOSTNAME

# IPv6
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
EOF

    # Add IPv6 host entry if available
    if [ -n "$MAIN_IPV6" ]; then
        echo "$MAIN_IPV6 $FQDN $HOSTNAME" >> template_files/hosts
    fi
    
    # Create sysctl configuration for IP forwarding
    cat > template_files/99-proxmox.conf <<EOF
# Enable IP forwarding for routed setup
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# Optimize network performance
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr

# Security settings
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
EOF

    # Create APT sources.list
    cat > template_files/sources.list <<EOF
# Debian Bookworm sources
deb http://ftp.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://ftp.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware

# Proxmox VE repository
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF

    echo -e "${CLR_GREEN}Network configuration templates created.${CLR_RESET}"
}

# Function to configure the installed system
configure_system() {
    echo -e "${CLR_BLUE}Configuring installed Proxmox system...${CLR_RESET}"
    
    # Remove known hosts entry to avoid SSH conflicts
    ssh-keygen -f "/root/.ssh/known_hosts" -R "[localhost]:5555" 2>/dev/null || true
    
    # Copy configuration files
    echo -e "${CLR_YELLOW}Copying configuration files...${CLR_RESET}"
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/hosts root@localhost:/etc/hosts
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/interfaces root@localhost:/etc/network/interfaces
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/99-proxmox.conf root@localhost:/etc/sysctl.d/99-proxmox.conf
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/sources.list root@localhost:/etc/apt/sources.list
    
    # Apply system configuration
    echo -e "${CLR_YELLOW}Applying system configuration...${CLR_RESET}"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "sed -i 's/^\([^#].*\)/# \1/g' /etc/apt/sources.list.d/pve-enterprise.list"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "sed -i 's/^\([^#].*\)/# \1/g' /etc/apt/sources.list.d/ceph.list"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "echo -e 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 1.0.0.1' > /etc/resolv.conf"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "echo $HOSTNAME > /etc/hostname"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "systemctl disable --now rpcbind rpcbind.socket"
    
    # Install essential packages
    echo -e "${CLR_YELLOW}Installing essential packages...${CLR_RESET}"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "apt update"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "apt install -y libguestfs-tools unzip iptables-persistent"
    
    # Power off the VM
    echo -e "${CLR_YELLOW}Powering off the installation VM...${CLR_RESET}"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost 'poweroff' || true
    
    # Wait for QEMU to exit
    echo -e "${CLR_YELLOW}Waiting for installation VM to stop...${CLR_RESET}"
    wait $QEMU_PID || true
    echo -e "${CLR_GREEN}Installation VM has stopped.${CLR_RESET}"
}

# Function to finalize installation
finalize_installation() {
    echo -e "${CLR_GREEN}=== Installation Complete! ===${CLR_RESET}"
    echo ""
    echo -e "${CLR_YELLOW}Installation Summary:${CLR_RESET}"
    echo "• Selected drives: ${SELECTED_DRIVES[*]}"
    echo "• ZFS RAID level: $ZFS_RAID"
    echo "• Network interface: $INTERFACE_NAME"
    echo "• Main IP: $MAIN_IPV4"
    echo "• Hostname: $HOSTNAME ($FQDN)"
    echo "• Private subnet: $PRIVATE_SUBNET"
    echo ""
    echo -e "${CLR_CYAN}Next Steps:${CLR_RESET}"
    echo "1. Reboot your server to boot into the new Proxmox installation"
    echo "2. Access the web interface at: https://$MAIN_IPV4:8006"
    echo "3. Login with username 'root' and your configured password"
    echo ""
    echo -e "${CLR_YELLOW}Network Configuration:${CLR_RESET}"
    echo "• The system is configured with Hetzner's routed network topology"
    echo "• Additional IPs can be routed through vmbr0"
    echo "• VMs can use the private subnet $PRIVATE_SUBNET"
    echo "• IP forwarding is enabled for proper routing"
    echo ""
    
    read -p "Reboot now? (y/N): " reboot_choice
    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        echo -e "${CLR_GREEN}Rebooting...${CLR_RESET}"
        reboot
    else
        echo -e "${CLR_YELLOW}Remember to reboot manually when ready.${CLR_RESET}"
    fi
}

# Main execution flow
main() {
    detect_drives
    select_drives
    select_raid_level
    get_network_config
    prepare_packages
    get_latest_proxmox_iso
    create_answer_file
    create_autoinstall_iso
    install_proxmox
    
    echo -e "${CLR_YELLOW}Installation phase complete. Starting configuration...${CLR_RESET}"
    
    boot_with_ssh || {
        echo -e "${CLR_RED}Failed to boot with SSH. Please check the installation manually.${CLR_RESET}"
        exit 1
    }
    
    create_network_templates
    configure_system
    finalize_installation
}

# Run the main function
main "$@"
