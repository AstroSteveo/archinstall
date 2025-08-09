#!/bin/bash

# Arch Linux Base Installation Script
# Following the Arch Way: Simple, Modern, Pragmatic, User-Centric, Versatile
# 
# This script automates the base installation of Arch Linux with proper error
# handling, user configuration, and filesystem management.

set -euo pipefail

# Global variables
readonly SCRIPT_NAME="archinstall"
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"
readonly MOUNT_POINT="/mnt"
readonly EFI_SIZE="512M"
readonly SWAP_SIZE="2G"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Configuration variables
DISK=""
FILESYSTEM_TYPE=""
ROOT_PASSWORD=""
USERNAME=""
USER_PASSWORD=""
USER_SHELL=""
ENABLE_SUDO=""
HOSTNAME=""
BOOTLOADER=""
CPU_VENDOR=""
ENABLE_MULTILIB=""

#######################################
# Logging and Output Functions
#######################################

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

fatal() {
    error "$*"
    exit 1
}

#######################################
# Validation Functions
#######################################

validate_uefi_boot() {
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        fatal "This script requires UEFI boot mode. Legacy BIOS is not supported."
    fi
    success "UEFI boot mode detected"
}

validate_network() {
    if ! ping -c 1 archlinux.org &>/dev/null; then
        fatal "No internet connection. Please configure network and try again."
    fi
    success "Network connectivity confirmed"
}

validate_disk() {
    local disk="$1"
    if [[ ! -b "$disk" ]]; then
        fatal "Disk $disk does not exist or is not a block device"
    fi
    
    # Check if disk is mounted
    if mount | grep -q "$disk"; then
        fatal "Disk $disk has mounted partitions. Please unmount before proceeding."
    fi
    
    success "Disk $disk validated"
}

