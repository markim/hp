# Makefile for Enhanced Proxmox VE Installation Scripts

.PHONY: help install remote-install check-syntax clean examples test

# Default target
help:
	@echo "Enhanced Proxmox VE Installation Scripts"
	@echo "========================================"
	@echo ""
	@echo "Available targets:"
	@echo "  install       - Run local installation (requires rescue system)"
	@echo "  remote-install - Run remote installation (requires server address)"
	@echo "  check-syntax  - Check shell script syntax"
	@echo "  examples      - Show example configurations"
	@echo "  test          - Run tests"
	@echo "  clean         - Clean temporary files"
	@echo "  help          - Show this help message"
	@echo ""
	@echo "Examples:"
	@echo "  make install"
	@echo "  make remote-install SERVER=proxmox.80px.com"
	@echo "  make check-syntax"

# Local installation
install:
	@echo "Starting local Proxmox VE installation..."
	@if [ ! -f /proc/version ] || ! grep -q "rescue" /proc/version 2>/dev/null; then \
		echo "Warning: This doesn't appear to be a rescue system"; \
		read -p "Continue anyway? (y/N): " confirm; \
		if [ "$$confirm" != "y" ]; then exit 1; fi; \
	fi
	@bash install.sh

# Remote installation
remote-install:
	@if [ -z "$(SERVER)" ]; then \
		echo "Error: SERVER variable is required"; \
		echo "Usage: make remote-install SERVER=your-server.com"; \
		exit 1; \
	fi
	@echo "Starting remote installation on $(SERVER)..."
	@bash remote-install.sh $(SERVER)

# Check shell script syntax
check-syntax:
	@echo "Checking shell script syntax..."
	@for script in *.sh; do \
		echo "Checking $$script..."; \
		bash -n "$$script" && echo "✓ $$script syntax OK" || echo "✗ $$script syntax error"; \
	done

# Show example configurations
examples:
	@echo "Example network configurations:"
	@echo "=============================="
	@echo ""
	@echo "Routed IPv4 setup:"
	@echo "  examples/interfaces-routed-ipv4.conf"
	@echo ""
	@echo "Routed dual-stack (IPv4+IPv6) setup:"
	@echo "  examples/interfaces-routed-dual.conf"
	@echo ""
	@echo "Bridged setup (requires virtual MACs):"
	@echo "  examples/interfaces-bridged.conf"
	@echo ""
	@echo "See examples/README.md for detailed information."

# Basic tests
test:
	@echo "Running basic tests..."
	@echo "Testing script syntax..."
	@make check-syntax
	@echo ""
	@echo "Testing network utilities..."
	@command -v ip >/dev/null || echo "Warning: 'ip' command not found"
	@command -v brctl >/dev/null || echo "Warning: 'brctl' command not found"
	@command -v qemu-system-x86_64 >/dev/null || echo "Warning: 'qemu-system-x86_64' not found"
	@echo "✓ Basic tests completed"

# Clean temporary files
clean:
	@echo "Cleaning temporary files..."
	@rm -f pve.iso pve-autoinstall.iso answer.toml
	@rm -f qemu_output.log
	@rm -rf template_files/
	@echo "✓ Cleanup completed"

# Development targets
dev-setup:
	@echo "Setting up development environment..."
	@command -v shellcheck >/dev/null || echo "Consider installing shellcheck for better linting"
	@chmod +x *.sh
	@echo "✓ Development setup completed"

# Install dependencies (for Debian/Ubuntu)
deps-debian:
	@echo "Installing dependencies for Debian/Ubuntu..."
	@apt update
	@apt install -y curl wget qemu-system-x86 ovmf bridge-utils sshpass
	@echo "✓ Dependencies installed"

# Install dependencies (for RHEL/CentOS)
deps-rhel:
	@echo "Installing dependencies for RHEL/CentOS..."
	@yum install -y curl wget qemu-kvm edk2-ovmf bridge-utils sshpass
	@echo "✓ Dependencies installed"

# Show system information useful for troubleshooting
sysinfo:
	@echo "System Information:"
	@echo "=================="
	@echo "OS: $$(cat /etc/os-release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '\"')"
	@echo "Kernel: $$(uname -r)"
	@echo "Architecture: $$(uname -m)"
	@echo ""
	@echo "Network Interfaces:"
	@ip link show | grep -E "^[0-9]+:" | cut -d: -f2 | sed 's/^ */  /'
	@echo ""
	@echo "Block Devices:"
	@lsblk -d | grep disk | awk '{print "  " $$1 " (" $$4 ")"}'
	@echo ""
	@echo "Memory:"
	@free -h | grep "^Mem:" | awk '{print "  Total: " $$2 ", Available: " $$7}'

# Generate documentation
docs:
	@echo "Generating documentation..."
	@echo "Available documentation files:"
	@echo "  README.md              - Main project overview"
	@echo "  INSTALLATION_GUIDE.md  - Detailed installation guide"
	@echo "  examples/README.md     - Network configuration examples"
	@echo ""
	@echo "For online viewing, consider using a markdown viewer or"
	@echo "converting to HTML with pandoc or similar tools."
