#!/bin/bash

#===========================================================
# Arch Linux Installation Script
#===========================================================

readonly LOG_FILE="/var/log/archinstall.log"
readonly MIN_DISK_SIZE=$((20 * 1024 * 1024 * 1024)) # 20GB in bytes

#-----------------------------------------------------------
# Core Utilities
#-----------------------------------------------------------

init_log() {
    # Skip in testing mode
    if [[ "${TESTING:-0}" == "1" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

log() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # In testing mode, just echo without tee
    if [[ "${TESTING:-0}" == "1" ]]; then
        echo "[$timestamp] $message"
    else
        echo "[$timestamp] $message" | tee -a "$LOG_FILE"
    fi
}

handle_error() {
    local exit_code=$?
    local line_number=$1
    log "ERROR on line $line_number: Command exited with status $exit_code"
    log "Installation failed. See log file at $LOG_FILE for details."
    exit $exit_code
}

prompt() {
    local message="$1"
    local varname="$2"
    echo "$message" > /dev/tty
    read -r "$varname" < /dev/tty
}

confirm_operation() {
    local message="$1"
    local response
    prompt "$message (yes/no): " response
    if [[ ! "$response" =~ ^[Yy][Ee][Ss]|[Yy]$ ]]; then
        log "Operation cancelled by user"
        return 1
    fi
    return 0
}

#-----------------------------------------------------------
# Validation Functions
#-----------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR: This script must be run as root"
        exit 1
    fi
}

check_boot_media() {
    if [ -d /run/archiso ]; then
        return 0
    fi
    for arg in "$@"; do
        if [ "$arg" = "--unsupported-boot-media" ]; then
            log "WARNING: Unofficial boot media detected, proceeding as requested"
            return 0
        fi
    done
    log "ERROR: Unofficial boot media detected. This script requires official Arch ISO."
    log "To override, rerun with the --unsupported-boot-media flag."
    exit 1
}

check_internet() {
    log "Checking internet connectivity..."
    if ! ping -c 1 archlinux.org &>/dev/null; then
        log "ERROR: No internet connection detected"
        exit 1
    fi
    log "Internet connection verified"
}

check_uefi() {
    if [[ ! -d /sys/firmware/efi ]]; then
        log "ERROR: System not booted in UEFI mode"
        exit 1
    fi
    log "UEFI boot mode verified"
}

verify_disk_space() {
    local disk="$1"
    if [[ ! -b "$disk" ]]; then
        log "ERROR: Disk $disk does not exist or is not a block device"
        return 1
    fi
    local disk_size
    disk_size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
    if [[ "$disk_size" -eq 0 ]]; then
        disk_size=$(lsblk -b -n -o SIZE "$disk" 2>/dev/null | head -n1 || echo 0)
    fi
    local disk_model
    disk_model=$(lsblk -n -o MODEL "$disk" 2>/dev/null | tr -d ' ' || echo "")
    if [[ "$disk_model" == *"QEMU"* || "$disk_model" == *"VBOX"* ]]; then
        log "QEMU/VirtualBox disk detected: $disk. Skipping size verification."
        return 0
    fi
    if ((disk_size < MIN_DISK_SIZE)); then
        if command -v numfmt >/dev/null 2>&1; then
            log "ERROR: Disk size ($(numfmt --to=iec-i --suffix=B ${disk_size})) is too small."
            log "Minimum required: $(numfmt --to=iec-i --suffix=B ${MIN_DISK_SIZE})"
        else
            log "ERROR: Disk size (${disk_size} bytes) is too small."
            log "Minimum required: ${MIN_DISK_SIZE} bytes (approx. 20GB)"
        fi
        return 1
    fi
    if command -v numfmt >/dev/null 2>&1; then
        log "Disk size verified: $(numfmt --to=iec-i --suffix=B ${disk_size})"
    else
        log "Disk size verified: ${disk_size} bytes"
    fi
    return 0
}

#-----------------------------------------------------------
# Disk and Partition Management
#-----------------------------------------------------------

create_disk_menu() {
    log "Listing available disks for selection..."
    echo "Available Disks (excluding loop devices and CD-ROMs):" > /dev/tty
    lsblk -d -p -n -o NAME,SIZE,MODEL,TYPE | grep -E "disk" | grep -v loop | nl > /dev/tty
    prompt "Enter the number corresponding to your disk: " disk_number
    if [[ ! "$disk_number" =~ ^[0-9]+$ ]] || [[ "$disk_number" -eq 0 ]]; then
        log "Invalid input: must be a positive number"
        create_disk_menu
        return
    fi
    selected_disk=$(lsblk -d -p -n -o NAME,TYPE | grep disk | grep -v loop | awk '{print $1}' | sed -n "${disk_number}p")
    if [[ -z "$selected_disk" ]]; then
        log "Invalid disk selection"
        create_disk_menu
        return
    fi
    log "Selected disk: $selected_disk"
    verify_disk_space "$selected_disk" || {
        log "Please select a larger disk"
        create_disk_menu
    }
}

get_partition_name() {
    local disk="$1"
    local part_num="$2"
    if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ ]]; then
        echo "${disk}p${part_num}"
    else
        echo "${disk}${part_num}"
    fi
}

