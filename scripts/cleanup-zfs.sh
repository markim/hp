#!/bin/bash

# ZFS Cleanup and Recovery Script
# This script cleans up broken ZFS installations and prepares for retry

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Clean up broken ZFS packages
cleanup_zfs() {
    info "Cleaning up broken ZFS packages..."
    
    # Stop any running ZFS services
    systemctl stop zfs-mount zfs-import-cache zfs-zed 2>/dev/null || true
    
    # Remove broken packages
    apt-get remove --purge -y zfs-dkms zfs-zed zfsutils-linux 2>/dev/null || true
    
    # Clean up DKMS
    if command -v dkms >/dev/null; then
        dkms remove -m zfs -v 2.1.11 --all 2>/dev/null || true
    fi
    
    # Clean package cache
    apt-get autoremove -y
    apt-get autoclean
    
    # Fix any broken packages
    dpkg --configure -a
    apt-get install -f
    
    success "ZFS cleanup completed"
}

# Check if ZFS is still functional from rescue system
check_rescue_zfs() {
    info "Checking rescue system ZFS..."
    
    if command -v zpool >/dev/null && zpool status >/dev/null 2>&1; then
        success "Rescue system ZFS is functional"
        return 0
    else
        warning "Rescue system ZFS not available"
        return 1
    fi
}

# Main cleanup function
main() {
    echo "=== ZFS Cleanup and Recovery ==="
    echo
    
    cleanup_zfs
    
    if check_rescue_zfs; then
        echo
        echo "✓ Ready to retry installation with rescue system ZFS"
        echo "  Run: ./install.sh"
    else
        echo
        echo "⚠ Rescue system ZFS not available"
        echo "  You may need to reboot into rescue system"
    fi
}

main "$@"
