#!/bin/bash

# Emergency Bootloader Fix Script
# This script attempts to fix the bootloader installation before reboot

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a /tmp/bootloader-fix.log
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

# Check if we're running as root
if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root"
fi

info "Starting emergency bootloader fix..."

# Function to check ZFS availability
check_zfs_availability() {
    info "Checking ZFS availability..."
    
    # Check if ZFS module is loaded
    if ! lsmod | grep -q "^zfs "; then
        info "ZFS module not loaded, attempting to load..."
        if modprobe zfs 2>/dev/null; then
            success "ZFS module loaded successfully"
            sleep 2  # Give module time to initialize
        else
            warning "Could not load ZFS module from packages"
            
            # Try to use rescue system ZFS if available
            if [[ -d /lib/modules/$(uname -r)/kernel/zfs ]]; then
                info "ZFS modules found in rescue system, trying alternative load..."
                for module in spl zfs; do
                    insmod "/lib/modules/$(uname -r)/kernel/zfs/$module.ko" 2>/dev/null || true
                done
                if lsmod | grep -q "^zfs "; then
                    success "ZFS loaded from rescue system modules"
                else
                    warning "Could not load ZFS from rescue system"
                fi
            fi
        fi
    else
        success "ZFS module already loaded"
    fi
    
    # Verify ZFS functionality
    if command -v zpool >/dev/null 2>&1 && command -v zfs >/dev/null 2>&1; then
        success "ZFS commands available"
        return 0
    else
        error_exit "ZFS commands not available - cannot proceed"
    fi
}

# Run ZFS availability check
check_zfs_availability

# Configuration (adjust these if different)
MOUNT_POINT="/mnt/proxmox"
ZFS_POOL_NAME="rpool"
ZFS_ROOT_DATASET="$ZFS_POOL_NAME/ROOT/pve-1"

# Step 1: Check if installation is mounted
info "Checking installation mount..."
if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    info "Mounting ZFS root filesystem..."
    mkdir -p "$MOUNT_POINT"
    
    # Ensure ZFS module is loaded
    if ! lsmod | grep -q "^zfs "; then
        info "Loading ZFS module..."
        modprobe zfs 2>/dev/null || warning "Could not load ZFS module"
        sleep 2  # Give module time to initialize
    fi
    
    # Try to import the pool if not already imported
    if ! zpool list "$ZFS_POOL_NAME" >/dev/null 2>&1; then
        info "ZFS pool not imported, attempting import..."
        if zpool import -f "$ZFS_POOL_NAME" 2>/dev/null; then
            success "ZFS pool imported successfully"
        else
            warning "Could not import ZFS pool, trying directory scan..."
            if zpool import -d /dev -f "$ZFS_POOL_NAME" 2>/dev/null; then
                success "ZFS pool imported with directory scan"
            else
                error_exit "Cannot import ZFS pool $ZFS_POOL_NAME"
            fi
        fi
    fi
    
    # Try to mount the ZFS dataset
    if ! mount -t zfs "$ZFS_ROOT_DATASET" "$MOUNT_POINT" 2>/dev/null; then
        # Try setting mountpoint and mounting
        info "Setting ZFS mountpoint and mounting..."
        zfs set mountpoint="$MOUNT_POINT" "$ZFS_ROOT_DATASET" 2>/dev/null || true
        if ! zfs mount "$ZFS_ROOT_DATASET" 2>/dev/null; then
            error_exit "Cannot mount ZFS root filesystem"
        fi
    fi
    success "ZFS root filesystem mounted"
else
    success "Installation already mounted"
fi

# Step 2: Setup chroot environment
info "Setting up chroot environment..."
mount --bind /dev "$MOUNT_POINT/dev" 2>/dev/null || true
mount --bind /proc "$MOUNT_POINT/proc" 2>/dev/null || true
mount --bind /sys "$MOUNT_POINT/sys" 2>/dev/null || true
cp /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf" 2>/dev/null || true

# Step 3: Find the actual physical drives (not partitions)
info "Detecting physical drives..."
DRIVES=""