wipe_partitions() {
    local disk="$1"
    if [[ ! -b "$disk" ]]; then
        log "ERROR: Disk $disk does not exist or is not a block device"
        exit 1
    fi
    log "Checking for mounted partitions on $disk..."
    local mounted_parts
    mounted_parts=$(lsblk -n -o NAME,MOUNTPOINT "$disk" 2>/dev/null | awk '$2 != "" {print $1}' || echo "")
    if [[ -n "$mounted_parts" ]]; then
        log "The following partitions are currently mounted:"
        lsblk -n -o NAME,MOUNTPOINT "$disk" 2>/dev/null | grep -v "^$disk " > /dev/tty
    fi
    local disk_model
    disk_model=$(lsblk -n -o MODEL "$disk" 2>/dev/null | tr -d ' ' || echo "")
    if [[ "$disk_model" == *"QEMU"* || "$disk_model" == *"VBOX"* ]]; then
        log "QEMU/VirtualBox disk detected: $disk. Proceeding without confirmation."
    else
        if ! confirm_operation "WARNING: All data on $disk will be erased. Continue?"; then
            exit 1
        fi
    fi
    log "Unmounting partitions and disabling swap on $disk..."
    local partitions
    partitions=$(lsblk -n -o NAME "$disk" 2>/dev/null | grep -v "^$(basename "$disk")$" || echo "")
    if [[ -n "$partitions" ]]; then
        for part in $partitions; do
            if [[ -b "/dev/$part" ]]; then
                log "Unmounting /dev/$part if mounted..."
                umount -f "/dev/$part" 2>/dev/null || true
                swapoff "/dev/$part" 2>/dev/null || true
            fi
        done
    else
        log "No partitions found on $disk"
    fi
    log "Wiping disk signatures on $disk..."
    if ! wipefs -a "$disk" 2>/dev/null; then
        log "WARNING: Failed to wipe disk signatures, attempting alternative method"
        dd if=/dev/zero of="$disk" bs=512 count=1 conv=notrunc 2>/dev/null || {
            log "ERROR: Failed to zero out disk. Continuing anyway..."
        }
    fi
    log "Creating new GPT partition table on $disk..."
    if ! parted -s "$disk" mklabel gpt 2>/dev/null; then
        log "WARNING: Failed with parted, trying fdisk alternative"
        echo -e "g\nw\n" | fdisk "$disk" 2>/dev/null || {
            log "ERROR: All methods to create GPT table failed. Aborting."
            exit 1
        }
    fi
    if ! parted -s "$disk" print 2>/dev/null | grep -q "Partition Table: gpt"; then
        log "WARNING: GPT partition table may not have been created correctly"
    fi
    log "Disk $disk has been prepared with a clean GPT partition table"
    sleep 2
}

