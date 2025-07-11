# Troubleshooting Guide

## Common Issues and Solutions

### Installation Issues

#### Error: "No suitable drives found"
**Cause:** Drives may be in use or excluded in configuration.
**Solution:**
1. Check if drives are mounted: `lsblk`
2. Unmount any mounted filesystems: `umount /dev/sdX*`
3. Review `EXCLUDE_DRIVES` in `config/server-config.conf`
4. Stop any RAID arrays: `mdadm --stop --scan`

#### Error: "Failed to load ZFS module"
**Cause:** ZFS kernel module not available or not loaded.
**Solution:**
1. Update package list: `apt-get update`
2. Install ZFS: `apt-get install zfsutils-linux`
3. Load module: `modprobe zfs`
4. Check if loaded: `lsmod | grep zfs`

#### Error: "Failed to download Proxmox ISO"
**Cause:** Network connectivity or URL issues.
**Solution:**
1. Check network: `ping google.com`
2. Update ISO URL in `config/server-config.conf`
3. Download manually and place in `/tmp/proxmox-ve.iso`

#### Error: "GRUB installation failed" or System won't boot
**Cause:** Firmware type mismatch (UEFI vs Legacy BIOS).
**Solution:**
1. Check firmware type: `ls /sys/firmware/efi` (exists = UEFI)
2. For UEFI systems:
   - Ensure EFI partition exists: `lsblk -o NAME,FSTYPE | grep vfat`
   - Set firmware type in config: `FIRMWARE_TYPE="uefi"`
   - Check EFI partition is mounted at `/boot/efi`
3. For Legacy BIOS systems:
   - Set firmware type in config: `FIRMWARE_TYPE="legacy"`
   - Ensure drives have proper MBR partition table
4. For Hetzner servers (typically UEFI-only):
   - Use `FIRMWARE_TYPE="uefi"` in configuration
   - Verify rescue system is booted in UEFI mode
   - Check that `/sys/firmware/efi` directory exists

#### Error: "No EFI partition found" on UEFI systems
**Cause:** EFI system partition missing or not detected.
**Solution:**
1. Check for EFI partitions: `lsblk -o NAME,FSTYPE | grep vfat`
2. If none exist, you may need to:
   - Boot Hetzner rescue system with installimage first
   - Or manually create EFI partition before running installation
3. Set EFI partition in config: `EFI_PARTITION="/dev/sdaX"`

### ZFS Issues

#### Error: "Pool already exists"
**Cause:** ZFS pool exists from previous installation.
**Solution:**
1. Check existing pools: `zpool list`
2. Export pool: `zpool export poolname`
3. If needed, force import: `zpool import -f poolname`
4. Or destroy pool: `zpool destroy poolname` (DATA LOSS!)

#### Error: "No devices available"
**Cause:** Drives not properly wiped or still in use.
**Solution:**
1. Check drive usage: `lsblk`
2. Wipe drives manually:
   ```bash
   wipefs -a /dev/sdX
   sgdisk --zap-all /dev/sdX
   dd if=/dev/zero of=/dev/sdX bs=1M count=100
   ```

#### Error: "Insufficient space"
**Cause:** Drive too small or already partitioned.
**Solution:**
1. Check drive size: `lsblk -b`
2. Ensure drive is larger than `MIN_MIRROR_SIZE` in config
3. Verify no existing partitions: `fdisk -l /dev/sdX`

### Network Issues

#### Error: "No network after reboot"
**Cause:** Network configuration not properly preserved.
**Solution:**
1. Boot into rescue system
2. Mount root filesystem: `mount -t zfs rpool/ROOT/pve-1 /mnt`
3. Check network config: `cat /mnt/etc/network/interfaces`
4. Fix configuration manually
5. Unmount and reboot: `umount /mnt && reboot`

#### Error: "Cannot access Proxmox web interface"
**Cause:** Firewall blocking port 8006 or service not running.
**Solution:**
1. Check if service is running: `systemctl status pveproxy`
2. Check firewall: `iptables -L`
3. Restart service: `systemctl restart pveproxy`
4. Access via SSH and check logs: `journalctl -u pveproxy`

