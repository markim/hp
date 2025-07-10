# Makefile for Hetzner Proxmox ZFS Installation

.PHONY: help install prepare zfs proxmox post-install clean check permissions

# Default target
help:
	@echo "Hetzner Proxmox ZFS Installation"
	@echo "================================"
	@echo ""
	@echo "Available targets:"
	@echo "  install     - Full automated installation"
	@echo "  prepare     - Prepare system and install dependencies"
	@echo "  zfs         - Setup ZFS pools and datasets"
	@echo "  proxmox     - Install Proxmox VE"
	@echo "  post-install - Post-installation configuration"
	@echo "  check       - Check system requirements"
	@echo "  permissions - Set correct script permissions"
	@echo "  clean       - Clean up temporary files"
	@echo ""
	@echo "Usage:"
	@echo "  make install    # Complete installation"
	@echo "  make check      # Check if system is ready"
	@echo ""

# Check if running as root
check-root:
	@if [ "$$(id -u)" != "0" ]; then \
		echo "Error: This must be run as root"; \
		exit 1; \
	fi

# Set correct permissions on scripts
permissions:
	@echo "Setting script permissions..."
	@chmod +x install.sh
	@chmod +x scripts/*.sh
	@echo "Permissions set successfully"

# Check system requirements
check: check-root
	@echo "Checking system requirements..."
	@which zfs >/dev/null 2>&1 || (echo "Installing ZFS utilities..." && apt-get update && apt-get install -y zfsutils-linux)
	@which debootstrap >/dev/null 2>&1 || (echo "Installing debootstrap..." && apt-get install -y debootstrap)
	@echo "System check completed"

# Full installation
install: check-root permissions
	@echo "Starting full Proxmox installation..."
	@./install.sh

# Individual steps
prepare: check-root permissions
	@echo "Preparing system..."
	@./scripts/01-prepare-system.sh

zfs: check-root permissions
	@echo "Setting up ZFS..."
	@./scripts/02-setup-zfs.sh

proxmox: check-root permissions
	@echo "Installing Proxmox..."
	@./scripts/03-install-proxmox.sh

post-install: check-root permissions
	@echo "Running post-installation..."
	@./scripts/04-post-install.sh

# Clean up temporary files
clean:
	@echo "Cleaning up temporary files..."
	@rm -f /tmp/drive_sizes.txt
	@rm -f /tmp/drives_*gb.txt
	@rm -f /tmp/proxmox-ve.iso
	@umount /mnt/proxmox-iso 2>/dev/null || true
	@umount /mnt/proxmox 2>/dev/null || true
	@echo "Cleanup completed"

# Dry run - show what would be done
dry-run: permissions
	@echo "=== DRY RUN MODE ==="
	@echo "The following operations would be performed:"
	@echo "1. System preparation and package installation"
	@echo "2. ZFS pool creation with detected drives:"
	@lsblk -d | grep -E 'sd|nvme|vd' || echo "   No drives detected"
	@echo "3. Proxmox VE installation"
	@echo "4. System configuration and reboot preparation"
	@echo ""
	@echo "To proceed with actual installation, run: make install"

# Show system information
info:
	@echo "=== System Information ==="
	@echo "Hostname: $$(hostname)"
	@echo "Kernel: $$(uname -r)"
	@echo "Memory: $$(free -h | grep Mem | awk '{print $$2}')"
	@echo "CPU: $$(nproc) cores"
	@echo ""
	@echo "=== Storage Devices ==="
	@lsblk -d -o NAME,SIZE,MODEL | grep -v loop
	@echo ""
	@echo "=== Network Configuration ==="
	@ip -4 addr show | grep inet | grep -v 127.0.0.1
	@echo ""
	@echo "=== ZFS Status ==="
	@if command -v zpool >/dev/null 2>&1; then \
		zpool list 2>/dev/null || echo "No ZFS pools found"; \
	else \
		echo "ZFS not installed"; \
	fi

# Backup current configuration
backup:
	@echo "Creating configuration backup..."
	@mkdir -p backups/$$(date +%Y%m%d_%H%M%S)
	@cp -r config/ backups/$$(date +%Y%m%d_%H%M%S)/ 2>/dev/null || true
	@ip addr show > backups/$$(date +%Y%m%d_%H%M%S)/network-config.txt
	@lsblk > backups/$$(date +%Y%m%d_%H%M%S)/storage-layout.txt
	@echo "Backup created in backups/ directory"

# Quick validation
validate:
	@echo "Validating configuration..."
	@if [ ! -f config/server-config.conf ]; then \
		echo "Error: Configuration file not found"; \
		exit 1; \
	fi
	@echo "Configuration file found"
	@if [ ! -d scripts ]; then \
		echo "Error: Scripts directory not found"; \
		exit 1; \
	fi
	@echo "Scripts directory found"
	@echo "Validation completed successfully"