calculate_swap_size() {
    local ram_kB
    ram_kB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local swap_mib=$(( ram_kB / 2 / 1024 ))
    echo "$swap_mib"
}

perform_partitioning() {
    local disk="$1"
    local choice="$2"
    local swap_size
    swap_size=$(calculate_swap_size)
    log "Calculating swap size: ${swap_size}MiB"
    case "$choice" in
        "auto_btrfs")
            log "Performing automatic partitioning (BTRFS) on $disk"
            local esp=$(get_partition_name "$disk" 1)
            local swp=$(get_partition_name "$disk" 2)
            local root=$(get_partition_name "$disk" 3)
            log "Creating partitions..."
            parted -s "$disk" mkpart primary fat32 1MiB 513MiB || { log "ERROR: Failed to create EFI partition"; exit 1; }
            parted -s "$disk" set 1 esp on || { log "ERROR: Failed to set ESP flag"; exit 1; }
            parted -s "$disk" mkpart primary linux-swap 513MiB "$((513 + swap_size))MiB" || { log "ERROR: Failed to create swap partition"; exit 1; }
            parted -s "$disk" mkpart primary btrfs "$((513 + swap_size))MiB" 100% || { log "ERROR: Failed to create root partition"; exit 1; }
            log "Refreshing partition table..."
            partprobe "$disk" || { log "ERROR: Failed to refresh partition table"; sleep 2; }
            log "Wiping filesystem signatures from new partitions..."
            wipefs -a "$esp" "$swp" "$root" || { log "WARNING: Failed to wipe some filesystem signatures"; }
            log "Formatting EFI partition ($esp)..."
            mkfs.fat -F32 "$esp" || { log "ERROR: Failed to format EFI partition"; exit 1; }
            log "Creating and activating swap ($swp)..."
            mkswap "$swp" || { log "ERROR: Failed to create swap"; exit 1; }
            swapon "$swp" || { log "WARNING: Failed to activate swap"; }
            log "Formatting BTRFS root partition ($root)..."
            mkfs.btrfs -f "$root" || { log "ERROR: Failed to format BTRFS partition"; exit 1; }
            log "Creating BTRFS subvolumes..."
            mount "$root" /mnt || { log "ERROR: Failed to mount BTRFS root partition"; exit 1; }
            btrfs subvolume create /mnt/@ && \
            btrfs subvolume create /mnt/@home && \
            btrfs subvolume create /mnt/@log && \
            btrfs subvolume create /mnt/@pkg && \
            btrfs subvolume create /mnt/@snapshots || {
                log "ERROR: Failed to create BTRFS subvolumes"
                umount /mnt
                exit 1
            }
            umount /mnt
            local btrfs_opts="noatime,discard=async,compress=zstd,space_cache=v2"
            log "Mounting BTRFS subvolumes..."
            mount -o "subvol=@,$btrfs_opts" "$root" /mnt || { log "ERROR: Failed to mount @ subvolume"; exit 1; }
            mkdir -p /mnt/{boot/efi,home,var/log,var/cache/pacman/pkg,.snapshots} || { log "ERROR: Failed to create mount directories"; exit 1; }
            mount -o "subvol=@home,$btrfs_opts" "$root" /mnt/home && \
            mount -o "subvol=@log,$btrfs_opts" "$root" /mnt/var/log && \
            mount -o "subvol=@pkg,$btrfs_opts" "$root" /mnt/var/cache/pacman/pkg && \
            mount -o "subvol=@snapshots,$btrfs_opts" "$root" /mnt/.snapshots || { log "ERROR: Failed to mount BTRFS subvolumes"; exit 1; }
            mount "$esp" /mnt/boot/efi || { log "ERROR: Failed to mount EFI partition"; exit 1; }
            log "All partitions created and mounted successfully"
            ;;
        "manual")
            log "Launching cfdisk for manual partitioning on $disk..."
            cfdisk "$disk"
            log "Manual partitioning completed. You must format and mount partitions yourself."
            log "IMPORTANT: Mount your root partition to /mnt and any others as needed."
            log "Press Enter when all partitions are mounted and ready to proceed."
            read -r < /dev/tty
            if ! mountpoint -q /mnt; then
                log "ERROR: /mnt is not mounted. Mount your root partition to /mnt first."
                exit 1
            fi
            if ! mountpoint -q /mnt/efi && ! mountpoint -q /mnt/boot/efi; then
                log "ERROR: EFI partition not mounted at /mnt/efi or /mnt/boot/efi"
                exit 1
            fi
            ;;
    esac
}

