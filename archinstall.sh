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
LOCALE=""
EDITOR_CHOICE=""
BTRFS_MOUNT_OPTIONS="compress=zstd,noatime"
BOOTLOADER_TIMEOUT="3"
SWAP_PARTITION=""

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

error_trap() {
    local exit_code=$?
    local line="$1"
    local cmd="$2"
    error "Command '${cmd}' failed at line ${line} with exit code ${exit_code}"
    exit "$exit_code"
}

#######################################
# Pre-flight checks
#######################################
require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        fatal "This script must be run as root"
    fi
}

check_dependencies() {
    local deps=(lsblk curl sgdisk partprobe pacstrap arch-chroot numfmt)
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            fatal "Required command '$cmd' not found"
        fi
    done
}

#######################################
# Prompt helpers
#######################################
yes_no_prompt() {
    # Ask a yes/no question until the user enters y or n
    local prompt="$1"
    local reply
    while true; do
        if ! read -rp "$prompt [y/n]: " reply; then
            fatal "Input aborted"
        fi
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
        info "$prompt" >&2
        for i in "${!options[@]}"; do
            printf '%d) %s\n' "$((i+1))" "${options[i]}" >&2
        done
        if ! read -rp "Select an option (1-${num}): " choice; then
            fatal "Input aborted"
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= num )); then
            echo "${options[$((choice-1))]}"
            return 0
        fi
        warning "Invalid choice. Please select a number between 1 and ${num}." >&2
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

    if command -v curl >/dev/null 2>&1; then
        if curl --max-time 10 --silent --head --fail https://archlinux.org/ >/dev/null; then
            success "Network connectivity confirmed"
            return 0
        else
            warning "curl check failed; attempting ping..."
            if ! command -v ping >/dev/null 2>&1; then
                fatal "Network check failed with curl and ping is not installed."
            fi
        fi
    else
        warning "curl not found; falling back to ping..."
        if ! command -v ping >/dev/null 2>&1; then
            fatal "Neither curl nor ping is available. Please install curl or iputils."
        fi
    fi

    if ping -c 1 -W 5 archlinux.org >/dev/null; then
        success "Network connectivity confirmed"
    else
        fatal "No internet connection. Please configure networking and try again."
    fi
}

