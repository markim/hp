#!/usr/bin/bash
# Remote execution script for Proxmox VE installation on Hetzner

set -e

# Define colors for output
CLR_RED="\033[1;31m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_CYAN="\033[1;36m"
CLR_RESET="\033[m"

# Configuration
SCRIPT_URL="https://raw.githubusercontent.com/markim/hp/main/install.sh"

show_usage() {
    echo -e "${CLR_CYAN}Enhanced Proxmox VE Remote Installation${CLR_RESET}"
    echo ""
    echo "Usage: $0 [OPTIONS] <server_address>"
    echo ""
    echo "Options:"
    echo "  -u, --user USER       SSH username (default: root)"
    echo "  -p, --port PORT       SSH port (default: 22)"
    echo "  -k, --key KEYFILE     SSH private key file"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 proxmox.80px.com"
    echo "  $0 -u root -p 22 198.51.100.10"
    echo "  $0 --key ~/.ssh/hetzner_key proxmox.example.com"
    echo ""
    echo "Features:"
    echo "  • Drive selection for ZFS RAID configuration"
    echo "  • Routed network topology (Hetzner recommended)"
    echo "  • Automated Proxmox VE installation"
    echo "  • IPv4 and IPv6 support"
    echo "  • Post-installation configuration"
    echo ""
}

# Default values
SSH_USER="root"
SSH_PORT="22"
SSH_KEY=""
SERVER=""

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--user)
                SSH_USER="$2"
                shift 2
                ;;
            -p|--port)
                SSH_PORT="$2"
                shift 2
                ;;
            -k|--key)
                SSH_KEY="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                echo -e "${CLR_RED}Unknown option: $1${CLR_RESET}"
                show_usage
                exit 1
                ;;
            *)
                if [[ -z "$SERVER" ]]; then
                    SERVER="$1"
                else
                    echo -e "${CLR_RED}Multiple servers specified. Only one server is allowed.${CLR_RESET}"
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$SERVER" ]]; then
        echo -e "${CLR_RED}Error: Server address is required${CLR_RESET}"
        show_usage
        exit 1
    fi
}

# Build SSH command with options
build_ssh_cmd() {
    local ssh_cmd="ssh"
    
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd="$ssh_cmd -i $SSH_KEY"
    fi
    
    ssh_cmd="$ssh_cmd -p $SSH_PORT"
    ssh_cmd="$ssh_cmd -o StrictHostKeyChecking=no"
    ssh_cmd="$ssh_cmd -o ConnectTimeout=10"
    
    echo "$ssh_cmd"
}

# Test SSH connectivity
test_connection() {
    echo -e "${CLR_BLUE}Testing SSH connection to $SERVER...${CLR_RESET}"
    
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    if $ssh_cmd "$SSH_USER@$SERVER" "echo 'Connection successful'" >/dev/null 2>&1; then
        echo -e "${CLR_GREEN}SSH connection successful${CLR_RESET}"
        return 0
    else
        echo -e "${CLR_RED}SSH connection failed${CLR_RESET}"
        echo "Please check:"
        echo "• Server address: $SERVER"
        echo "• SSH port: $SSH_PORT"
        echo "• SSH user: $SSH_USER"
        if [[ -n "$SSH_KEY" ]]; then
            echo "• SSH key: $SSH_KEY"
        fi
        return 1
    fi
}

# Check if server is in rescue mode
check_rescue_mode() {
    echo -e "${CLR_BLUE}Checking if server is in rescue mode...${CLR_RESET}"
    
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    local rescue_check
    rescue_check=$($ssh_cmd "$SSH_USER@$SERVER" "cat /etc/hostname 2>/dev/null || echo 'unknown'")
    
    if [[ "$rescue_check" == "rescue" ]] || [[ "$rescue_check" =~ rescue ]]; then
        echo -e "${CLR_GREEN}Server is in rescue mode${CLR_RESET}"
        return 0
    else
        echo -e "${CLR_YELLOW}Warning: Server may not be in rescue mode${CLR_RESET}"
        echo "Current hostname: $rescue_check"
        echo ""
        read -p "Continue anyway? (y/N): " continue_choice
        if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
            echo "Aborting installation."
            echo ""
            echo "To activate rescue mode:"
            echo "1. Login to Hetzner Robot Panel"
            echo "2. Go to your server's Rescue tab"
            echo "3. Select Linux rescue system"
            echo "4. Reset your server"
            exit 1
        fi
    fi
}