#-----------------------------------------------------------
# SYSTEM INSTALLATION
#-----------------------------------------------------------

select_install_packages() {
    # Minimal base system for pacstrap
    base_pkgs=(base linux linux-firmware)
    
    # Additional packages to install after base system (including btrfs-progs by default)
    additional_pkgs=(sudo grub efibootmgr networkmanager zsh git base-devel btrfs-progs)
    
    # Detect and add microcode package
    microcode_pkg=""
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        microcode_pkg="intel-ucode"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        microcode_pkg="amd-ucode"
    fi
    [[ -n "$microcode_pkg" ]] && additional_pkgs+=("$microcode_pkg")
    
    # Zsh is now default - no need to ask
    default_shell="zsh"
    log "Zsh will be installed and set as the default shell with zinit framework"
    log "BTRFS filesystem will be used with btrfs-progs tools included"
    
    # Enable multilib and pacman improvements by default
    enable_multilib="yes"
    improve_pacman="yes"
    log "Multilib repository will be enabled by default"
    log "Pacman improvements (colors and parallel downloads) will be enabled by default"
    
    export base_pkgs additional_pkgs
}

install_base_system() {
    if ! mountpoint -q /mnt; then
        log "ERROR: /mnt is not mounted. Cannot install base system."
        return 1
    fi
    
    # Install minimal base system first
    log "Installing minimal base system: ${base_pkgs[*]}"
    if ! pacstrap -K /mnt "${base_pkgs[@]}"; then
        log "ERROR: Failed to install minimal base system"
        return 1
    fi
    
    log "Generating fstab..."
    if ! genfstab -U /mnt >> /mnt/etc/fstab; then
        log "ERROR: Failed to generate fstab"
        return 1
    fi
    
    # Enable repositories before installing additional packages
    if [[ "$enable_multilib" =~ ^[Yy][Ee][Ss]|[Yy]$ ]]; then
        enable_multilib_repository
    fi
    if [[ "$improve_pacman" =~ ^[Yy][Ee][Ss]|[Yy]$ ]]; then
        configure_pacman_improvements
    fi
    
    # Install additional packages
    log "Installing additional packages: ${additional_pkgs[*]}"
    if ! arch-chroot /mnt pacman -S --noconfirm "${additional_pkgs[@]}"; then
        log "ERROR: Failed to install additional packages"
        return 1
    fi
    
    log "Base system and additional packages installed successfully"
    return 0
}

enable_multilib_repository() {
    log "Enabling multilib repository..."
    local pacman_conf="/mnt/etc/pacman.conf"
    if grep -q "^\[multilib\]" "$pacman_conf"; then
        log "Multilib repository is already enabled"
        return 0
    fi
    if grep -q "^#\[multilib\]" "$pacman_conf"; then
        log "Uncommenting existing multilib section"
        sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "$pacman_conf"
    else
        log "Adding multilib section to pacman.conf"
        cat >> "$pacman_conf" <<EOF

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
    fi
    log "Updating package database with multilib repository..."
    arch-chroot /mnt pacman -Sy || { log "WARNING: Failed to update package database with multilib repository"; }
    log "Multilib repository enabled successfully"
}

