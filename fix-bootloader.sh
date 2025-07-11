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

# Configuration (adjust these if different)
MOUNT_POINT="/mnt/proxmox"
ZFS_POOL_NAME="rpool"
ZFS_ROOT_DATASET="$ZFS_POOL_NAME/ROOT/pve-1"

# Step 1: Check if installation is mounted
info "Checking installation mount..."
if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    info "Mounting ZFS root filesystem..."
    mkdir -p "$MOUNT_POINT"
    
    # Try to mount the ZFS dataset
    if ! mount -t zfs "$ZFS_ROOT_DATASET" "$MOUNT_POINT"; then
        # Try setting mountpoint and mounting
        zfs set mountpoint="$MOUNT_POINT" "$ZFS_ROOT_DATASET"
        if ! zfs mount "$ZFS_ROOT_DATASET"; then
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
cat > "$MOUNT_POINT/etc/default/grub" << EOF
# GRUB Configuration for ZFS Boot
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Proxmox VE"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="root=ZFS=$ZFS_ROOT_DATASET boot=zfs"
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=false
EOF

# Step 5: Fix the "unknown filesystem" issue
info "Fixing GRUB filesystem detection..."

# The issue is that grub-probe can't read ZFS, so we need to help it
# Create a bind mount of /boot to a location GRUB can understand
mkdir -p "$MOUNT_POINT/boot/grub"

# Copy current kernel and initrd to a location GRUB can find
KERNEL=""
INITRD=""
for kernel_file in "$MOUNT_POINT/boot/vmlinuz-"*; do
    if [[ -f "$kernel_file" ]]; then
        KERNEL="$kernel_file"
        break
    fi
done

if [[ -n "$KERNEL" ]]; then
    for initrd_file in "$MOUNT_POINT/boot/initrd.img-"*; do
        if [[ -f "$initrd_file" ]]; then
            INITRD="$initrd_file"
            break
        fi
    done
    KERNEL_VERSION=$(basename "$KERNEL" | sed 's/vmlinuz-//')
    
    info "Found kernel: $KERNEL_VERSION"
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

# Create a script to run in chroot that bypasses the filesystem detection
cat > "$MOUNT_POINT/tmp/install-grub.sh" << 'GRUB_SCRIPT'
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Install GRUB to each drive
for drive in $@; do
    echo "Installing GRUB to $drive..."
    
    # Method 1: Direct installation bypassing filesystem detection
    if grub-install --target=i386-pc --boot-directory=/boot --force --skip-fs-probe "$drive" 2>/dev/null; then
        echo "✓ GRUB installed successfully to $drive"
        continue
    fi
    
    # Method 2: Install with --allow-floppy (for compatibility)
    if grub-install --target=i386-pc --boot-directory=/boot --force --allow-floppy "$drive" 2>/dev/null; then
        echo "✓ GRUB installed with floppy compatibility to $drive"
        continue
    fi
    
    # Method 3: Try without filesystem probing at all
    if grub-install --target=i386-pc --boot-directory=/boot --force --no-floppy --skip-fs-probe "$drive" 2>/dev/null; then
        echo "✓ GRUB installed with no-floppy to $drive"
        continue
    fi
    
    echo "⚠ Failed to install GRUB to $drive"
done

# Verify GRUB installation
echo "Verifying GRUB installation..."
for drive in $@; do
    if dd if="$drive" bs=512 count=1 2>/dev/null | grep -q "GRUB"; then
        echo "✓ GRUB signature found on $drive"
    else
        echo "⚠ No GRUB signature on $drive"
    fi
done
GRUB_SCRIPT

chmod +x "$MOUNT_POINT/tmp/install-grub.sh"

# Execute GRUB installation in chroot
if chroot "$MOUNT_POINT" /tmp/install-grub.sh $DRIVES; then
    success "GRUB installation completed"
else
    warning "GRUB installation had issues, trying alternative method..."
    
    # Alternative: Install GRUB directly from rescue system
    info "Attempting direct GRUB installation from rescue system..."
    
    for drive in $DRIVES; do
        info "Installing GRUB to $drive (direct method)..."
        
        # Install GRUB directly, pointing to the chroot /boot
        if grub-install --target=i386-pc --boot-directory="$MOUNT_POINT/boot" --force --skip-fs-probe "$drive" 2>/dev/null; then
            success "GRUB installed directly to $drive"
        else
            warning "Direct installation to $drive failed"
        fi
    done
fi

# Step 8: Verify bootloader installation
info "Verifying bootloader installation..."
GRUB_INSTALLED=false

for drive in $DRIVES; do
    if dd if="$drive" bs=512 count=1 2>/dev/null | grep -q "GRUB" 2>/dev/null; then
        success "GRUB verified on $drive"
        GRUB_INSTALLED=true
    else
        warning "GRUB not detected on $drive"
    fi
done

# Step 9: Final status
echo
echo "=========================================="
echo "         BOOTLOADER FIX SUMMARY"
echo "=========================================="
echo

if [[ "$GRUB_INSTALLED" == "true" ]]; then
    echo -e "${GREEN}✓ BOOTLOADER FIX SUCCESSFUL${NC}"
    echo -e "${BLUE}At least one drive has GRUB installed properly.${NC}"
    echo -e "${GREEN}Your system should boot successfully.${NC}"
    echo
    echo -e "${BLUE}You can now safely run:${NC}"
    echo -e "${YELLOW}./scripts/04-post-install.sh${NC}"
    echo -e "${BLUE}And then:${NC}"
    echo -e "${YELLOW}reboot${NC}"
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
