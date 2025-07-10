#!/bin/bash

# ZFS Functionality Test Script
# Quick test to verify ZFS is working before installation

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

error() {
    echo -e "${RED}✗ $1${NC}"
}

warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Test ZFS commands
test_zfs_commands() {
    info "Testing ZFS commands..."
    
    if ! command -v zpool >/dev/null; then
        error "zpool command not found"
        return 1
    fi
    success "zpool command available"
    
    if ! command -v zfs >/dev/null; then
        error "zfs command not found"
        return 1
    fi
    success "zfs command available"
    
    return 0
}

# Test ZFS module
test_zfs_module() {
    info "Testing ZFS module..."
    
    if lsmod | grep -q zfs; then
        success "ZFS module loaded"
        return 0
    fi
    
    warning "ZFS module not loaded, attempting to load..."
    if modprobe zfs 2>/dev/null; then
        success "ZFS module loaded successfully"
        return 0
    else
        error "Could not load ZFS module"
        return 1
    fi
}

# Test ZFS functionality
test_zfs_functionality() {
    info "Testing ZFS functionality..."
    
    if zpool status >/dev/null 2>&1; then
        success "ZFS status command works"
    else
        error "ZFS status command failed"
        return 1
    fi
    
    # Test with a minimal command that shouldn't affect anything
    if zfs list >/dev/null 2>&1; then
        success "ZFS list command works"
    else
        warning "ZFS list command failed (may be normal if no pools exist)"
    fi
    
    return 0
}

# Show system information
show_system_info() {
    echo
    echo "=== System Information ==="
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "ZFS version: $(zfs version 2>/dev/null | head -1 || echo "Unknown")"
    echo
}

# Main test function
main() {
    echo "=== ZFS Functionality Test ==="
    show_system_info
    
    local tests_passed=0
    local total_tests=3
    
    if test_zfs_commands; then
        ((tests_passed++))
    fi
    
    if test_zfs_module; then
        ((tests_passed++))
    fi
    
    if test_zfs_functionality; then
        ((tests_passed++))
    fi
    
    echo
    echo "=== Test Results ==="
    echo "Passed: $tests_passed/$total_tests tests"
    
    if [[ $tests_passed -eq $total_tests ]]; then
        success "All ZFS tests passed - ready for installation!"
        exit 0
    elif [[ $tests_passed -gt 0 ]]; then
        warning "Some ZFS tests passed - installation may work with rescue system ZFS"
        exit 0
    else
        error "All ZFS tests failed - installation will likely fail"
        echo
        echo "Suggestions:"
        echo "1. Run: ./scripts/cleanup-zfs.sh"
        echo "2. Reboot into rescue system"
        echo "3. Try installation with USE_RESCUE_ZFS=yes"
        exit 1
    fi
}

main "$@"