validate_username() {
    local username="$1"
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        return 1
    fi
    if [[ ${#username} -gt 32 ]]; then
        return 1
    fi
    return 0
}

validate_hostname() {
    local hostname="$1"
    if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 1
    fi
    return 0
}

#######################################
# User Input Functions
#######################################

get_disk_selection() {
    info "Detecting available disks..."
    
    # Get list of available disks
    local disks=()
    local disk_info=()
    
    while IFS= read -r line; do
        local disk_name
        local disk_size  
        local disk_model
        disk_name=$(echo "$line" | awk '{print $1}')
        disk_size=$(echo "$line" | awk '{print $2}')
        disk_model=$(echo "$line" | cut -d' ' -f3-)
        
        if [[ -b "/dev/$disk_name" ]]; then
            disks+=("/dev/$disk_name")
            disk_info+=("$disk_name ($disk_size) - $disk_model")
        fi
    done < <(lsblk -d -n -o NAME,SIZE,MODEL | grep -E "sd[a-z]|nvme[0-9]n[0-9]|vd[a-z]")
    
    if [[ ${#disks[@]} -eq 0 ]]; then
        fatal "No suitable disks found"
    fi
    
    info "Available disks:"
    for i in "${!disks[@]}"; do
        echo "$((i+1))) ${disk_info[i]}"
    done
    
    while true; do
        read -r -p "Select disk (1-${#disks[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#disks[@]} ]]; then
            DISK="${disks[$((choice-1))]}"
            break
        else
            warning "Invalid choice. Please select a number between 1 and ${#disks[@]}."
        fi
    done
    
    info "Selected disk: $DISK (${disk_info[$((choice-1))]})"
    
    # Validate disk (will exit if invalid)
    validate_disk "$DISK"
    
    # Warn user about data destruction for valid disk
    warning "WARNING: All data on $DISK will be destroyed!"
    read -r -p "Are you sure you want to continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        fatal "Installation cancelled by user"
    fi
}

get_filesystem_type() {
    info "Available filesystem types:"
    echo "1) ext4 (traditional, stable)"
    echo "2) btrfs (modern, with snapshots)"
    echo "3) xfs (high performance)"
    
    while true; do
        read -r -p "Select filesystem type (1-3): " choice
        case "$choice" in
            1) FILESYSTEM_TYPE="ext4"; break ;;
            2) FILESYSTEM_TYPE="btrfs"; break ;;
            3) FILESYSTEM_TYPE="xfs"; break ;;
            *) warning "Invalid choice. Please select 1, 2, or 3." ;;
        esac
    done
    
    success "Selected filesystem: $FILESYSTEM_TYPE"
    
    # Configure btrfs subvolumes if selected
    if [[ "$FILESYSTEM_TYPE" == "btrfs" ]]; then
        get_btrfs_layout
    fi
}

get_btrfs_layout() {
    info "Btrfs subvolume layout configuration:"
    echo "Default layout:"
    echo "  @ -> / (root)"
    echo "  @home -> /home"
    echo "  @log -> /var/log"
    echo "  @pkg -> /var/cache/pacman/pkg"
    echo
    
    read -r -p "Use default subvolume layout? (y/n): " use_default
    if [[ "$use_default" == "y" ]]; then
        success "Using default btrfs subvolume layout"
    else
        warning "Custom btrfs layouts not implemented in this version. Using default layout."
    fi
}

get_hostname() {
    while true; do
        read -r -p "Enter hostname for this system: " HOSTNAME
        if [[ -z "$HOSTNAME" ]]; then
            warning "Hostname cannot be empty"
            continue
        fi
        
        if validate_hostname "$HOSTNAME"; then
            break
        else
            warning "Invalid hostname. Use only letters, numbers, and hyphens."
        fi
    done
    
    success "Hostname set to: $HOSTNAME"
}

get_root_password() {
    while true; do
        read -r -s -p "Enter root password: " ROOT_PASSWORD
        echo
        if [[ ${#ROOT_PASSWORD} -lt 8 ]]; then
            warning "Password must be at least 8 characters long"
            continue
        fi
        
        read -r -s -p "Confirm root password: " confirm
        echo
        if [[ "$ROOT_PASSWORD" != "$confirm" ]]; then
            warning "Passwords do not match"
            continue
        fi
        
        break
    done
    
    success "Root password set"
}

get_user_configuration() {
    while true; do
        read -r -p "Enter username for standard user: " USERNAME
        if [[ -z "$USERNAME" ]]; then
            warning "Username cannot be empty"
            continue
        fi
        
        if validate_username "$USERNAME"; then
            break
        else
            warning "Invalid username. Use only lowercase letters, numbers, underscore, and hyphen."
        fi
    done
    
    while true; do
        read -r -s -p "Enter password for $USERNAME: " USER_PASSWORD
        echo
        if [[ ${#USER_PASSWORD} -lt 8 ]]; then
            warning "Password must be at least 8 characters long"
            continue
        fi
        
        read -r -s -p "Confirm password for $USERNAME: " confirm
        echo
        if [[ "$USER_PASSWORD" != "$confirm" ]]; then
            warning "Passwords do not match"
            continue
        fi
        
        break
    done
    
    read -r -p "Grant sudo privileges to $USERNAME? (y/n): " sudo_choice
    ENABLE_SUDO=$([ "$sudo_choice" = "y" ] && echo "yes" || echo "no")
    
    info "Available shells:"
    echo "1) bash (default)"
    echo "2) zsh (advanced features)"
    echo "3) fish (user-friendly)"
    
    while true; do
        read -r -p "Select shell for $USERNAME (1-3): " shell_choice
        case "$shell_choice" in
            1) USER_SHELL="bash"; break ;;
            2) USER_SHELL="zsh"; break ;;
            3) USER_SHELL="fish"; break ;;
            *) warning "Invalid choice. Please select 1, 2, or 3." ;;
        esac
    done
    
    success "User configuration completed"
}

get_bootloader_selection() {
    info "Available bootloaders:"
    echo "1) GRUB (traditional, widely supported)"
    echo "2) systemd-boot (simple, UEFI only)"
    echo "3) rEFInd (graphical, advanced)"
    
    while true; do
        read -r -p "Select bootloader (1-3): " choice
        case "$choice" in
            1) BOOTLOADER="grub"; break ;;
            2) BOOTLOADER="systemd-boot"; break ;;
            3) BOOTLOADER="refind"; break ;;
            *) warning "Invalid choice. Please select 1, 2, or 3." ;;
        esac
    done
    
    success "Selected bootloader: $BOOTLOADER"
}