# Download and execute installation script
execute_installation() {
    echo -e "${CLR_BLUE}Starting remote Proxmox VE installation...${CLR_RESET}"
    echo -e "${CLR_YELLOW}This will run the installation script on $SERVER${CLR_RESET}"
    echo ""
    
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    # Create the command to download and execute the script
    local install_cmd="bash <(curl -sSL $SCRIPT_URL)"
    
    echo -e "${CLR_CYAN}Executing installation command:${CLR_RESET}"
    echo "$install_cmd"
    echo ""
    
    # Execute the installation script remotely
    if $ssh_cmd "$SSH_USER@$SERVER" "$install_cmd"; then
        echo ""
        echo -e "${CLR_GREEN}=== Remote Installation Completed Successfully ===${CLR_RESET}"
        echo ""
        echo -e "${CLR_CYAN}Next Steps:${CLR_RESET}"
        echo "1. The server should now reboot automatically"
        echo "2. Wait a few minutes for the system to come online"
        echo "3. Access Proxmox web interface at: https://$SERVER:8006"
        echo "4. Login with username 'root' and the password you set"
        echo ""
        echo -e "${CLR_YELLOW}If the server doesn't reboot automatically:${CLR_RESET}"
        echo "Run: ssh $SSH_USER@$SERVER reboot"
        echo ""
    else
        echo ""
        echo -e "${CLR_RED}Installation failed or was interrupted${CLR_RESET}"
        echo "Check the output above for error details"
        exit 1
    fi
}

# Interactive mode for easier configuration
interactive_mode() {
    echo -e "${CLR_CYAN}=== Interactive Remote Installation ===${CLR_RESET}"
    echo ""
    
    if [[ -z "$SERVER" ]]; then
        read -p "Enter server address (IP or hostname): " SERVER
    fi
    
    read -e -p "SSH username [$SSH_USER]: " input_user
    if [[ -n "$input_user" ]]; then
        SSH_USER="$input_user"
    fi
    
    read -e -p "SSH port [$SSH_PORT]: " input_port
    if [[ -n "$input_port" ]]; then
        SSH_PORT="$input_port"
    fi
    
    read -e -p "SSH private key file (optional): " input_key
    if [[ -n "$input_key" ]]; then
        SSH_KEY="$input_key"
    fi
    
    echo ""
    echo -e "${CLR_YELLOW}Configuration Summary:${CLR_RESET}"
    echo "Server: $SERVER"
    echo "User: $SSH_USER"
    echo "Port: $SSH_PORT"
    if [[ -n "$SSH_KEY" ]]; then
        echo "Key: $SSH_KEY"
    fi
    echo ""
    
    read -p "Proceed with installation? (y/N): " proceed
    if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
}

# Show system requirements
show_requirements() {
    echo -e "${CLR_BLUE}System Requirements:${CLR_RESET}"
    echo "• Hetzner dedicated server"
    echo "• Server must be in rescue mode"
    echo "• At least 2 drives for ZFS RAID"
    echo "• Minimum 8GB RAM recommended"
    echo "• SSH access to the server"
    echo ""
}

# Main execution
main() {
    clear
    echo -e "${CLR_GREEN}=== Enhanced Proxmox VE Remote Installation ===${CLR_RESET}"
    echo -e "${CLR_CYAN}Drive Selection • Routed Network • Automated Setup${CLR_RESET}"
    echo ""
    
    if [[ $# -eq 0 ]]; then
        show_requirements
        interactive_mode
    else
        parse_args "$@"
    fi
    
    echo -e "${CLR_BLUE}Starting remote installation process...${CLR_RESET}"
    echo ""
    
    test_connection || exit 1
    check_rescue_mode
    execute_installation
}

# Handle script interruption
trap 'echo -e "\n${CLR_YELLOW}Installation interrupted${CLR_RESET}"; exit 1' INT TERM

# Run main function
main "$@"
