#!/usr/bin/env bash

# Robust Arch Linux base installer – improved version
set -Eeuo pipefail

#######################################
# Global configuration and constants
#######################################
readonly SCRIPT_NAME="archinstall"
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"
readonly MOUNT_POINT="/mnt"
readonly DEFAULT_EFI_SIZE="512M"
readonly DEFAULT_SWAP_SIZE="2G"

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Runtime variables (initially empty)
DISK=""
FILESYSTEM_TYPE=""
ROOT_PASSWORD=""
USERNAME=""
USER_PASSWORD=""
USER_SHELL="bash"
ENABLE_SUDO="no"
HOSTNAME=""
BOOTLOADER=""
CPU_VENDOR=""
ENABLE_MULTILIB="no"
SWAP_SIZE="$DEFAULT_SWAP_SIZE"
EFI_SIZE="$DEFAULT_EFI_SIZE"
TIMEZONE=""

#######################################
# Logging helpers
#######################################
log() {
    printf '%(%Y-%m-%d %H:%M:%S)T - %s\n' -1 "$*" | tee -a "$LOG_FILE"
}
info()    { printf "${BLUE}[INFO]${NC} %s\n"    "$*" | tee -a "$LOG_FILE"; }
success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
warning() { printf "${YELLOW}[WARNING]${NC} %s\n" "$*" | tee -a "$LOG_FILE"; }
error()   { printf "${RED}[ERROR]${NC} %s\n"   "$*" | tee -a "$LOG_FILE"; }

fatal() {
    error "$*"
    exit 1
}

#######################################
# Prompt helpers
#######################################
yes_no_prompt() {
    # Ask a yes/no question until the user enters y or n
    local prompt="$1"
    local reply
    while true; do
        read -rp "$prompt [y/n]: " reply
        case "$reply" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
        esac
        warning "Please answer 'y' or 'n'."
    done
}

select_from_menu() {
    # Generic menu selection helper
    local prompt="$1"
    shift
    local options=("$@")
    local num="${#options[@]}"
    local choice
    while true; do
        info "$prompt"
        for i in "${!options[@]}"; do
            printf '%d) %s\n' "$((i+1))" "${options[i]}"
        done
        read -rp "Select an option (1-${num}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= num )); then
            echo "${options[$((choice-1))]}"
            return 0
        fi
        warning "Invalid choice. Please select a number between 1 and ${num}."
    done
}

#######################################
# Validation functions
#######################################
validate_uefi_boot() {
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        fatal "This script requires UEFI boot mode. Legacy BIOS is not supported."
    fi
    success "UEFI boot mode detected"
}

validate_network() {
    info "Checking network connectivity..."
    if ! curl --silent --head --fail https://archlinux.org/ >/dev/null; then
        fatal "No internet connection. Please configure networking and try again."
    fi
    success "Network connectivity confirmed"
}

validate_disk() {
    local disk="$1"
    if [[ ! -b "$disk" ]]; then
        fatal "Disk $disk does not exist or is not a block device"
    fi
    if mount | grep -qE "^$disk"; then
        fatal "Disk $disk has mounted partitions. Please unmount them before proceeding."
    fi
    success "Disk $disk validated"
}

validate_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ && ${#1} -le 32 ]]
}

validate_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

