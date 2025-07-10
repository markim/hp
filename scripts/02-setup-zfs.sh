#!/bin/bash

# ZFS Setup Script for Hetzner Proxmox Installation
# This script configures ZFS pools with automatic mirroring

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/server-config.conf
source "${SCRIPT_DIR}/config/server-config.conf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a /tmp/proxmox-install.log
}

error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    log "ERROR: $1"
    exit 1
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
    log "SUCCESS: $1"
}

info() {
    echo -e "${BLUE}ℹ $1${NC}"
    log "INFO: $1"
}

warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
    log "WARNING: $1"
}

# Get drive size in bytes
get_drive_size() {
    local drive="$1"
    lsblk -bnd -o SIZE "$drive" | tr -d ' '
}

# Get drive size in GB for display
get_drive_size_gb() {
    local drive="$1"
    local size_bytes
    size_bytes=$(get_drive_size "$drive")
    echo $((size_bytes / 1024 / 1024 / 1024))
}

# Analyze drives and group by size
analyze_drives() {
    info "Analyzing drives for ZFS configuration..."
    
    declare -A drive_groups
    local drives=()
    
    # Get all available drives
    while IFS= read -r drive; do
        if [[ " ${EXCLUDE_DRIVES[*]} " =~ ${drive} ]]; then
            continue
        fi
        drives+=("$drive")
    done < <(lsblk -nd -o NAME | grep -E '^(sd|nvme|vd)' | sed 's/^/\/dev\//')
    
    if [[ ${#drives[@]} -eq 0 ]]; then
        error_exit "No suitable drives found for ZFS setup"
    fi
    
    # Group drives by size
    for drive in "${drives[@]}"; do
        local size_gb
        size_gb=$(get_drive_size_gb "$drive")
        
        if [[ -z "${drive_groups[$size_gb]:-}" ]]; then
            drive_groups[$size_gb]="$drive"
        else
            drive_groups[$size_gb]="${drive_groups[$size_gb]} $drive"
        fi
    done
    
    # Display drive groups
    echo "=== Drive Groups by Size ==="
    for size in "${!drive_groups[@]}"; do
        local group_drives=(${drive_groups[$size]})
        echo "Size: ${size}GB - Drives: ${group_drives[*]} (${#group_drives[@]} drives)"
        
        if [[ ${#group_drives[@]} -eq 2 && "$AUTO_MIRROR" == "yes" && $size -ge $MIN_MIRROR_SIZE ]]; then
            echo "  → Will add ZFS mirror vdev to rpool"
        elif [[ ${#group_drives[@]} -gt 2 && "$AUTO_MIRROR" == "yes" && $size -ge $MIN_MIRROR_SIZE ]]; then
            echo "  → Will add multiple ZFS mirror vdevs to rpool (pairs)"
        else
            echo "  → Will add individual vdevs to rpool"
        fi
    done
    echo
    
    # Store for later use
    printf '%s\n' "${!drive_groups[@]}" > /tmp/drive_sizes.txt
    for size in "${!drive_groups[@]}"; do
        echo "${drive_groups[$size]}" > "/tmp/drives_${size}gb.txt"
    done
    
    success "Drive analysis completed"
}

# Wipe a drive completely
wipe_drive() {
    local drive="$1"
    info "Wiping drive $drive..."
    
    # Unmount any mounted filesystems
    umount "${drive}"* 2>/dev/null || true
    
    # Stop any LVM/mdadm
    vgchange -an 2>/dev/null || true
    mdadm --stop --scan 2>/dev/null || true
    
    # Clear ZFS labels first
    zpool labelclear "$drive" 2>/dev/null || true
    
    # Wipe filesystem signatures
    wipefs -a "$drive" 2>/dev/null || true
    
    # Zero out the beginning and end of the drive
    dd if=/dev/zero of="$drive" bs=1M count=100 2>/dev/null || true
    dd if=/dev/zero of="$drive" bs=1M seek=$(($(get_drive_size "$drive") / 1024 / 1024 - 100)) count=100 2>/dev/null || true
    
    # Clear partition table
    sgdisk --zap-all "$drive" 2>/dev/null || true
    
    # Clear any remaining ZFS labels again
    zpool labelclear "$drive" 2>/dev/null || true
    
    success "Drive $drive wiped"
}

# Create ZFS pool
create_zfs_pool() {
    local pool_name="$1"
    local pool_type="$2"
    shift 2
    local drives=("$@")
    
    info "Creating ZFS pool '$pool_name' with type '$pool_type'..."
    
    # Check if pool already exists and destroy it
    if zpool list "$pool_name" >/dev/null 2>&1; then
        warning "Pool '$pool_name' already exists"
        if [[ "${FORCE_INSTALL:-no}" == "yes" ]] || [[ "$WIPE_DRIVES" == "yes" ]]; then
            info "Destroying existing pool '$pool_name'..."
            if ! force_unmount_and_export_pool "$pool_name"; then
                # If export failed, try force destroy
                zpool destroy -f "$pool_name" || error_exit "Failed to destroy existing pool $pool_name"
            fi
            success "Existing pool '$pool_name' destroyed"
        else
            read -p "Pool '$pool_name' exists. Destroy it? (type 'yes' to confirm): " confirm
            if [[ "$confirm" == "yes" ]]; then
                info "Destroying existing pool '$pool_name'..."
                if ! force_unmount_and_export_pool "$pool_name"; then
                    # If export failed, try force destroy
                    zpool destroy -f "$pool_name" || error_exit "Failed to destroy existing pool $pool_name"
                fi
                success "Existing pool '$pool_name' destroyed"
            else
                error_exit "Cannot proceed with existing pool '$pool_name'. Installation cancelled."
            fi
        fi
    fi
    
    # Build zpool create command with only valid pool properties
    local cmd="zpool create"
    
    # Add only valid pool options (not dataset options)
    cmd="$cmd -o ashift=12"
    
    # Add pool name
    cmd="$cmd $pool_name"
    
    # Add vdev configuration
    if [[ "$pool_type" == "mirror" ]]; then
        cmd="$cmd mirror"
    fi
    
    # Add drives
    for drive in "${drives[@]}"; do
        cmd="$cmd $drive"
    done
    
    info "Executing: $cmd"
    eval "$cmd" || error_exit "Failed to create ZFS pool $pool_name"
    
    # Set dataset properties after pool creation
    info "Setting dataset properties on pool '$pool_name'..."
    zfs set compression="$ZFS_COMPRESSION" "$pool_name" || warning "Failed to set compression on $pool_name"
    zfs set atime="$ZFS_ATIME" "$pool_name" || warning "Failed to set atime on $pool_name"
    zfs set relatime="$ZFS_RELATIME" "$pool_name" || warning "Failed to set relatime on $pool_name"
    
    success "ZFS pool '$pool_name' created successfully"
}

# Add vdev to existing ZFS pool
add_vdev_to_pool() {
    local pool_name="$1"
    local pool_type="$2"
    shift 2
    local drives=("$@")
    
    info "Adding $pool_type vdev to existing pool '$pool_name'..."
    
    # Check if pool exists
    if ! zpool list "$pool_name" >/dev/null 2>&1; then
        error_exit "Pool '$pool_name' does not exist"
    fi
    
    # Build zpool add command
    local cmd="zpool add $pool_name"
    
    # Add vdev configuration
    if [[ "$pool_type" == "mirror" ]]; then
        cmd="$cmd mirror"
    fi
    
    # Add drives
    for drive in "${drives[@]}"; do
        cmd="$cmd $drive"
    done
    
    info "Executing: $cmd"
    eval "$cmd" || error_exit "Failed to add vdev to ZFS pool $pool_name"
    
    success "Added $pool_type vdev to pool '$pool_name' successfully"
}

# Configure ZFS datasets
create_zfs_datasets() {
    local pool_name="$1"
    
    info "Creating ZFS datasets for pool '$pool_name'..."
    
    # Create root dataset with proper options
    local root_opts=""
    for option in "${ZFS_ROOT_OPTIONS[@]}"; do
        root_opts="$root_opts -o $option"
    done
    
    info "Creating ROOT dataset..."
    eval "zfs create $root_opts $pool_name/ROOT" || error_exit "Failed to create ROOT dataset"
    
    # Create system datasets
    info "Creating system datasets..."
    zfs create -o canmount=noauto -o mountpoint=/ "$pool_name/ROOT/pve-1" || error_exit "Failed to create pve-1 dataset"
    zfs create "$pool_name/data" || error_exit "Failed to create data dataset"
    zfs create "$pool_name/data/subvol-100-disk-0" || error_exit "Failed to create subvol dataset"
    
    # Apply dataset options to data datasets
    info "Applying dataset properties..."
    zfs set compression="$ZFS_COMPRESSION" "$pool_name/data" || warning "Failed to set compression on data"
    zfs set atime="$ZFS_ATIME" "$pool_name/data" || warning "Failed to set atime on data"
    zfs set relatime="$ZFS_RELATIME" "$pool_name/data" || warning "Failed to set relatime on data"
    
    success "ZFS datasets created for pool '$pool_name'"
}

# Check for existing ZFS pools and handle them
check_existing_pools() {
    info "Checking for existing ZFS pools..."
    
    local existing_pools
    existing_pools=$(zpool list -H -o name 2>/dev/null || true)
    
    if [[ -n "$existing_pools" ]]; then
        warning "Found existing ZFS pools: $existing_pools"
        
        if [[ "${FORCE_INSTALL:-no}" == "yes" ]] || [[ "$WIPE_DRIVES" == "yes" ]]; then
            info "Force install enabled - will destroy existing pools when creating new ones"
        else
            echo
            echo "The following ZFS pools exist and may conflict with installation:"
            zpool list
            echo
            read -p "Continue with installation? Existing pools will be destroyed as needed (type 'yes' to confirm): " confirm
            
            if [[ "$confirm" != "yes" ]]; then
                info "Installation cancelled by user"
                exit 0
            fi
        fi
    else
        info "No existing ZFS pools found"
    fi
}

# Force unmount all datasets and export pool
force_unmount_and_export_pool() {
    local pool_name="$1"
    
    info "Force unmounting all datasets for pool '$pool_name'..."
    
    # Get all mounted datasets for this pool
    local datasets
    datasets=$(zfs list -H -o name,mountpoint | grep "^$pool_name" | awk '{print $1}' || true)
    
    if [[ -n "$datasets" ]]; then
        # Unmount all datasets in reverse order (children first)
        echo "$datasets" | tac | while read -r dataset; do
            if [[ -n "$dataset" ]]; then
                info "Unmounting dataset: $dataset"
                zfs unmount -f "$dataset" 2>/dev/null || true
            fi
        done
    fi
    
    # Force unmount any remaining mountpoints
    local mountpoints
    mountpoints=$(mount | grep " on .* type zfs " | grep "$pool_name" | awk '{print $3}' || true)
    
    if [[ -n "$mountpoints" ]]; then
        echo "$mountpoints" | while read -r mountpoint; do
            if [[ -n "$mountpoint" ]]; then
                info "Force unmounting: $mountpoint"
                umount -f "$mountpoint" 2>/dev/null || true
                umount -l "$mountpoint" 2>/dev/null || true  # lazy unmount as last resort
            fi
        done
    fi
    
    # Try to export the pool first (cleaner than destroy)
    info "Attempting to export pool '$pool_name'..."
    if zpool export "$pool_name" 2>/dev/null; then
        success "Pool '$pool_name' exported successfully"
        return 0
    else
        warning "Could not export pool '$pool_name', will attempt force destroy"
        return 1
    fi
}

# Setup ZFS pools based on drive analysis
setup_zfs_pools() {
    info "Setting up ZFS pools..."
    
    local pool_counter=1
    local rpool_created=false
    
    while IFS= read -r size; do
        local drives
        read -ra drives < "/tmp/drives_${size}gb.txt"
        local num_drives=${#drives[@]}
        
        info "Processing ${num_drives} drive(s) of size ${size}GB: ${drives[*]}"
        
        # Create pools based on number of drives and configuration
        if [[ $num_drives -eq 1 ]]; then
            # Single drive
            if [[ "$rpool_created" == "false" ]]; then
                # Wipe drive before creating initial rpool
                if [[ "$WIPE_DRIVES" == "yes" ]]; then
                    wipe_drive "${drives[0]}"
                fi
                # Create initial rpool
                create_zfs_pool "$ZFS_ROOT_POOL_NAME" "single" "${drives[0]}"
                create_zfs_datasets "$ZFS_ROOT_POOL_NAME"
                rpool_created=true
            else
                # Wipe drive before adding to existing rpool
                if [[ "$WIPE_DRIVES" == "yes" ]]; then
                    wipe_drive "${drives[0]}"
                fi
                # Add single drive to existing rpool
                add_vdev_to_pool "$ZFS_ROOT_POOL_NAME" "single" "${drives[0]}"
            fi
            
        elif [[ $num_drives -eq 2 && "$AUTO_MIRROR" == "yes" && $size -ge $MIN_MIRROR_SIZE ]]; then
            # Two drives - create/add mirror
            if [[ "$rpool_created" == "false" ]]; then
                # Wipe drives before creating initial rpool
                if [[ "$WIPE_DRIVES" == "yes" ]]; then
                    for drive in "${drives[@]}"; do
                        wipe_drive "$drive"
                    done
                fi
                # Create initial rpool as mirror
                create_zfs_pool "$ZFS_ROOT_POOL_NAME" "mirror" "${drives[@]}"
                create_zfs_datasets "$ZFS_ROOT_POOL_NAME"
                rpool_created=true
            else
                # Wipe drives before adding to existing rpool
                if [[ "$WIPE_DRIVES" == "yes" ]]; then
                    for drive in "${drives[@]}"; do
                        wipe_drive "$drive"
                    done
                fi
                # Add mirror vdev to existing rpool
                add_vdev_to_pool "$ZFS_ROOT_POOL_NAME" "mirror" "${drives[@]}"
            fi
            
        elif [[ $num_drives -gt 2 && "$AUTO_MIRROR" == "yes" && $size -ge $MIN_MIRROR_SIZE ]]; then
            # Multiple drives - create mirrors in pairs
            local i=0
            while [[ $i -lt $num_drives ]]; do
                if [[ $((i + 1)) -lt $num_drives ]]; then
                    # Create/add mirror with pair
                    if [[ "$rpool_created" == "false" ]]; then
                        # Wipe drives before creating initial rpool
                        if [[ "$WIPE_DRIVES" == "yes" ]]; then
                            wipe_drive "${drives[$i]}"
                            wipe_drive "${drives[$((i + 1))]}"
                        fi
                        # Create initial rpool as mirror
                        create_zfs_pool "$ZFS_ROOT_POOL_NAME" "mirror" "${drives[$i]}" "${drives[$((i + 1))]}"
                        create_zfs_datasets "$ZFS_ROOT_POOL_NAME"
                        rpool_created=true
                    else
                        # Wipe drives before adding to existing rpool
                        if [[ "$WIPE_DRIVES" == "yes" ]]; then
                            wipe_drive "${drives[$i]}"
                            wipe_drive "${drives[$((i + 1))]}"
                        fi
                        # Add mirror vdev to existing rpool
                        add_vdev_to_pool "$ZFS_ROOT_POOL_NAME" "mirror" "${drives[$i]}" "${drives[$((i + 1))]}"
                    fi
                    i=$((i + 2))
                else
                    # Odd drive - add as single vdev
                    if [[ "$rpool_created" == "false" ]]; then
                        # Wipe drive before creating initial rpool
                        if [[ "$WIPE_DRIVES" == "yes" ]]; then
                            wipe_drive "${drives[$i]}"
                        fi
                        # Create initial rpool
                        create_zfs_pool "$ZFS_ROOT_POOL_NAME" "single" "${drives[$i]}"
                        create_zfs_datasets "$ZFS_ROOT_POOL_NAME"
                        rpool_created=true
                    else
                        # Wipe drive before adding to existing rpool
                        if [[ "$WIPE_DRIVES" == "yes" ]]; then
                            wipe_drive "${drives[$i]}"
                        fi
                        # Add single drive to existing rpool
                        add_vdev_to_pool "$ZFS_ROOT_POOL_NAME" "single" "${drives[$i]}"
                    fi
                    i=$((i + 1))
                fi
            done
            
        else
            # Create individual vdevs for each drive
            for drive in "${drives[@]}"; do
                if [[ "$rpool_created" == "false" ]]; then
                    # Wipe drive before creating initial rpool
                    if [[ "$WIPE_DRIVES" == "yes" ]]; then
                        wipe_drive "$drive"
                    fi
                    # Create initial rpool
                    create_zfs_pool "$ZFS_ROOT_POOL_NAME" "single" "$drive"
                    create_zfs_datasets "$ZFS_ROOT_POOL_NAME"
                    rpool_created=true
                else
                    # Wipe drive before adding to existing rpool
                    if [[ "$WIPE_DRIVES" == "yes" ]]; then
                        wipe_drive "$drive"
                    fi
                    # Add single drive to existing rpool
                    add_vdev_to_pool "$ZFS_ROOT_POOL_NAME" "single" "$drive"
                fi
            done
        fi
        
        pool_counter=$((pool_counter + 1))
        
    done < /tmp/drive_sizes.txt
    
    # Log all drives used in ZFS setup for later reference
    info "Logging drives used in ZFS setup..."
    {
        echo "# Drives used in ZFS setup - $(date)"
        while IFS= read -r size; do
            local drives
            read -ra drives < "/tmp/drives_${size}gb.txt"
            printf '%s\n' "${drives[@]}"
        done < /tmp/drive_sizes.txt
    } > /tmp/drives_used_for_zfs.txt
    
    success "All ZFS vdevs configured in rpool"
}

# Display ZFS configuration
display_zfs_status() {
    info "Final ZFS configuration:"
    echo
    echo "=== ZFS Pools ==="
    zpool list
    echo
    echo "=== ZFS Pool Status ==="
    zpool status
    echo
    echo "=== ZFS Datasets ==="
    zfs list
    echo
}

# Main function
main() {
    info "Starting ZFS setup..."
    
    check_existing_pools
    analyze_drives
    
    # Confirmation prompt
    echo -e "${YELLOW}WARNING: This will destroy all data on the selected drives!${NC}"
    read -p "Continue with ZFS setup? (type 'yes' to confirm): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        info "ZFS setup cancelled by user"
        exit 0
    fi
    
    setup_zfs_pools
    display_zfs_status
    
    success "ZFS setup completed successfully!"
    echo
    echo "Next step: Run ./scripts/03-install-proxmox.sh"
}

main "$@"