validate_disk() {
    local disk="$1"
    if [[ ! -b "$disk" ]]; then
        fatal "Disk $disk does not exist or is not a block device"
    fi

    if [[ $(lsblk -dn -o TYPE "$disk") != "disk" ]]; then
        fatal "Target $disk is not a disk device"
    fi

    if lsblk -rno MOUNTPOINT "$disk" | grep -qE '\S'; then
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

validate_disk_size() {
    local disk_bytes efi_bytes swap_bytes root_min bytes_required
    disk_bytes=$(lsblk -b -dn -o SIZE "$DISK")
    efi_bytes=$(numfmt --from=iec "$EFI_SIZE")
    swap_bytes=$(numfmt --from=iec "$SWAP_SIZE")
    root_min=$((1 * 1024 * 1024 * 1024))
    bytes_required=$((efi_bytes + swap_bytes + root_min))
    if (( disk_bytes < bytes_required )); then
        fatal "Disk size $(numfmt --to=iec $disk_bytes) is smaller than required $(numfmt --to=iec $bytes_required)"
    fi
    success "Disk has sufficient capacity: $(numfmt --to=iec $disk_bytes)"
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
    done < <(lsblk -dn -o NAME,SIZE,MODEL,TYPE | grep 'disk$')

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
    
    if yes_no_prompt "Use default Btrfs mount options (compress=zstd,noatime)?"; then
        info "Using default mount options"
    else
        if ! read -rp "Enter Btrfs mount options (e.g. compress=lzo,noatime): " BTRFS_MOUNT_OPTIONS; then
            fatal "Input aborted"
        fi
        success "Btrfs mount options set to: $BTRFS_MOUNT_OPTIONS"
    fi
}

get_hostname() {
    while true; do
        if ! read -rp "Enter hostname for this system: " HOSTNAME; then
            fatal "Input aborted"
        fi
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
        if ! read -rsp "$prompt: " pass; then
            fatal "Input aborted"
        fi
        echo
        (( ${#pass} >= 8 )) || { warning "Password must be at least 8 characters long"; continue; }
        if ! read -rsp "Confirm password: " confirm; then
            fatal "Input aborted"
        fi
        echo
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
        if ! read -rp "Enter username for standard user: " USERNAME; then
            fatal "Input aborted"
        fi
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
    
    if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
        if ! read -rp "Enter bootloader timeout in seconds [default 3]: " timeout; then
            fatal "Input aborted"
        fi
        if [[ -n "$timeout" && "$timeout" =~ ^[0-9]+$ ]]; then
            BOOTLOADER_TIMEOUT="$timeout"
            success "Bootloader timeout set to $BOOTLOADER_TIMEOUT seconds"
        else
            info "Using default timeout of 3 seconds"
        fi
    fi
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

get_editor_preference() {
    EDITOR_CHOICE=$(select_from_menu \
        "Select text editor to install:" \
        "vim" \
        "nano" \
        "both" \
        "none" \
    )
    success "Editor selection: $EDITOR_CHOICE"
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
        if ! read -rp "Enter your timezone (e.g. America/Chicago): " TIMEZONE; then
            fatal "Input aborted"
        fi
        [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] && break
        warning "Invalid timezone. Please choose a valid entry from /usr/share/zoneinfo."
    done
}

choose_locale() {
    info "Selecting system locale"
    LOCALE=$(select_from_menu \
        "Select system locale:" \
        "en_US.UTF-8" \
        "en_GB.UTF-8" \
        "de_DE.UTF-8" \
        "fr_FR.UTF-8" \
        "es_ES.UTF-8" \
        "it_IT.UTF-8" \
        "pt_BR.UTF-8" \
        "ru_RU.UTF-8" \
        "ja_JP.UTF-8" \
        "zh_CN.UTF-8" \
        "Other (manual entry)" \
    )
    if [[ "$LOCALE" == "Other (manual entry)" ]]; then
        while true; do
            if ! read -rp "Enter locale (e.g. en_US.UTF-8): " LOCALE; then
                fatal "Input aborted"
            fi
            if [[ "$LOCALE" =~ ^[a-z]{2}_[A-Z]{2}\.UTF-8$ ]]; then
                break
            else
                warning "Invalid locale format. Use format like 'en_US.UTF-8'"
            fi
        done
    fi
    success "Selected locale: $LOCALE"
}

configure_swap_size() {
    if ! read -rp "Enter swap size (e.g. 2G, 512M) [default $SWAP_SIZE]: " size; then
        fatal "Input aborted"
    fi
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
partition_prefix() {
    local disk="$1"
    if [[ "$disk" =~ (nvme|mmcblk|loop) ]]; then
        echo "${disk}p"
    else
        echo "$disk"
    fi
}

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
    local prefix
    prefix=$(partition_prefix "$DISK")

  local efi_partition="${prefix}1"
  local swap_partition="${prefix}2"
  local root_partition="${prefix}3"

  SWAP_PARTITION="$swap_partition"

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
    local prefix
    prefix=$(partition_prefix "$DISK")

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

        mount -o subvol=@,$BTRFS_MOUNT_OPTIONS "$root_partition" "$MOUNT_POINT"

        mkdir -p "$MOUNT_POINT/home" "$MOUNT_POINT/var/log" "$MOUNT_POINT/var/cache/pacman/pkg"
        mount -o subvol=@home,$BTRFS_MOUNT_OPTIONS "$root_partition" "$MOUNT_POINT/home"
        mount -o subvol=@log,$BTRFS_MOUNT_OPTIONS "$root_partition" "$MOUNT_POINT/var/log"
        mount -o subvol=@pkg,$BTRFS_MOUNT_OPTIONS "$root_partition" "$MOUNT_POINT/var/cache/pacman/pkg"

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
    local pacman_conf="$MOUNT_POINT/etc/pacman.conf"
    if [[ "$ENABLE_MULTILIB" == "yes" ]]; then
        if [[ -f "$pacman_conf" ]]; then
            sed -i '/^\[multilib\]/,/^Include/ s/^#//' "$pacman_conf"
        else
            warning "pacman.conf not found; skipping multilib configuration"
        fi
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
    pacstrap --noconfirm "$MOUNT_POINT" "${pkgs[@]}"
    success "Base system installed successfully"
}

install_additional_packages() {
    info "Installing additional essential packages"
    local pkgs=(networkmanager sudo)
    case "$EDITOR_CHOICE" in
        vim) pkgs+=(vim) ;;
        nano) pkgs+=(nano) ;;
        both) pkgs+=(vim nano) ;;
    esac
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
    genfstab -U "$MOUNT_POINT" > "$MOUNT_POINT/etc/fstab"

    # Timezone & locale
    arch-chroot "$MOUNT_POINT" ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    arch-chroot "$MOUNT_POINT" hwclock --systohc
    echo "$LOCALE UTF-8" >> "$MOUNT_POINT/etc/locale.gen"
    arch-chroot "$MOUNT_POINT" locale-gen
    echo "LANG=$LOCALE" > "$MOUNT_POINT/etc/locale.conf"

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
    local prefix
    prefix=$(partition_prefix "$DISK")
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
timeout $BOOTLOADER_TIMEOUT
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

    # No default shell configurations - let users configure their shell as they prefer
    success "Users configured successfully"
}

#######################################
# Cleanup and main logic
#######################################
cleanup() {
    info "Performing cleanup"
    # Unmount submounts in reverse order
    if mountpoint -q "$MOUNT_POINT/boot"; then
        umount "$MOUNT_POINT/boot" || true
    fi
    if [[ "$FILESYSTEM_TYPE" == "btrfs" ]]; then
        for sub in home var/log var/cache/pacman/pkg; do
            if mountpoint -q "$MOUNT_POINT/$sub"; then
                umount "$MOUNT_POINT/$sub" || true
            fi
        done
    fi
  if mountpoint -q "$MOUNT_POINT"; then
      umount "$MOUNT_POINT" || true
  fi
  if [[ -n "$SWAP_PARTITION" ]]; then
      swapoff "$SWAP_PARTITION" || true
  fi
}

main() {
    require_root
    check_dependencies
    trap cleanup EXIT
    trap 'error_trap $LINENO $BASH_COMMAND' ERR
    info "Starting Arch Linux installation"
    validate_uefi_boot
    validate_network

    get_disk_selection
    configure_swap_size
    validate_disk_size
    get_filesystem_type
    [[ "$FILESYSTEM_TYPE" == "btrfs" ]] && get_btrfs_layout
    get_hostname
    choose_timezone
    choose_locale
    get_root_password
    get_user_configuration
    get_bootloader_selection
    detect_cpu_microcode
    get_editor_preference
    get_multilib_preference

    # Summary
    info "Installation summary:"
    printf 'Disk: %s\nFilesystem: %s\nEFI size: %s\nSwap size: %s\nHostname: %s\nUsername: %s\nShell: %s\nSudo: %s\nBootloader: %s\nCPU: %s\nEditor: %s\nMultilib: %s\nTimezone: %s\nLocale: %s\n\n' \
        "$DISK" "$FILESYSTEM_TYPE" "$EFI_SIZE" "$SWAP_SIZE" "$HOSTNAME" "$USERNAME" "$USER_SHELL" "$ENABLE_SUDO" "$BOOTLOADER" "$CPU_VENDOR" "$EDITOR_CHOICE" "$ENABLE_MULTILIB" "$TIMEZONE" "$LOCALE"

    yes_no_prompt "Proceed with installation?" || fatal "Installation cancelled by user"

    create_partitions
    format_partitions
    mount_filesystems

    install_base_system
    configure_pacman
    install_additional_packages
    configure_system
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