#######################################
# User input functions
#######################################
get_disk_selection() {
    info "Detecting available disks..."
    local disks=()
    local labels=()

    while IFS= read -r line; do
        line="${line% disk}"
        local name size model
        name=$(awk '{print $1}' <<< "$line")
        size=$(awk '{print $2}' <<< "$line")
        model=$(cut -d' ' -f3- <<< "$line")
        if [[ -b "/dev/$name" ]]; then
            disks+=("/dev/$name")
            labels+=("$name ($size) - $model")
        fi
    done < <(lsblk -dn -o NAME,SIZE,MODEL,TYPE | awk '$4 == "disk"')

    if [[ ${#disks[@]} -eq 0 ]]; then
        fatal "No suitable disks found"
    fi

    local selection
    selection=$(select_from_menu "Available disks:" "${labels[@]}")
    local index
    for i in "${!labels[@]}"; do
        if [[ "${labels[i]}" == "$selection" ]]; then
            index="$i"
            break
        fi
    done
    DISK="${disks[$index]}"
    info "Selected disk: $DISK (${labels[$index]})"
    validate_disk "$DISK"

    yes_no_prompt "WARNING: All data on $DISK will be destroyed. Continue?" || fatal "Installation cancelled by user"
}

get_filesystem_type() {
    FILESYSTEM_TYPE=$(select_from_menu \
        "Select filesystem type:" \
        "ext4 (traditional, stable)" \
        "btrfs (modern, with snapshots)" \
        "xfs (high performance)" \
    )
    case "$FILESYSTEM_TYPE" in
        ext4*) FILESYSTEM_TYPE="ext4" ;;
        btrfs*) FILESYSTEM_TYPE="btrfs" ;;
        xfs*) FILESYSTEM_TYPE="xfs" ;;
    esac
    success "Selected filesystem: $FILESYSTEM_TYPE"
}

get_btrfs_layout() {
    if yes_no_prompt "Use the default Btrfs subvolume layout?"; then
        info "Using default Btrfs layout"
    else
        warning "Custom Btrfs layouts are not implemented in this script. Falling back to default layout."
    fi
}

get_hostname() {
    while true; do
        read -rp "Enter hostname for this system: " HOSTNAME
        [[ -n "$HOSTNAME" ]] || { warning "Hostname cannot be empty"; continue; }
        if validate_hostname "$HOSTNAME"; then
            break
        else
            warning "Invalid hostname. Use letters, numbers and hyphens only."
        fi
    done
    success "Hostname set to: $HOSTNAME"
}

get_password() {
    local prompt="$1"
    local pass confirm
    while true; do
        read -rsp "$prompt: " pass; echo
        (( ${#pass} >= 8 )) || { warning "Password must be at least 8 characters long"; continue; }
        read -rsp "Confirm password: " confirm; echo
        [[ "$pass" == "$confirm" ]] || { warning "Passwords do not match"; continue; }
        echo "$pass"
        return 0
    done
}

get_root_password() {
    ROOT_PASSWORD=$(get_password "Enter root password")
    success "Root password set"
}

get_user_configuration() {
    while true; do
        read -rp "Enter username for standard user: " USERNAME
        [[ -n "$USERNAME" ]] || { warning "Username cannot be empty"; continue; }
        if validate_username "$USERNAME"; then
            break
        else
            warning "Invalid username. Use lowercase letters, numbers, underscores and hyphens (max 32 chars)."
        fi
    done
    USER_PASSWORD=$(get_password "Enter password for $USERNAME")
    yes_no_prompt "Grant sudo privileges to $USERNAME?" && ENABLE_SUDO="yes"

    USER_SHELL=$(select_from_menu \
        "Select shell for $USERNAME:" \
        "bash (default)" "zsh (advanced features)" "fish (user friendly)" \
    )
    case "$USER_SHELL" in
        bash*) USER_SHELL="bash" ;;
        zsh*)  USER_SHELL="zsh" ;;
        fish*) USER_SHELL="fish" ;;
    esac
    success "User configuration completed"
}

get_bootloader_selection() {
    BOOTLOADER=$(select_from_menu \
        "Select bootloader:" \
        "grub (traditional)" "systemd-boot (simple UEFI)" "refind (graphical)" \
    )
    case "$BOOTLOADER" in
        grub*)        BOOTLOADER="grub" ;;
        systemd-boot*) BOOTLOADER="systemd-boot" ;;
        refind*)      BOOTLOADER="refind" ;;
    esac
    success "Selected bootloader: $BOOTLOADER"
}

detect_cpu_microcode() {
    info "Detecting CPU vendor for microcode…"
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        CPU_VENDOR="intel"
        success "Intel CPU detected - will install intel-ucode"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        CPU_VENDOR="amd"
        success "AMD CPU detected - will install amd-ucode"
    else
        CPU_VENDOR="unknown"
        warning "Unknown CPU vendor – no microcode will be installed"
    fi
}

get_multilib_preference() {
    if yes_no_prompt "Enable multilib repository? (useful for gaming and WINE)"; then
        ENABLE_MULTILIB="yes"
        success "Multilib repository will be enabled"
    else
        info "Multilib repository will remain disabled"
    fi
}