# Method 1: Get drives from ZFS pool
if zpool status "$ZFS_POOL_NAME" >/tmp/pool_status.txt 2>/dev/null; then
    # Extract device names and convert to base drives
    POOL_DEVICES=$(grep -E '^\s+(/dev/|nvme|sd)' /tmp/pool_status.txt | awk '{print $1}' | grep -E '^(/dev/)?(nvme[0-9]+n[0-9]+|sd[a-z]+)' || echo "")
    
    for device in $POOL_DEVICES; do
        # Clean up device name
        device=$(echo "$device" | sed 's|^/dev/||')
        
        # Convert partition to base drive (e.g., nvme0n1p1 -> nvme0n1, sda1 -> sda)
        if [[ "$device" =~ ^nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
            # NVMe partition -> base drive
            base_drive=$(echo "$device" | sed 's/p[0-9]*$//')
        elif [[ "$device" =~ ^sd[a-z]+[0-9]+$ ]]; then
            # SATA partition -> base drive  
            base_drive=$(echo "$device" | sed 's/[0-9]*$//')
        elif [[ "$device" =~ ^(nvme[0-9]+n[0-9]+|sd[a-z]+)$ ]]; then
            # Already a base drive
            base_drive="$device"
        else
            warning "Unrecognized device format: $device"
            continue
        fi
        
        # Add /dev/ prefix and add to drives list if not already present
        full_path="/dev/$base_drive"
        if [[ -b "$full_path" ]] && [[ " $DRIVES " != *" $full_path "* ]]; then
            DRIVES="$DRIVES $full_path"
        fi
    done
fi

# Method 2: Fallback - get all NVMe drives
if [[ -z "$DRIVES" ]]; then
    warning "Could not detect drives from ZFS, using system detection..."
    DRIVES=$(lsblk -nd -o NAME,TYPE | grep disk | grep nvme | awk '{print "/dev/" $1}' | head -4 | tr '\n' ' ')
fi

# Clean up drives list
DRIVES=$(echo "$DRIVES" | tr ' ' '\n' | sort -u | tr '\n' ' ')

info "Detected drives: $DRIVES"

if [[ -z "$DRIVES" ]]; then
    error_exit "No drives detected for bootloader installation"
fi

# Step 4: Create a working GRUB configuration
info "Creating GRUB configuration..."

# Ensure GRUB directory exists
mkdir -p "$MOUNT_POINT/boot/grub"

# Create proper GRUB default configuration
cat > "$MOUNT_POINT/etc/default/grub" << EOF
# GRUB Configuration for ZFS Boot
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Proxmox VE"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="root=ZFS=$ZFS_ROOT_DATASET boot=zfs"
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=false
# Disable problematic filesystem detection for ZFS
GRUB_DISABLE_LINUX_UUID=true
GRUB_DISABLE_LINUX_PARTUUID=true
EOF

# Step 5: Fix the "unknown filesystem" issue
info "Fixing GRUB filesystem detection..."

# Create a bind mount of /boot to a location GRUB can understand
mkdir -p "$MOUNT_POINT/boot/grub"

# Find kernel and initrd files
KERNEL=""
KERNEL_VERSION=""
for kernel_file in "$MOUNT_POINT/boot/vmlinuz-"*; do
    if [[ -f "$kernel_file" ]]; then
        KERNEL="$kernel_file"
        KERNEL_VERSION=$(basename "$kernel_file" | sed 's/vmlinuz-//')
        break
    fi
done

if [[ -n "$KERNEL" ]]; then
    info "Found kernel: $KERNEL_VERSION"
    
    # Verify initrd exists
    INITRD_FILE="$MOUNT_POINT/boot/initrd.img-$KERNEL_VERSION"
    if [[ ! -f "$INITRD_FILE" ]]; then
        warning "Initrd not found for kernel $KERNEL_VERSION, looking for alternatives..."
        # Try to find any initrd file
        for initrd_file in "$MOUNT_POINT/boot/initrd.img-"*; do
            if [[ -f "$initrd_file" ]]; then
                INITRD_FILE="$initrd_file"
                warning "Using alternative initrd: $(basename "$INITRD_FILE")"
                break
            fi
        done
    fi
else
    error_exit "No kernel found in /boot"
fi

# Step 6: Create minimal GRUB configuration manually
info "Creating minimal GRUB configuration..."
cat > "$MOUNT_POINT/boot/grub/grub.cfg" << EOF
set timeout=5
set default=0

menuentry "Proxmox VE" {
    linux /boot/vmlinuz-$KERNEL_VERSION root=ZFS=$ZFS_ROOT_DATASET boot=zfs quiet
    initrd /boot/initrd.img-$KERNEL_VERSION
}

menuentry "Proxmox VE (single user)" {
    linux /boot/vmlinuz-$KERNEL_VERSION root=ZFS=$ZFS_ROOT_DATASET boot=zfs single
    initrd /boot/initrd.img-$KERNEL_VERSION
}
EOF

success "GRUB configuration created"

# Step 7: Install GRUB bootloader to MBR of each drive
info "Installing GRUB bootloader..."

# Detect firmware type
FIRMWARE_TYPE="legacy"
if [[ -d /sys/firmware/efi ]]; then
    FIRMWARE_TYPE="uefi"
    info "UEFI firmware detected"
else
    info "Legacy BIOS firmware detected"
fi

# Create a comprehensive script to run in chroot that handles different scenarios
cat > "$MOUNT_POINT/tmp/install-grub.sh" << 'GRUB_SCRIPT'
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

FIRMWARE_TYPE="$1"
shift
DRIVES="$@"

echo "Installing GRUB with firmware type: $FIRMWARE_TYPE"
echo "Target drives: $DRIVES"

# Function to run commands with timeout
run_with_timeout() {
    local cmd="$1"
    local timeout_duration=60
    echo "Running: $cmd"
    
    if timeout --kill-after=10s "$timeout_duration" bash -c "$cmd" 2>&1; then
        echo "✓ Success: $cmd"
        return 0
    else
        echo "⚠ Command failed or timed out: $cmd"
        return 1
    fi
}

# Update initramfs to include ZFS support
echo "Updating initramfs with ZFS support..."
if run_with_timeout "update-initramfs -u -k all"; then
    echo "✓ Initramfs updated successfully"
else
    echo "⚠ Warning: Initramfs update failed, trying single kernel..."
    if run_with_timeout "update-initramfs -u"; then
        echo "✓ Initramfs updated with fallback method"
    else
        echo "⚠ Warning: Initramfs update failed"
    fi
fi

# Try to update GRUB configuration
echo "Attempting to update GRUB configuration..."
if run_with_timeout "update-grub"; then
    echo "✓ GRUB configuration updated successfully"
elif run_with_timeout "grub-mkconfig -o /boot/grub/grub.cfg"; then
    echo "✓ GRUB configuration created via grub-mkconfig"
else
    echo "⚠ Standard GRUB update failed, manual configuration will be used"
fi

if [[ "$FIRMWARE_TYPE" == "uefi" ]]; then
    echo "Installing GRUB for UEFI boot..."
    
    # Ensure EFI directory exists
    mkdir -p /boot/efi
    
    # Try to mount EFI partition if not already mounted
    if ! mountpoint -q /boot/efi 2>/dev/null; then
        # Find EFI partition
        EFI_PARTITION=$(lsblk -no NAME,FSTYPE | grep vfat | head -1 | awk '{print "/dev/" $1}' || echo "")
        if [[ -n "$EFI_PARTITION" ]]; then
            echo "Mounting EFI partition: $EFI_PARTITION"
            mount "$EFI_PARTITION" /boot/efi 2>/dev/null || echo "⚠ Could not mount EFI partition"
        fi
    fi
    
    # Install GRUB for UEFI
    if run_with_timeout "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=proxmox --recheck"; then
        echo "✓ GRUB EFI installed successfully"
        
        # Create removable fallback
        if run_with_timeout "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=proxmox --removable"; then
            echo "✓ GRUB EFI fallback created"
        fi
        
        echo "✓ UEFI GRUB installation completed"
        exit 0
    else
        echo "⚠ Error: GRUB EFI installation failed"
        exit 1
    fi
else
    echo "Installing GRUB for Legacy BIOS boot..."
    failed_drives=0
    installed_drives=0

    for drive in $DRIVES; do
        # Clean up drive path and validate
        drive=$(echo "$drive" | xargs)
        if [[ -n "$drive" && -b "$drive" ]]; then
            echo "Installing GRUB to $drive..."
            
            # Method 1: Standard installation with ZFS modules
            if run_with_timeout "grub-install --target=i386-pc --boot-directory=/boot --force --modules='biosdisk part_msdos part_gpt zfs' $drive"; then
                echo "✓ GRUB installed successfully to $drive (with ZFS modules)"
                ((installed_drives++))
                continue
            fi
            
            # Method 2: Installation bypassing filesystem detection
            if run_with_timeout "grub-install --target=i386-pc --boot-directory=/boot --force --skip-fs-probe $drive"; then
                echo "✓ GRUB installed successfully to $drive (skip filesystem probe)"
                ((installed_drives++))
                continue
            fi
            
            # Method 3: Installation with floppy compatibility
            if run_with_timeout "grub-install --target=i386-pc --boot-directory=/boot --force --allow-floppy $drive"; then
                echo "✓ GRUB installed successfully to $drive (with floppy compatibility)"
                ((installed_drives++))
                continue
            fi
            
            # Method 4: Installation without floppy
            if run_with_timeout "grub-install --target=i386-pc --boot-directory=/boot --force --no-floppy $drive"; then
                echo "✓ GRUB installed successfully to $drive (no floppy)"
                ((installed_drives++))
                continue
            fi
            
            # Method 5: Basic installation without options
            if timeout 30 grub-install --target=i386-pc --force $drive 2>/dev/null; then
                echo "✓ GRUB installed successfully to $drive (basic method)"
                ((installed_drives++))
                continue
            fi
            
            echo "⚠ Failed to install GRUB to $drive"
            ((failed_drives++))
        else
            echo "⚠ Skipping invalid drive: '$drive'"
            ((failed_drives++))
        fi
    done

    echo "GRUB installation summary:"
    echo "- Successfully installed to $installed_drives drive(s)"
    echo "- Failed on $failed_drives drive(s)"

    if [[ $installed_drives -gt 0 ]]; then
        echo "✓ Legacy BIOS GRUB installation completed successfully"
        exit 0
    else
        echo "⚠ Error: GRUB installation failed on all drives"
        exit 1
    fi
fi
GRUB_SCRIPT

chmod +x "$MOUNT_POINT/tmp/install-grub.sh"

# Execute GRUB installation in chroot
if chroot "$MOUNT_POINT" /tmp/install-grub.sh "$FIRMWARE_TYPE" $DRIVES; then
    success "GRUB installation completed"
else
    warning "GRUB installation had issues, trying alternative method..."
    
    # Alternative: Install GRUB directly from rescue system
    info "Attempting direct GRUB installation from rescue system..."
    
    for drive in $DRIVES; do
        info "Installing GRUB to $drive (direct method)..."
        
        if [[ "$FIRMWARE_TYPE" == "uefi" ]]; then
            # UEFI direct installation
            if grub-install --target=x86_64-efi --boot-directory="$MOUNT_POINT/boot" --efi-directory="$MOUNT_POINT/boot/efi" --bootloader-id=proxmox --force 2>/dev/null; then
                success "GRUB EFI installed directly to $drive"
            else
                warning "Direct EFI installation to $drive failed"
            fi
        else
            # Legacy BIOS direct installation
            if grub-install --target=i386-pc --boot-directory="$MOUNT_POINT/boot" --force --skip-fs-probe "$drive" 2>/dev/null; then
                success "GRUB installed directly to $drive"
            else
                warning "Direct installation to $drive failed"
            fi
        fi
    done
fi

# Step 8: Verify bootloader installation
info "Verifying bootloader installation..."
GRUB_INSTALLED=false
BOOT_SIGNATURE_FOUND=false

for drive in $DRIVES; do
    # Check for GRUB signature in MBR/GPT
    if dd if="$drive" bs=512 count=1 2>/dev/null | grep -q "GRUB" 2>/dev/null; then
        success "GRUB signature verified on $drive"
        GRUB_INSTALLED=true
    elif dd if="$drive" bs=512 count=2 2>/dev/null | strings | grep -qi "grub\|boot" 2>/dev/null; then
        success "Boot signature found on $drive"
        BOOT_SIGNATURE_FOUND=true
    else
        warning "No boot signature detected on $drive"
    fi
    
    # For UEFI systems, check EFI partition
    if [[ "$FIRMWARE_TYPE" == "uefi" ]]; then
        if [[ -d "$MOUNT_POINT/boot/efi/EFI" ]]; then
            if find "$MOUNT_POINT/boot/efi/EFI" -name "*.efi" -o -name "grub*" | grep -q .; then
                success "EFI boot files found for UEFI system"
                GRUB_INSTALLED=true
            fi
        fi
    fi
done

# Check for GRUB configuration file
if [[ -f "$MOUNT_POINT/boot/grub/grub.cfg" ]]; then
    if grep -q "Proxmox" "$MOUNT_POINT/boot/grub/grub.cfg" 2>/dev/null; then
        success "GRUB configuration file verified"
    else
        warning "GRUB configuration exists but may be incomplete"
    fi
else
    warning "GRUB configuration file not found"
fi

# Step 9: Final status
echo
echo "=========================================="
echo "         BOOTLOADER FIX SUMMARY"
echo "=========================================="
echo

if [[ "$GRUB_INSTALLED" == "true" ]]; then
    echo -e "${GREEN}✓ BOOTLOADER FIX SUCCESSFUL${NC}"
    echo -e "${BLUE}GRUB has been installed properly on at least one drive.${NC}"
    echo -e "${GREEN}Your system should boot successfully.${NC}"
    echo
    echo -e "${BLUE}You can now safely run:${NC}"
    echo -e "${YELLOW}./scripts/04-post-install.sh${NC}"
    echo -e "${BLUE}And then:${NC}"
    echo -e "${YELLOW}reboot${NC}"
elif [[ "$BOOT_SIGNATURE_FOUND" == "true" ]]; then
    echo -e "${YELLOW}⚠ BOOTLOADER PARTIALLY INSTALLED${NC}"
    echo -e "${YELLOW}Boot signatures found but GRUB may not be fully configured.${NC}"
    echo -e "${BLUE}The system might boot, but you should test carefully.${NC}"
    echo
    echo -e "${BLUE}Recommended actions:${NC}"
    echo -e "${YELLOW}1. Try running this script again${NC}"
    echo -e "${YELLOW}2. If it still fails, check the installation log${NC}"
    echo -e "${YELLOW}3. You may proceed with caution to:${NC}"
    echo -e "${YELLOW}   ./scripts/04-post-install.sh && reboot${NC}"
else
    echo -e "${RED}⚠ BOOTLOADER FIX INCOMPLETE${NC}"
    echo -e "${RED}GRUB installation may have failed on all drives.${NC}"
    echo -e "${YELLOW}REBOOTING NOW COULD RESULT IN AN UNBOOTABLE SYSTEM${NC}"
    echo
    echo -e "${BLUE}Recommended actions:${NC}"
    echo -e "${YELLOW}1. Check the installation log: /tmp/bootloader-fix.log${NC}"
    echo -e "${YELLOW}2. Try running this script again${NC}"
    echo -e "${YELLOW}3. Consider reinstalling from scratch if issues persist${NC}"
fi

echo
echo "Drives processed: $DRIVES"
echo "Installation log: /tmp/bootloader-fix.log"
echo

# Cleanup
umount "$MOUNT_POINT/sys" 2>/dev/null || true
umount "$MOUNT_POINT/proc" 2>/dev/null || true  
umount "$MOUNT_POINT/dev" 2>/dev/null || true

success "Bootloader fix completed"