detect_cpu_microcode() {
    info "Detecting CPU vendor for microcode..."
    
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        CPU_VENDOR="intel"
        success "Intel CPU detected - will install intel-ucode"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        CPU_VENDOR="amd"
        success "AMD CPU detected - will install amd-ucode"
    else
        CPU_VENDOR="unknown"
        warning "Unknown CPU vendor - no microcode will be installed"
    fi
}

get_multilib_preference() {
    info "Multilib repository provides 32-bit compatibility for 64-bit systems."
    info "This is useful for gaming, Wine, and some proprietary software."
    
    read -r -p "Enable multilib repository? (y/n): " multilib_choice
    ENABLE_MULTILIB=$([ "$multilib_choice" = "y" ] && echo "yes" || echo "no")
    
    if [[ "$ENABLE_MULTILIB" == "yes" ]]; then
        success "Multilib repository will be enabled"
    else
        info "Multilib repository will remain disabled"
    fi
}

#######################################
# Disk Management Functions
#######################################

create_partitions() {
    info "Creating partitions on $DISK"
    
    # Clear existing partition table
    wipefs -af "$DISK"
    
    # Create new GPT partition table
    parted "$DISK" --script mklabel gpt
    
    # Create EFI partition
    parted "$DISK" --script mkpart ESP fat32 1MiB "$EFI_SIZE"
    parted "$DISK" --script set 1 esp on
    
    # Create swap partition
    local swap_start=$EFI_SIZE
    local swap_end
    swap_end=$(( ${EFI_SIZE%M} + ${SWAP_SIZE%G} * 1024 ))M
    parted "$DISK" --script mkpart primary linux-swap "$swap_start" "$swap_end"
    
    # Create root partition (remaining space)
    parted "$DISK" --script mkpart primary "$FILESYSTEM_TYPE" "$swap_end" 100%
    
    # Wait for kernel to re-read partition table
    partprobe "$DISK"
    sleep 2
    
    success "Partitions created successfully"
}

format_partitions() {
    info "Formatting partitions"
    
    # Determine partition naming scheme
    local part_prefix=""
    if [[ "$DISK" =~ nvme ]]; then
        part_prefix="${DISK}p"
    else
        part_prefix="$DISK"
    fi
    
    local efi_partition="${part_prefix}1"
    local swap_partition="${part_prefix}2"
    local root_partition="${part_prefix}3"
    
    # Format EFI partition
    mkfs.fat -F32 "$efi_partition"
    
    # Create swap
    mkswap "$swap_partition"
    swapon "$swap_partition"
    
    # Format root partition based on filesystem type
    case "$FILESYSTEM_TYPE" in
        ext4)
            mkfs.ext4 -F "$root_partition"
            ;;
        btrfs)
            mkfs.btrfs -f "$root_partition"
            ;;
        xfs)
            mkfs.xfs -f "$root_partition"
            ;;
    esac
    
    success "Partitions formatted successfully"
}