choose_timezone() {
    info "Setting timezone. You can choose your region."
    local auto_zone
    auto_zone=$(timedatectl show --value --property=Timezone 2>/dev/null || true)
    if [[ -n "$auto_zone" ]]; then
        info "Detected current timezone: $auto_zone"
        if yes_no_prompt "Use detected timezone ($auto_zone)?"; then
            TIMEZONE="$auto_zone"
            return 0
        fi
    fi
    while true; do
        read -rp "Enter your timezone (e.g. America/Chicago): " TIMEZONE
        [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] && break
        warning "Invalid timezone. Please choose a valid entry from /usr/share/zoneinfo."
    done
}

configure_swap_size() {
    read -rp "Enter swap size (e.g. 2G, 512M) [default $SWAP_SIZE]: " size
    if [[ -n "$size" ]]; then
        if [[ "$size" =~ ^[0-9]+[MG]$ ]]; then
            SWAP_SIZE="$size"
            success "Swap size set to $SWAP_SIZE"
        else
            warning "Invalid swap size format. Using default ($SWAP_SIZE)."
        fi
    fi
}

#######################################
# Disk management functions
#######################################
create_partitions() {
    info "Creating partitions on $DISK"
    wipefs -af "$DISK"
    sgdisk --zap-all "$DISK" >/dev/null
    sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 "$DISK"
    sgdisk -n 2:0:+${SWAP_SIZE} -t 2:8200 "$DISK"
    sgdisk -n 3:0:0 -t 3:8300 "$DISK"
    partprobe "$DISK"
    sleep 2
    success "Partitions created successfully"
}

format_partitions() {
    info "Formatting partitions"
    local prefix="$DISK"
    [[ "$DISK" == *"nvme"* ]] && prefix="${DISK}p"

    local efi_partition="${prefix}1"
    local swap_partition="${prefix}2"
    local root_partition="${prefix}3"

    mkfs.fat -F32 "$efi_partition"
    mkswap "$swap_partition"
    swapon "$swap_partition"

    case "$FILESYSTEM_TYPE" in
        ext4) mkfs.ext4 -F "$root_partition" ;;
        btrfs) mkfs.btrfs -f "$root_partition" ;;
        xfs) mkfs.xfs -f "$root_partition" ;;
    esac
    success "Partitions formatted successfully"
}

mount_filesystems() {
    info "Mounting filesystems"
    local prefix="$DISK"
    [[ "$DISK" == *"nvme"* ]] && prefix="${DISK}p"

    local efi_partition="${prefix}1"
    local root_partition="${prefix}3"

    mount "$root_partition" "$MOUNT_POINT"
    mkdir -p "$MOUNT_POINT/boot"
    mount "$efi_partition" "$MOUNT_POINT/boot"

    if [[ "$FILESYSTEM_TYPE" == "btrfs" ]]; then
        btrfs subvolume create "$MOUNT_POINT/@"
        btrfs subvolume create "$MOUNT_POINT/@home"
        btrfs subvolume create "$MOUNT_POINT/@log"
        btrfs subvolume create "$MOUNT_POINT/@pkg"

        umount "$MOUNT_POINT/boot"
        umount "$MOUNT_POINT"

        mount -o subvol=@,compress=zstd,noatime "$root_partition" "$MOUNT_POINT"

        mkdir -p "$MOUNT_POINT/home" "$MOUNT_POINT/var/log" "$MOUNT_POINT/var/cache/pacman/pkg"
        mount -o subvol=@home,compress=zstd,noatime "$root_partition" "$MOUNT_POINT/home"
        mount -o subvol=@log,compress=zstd,noatime "$root_partition" "$MOUNT_POINT/var/log"
        mount -o subvol=@pkg,compress=zstd,noatime "$root_partition" "$MOUNT_POINT/var/cache/pacman/pkg"

        mkdir -p "$MOUNT_POINT/boot"
        mount "$efi_partition" "$MOUNT_POINT/boot"
    fi
    success "Filesystems mounted successfully"
}