### Boot Issues

#### Error: "System won't boot from ZFS"
**Cause:** GRUB not properly installed or configured.
**Solution:**
1. Boot into rescue system
2. Import ZFS pool: `zpool import rpool`
3. Mount root: `mount -t zfs rpool/ROOT/pve-1 /mnt`
4. Mount boot filesystems:
   ```bash
   mount --bind /dev /mnt/dev
   mount --bind /proc /mnt/proc
   mount --bind /sys /mnt/sys
   ```
5. Reinstall GRUB:
   ```bash
   chroot /mnt
   grub-install /dev/sdX  # for each drive
   update-grub
   ```
6. Exit chroot and reboot

#### Error: "ZFS pool not found on boot"
**Cause:** ZFS cache file missing or pools not imported.
**Solution:**
1. Check if pools are importable: `zpool import`
2. Force import: `zpool import -f rpool`
3. Update cache: `zpool set cachefile=/etc/zfs/zpool.cache rpool`
4. Enable ZFS services:
   ```bash
   systemctl enable zfs-import-cache
   systemctl enable zfs-mount
   ```

### Performance Issues

#### Slow ZFS Performance
**Cause:** Suboptimal ZFS settings or insufficient RAM.
**Solution:**
1. Check RAM: `free -h` (ZFS needs at least 1GB)
2. Verify ashift setting: `zpool get ashift poolname`
3. Enable compression: `zfs set compression=lz4 poolname`
4. Disable atime: `zfs set atime=off poolname`

#### High CPU Usage
**Cause:** ZFS compression or deduplication enabled.
**Solution:**
1. Check compression: `zfs get compression`
2. Disable dedup if enabled: `zfs set dedup=off poolname`
3. Use lz4 instead of gzip compression

### Recovery Procedures

#### Complete System Recovery
If the system is completely broken:

1. **Boot into Hetzner rescue system**
2. **Import ZFS pools:**
   ```bash
   zpool import -f rpool
   zfs list
   ```
3. **Mount filesystem:**
   ```bash
   mkdir /mnt/recovery
   mount -t zfs rpool/ROOT/pve-1 /mnt/recovery
   ```
4. **Backup important data:**
   ```bash
   cp -r /mnt/recovery/etc /tmp/etc-backup
   cp -r /mnt/recovery/root /tmp/root-backup
   ```
5. **Reinstall if necessary or fix issues**

#### Data Recovery from ZFS
If you need to recover data from ZFS pools:

1. **Import pools read-only:**
   ```bash
   zpool import -o readonly=on poolname
   ```
2. **Mount datasets:**
   ```bash
   zfs mount -a
   ```
3. **Copy data to safe location:**
   ```bash
   rsync -av /poolname/dataset/ /backup/location/
   ```

### Log Files and Debugging

#### Important Log Locations
- Installation log: `/tmp/proxmox-install.log`
- System logs: `/var/log/syslog`
- ZFS events: `zpool events`
- Proxmox logs: `/var/log/pve/`

#### Debug Mode
Enable debug mode by setting `DEBUG="yes"` in `config/server-config.conf`.

#### Verbose Output
Add `-x` to script shebangs for detailed execution tracing.

### Getting Help

#### Collect System Information
Before asking for help, collect this information:

```bash
# System info
uname -a
free -h
lscpu

# Storage info
lsblk
zpool list
zpool status
zfs list

# Network info
ip addr show
ip route show

# Logs
tail -100 /tmp/proxmox-install.log
dmesg | tail -50
```

#### Community Resources
- Proxmox Community Forum: https://forum.proxmox.com/
- ZFS Documentation: https://openzfs.github.io/openzfs-docs/
- Hetzner Community: https://community.hetzner.com/

### Prevention

#### Before Installation
1. Always backup important data
2. Test network connectivity
3. Verify hardware compatibility
4. Have rescue system access ready

#### After Installation
1. Document your configuration
2. Test backups regularly
3. Monitor system health
4. Keep system updated