mount_filesystems() {
    info "Mounting filesystems"
    
    # Determine partition naming scheme
    local part_prefix=""
    if [[ "$DISK" =~ nvme ]]; then
        part_prefix="${DISK}p"
    else
        part_prefix="$DISK"
    fi
    
    local efi_partition="${part_prefix}1"
    local root_partition="${part_prefix}3"
    
    # Mount root partition
    mount "$root_partition" "$MOUNT_POINT"
    
    # Create and mount EFI directory
    mkdir -p "$MOUNT_POINT/boot"
    mount "$efi_partition" "$MOUNT_POINT/boot"
    
    # Create btrfs subvolumes if using btrfs
    if [[ "$FILESYSTEM_TYPE" == "btrfs" ]]; then
        # Create subvolumes
        btrfs subvolume create "$MOUNT_POINT/@"
        btrfs subvolume create "$MOUNT_POINT/@home"
        btrfs subvolume create "$MOUNT_POINT/@log"
        btrfs subvolume create "$MOUNT_POINT/@pkg"
        
        # Remount with subvolumes
        umount "$MOUNT_POINT/boot"
        umount "$MOUNT_POINT"
        
        # Mount root subvolume
        mount -o subvol=@,compress=zstd,noatime "$root_partition" "$MOUNT_POINT"
        
        # Create mount points and mount subvolumes
        mkdir -p "$MOUNT_POINT/home"
        mkdir -p "$MOUNT_POINT/var/log"
        mkdir -p "$MOUNT_POINT/var/cache/pacman/pkg"
        
        mount -o subvol=@home,compress=zstd,noatime "$root_partition" "$MOUNT_POINT/home"
        mount -o subvol=@log,compress=zstd,noatime "$root_partition" "$MOUNT_POINT/var/log"
        mount -o subvol=@pkg,compress=zstd,noatime "$root_partition" "$MOUNT_POINT/var/cache/pacman/pkg"
        
        mkdir -p "$MOUNT_POINT/boot"
        mount "$efi_partition" "$MOUNT_POINT/boot"
    fi
    
    success "Filesystems mounted successfully"
}

#######################################
# System Installation Functions
#######################################

configure_pacman() {
    info "Configuring pacman"
    
    # Enable multilib if requested
    if [[ "$ENABLE_MULTILIB" == "yes" ]]; then
        info "Enabling multilib repository"
        sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/ s/^#//' "$MOUNT_POINT/etc/pacman.conf"
    fi
    
    # Update package database in chroot
    arch-chroot "$MOUNT_POINT" pacman -Sy --noconfirm
    
    success "Pacman configured successfully"
}

install_base_system() {
    info "Installing base system (minimal)"
    
    # Update package database
    pacman -Sy --noconfirm
    
    # Install only essential base packages
    local base_packages=(
        base
        linux
        linux-firmware
    )
    
    # Add CPU microcode
    case "$CPU_VENDOR" in
        intel)
            base_packages+=(intel-ucode)
            ;;
        amd)
            base_packages+=(amd-ucode)
            ;;
    esac
    
    # Add filesystem-specific packages
    case "$FILESYSTEM_TYPE" in
        btrfs)
            base_packages+=(btrfs-progs)
            ;;
        xfs)
            base_packages+=(xfsprogs)
            ;;
    esac
    
    # Install minimal base system
    pacstrap "$MOUNT_POINT" "${base_packages[@]}"
    
    success "Base system installed successfully"
}

install_additional_packages() {
    info "Installing additional essential packages"
    
    local additional_packages=(
        networkmanager
        sudo
        vim
        nano
    )
    
    # Add bootloader packages
    case "$BOOTLOADER" in
        grub)
            additional_packages+=(grub efibootmgr)
            ;;
        systemd-boot)
            # systemd-boot is included in systemd (part of base)
            ;;
        refind)
            additional_packages+=(refind)
            ;;
    esac
    
    # Add shell packages
    case "$USER_SHELL" in
        zsh)
            additional_packages+=(zsh zsh-completions)
            ;;
        fish)
            additional_packages+=(fish)
            ;;
    esac
    
    # Install additional packages
    arch-chroot "$MOUNT_POINT" pacman -S --noconfirm "${additional_packages[@]}"
    
    success "Additional packages installed successfully"
}