#######################################
# System installation functions
#######################################
configure_pacman() {
    info "Configuring pacman"
    if [[ "$ENABLE_MULTILIB" == "yes" ]]; then
        sed -i '/^\[multilib\]/,/^Include/ s/^#//' "$MOUNT_POINT/etc/pacman.conf"
    fi
    arch-chroot "$MOUNT_POINT" pacman -Sy --noconfirm
    success "Pacman configured successfully"
}

install_base_system() {
    info "Installing base system (minimal)"
    pacman -Sy --noconfirm
    local pkgs=(base linux linux-firmware)
    case "$CPU_VENDOR" in
        intel) pkgs+=(intel-ucode) ;;
        amd)   pkgs+=(amd-ucode)   ;;
    esac
    case "$FILESYSTEM_TYPE" in
        btrfs) pkgs+=(btrfs-progs) ;;
        xfs)   pkgs+=(xfsprogs)    ;;
    esac
    pacstrap "$MOUNT_POINT" "${pkgs[@]}"
    success "Base system installed successfully"
}

install_additional_packages() {
    info "Installing additional essential packages"
    local pkgs=(networkmanager sudo vim nano)
    case "$BOOTLOADER" in
        grub)        pkgs+=(grub efibootmgr) ;;
        systemd-boot) ;; # systemd-boot is part of systemd
        refind)      pkgs+=(refind)      ;;
    esac
    case "$USER_SHELL" in
        zsh) pkgs+=(zsh zsh-completions) ;;
        fish) pkgs+=(fish) ;;
    esac
    arch-chroot "$MOUNT_POINT" pacman -S --noconfirm "${pkgs[@]}"
    success "Additional packages installed successfully"
}

configure_system() {
    info "Configuring system"
    genfstab -U "$MOUNT_POINT" >> "$MOUNT_POINT/etc/fstab"

    # Timezone & locale
    arch-chroot "$MOUNT_POINT" ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    arch-chroot "$MOUNT_POINT" hwclock --systohc
    echo "en_US.UTF-8 UTF-8" >> "$MOUNT_POINT/etc/locale.gen"
    arch-chroot "$MOUNT_POINT" locale-gen
    echo "LANG=en_US.UTF-8" > "$MOUNT_POINT/etc/locale.conf"

    # Hostname & hosts file
    echo "$HOSTNAME" > "$MOUNT_POINT/etc/hostname"
    cat > "$MOUNT_POINT/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

    # Enable NetworkManager
    arch-chroot "$MOUNT_POINT" systemctl enable NetworkManager
    success "System configuration completed"
}

configure_bootloader() {
    info "Configuring bootloader: $BOOTLOADER"
    local prefix="$DISK"
    [[ "$DISK" == *"nvme"* ]] && prefix="${DISK}p"
    local root_uuid
    root_uuid=$(blkid -s UUID -o value "${prefix}3")

    case "$BOOTLOADER" in
        grub)
            arch-chroot "$MOUNT_POINT" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
            arch-chroot "$MOUNT_POINT" grub-mkconfig -o /boot/grub/grub.cfg
            ;;
        systemd-boot)
            arch-chroot "$MOUNT_POINT" bootctl --path=/boot install
            cat > "$MOUNT_POINT/boot/loader/loader.conf" <<EOF
default arch.conf
timeout 3
console-mode max
editor no
EOF
            cat > "$MOUNT_POINT/boot/loader/entries/arch.conf" <<EOF
title   Arch Linux
linux   /vmlinuz-linux
EOF
            case "$CPU_VENDOR" in
                intel) echo "initrd /intel-ucode.img" >> "$MOUNT_POINT/boot/loader/entries/arch.conf" ;;
                amd)   echo "initrd /amd-ucode.img"   >> "$MOUNT_POINT/boot/loader/entries/arch.conf" ;;
            esac
            echo "initrd /initramfs-linux.img" >> "$MOUNT_POINT/boot/loader/entries/arch.conf"
            if [[ "$FILESYSTEM_TYPE" == "btrfs" ]]; then
                echo "options root=UUID=$root_uuid rw rootflags=subvol=@" >> "$MOUNT_POINT/boot/loader/entries/arch.conf"
            else
                echo "options root=UUID=$root_uuid rw" >> "$MOUNT_POINT/boot/loader/entries/arch.conf"
            fi
            ;;
        refind)
            arch-chroot "$MOUNT_POINT" refind-install
            ;;
    esac
    success "Bootloader ($BOOTLOADER) configured successfully"
}

