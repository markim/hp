# ZFS Mirroring Changes

## Overview
Modified the ZFS setup to add ALL available drives to the `rpool` during initial installation, creating multiple mirror vdevs (mirror-0, mirror-1, etc.) rather than creating an initial pool and saving drives for post-install expansion.

## Key Changes

### 1. Modified `scripts/02-setup-zfs.sh`

**Before:**
- Created initial rpool with first mirror pair only
- Saved remaining drives for post-install expansion
- Generated `/tmp/remaining_drives_for_expansion.txt` for later use

**After:**
- Processes ALL available drives during initial setup
- Creates multiple mirror vdevs in single rpool (mirror-0, mirror-1, etc.)
- Groups drives by size and creates mirror pairs where possible
- Single drives (no pair available) added as individual vdevs
- Generates `/tmp/zfs_rpool_configuration.txt` with final layout

### 2. Updated Configuration Documentation

Updated `config/server-config.conf.example` to clarify:
- All drives added to single rpool during initial setup
- Mirror vdevs created as mirror-0, mirror-1, etc.
- Mixed drive sizes handled appropriately

## Behavior Examples

### Example 1: 4x 1TB drives
**Result:** 
- rpool with 2 mirror vdevs (mirror-0, mirror-1)
- Full redundancy across all drives

### Example 2: 2x 1TB + 2x 2TB drives  
**Result:**
- rpool with 2 mirror vdevs
- mirror-0: 1TB + 1TB
- mirror-1: 2TB + 2TB

### Example 3: 3x 1TB drives
**Result:**
- rpool with 1 mirror vdev + 1 single vdev
- mirror-0: 1TB + 1TB  
- single vdev: 1TB

## Benefits

1. **Simplified Installation:** All storage configured during initial setup
2. **Maximum Redundancy:** Mirror vdevs created wherever possible
3. **Single Pool Management:** All drives in one rpool for easier administration
4. **No Post-Install Steps:** Complete storage configuration during installation
5. **Better Performance:** Multiple vdevs can provide better performance than single mirror

## Configuration Options

- `AUTO_MIRROR="yes"`: Enable automatic mirror creation
- `MIN_MIRROR_SIZE="100"`: Minimum drive size (GB) for mirroring
- `EXCLUDE_DRIVES=()`: Array of drives to exclude from setup

## Files Modified

- `scripts/02-setup-zfs.sh`: Core ZFS setup logic
- `config/server-config.conf.example`: Documentation updates

## Verification

After installation, verify with:
```bash
zpool status rpool
```

Should show multiple vdevs:
```
  pool: rpool
 state: ONLINE
config:
    NAME        STATE     READ WRITE CKSUM
    rpool       ONLINE       0     0     0
      mirror-0  ONLINE       0     0     0
        sda     ONLINE       0     0     0
        sdb     ONLINE       0     0     0
      mirror-1  ONLINE       0     0     0
        sdc     ONLINE       0     0     0
        sdd     ONLINE       0     0     0
```