configure_system() {
    info "Configuring system"
    
    # Generate fstab
    genfstab -U "$MOUNT_POINT" >> "$MOUNT_POINT/etc/fstab"
    
    # Configure timezone (using systemd-timedatectl approach)
    arch-chroot "$MOUNT_POINT" ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    arch-chroot "$MOUNT_POINT" hwclock --systohc
    
    # Configure locale
    echo "en_US.UTF-8 UTF-8" >> "$MOUNT_POINT/etc/locale.gen"
    arch-chroot "$MOUNT_POINT" locale-gen
    echo "LANG=en_US.UTF-8" > "$MOUNT_POINT/etc/locale.conf"
    
    # Set hostname
    echo "$HOSTNAME" > "$MOUNT_POINT/etc/hostname"
    
    # Configure hosts file
    cat > "$MOUNT_POINT/etc/hosts" << EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	$HOSTNAME.localdomain	$HOSTNAME
EOF
    
    # Enable NetworkManager
    arch-chroot "$MOUNT_POINT" systemctl enable NetworkManager
    
    success "System configuration completed"
}

configure_bootloader() {
    info "Configuring bootloader: $BOOTLOADER"
    
    # Determine partition naming scheme
    local part_prefix=""
    if [[ "$DISK" =~ nvme ]]; then
        part_prefix="${DISK}p"
    else
        part_prefix="$DISK"
    fi
    
    case "$BOOTLOADER" in
        grub)
            # Install GRUB
            arch-chroot "$MOUNT_POINT" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
            
            # Generate GRUB configuration
            arch-chroot "$MOUNT_POINT" grub-mkconfig -o /boot/grub/grub.cfg
            ;;
        systemd-boot)
            # Install systemd-boot
            arch-chroot "$MOUNT_POINT" bootctl --path=/boot install
            
            # Create loader configuration
            mkdir -p "$MOUNT_POINT/boot/loader/entries"
            cat > "$MOUNT_POINT/boot/loader/loader.conf" << EOF
default arch.conf
timeout 3
console-mode max
editor no
EOF
            
            # Get root partition UUID
            local root_uuid
            root_uuid=$(blkid -s UUID -o value "${part_prefix}3")
            
            # Create boot entry
            cat > "$MOUNT_POINT/boot/loader/entries/arch.conf" << EOF
title Arch Linux
linux /vmlinuz-linux
EOF
            
            # Add microcode if available
            case "$CPU_VENDOR" in
                intel)
                    echo "initrd /intel-ucode.img" >> "$MOUNT_POINT/boot/loader/entries/arch.conf"
                    ;;
                amd)
                    echo "initrd /amd-ucode.img" >> "$MOUNT_POINT/boot/loader/entries/arch.conf"
                    ;;
            esac
            
            echo "initrd /initramfs-linux.img" >> "$MOUNT_POINT/boot/loader/entries/arch.conf"
            
            if [[ "$FILESYSTEM_TYPE" == "btrfs" ]]; then
                echo "options root=UUID=$root_uuid rw rootflags=subvol=@" >> "$MOUNT_POINT/boot/loader/entries/arch.conf"
            else
                echo "options root=UUID=$root_uuid rw" >> "$MOUNT_POINT/boot/loader/entries/arch.conf"
            fi
            ;;
        refind)
            # Install rEFInd
            arch-chroot "$MOUNT_POINT" refind-install
            ;;
    esac
    
    success "Bootloader ($BOOTLOADER) configured successfully"
}