configure_pacman_improvements() {
    log "Applying pacman improvements..."
    local pacman_conf="/mnt/etc/pacman.conf"
    if grep -q "^#Color" "$pacman_conf"; then
        log "Enabling colored output in pacman"
        sed -i 's/^#Color/Color/' "$pacman_conf"
    elif ! grep -q "^Color" "$pacman_conf"; then
        log "Adding Color option to pacman.conf"
        sed -i '/\[options\]/a Color' "$pacman_conf"
    fi
    if grep -q "^#ParallelDownloads" "$pacman_conf"; then
        log "Setting parallel downloads to 5"
        sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' "$pacman_conf"
    elif ! grep -q "^ParallelDownloads" "$pacman_conf"; then
        log "Adding ParallelDownloads option to pacman.conf"
        sed -i '/\[options\]/a ParallelDownloads = 5' "$pacman_conf"
    fi
    log "Pacman improvements applied successfully"
}

configure_initramfs() {
    log "Tweaking mkinitcpio.conf and generating initramfs exactly ONCE."
    local mkinitcpio_conf="/mnt/etc/mkinitcpio.conf"
    if [[ ! -f "$mkinitcpio_conf" ]]; then
        log "ERROR: mkinitcpio.conf missing after pacstrap. What the hell did you do?"
        return 1
    fi
    if [[ "$partition_choice" == "auto_btrfs" ]]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard btrfs fsck)/' "$mkinitcpio_conf"
        log "Added 'btrfs' hook to mkinitcpio.conf"
    fi
    arch-chroot /mnt mkinitcpio -P || { log "ERROR: mkinitcpio failed to generate initramfs. Hope you like black screens."; return 1; }
    log "Initramfs generated. If this took forever, blame your potato CPU."
    return 0
}

install_bootloader() {
    log "Installing GRUB bootloader..."
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory="/boot/efi" --bootloader-id=GRUB || {
        log "ERROR: Failed to install GRUB bootloader"
        return 1
    }
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg || { log "ERROR: Failed to generate GRUB configuration"; return 1; }
    log "Bootloader installed and configured."
    return 0
}

setup_network() {
    if ! mountpoint -q /mnt; then
        log "ERROR: /mnt is not mounted. Cannot configure network."
        return 1
    fi
    log "Enabling NetworkManager..."
    arch-chroot /mnt systemctl enable NetworkManager.service || log "WARNING: Failed to enable NetworkManager. Do it yourself later."
    return 0
}

configure_system() {
    if ! mountpoint -q /mnt; then
        log "ERROR: /mnt is not mounted. Cannot configure system."
        return 1
    fi
    log "Configuring system settings..."
    locales=(
        "en_US.UTF-8 UTF-8"
        "en_GB.UTF-8 UTF-8"
        "fr_FR.UTF-8 UTF-8"
        "de_DE.UTF-8 UTF-8"
    )
    echo "Available Locales:" > /dev/tty
    for i in "${!locales[@]}"; do
        echo "$((i + 1)). ${locales[$i]}" > /dev/tty
    done
    while :; do
        prompt "Select your locale (1-${#locales[@]}): " locale_choice
        if [[ "$locale_choice" =~ ^[0-9]+$ ]] && (( locale_choice >= 1 && locale_choice <= ${#locales[@]} )); then
            selected_locale="${locales[$((locale_choice - 1))]}"
            break
        else
            log "Invalid choice. Please enter a number between 1 and ${#locales[@]}."
        fi
    done
    log "Setting up locale: $selected_locale"
    echo "$selected_locale" > /mnt/etc/locale.gen || { log "ERROR: Failed to create locale.gen"; return 1; }
    arch-chroot /mnt locale-gen || { log "ERROR: Failed to generate locales"; return 1; }
    echo "LANG=$(echo "$selected_locale" | awk '{print $1}')" > /mnt/etc/locale.conf || { log "ERROR: Failed to set locale.conf"; return 1; }
    prompt "Enter your desired hostname: " hostname
    echo "$hostname" > /mnt/etc/hostname || { log "ERROR: Failed to set hostname"; return 1; }
    {
        echo "127.0.0.1    localhost"
        echo "::1          localhost"
        echo "127.0.1.1    $hostname.localdomain $hostname"
    } > /mnt/etc/hosts || { log "ERROR: Failed to configure hosts file"; return 1; }
    log "Setting timezone..."
    local timezone
    timezone=$(curl -s https://ipapi.co/timezone 2>/dev/null)
    if [[ -z "$timezone" || ! -f "/mnt/usr/share/zoneinfo/$timezone" ]]; then
        log "Could not auto-detect timezone. Please enter it manually."
        prompt "Enter your timezone (e.g., America/New_York): " timezone
        while [[ ! -f "/mnt/usr/share/zoneinfo/$timezone" ]]; do
            log "Invalid timezone '$timezone'. Please try again."
            prompt "Enter your timezone (e.g., America/New_York): " timezone
        done
    fi
    arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime || { log "ERROR: Failed to set timezone to $timezone"; return 1; }
    arch-chroot /mnt hwclock --systohc || { log "WARNING: Failed to set hardware clock"; }
    log "Setting root password (you will be prompted in chroot):"
    while ! arch-chroot /mnt passwd; do
        log "Password setting failed. Please try again."
    done
    log "System configuration completed successfully"
    return 0
}

setup_systemwide_zshenv() {
    log "Writing system-wide /etc/zsh/zshenv for strict XDG and ZDOTDIR"
    arch-chroot /mnt mkdir -p /etc/zsh
    cat > /mnt/etc/zsh/zshenv <<'EOF'
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"
EOF
}

set_systemwide_default_shell() {
    log "Setting system-wide default shell to zsh for new users"
    sed -i 's|^SHELL=.*|SHELL=/usr/bin/zsh|' /mnt/etc/default/useradd
}

set_root_shell() {
    log "Setting root shell to zsh"
    arch-chroot /mnt chsh -s /usr/bin/zsh root
}

create_user_account() {
    local username
    while true; do
        prompt "Enter username (lowercase letters, numbers, or underscore, 3-32 chars): " username
        if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]{2,31}$ ]]; then
            log "ERROR: Invalid username format. Please try again."
            continue
        fi
        if grep -q "^$username:" /mnt/etc/passwd 2>/dev/null; then
            log "ERROR: Username '$username' already exists."
            continue
        fi
        local reserved_names=("root" "daemon" "bin" "sys" "sync" "games" "man" "lp" "mail" "news" "uucp" "proxy" "www-data" "backup" "list" "irc" "gnats" "nobody" "systemd-network" "systemd-resolve" "messagebus" "systemd-timesync" "polkitd")
        if [[ " ${reserved_names[@]} " =~ " ${username} " ]]; then
            log "ERROR: Username '$username' is reserved. Please choose another."
            continue
        fi
        break
    done
    log "Creating user account for $username with $default_shell as default shell..."
    arch-chroot /mnt useradd -mG wheel -s "/bin/$default_shell" "$username" || { log "ERROR: Failed to create user account"; return 1; }
    log "Setting password for user $username..."
    while ! arch-chroot /mnt passwd "$username"; do
        log "Password setting failed. Please try again."
    done
    # Export username for use in other functions
    export username
    return 0
}

configure_sudo_access() {
    local sudoers_dropin="/mnt/etc/sudoers.d/99_wheel_nopasswd"
    log "Configuring sudo access with a drop-in..."
    if [[ ! -d "/mnt/etc/sudoers.d" ]]; then
        mkdir -p /mnt/etc/sudoers.d || { log "ERROR: Failed to create /mnt/etc/sudoers.d"; return 1; }
    fi
    echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > "$sudoers_dropin" || { log "ERROR: Failed to write $sudoers_dropin"; return 1; }
    chmod 0440 "$sudoers_dropin" || { log "ERROR: Failed to chmod 0440 $sudoers_dropin"; return 1; }
    perms=$(stat -c "%a" "$sudoers_dropin")
    if [[ "$perms" != "440" ]]; then
        log "ERROR: $sudoers_dropin perms are $perms, should be 440."
        prompt "Want me to fix it for you, or you want to screw around with it yourself? (yes to fix / no to rage quit): " fix_perm
        if [[ "$fix_perm" =~ ^[Yy][Ee][Ss]|[Yy]$ ]]; then
            chmod 0440 "$sudoers_dropin"
            perms=$(stat -c "%a" "$sudoers_dropin")
            if [[ "$perms" == "440" ]]; then
                log "I fixed it. You're welcome. Next time, RTFM."
            else
                log "Still fucked. You're on your own."
                return 1
            fi
        else
            log "Fine. Not fixing shit. Exiting."
            return 1
        fi
    fi
    if ! arch-chroot /mnt visudo -cf /etc/sudoers; then
        log "ERROR: Main sudoers syntax broken. Undo your crimes."
        return 1
    fi
    if ! arch-chroot /mnt visudo -cf /etc/sudoers.d/99_wheel_nopasswd; then
        log "ERROR: Drop-in sudoers file syntax broken. RTFM and try again."
        return 1
    fi
    log "Sudo access configured successfully with NOPASSWD for wheel group."
    return 0
}

setup_user_accounts() {
    log "Setting up user accounts..."
    create_user_account || { log "ERROR: Failed to create user account"; return 1; }
    configure_sudo_access || { log "ERROR: Failed to configure sudo access"; return 1; }
    setup_zsh_enhancements "$username" || { log "ERROR: Failed to setup zsh enhancements"; return 1; }
    log "User account setup completed successfully"
    return 0
}

setup_zinit_framework() {
    log "Setting up zinit framework for zsh..."
    local username="$1"
    local user_home="/mnt/home/$username"
    local zdotdir="$user_home/.config/zsh"
    local zinit_home="$user_home/.local/share/zinit"
    
    # Create necessary directories
    arch-chroot /mnt mkdir -p "$zdotdir" "$zinit_home" "$user_home/.cache/zsh" || { 
        log "ERROR: Failed to create zsh directories"; return 1; 
    }
    
    # Install zinit using the preferred method with conditional logic
    log "Installing zinit framework..."
    arch-chroot /mnt bash -c "
        cd '$zinit_home'
        if [[ ! -d zinit.git ]]; then
            git clone https://github.com/zdharma-continuum/zinit.git zinit.git
        fi
        chown -R $username:$username '$user_home/.local' '$user_home/.config' '$user_home/.cache'
    " || { log "ERROR: Failed to install zinit"; return 1; }
    
    log "Zinit framework installed successfully"
    return 0
}

create_zsh_config() {
    log "Creating starter zsh configuration..."
    local username="$1"
    local user_home="/mnt/home/$username"
    local zdotdir="$user_home/.config/zsh"
    
    # Create .zshrc with sensible defaults and zinit setup
    cat > "$zdotdir/.zshrc" <<'EOF'
#!/usr/bin/env zsh

# Zinit setup
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
if [[ ! -d "$ZINIT_HOME" ]]; then
    mkdir -p "$(dirname "$ZINIT_HOME")"
    git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
fi
source "${ZINIT_HOME}/zinit.zsh"

# Load zsh-completions before compinit
zinit ice wait lucid
zinit load zsh-users/zsh-completions

# Completion settings (with custom compdump location in ~/.cache/zsh)
autoload -Uz compinit
compinit -d "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump-$ZSH_VERSION"
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu select

# Essential plugins
zinit light zsh-users/zsh-autosuggestions
zinit light zsh-users/zsh-syntax-highlighting

# History settings
HISTFILE="${ZDOTDIR:-$HOME}/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_SAVE_NO_DUPS
setopt SHARE_HISTORY
setopt APPEND_HISTORY
setopt INC_APPEND_HISTORY

# Key bindings
bindkey '^[[A' history-search-backward
bindkey '^[[B' history-search-forward
bindkey '^[[1;5C' forward-word
bindkey '^[[1;5D' backward-word

# Aliases
alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# Modern replacements (install if available)
if command -v exa &> /dev/null; then
    alias ls='exa'
    alias ll='exa -la'
    alias tree='exa --tree'
fi

if command -v bat &> /dev/null; then
    alias cat='bat'
fi

if command -v fd &> /dev/null; then
    alias find='fd'
fi

# Prompt setup (simple but effective)
setopt PROMPT_SUBST
autoload -U colors && colors

# Simple but informative prompt
PROMPT='%{$fg[cyan]%}%n%{$reset_color%}@%{$fg[blue]%}%m%{$reset_color%}:%{$fg[yellow]%}%~%{$reset_color%}$ '

# Right prompt with git branch if available
autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats '%b'
RPROMPT='%{$fg[green]%}${vcs_info_msg_0_}%{$reset_color%}'

# Environment variables
export EDITOR='nvim'
export PAGER='less'
export LESS='-R'

# Zinit optimization
zinit cdreplay -q
EOF

    # Create root's zsh config as well
    local root_zdotdir="/mnt/root/.config/zsh"
    arch-chroot /mnt mkdir -p "$root_zdotdir" "/root/.cache/zsh" "/root/.local/share/zinit"
    cp "$zdotdir/.zshrc" "$root_zdotdir/.zshrc"
    
    # Install zinit for root too
    arch-chroot /mnt bash -c "
        cd /root/.local/share/zinit
        if [[ ! -d zinit.git ]]; then
            git clone https://github.com/zdharma-continuum/zinit.git zinit.git
        fi
    "
    
    # Set proper ownership
    arch-chroot /mnt chown -R "$username:$username" "$user_home/.config" "$user_home/.cache" "$user_home/.local"
    arch-chroot /mnt chown -R root:root "/root/.config" "/root/.cache" "/root/.local"
    
    log "Zsh configuration created successfully"
    return 0
}

setup_zsh_enhancements() {
    log "Setting up zsh enhancements..."
    local username="$1"
    
    # Setup zinit framework
    setup_zinit_framework "$username" || { log "ERROR: Failed to setup zinit"; return 1; }
    
    # Create zsh configuration
    create_zsh_config "$username" || { log "ERROR: Failed to create zsh config"; return 1; }
    
    log "Zsh enhancements setup completed successfully"
    return 0
}

#-----------------------------------------------------------
# MAIN INSTALL PROCESS
#-----------------------------------------------------------

main() {
    log "Starting Arch Linux installation..."
    check_internet || exit 1
    check_uefi || exit 1
    create_disk_menu
    wipe_partitions "$selected_disk"
    # Always use BTRFS partitioning (no prompt)
    partition_choice="auto_btrfs"
    log "Using automatic BTRFS partitioning"
    perform_partitioning "$selected_disk" "$partition_choice"
    select_install_packages
    install_base_system || exit 1
    configure_initramfs || exit 1
    setup_network || exit 1
    configure_system || exit 1
    set_root_shell || exit 1
    setup_systemwide_zshenv || exit 1
    set_systemwide_default_shell || exit 1
    setup_user_accounts || exit 1
    install_bootloader || exit 1
    log "Installation completed successfully!"
    log "You can now reboot into your new Arch Linux system."
    log "Remember to remove the installation media before rebooting."
}

#-----------------------------------------------------------
# Script Initialization
#-----------------------------------------------------------

# Only run if not in testing mode
if [[ "${TESTING:-0}" != "1" ]]; then
    trap 'handle_error ${LINENO}' ERR
    check_root
    init_log
    check_boot_media "$@"
    main
    exit 0
fi
