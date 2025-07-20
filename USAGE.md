# How to Use Your Enhanced Arch Linux Installer

## 🚀 **TL;DR - Just Run It!**

```bash
sudo ./archinstall.sh
```

That's it! The installer will guide you through everything with nice progress bars and menus.

## 📋 **What You'll Experience**

### **1. Welcome & Progress**
```
=============================================================
                  Arch Linux Installer
=============================================================
Step 1/12: Checking system requirements (8%)
=============================================================
✓ Successfully reached archlinux.org
✓ Successfully reached 8.8.8.8
✓ Successfully reached 1.1.1.1
Internet connection verified (3/3 hosts reachable)
UEFI boot mode verified
✓ Completed: System requirements check
```

### **2. Smart Disk Selection**
```
Available Disks (excluding loop devices and CD-ROMs):
     1	/dev/sda   20G   QEMU_HARDDISK   disk
     2	/dev/nvme0n1   512G   Samsung_SSD   disk

Enter the number corresponding to your disk (1-2, or 'q' to quit): 1
✓ Selected disk: /dev/sda
✓ Disk size verified: 20 GB
```

### **3. Interactive Btrfs Configuration**

The installer will show you this menu:

```
=== Btrfs Subvolume Configuration ===
Current subvolumes:
  @ -> /
  @home -> /home
  @log -> /var/log
  @pkg -> /var/cache/pacman/pkg
  @snapshots -> /.snapshots

1. Keep default configuration
2. Add more subvolumes  
3. Modify existing subvolumes
4. Remove subvolumes (except @)
5. Preview configuration
6. Continue with current configuration

Choose action (1-6): 
```

**For most users**: Just press `1` (keep defaults) - they're perfectly optimized!

**For power users**: Want a custom `@var` subvolume? Press `2`, enter `@var`, then `/var`. Easy!

### **4. Mount Options Made Simple**

```
=== Btrfs Mount Options Configuration ===
Current global mount options: noatime,discard=async,compress=zstd,space_cache=v2

1. Keep default options
2. Modify mount options
3. Configure per-subvolume options (advanced)
4. Continue with current configuration

Choose action (1-4):
```

**For most users**: Press `1` - the defaults are performance-optimized!

**For tweakers**: Press `2` to customize compression, enable autodefrag, etc.

### **5. Configuration Preview**

Before applying changes, you'll see:

```
=== Btrfs Configuration Preview ===

Global mount options: noatime,discard=async,compress=zstd,space_cache=v2

Subvolumes and mount points:
  @ -> /
    Options: subvol=@,noatime,discard=async,compress=zstd,space_cache=v2
  @home -> /home
    Options: subvol=@home,noatime,discard=async,compress=zstd,space_cache=v2
  @log -> /var/log
    Options: subvol=@log,noatime,discard=async,compress=zstd,space_cache=v2

Press Enter to continue...
```

### **6. Automated Installation**

The rest happens automatically with progress tracking:

```
Step 5/12: Installing base system (42%)
=============================================================
✓ Completed: Base system installation

Step 6/12: Configuring initial ramdisk (50%)
=============================================================
✓ Completed: Initial ramdisk configuration
```

## 🧪 **Testing Before You Install**

### **Quick Function Test** (30 seconds)
```bash
./simple_test.sh
```

This validates all the core functions work on your system.

### **Full Test Suite** (if you have root and want comprehensive testing)
```bash
sudo ./test_archinstall.sh
```

## 🎯 **Common Use Cases**

### **Default Setup (Recommended)**
Perfect for 99% of users:
- Root (`@`) at `/`
- Home (`@home`) at `/home` 
- Logs (`@log`) at `/var/log`
- Package cache (`@pkg`) at `/var/cache/pacman/pkg`
- Snapshots (`@snapshots`) at `/.snapshots`
- Optimized mount options for performance and SSD longevity

**Action**: Press `1` for subvolumes, `1` for mount options. Done!

### **Server Setup**
Add separate subvolumes for server data:

1. Choose `2` (Add more subvolumes)
2. Add `@var` → `/var` (for server data)
3. Add `@srv` → `/srv` (for service data)
4. Add `@opt` → `/opt` (for optional software)

### **Development Setup**
Isolate development environments:

1. Add `@dev` → `/home/dev` (development projects)
2. Add `@containers` → `/var/lib/containers` (if using containers)

### **Gaming Setup**
Separate game storage:

1. Add `@games` → `/home/games` (game installations)
2. Optionally use `compress=lzo` for games subvolume (faster loading)

## 🔧 **Advanced Options**

### **Custom Mount Options**
Common tweaks:
- `compress=lzo` - Faster compression for frequently accessed data
- `compress=zlib` - Better compression for archival data
- `autodefrag` - Automatic defragmentation for databases
- `commit=30` - Custom commit interval for performance tuning

### **Per-Subvolume Options**
Example: Games with different compression:
1. Choose `3` (Configure per-subvolume options)
2. For `@games`: Add `compress=lzo`
3. For `@home`: Add `autodefrag`

## ⚠️ **System Requirements**

- **Boot Mode**: UEFI (the installer checks this)
- **Internet**: Multi-host connectivity test (archlinux.org, 8.8.8.8, 1.1.1.1)
- **Disk Space**: Minimum 20GB (automatically verified)
- **Environment**: Official Arch Linux ISO

## 🔒 **Security Features**

The installer includes enterprise-grade security:
- **No passwordless sudo** (requires password with 15-min timeout)
- **Input validation** (prevents crashes and exploits)
- **Secure network calls** (timeouts, certificate validation)
- **Proper file permissions** (sudoers validation)

## 🚨 **If Something Goes Wrong**

The installer has comprehensive error handling:
- **Automatic cleanup** on failure (unmounts, disables swap)
- **Detailed logging** to `/var/log/archinstall.log`
- **Graceful recovery** with helpful error messages
- **No system damage** - safe to restart

## 🎉 **After Installation**

Your new system will have:
- ✅ **Secure sudo configuration** (password required)
- ✅ **Optimized Btrfs setup** with your custom subvolumes
- ✅ **Zsh with Zinit framework** for both root and user
- ✅ **NetworkManager** enabled for connectivity
- ✅ **Proper microcode** (Intel/AMD auto-detected)
- ✅ **Multilib repository** enabled
- ✅ **Pacman optimizations** (colors, parallel downloads)

**Final step**: Reboot and enjoy your perfectly configured Arch Linux system!

---

**Remember**: The installer size doubled but the **usage is actually simpler** thanks to better UX and error handling. All the complexity is hidden behind an intuitive interface! 🚀