configure_users() {
    info "Configuring users"
    
    # Set root password
    echo "root:$ROOT_PASSWORD" | arch-chroot "$MOUNT_POINT" chpasswd
    
    # Create user
    arch-chroot "$MOUNT_POINT" useradd -m -s "/bin/$USER_SHELL" "$USERNAME"
    echo "$USERNAME:$USER_PASSWORD" | arch-chroot "$MOUNT_POINT" chpasswd
    
    # Configure sudo if requested
    if [[ "$ENABLE_SUDO" == "yes" ]]; then
        echo "$USERNAME ALL=(ALL:ALL) ALL" >> "$MOUNT_POINT/etc/sudoers.d/$USERNAME"
        chmod 440 "$MOUNT_POINT/etc/sudoers.d/$USERNAME"
    fi
    
    # Install and configure shell-specific configurations
    case "$USER_SHELL" in
        zsh)
            # Create basic zsh config
            cat > "$MOUNT_POINT/home/$USERNAME/.zshrc" << 'EOF'
# Basic zsh configuration
autoload -Uz compinit
compinit

# History configuration
HISTSIZE=1000
SAVEHIST=1000
HISTFILE=~/.zsh_history
setopt appendhistory

# Basic prompt
PS1='%n@%m:%~$ '
EOF
            chown 1000:1000 "$MOUNT_POINT/home/$USERNAME/.zshrc"
            ;;
        fish)
            # Create fish config directory
            mkdir -p "$MOUNT_POINT/home/$USERNAME/.config/fish"
            cat > "$MOUNT_POINT/home/$USERNAME/.config/fish/config.fish" << 'EOF'
# Basic fish configuration
set fish_greeting ""
EOF
            arch-chroot "$MOUNT_POINT" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"
            ;;
    esac
    
    success "Users configured successfully"
}

#######################################
# Main Installation Flow
#######################################

cleanup() {
    info "Performing cleanup"
    
    # Unmount filesystems
    if mountpoint -q "$MOUNT_POINT/boot"; then
        umount "$MOUNT_POINT/boot"
    fi
    
    if [[ "$FILESYSTEM_TYPE" == "btrfs" ]]; then
        if mountpoint -q "$MOUNT_POINT/home"; then
            umount "$MOUNT_POINT/home"
        fi
        if mountpoint -q "$MOUNT_POINT/var/log"; then
            umount "$MOUNT_POINT/var/log"
        fi
        if mountpoint -q "$MOUNT_POINT/var/cache/pacman/pkg"; then
            umount "$MOUNT_POINT/var/cache/pacman/pkg"
        fi
    fi
    
    if mountpoint -q "$MOUNT_POINT"; then
        umount "$MOUNT_POINT"
    fi
    
    # Turn off swap
    swapoff -a 2>/dev/null || true
}

main() {
    info "Starting Arch Linux installation"
    
    # Set up cleanup trap
    trap cleanup EXIT
    
    # Pre-installation checks
    validate_uefi_boot
    validate_network
    
    # Collect user input
    get_disk_selection
    get_filesystem_type
    get_hostname
    get_root_password
    get_user_configuration
    get_bootloader_selection
    detect_cpu_microcode
    get_multilib_preference
    
    # Confirm installation
    info "Installation Summary:"
    echo "Disk: $DISK"
    echo "Filesystem: $FILESYSTEM_TYPE"
    echo "Hostname: $HOSTNAME"
    echo "Username: $USERNAME"
    echo "User Shell: $USER_SHELL"
    echo "Sudo Access: $ENABLE_SUDO"
    echo "Bootloader: $BOOTLOADER"
    echo "CPU Microcode: $CPU_VENDOR"
    echo "Multilib: $ENABLE_MULTILIB"
    echo
    
    read -r -p "Proceed with installation? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        fatal "Installation cancelled by user"
    fi
    
    # Disk operations
    create_partitions
    format_partitions
    mount_filesystems
    
    # System installation
    install_base_system
    configure_system
    configure_pacman
    install_additional_packages
    configure_bootloader
    configure_users
    
    success "Arch Linux installation completed successfully!"
    info "System is ready to boot. Remove installation media and reboot."
    
    read -r -p "Reboot now? (y/n): " reboot_choice
    if [[ "$reboot_choice" == "y" ]]; then
        reboot
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi