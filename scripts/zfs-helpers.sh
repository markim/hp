#!/bin/bash

# ZFS Helper Functions
# Common functions for consistent ZFS operations across scripts

# Safe ZFS mount function that handles various mounting scenarios
safe_zfs_mount() {
    local dataset="$1"
    local mountpoint="$2"
    local force="${3:-no}"
    
    # Create mountpoint if it doesn't exist
    mkdir -p "$mountpoint"
    
    # Check if already mounted
    if mountpoint -q "$mountpoint"; then
        if [[ "$force" == "yes" ]]; then
            umount "$mountpoint" 2>/dev/null || true
        else
            echo "Mountpoint $mountpoint already in use"
            return 0
        fi
    fi
    
    # Try ZFS native mount first
    if zfs mount "$dataset" 2>/dev/null; then
        # Check if it mounted to the right place
        local current_mountpoint
        current_mountpoint=$(zfs get -H -o value mountpoint "$dataset")
        if [[ "$current_mountpoint" != "$mountpoint" ]]; then
            zfs umount "$dataset" 2>/dev/null || true
            zfs set mountpoint="$mountpoint" "$dataset"
            zfs mount "$dataset" || return 1
        fi
        return 0
    fi
    
    # Fall back to mount command
    zfs set mountpoint="$mountpoint" "$dataset" 2>/dev/null || true
    mount -t zfs "$dataset" "$mountpoint" || return 1
    
    return 0
}

# Safe ZFS unmount function
safe_zfs_umount() {
    local mountpoint="$1"
    local dataset="${2:-}"
    
    # Try regular umount first
    if umount "$mountpoint" 2>/dev/null; then
        return 0
    fi
    
    # If dataset specified, try ZFS umount
    if [[ -n "$dataset" ]]; then
        zfs umount "$dataset" 2>/dev/null || true
    fi
    
    # Force umount if necessary
    umount -f "$mountpoint" 2>/dev/null || true
    
    return 0
}

# Test ZFS functionality and fix common issues
test_and_fix_zfs() {
    local fixed_issues=false
    
    # Test basic ZFS commands
    if ! zpool status >/dev/null 2>&1; then
        echo "ERROR: ZFS pool status command failed"
        return 1
    fi
    
    # Test mount.zfs specifically for symbol issues
    if [[ -f /sbin/mount.zfs ]]; then
        # Check for symbol lookup errors
        if ! /sbin/mount.zfs --help >/dev/null 2>&1; then
            echo "WARNING: mount.zfs has symbol compatibility issues"
            
            # Try to fix by using rescue system ZFS if available
            if [[ -f /tmp/zfs-rescue/install-rescue-zfs.sh ]]; then
                echo "Attempting to fix using rescue system ZFS..."
                /tmp/zfs-rescue/install-rescue-zfs.sh
                fixed_issues=true
            fi
        fi
    fi
    
    # Re-test after potential fixes
    if [[ "$fixed_issues" == "true" ]]; then
        if ! zpool status >/dev/null 2>&1; then
            echo "ERROR: ZFS still not functional after attempted fixes"
            return 1
        fi
    fi
    
    return 0
}

# Check if this script is being sourced or run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script should be sourced, not executed directly"
    echo "Usage: source scripts/zfs-helpers.sh"
    exit 1
fi