configure_users() {
    info "Configuring users"
    echo "root:$ROOT_PASSWORD" | arch-chroot "$MOUNT_POINT" chpasswd

    arch-chroot "$MOUNT_POINT" useradd -m -s "/bin/$USER_SHELL" "$USERNAME"
    echo "$USERNAME:$USER_PASSWORD" | arch-chroot "$MOUNT_POINT" chpasswd

    if [[ "$ENABLE_SUDO" == "yes" ]]; then
        echo "$USERNAME ALL=(ALL:ALL) ALL" > "$MOUNT_POINT/etc/sudoers.d/$USERNAME"
        chmod 440 "$MOUNT_POINT/etc/sudoers.d/$USERNAME"
    fi

    case "$USER_SHELL" in
        zsh)
            cat > "$MOUNT_POINT/home/$USERNAME/.zshrc" <<'EOF'
# Simple zsh configuration
autoload -Uz compinit && compinit
HISTSIZE=1000
SAVEHIST=1000
HISTFILE=~/.zsh_history
setopt appendhistory
PS1='%n@%m:%~$ '
EOF
            arch-chroot "$MOUNT_POINT" chown "$USERNAME:$USERNAME" "/home/$USERNAME/.zshrc"
            ;;
        fish)
            mkdir -p "$MOUNT_POINT/home/$USERNAME/.config/fish"
            cat > "$MOUNT_POINT/home/$USERNAME/.config/fish/config.fish" <<'EOF'
# Basic fish configuration
set fish_greeting ""
EOF
            arch-chroot "$MOUNT_POINT" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"
            ;;
    esac
    success "Users configured successfully"
}

#######################################
# Cleanup and main logic
#######################################
cleanup() {
    info "Performing cleanup"
    # Unmount submounts in reverse order
    if mountpoint -q "$MOUNT_POINT/boot"; then
        umount "$MOUNT_POINT/boot"
    fi
    if [[ "$FILESYSTEM_TYPE" == "btrfs" ]]; then
        for sub in home var/log var/cache/pacman/pkg; do
            if mountpoint -q "$MOUNT_POINT/$sub"; then
                umount "$MOUNT_POINT/$sub"
            fi
        done
    fi
    if mountpoint -q "$MOUNT_POINT"; then
        umount "$MOUNT_POINT"
    fi
    swapoff -a || true
}
trap cleanup EXIT

main() {
    info "Starting Arch Linux installation"
    validate_uefi_boot
    validate_network

    get_disk_selection
    configure_swap_size
    get_filesystem_type
    [[ "$FILESYSTEM_TYPE" == "btrfs" ]] && get_btrfs_layout
    get_hostname
    choose_timezone
    get_root_password
    get_user_configuration
    get_bootloader_selection
    detect_cpu_microcode
    get_multilib_preference

    # Summary
    info "Installation summary:"
    printf 'Disk: %s\nFilesystem: %s\nEFI size: %s\nSwap size: %s\nHostname: %s\nUsername: %s\nShell: %s\nSudo: %s\nBootloader: %s\nCPU: %s\nMultilib: %s\nTimezone: %s\n\n' \
        "$DISK" "$FILESYSTEM_TYPE" "$EFI_SIZE" "$SWAP_SIZE" "$HOSTNAME" "$USERNAME" "$USER_SHELL" "$ENABLE_SUDO" "$BOOTLOADER" "$CPU_VENDOR" "$ENABLE_MULTILIB" "$TIMEZONE"

    yes_no_prompt "Proceed with installation?" || fatal "Installation cancelled by user"

    create_partitions
    format_partitions
    mount_filesystems

    install_base_system
    configure_system
    configure_pacman
    install_additional_packages
    configure_bootloader
    configure_users

    success "Arch Linux installation completed successfully!"
    info "System is ready to boot. Remove installation media and reboot."
    if yes_no_prompt "Reboot now?"; then
        reboot
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
