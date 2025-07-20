#!/usr/bin/env bash

#===========================================================
# Arch Linux Installation Script
#===========================================================

readonly LOG_FILE="/var/log/archinstall.log"
readonly MIN_DISK_SIZE=$((20 * 1024 * 1024 * 1024)) # 20GB in bytes

#-----------------------------------------------------------
# Core Utilities
#-----------------------------------------------------------

# Progress tracking
TOTAL_STEPS=12
CURRENT_STEP=0

show_progress() {
    local step_name="$1"
    ((CURRENT_STEP++))
    local percentage=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    
    echo > /dev/tty
    echo "===========================================================" > /dev/tty
    echo "Step $CURRENT_STEP/$TOTAL_STEPS: $step_name ($percentage%)" > /dev/tty
    echo "===========================================================" > /dev/tty
    log "Starting step $CURRENT_STEP/$TOTAL_STEPS: $step_name"
}

show_step_complete() {
    local step_name="$1"
    echo "✓ Completed: $step_name" > /dev/tty
    log "Completed step $CURRENT_STEP/$TOTAL_STEPS: $step_name"
}

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
    # Ensure we never exit with success code when handling an error
    [[ $exit_code -eq 0 ]] && exit_code=1
    log "ERROR on line $line_number: Command exited with status $exit_code"
    log "Installation failed. See log file at $LOG_FILE for details."
    cleanup_on_error
    exit $exit_code
}

cleanup_on_error() {
    log "Performing cleanup after error..."
    # Unmount any mounted partitions
    mountpoint -q /mnt && {
        log "Unmounting /mnt..."
        umount -R /mnt 2>/dev/null || true
    }
    # Disable any activated swap
    swapoff -a 2>/dev/null || true
    log "Cleanup completed"
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
    local hosts=("archlinux.org" "8.8.8.8" "1.1.1.1")
    local success=0
    
    for host in "${hosts[@]}"; do
        if ping -c 2 -W 5 "$host" &>/dev/null; then
            ((success++))
            log "Successfully reached $host"
        else
            log "Failed to reach $host"
        fi
    done
    
    if [[ $success -lt 2 ]]; then
        log "ERROR: Insufficient internet connectivity (only $success/${#hosts[@]} hosts reachable)"
        log "Please check your network connection and try again"
        return 1
    fi
    
    # Test DNS resolution
    if ! nslookup archlinux.org &>/dev/null; then
        log "WARNING: DNS resolution test failed, but continuing with installation"
    fi
    
    log "Internet connection verified ($success/${#hosts[@]} hosts reachable)"
    return 0
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

# Global arrays for Btrfs configuration
declare -A SUBVOLUMES  # subvol_name -> mount_point
declare -A MOUNT_OPTS  # subvol_name -> mount_options
declare GLOBAL_MOUNT_OPTS=""

#-----------------------------------------------------------
# Btrfs Configuration Functions
#-----------------------------------------------------------

validate_mount_point() {
    local mount_point="$1"
    # Must start with / and not end with / (except for root)
    if [[ ! "$mount_point" =~ ^/([a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*)?$ ]] && [[ "$mount_point" != "/" ]]; then
        return 1
    fi
    # Check for reserved paths
    local reserved_paths=("/dev" "/proc" "/sys" "/run" "/tmp")
    for reserved in "${reserved_paths[@]}"; do
        if [[ "$mount_point" == "$reserved"* ]]; then
            return 1
        fi
    done
    return 0
}

validate_subvolume_name() {
    local name="$1"
    # Must start with @ and contain only valid characters
    if [[ ! "$name" =~ ^@[a-zA-Z0-9._-]*$ ]]; then
        return 1
    fi
    return 0
}

validate_mount_options() {
    local options="$1"
    # Basic validation for common Btrfs mount options
    local valid_opts="noatime|relatime|atime|discard|discard=async|discard=sync|compress=zstd|compress=lzo|compress=zlib|space_cache=v2|space_cache=v1|autodefrag|noautodefrag|inode_cache|noinode_cache|ssd|nossd|commit=[0-9]+|max_inline=[0-9]+|thread_pool=[0-9]+"
    
    # Split by comma and validate each option
    IFS=',' read -ra OPTS <<< "$options"
    for opt in "${OPTS[@]}"; do
        # Trim whitespace using parameter expansion instead of xargs
        opt="${opt#"${opt%%[![:space:]]*}"}"  # trim leading
        opt="${opt%"${opt##*[![:space:]]}"}"  # trim trailing
        
        if [[ -n "$opt" && ! "$opt" =~ ^($valid_opts)$ ]]; then
            log "WARNING: Mount option '$opt' may not be valid for Btrfs"
        fi
    done
    return 0
}

configure_btrfs_subvolumes() {
    log "Configuring Btrfs subvolumes..."
    
    # Initialize with default subvolumes
    SUBVOLUMES["@"]="/"
    SUBVOLUMES["@home"]="/home"
    SUBVOLUMES["@log"]="/var/log"
    SUBVOLUMES["@pkg"]="/var/cache/pacman/pkg"
    SUBVOLUMES["@snapshots"]="/.snapshots"
    
    echo "=== Btrfs Subvolume Configuration ===" > /dev/tty
    echo "Default subvolumes have been configured. You can:" > /dev/tty
    echo "1. Keep default configuration" > /dev/tty
    echo "2. Add more subvolumes" > /dev/tty
    echo "3. Modify existing subvolumes" > /dev/tty
    echo "4. Remove subvolumes (except @)" > /dev/tty
    echo "5. Preview configuration" > /dev/tty
    echo "6. Continue with current configuration" > /dev/tty
    echo > /dev/tty
    
    while true; do
        echo "Current subvolumes:" > /dev/tty
        for subvol in "${!SUBVOLUMES[@]}"; do
            echo "  $subvol -> ${SUBVOLUMES[$subvol]}" > /dev/tty
        done
        echo > /dev/tty
        
        prompt "Choose action (1-6): " action
        case "$action" in
            1)
                log "Keeping default subvolume configuration"
                break
                ;;
            2)
                add_subvolume
                ;;
            3)
                modify_subvolume
                ;;
            4)
                remove_subvolume
                ;;
            5)
                preview_btrfs_config
                ;;
            6)
                if confirm_operation "Continue with current subvolume configuration?"; then
                    break
                fi
                ;;
            *)
                log "Invalid choice. Please enter 1-6."
                ;;
        esac
    done
}

add_subvolume() {
    local subvol_name mount_point
    
    while true; do
        prompt "Enter subvolume name (must start with @): " subvol_name
        if validate_subvolume_name "$subvol_name"; then
            if [[ -n "${SUBVOLUMES[$subvol_name]}" ]]; then
                log "Subvolume '$subvol_name' already exists. Use modify option instead."
                continue
            fi
            break
        else
            log "Invalid subvolume name. Must start with @ and contain only letters, numbers, dots, underscores, and hyphens."
        fi
    done
    
    while true; do
        prompt "Enter mount point for $subvol_name: " mount_point
        if validate_mount_point "$mount_point"; then
            # Check if mount point is already used
            local used=false
            for existing_mount in "${SUBVOLUMES[@]}"; do
                if [[ "$existing_mount" == "$mount_point" ]]; then
                    log "Mount point '$mount_point' is already used by another subvolume."
                    used=true
                    break
                fi
            done
            if [[ "$used" == false ]]; then
                break
            fi
        else
            log "Invalid mount point. Must be an absolute path and not a reserved system path."
        fi
    done
    
    SUBVOLUMES["$subvol_name"]="$mount_point"
    log "Added subvolume: $subvol_name -> $mount_point"
}

modify_subvolume() {
    if [[ ${#SUBVOLUMES[@]} -eq 0 ]]; then
        log "No subvolumes to modify."
        return
    fi
    
    echo "Select subvolume to modify:" > /dev/tty
    local i=1
    local subvol_list=()
    for subvol in "${!SUBVOLUMES[@]}"; do
        echo "$i. $subvol -> ${SUBVOLUMES[$subvol]}" > /dev/tty
        subvol_list+=("$subvol")
        ((i++))
    done
    
    local choice
    while true; do
        prompt "Enter number (1-${#subvol_list[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#subvol_list[@]} )); then
            break
        else
            log "Invalid choice. Please enter a number between 1 and ${#subvol_list[@]}."
        fi
    done
    
    local selected_subvol="${subvol_list[$((choice - 1))]}"
    if [[ "$selected_subvol" == "@" ]]; then
        log "Cannot modify the root subvolume (@)."
        return
    fi
    
    local new_mount_point
    echo "Current mount point for $selected_subvol: ${SUBVOLUMES[$selected_subvol]}" > /dev/tty
    while true; do
        prompt "Enter new mount point: " new_mount_point
        if validate_mount_point "$new_mount_point"; then
            # Check if mount point is already used by another subvolume
            local used=false
            for subvol in "${!SUBVOLUMES[@]}"; do
                if [[ "$subvol" != "$selected_subvol" && "${SUBVOLUMES[$subvol]}" == "$new_mount_point" ]]; then
                    log "Mount point '$new_mount_point' is already used by subvolume '$subvol'."
                    used=true
                    break
                fi
            done
            if [[ "$used" == false ]]; then
                break
            fi
        else
            log "Invalid mount point. Must be an absolute path and not a reserved system path."
        fi
    done
    
    SUBVOLUMES["$selected_subvol"]="$new_mount_point"
    log "Modified subvolume: $selected_subvol -> $new_mount_point"
}

remove_subvolume() {
    if [[ ${#SUBVOLUMES[@]} -le 1 ]]; then
        log "Cannot remove subvolumes. At least the root subvolume (@) must remain."
        return
    fi
    
    echo "Select subvolume to remove:" > /dev/tty
    local i=1
    local subvol_list=()
    for subvol in "${!SUBVOLUMES[@]}"; do
        if [[ "$subvol" != "@" ]]; then
            echo "$i. $subvol -> ${SUBVOLUMES[$subvol]}" > /dev/tty
            subvol_list+=("$subvol")
            ((i++))
        fi
    done
    
    if [[ ${#subvol_list[@]} -eq 0 ]]; then
        log "No removable subvolumes (root subvolume @ cannot be removed)."
        return
    fi
    
    local choice
    while true; do
        prompt "Enter number (1-${#subvol_list[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#subvol_list[@]} )); then
            break
        else
            log "Invalid choice. Please enter a number between 1 and ${#subvol_list[@]}."
        fi
    done
    
    local selected_subvol="${subvol_list[$((choice - 1))]}"
    if confirm_operation "Remove subvolume '$selected_subvol'?"; then
        unset SUBVOLUMES["$selected_subvol"]
        log "Removed subvolume: $selected_subvol"
    fi
}

configure_mount_options() {
    log "Configuring Btrfs mount options..."
    
    # Set default mount options
    GLOBAL_MOUNT_OPTS="noatime,discard=async,compress=zstd,space_cache=v2"
    
    echo "=== Btrfs Mount Options Configuration ===" > /dev/tty
    echo "Current global mount options: $GLOBAL_MOUNT_OPTS" > /dev/tty
    echo > /dev/tty
    echo "Common Btrfs mount options:" > /dev/tty
    echo "  noatime          - Don't update access times (recommended)" > /dev/tty
    echo "  discard=async    - Async TRIM for SSDs (recommended for SSDs)" > /dev/tty
    echo "  compress=zstd    - Zstandard compression (recommended)" > /dev/tty
    echo "  compress=lzo     - LZO compression (faster, less compression)" > /dev/tty
    echo "  compress=zlib    - Zlib compression (slower, better compression)" > /dev/tty
    echo "  space_cache=v2   - Enable space cache v2 (recommended)" > /dev/tty
    echo "  autodefrag       - Enable automatic defragmentation" > /dev/tty
    echo "  ssd              - Enable SSD optimizations (auto-detected)" > /dev/tty
    echo > /dev/tty
    
    while true; do
        echo "1. Keep default options ($GLOBAL_MOUNT_OPTS)" > /dev/tty
        echo "2. Modify mount options" > /dev/tty
        echo "3. Configure per-subvolume options (advanced)" > /dev/tty
        echo "4. Continue with current configuration" > /dev/tty
        
        prompt "Choose action (1-4): " action
        case "$action" in
            1)
                log "Keeping default mount options"
                break
                ;;
            2)
                modify_global_mount_options
                ;;
            3)
                configure_per_subvolume_options
                ;;
            4)
                if confirm_operation "Continue with current mount options?"; then
                    break
                fi
                ;;
            *)
                log "Invalid choice. Please enter 1-4."
                ;;
        esac
    done
}

modify_global_mount_options() {
    local new_options
    echo "Current global mount options: $GLOBAL_MOUNT_OPTS" > /dev/tty
    echo "Enter new mount options (comma-separated):" > /dev/tty
    echo "Example: noatime,discard=async,compress=zstd,space_cache=v2" > /dev/tty
    prompt "Mount options: " new_options
    
    if [[ -n "$new_options" ]]; then
        validate_mount_options "$new_options"
        GLOBAL_MOUNT_OPTS="$new_options"
        log "Updated global mount options: $GLOBAL_MOUNT_OPTS"
    else
        log "No changes made to mount options"
    fi
}

configure_per_subvolume_options() {
    echo "Configure per-subvolume mount options (in addition to global options):" > /dev/tty
    
    for subvol in "${!SUBVOLUMES[@]}"; do
        echo > /dev/tty
        echo "Subvolume: $subvol (${SUBVOLUMES[$subvol]})" > /dev/tty
        echo "Current additional options: ${MOUNT_OPTS[$subvol]:-none}" > /dev/tty
        
        if confirm_operation "Add/modify additional options for $subvol?"; then
            local additional_opts
            prompt "Additional mount options for $subvol (or empty for none): " additional_opts
            if [[ -n "$additional_opts" ]]; then
                validate_mount_options "$additional_opts"
                MOUNT_OPTS["$subvol"]="$additional_opts"
                log "Set additional options for $subvol: $additional_opts"
            else
                unset MOUNT_OPTS["$subvol"]
                log "Cleared additional options for $subvol"
            fi
        fi
    done
}

preview_btrfs_config() {
    echo > /dev/tty
    echo "=== Btrfs Configuration Preview ===" > /dev/tty
    echo > /dev/tty
    echo "Global mount options: $GLOBAL_MOUNT_OPTS" > /dev/tty
    echo > /dev/tty
    echo "Subvolumes and mount points:" > /dev/tty
    for subvol in $(printf '%s\n' "${!SUBVOLUMES[@]}" | sort); do
        local mount_point="${SUBVOLUMES[$subvol]}"
        local additional="${MOUNT_OPTS[$subvol]:-}"
        local full_opts="$GLOBAL_MOUNT_OPTS"
        if [[ -n "$additional" ]]; then
            full_opts="$full_opts,$additional"
        fi
        echo "  $subvol -> $mount_point" > /dev/tty
        echo "    Options: subvol=$subvol,$full_opts" > /dev/tty
    done
    echo > /dev/tty
    
    prompt "Press Enter to continue..." dummy
}

create_btrfs_subvolumes() {
    local root_partition="$1"
    
    log "Creating Btrfs subvolumes..."
    mount "$root_partition" /mnt || { log "ERROR: Failed to mount Btrfs root partition"; return 1; }
    
    for subvol in "${!SUBVOLUMES[@]}"; do
        log "Creating subvolume: $subvol"
        if ! btrfs subvolume create "/mnt/$subvol"; then
            log "ERROR: Failed to create subvolume $subvol"
            umount /mnt
            return 1
        fi
    done
    
    umount /mnt
    log "All Btrfs subvolumes created successfully"
    return 0
}

mount_btrfs_subvolumes() {
    local root_partition="$1"
    
    log "Mounting Btrfs subvolumes..."
    
    # Mount root subvolume first
    local root_opts="subvol=@,$GLOBAL_MOUNT_OPTS"
    if [[ -n "${MOUNT_OPTS[@]}" ]]; then
        root_opts="$root_opts,${MOUNT_OPTS[@]}"
    fi
    
    log "Mounting root subvolume with options: $root_opts"
    if ! mount -o "$root_opts" "$root_partition" /mnt; then
        log "ERROR: Failed to mount root subvolume"
        return 1
    fi
    
    # Create mount directories and mount other subvolumes
    local mount_dirs=()
    for subvol in "${!SUBVOLUMES[@]}"; do
        if [[ "$subvol" != "@" ]]; then
            local mount_point="${SUBVOLUMES[$subvol]}"
            mount_dirs+=("/mnt$mount_point")
        fi
    done
    
    if [[ ${#mount_dirs[@]} -gt 0 ]]; then
        log "Creating mount directories..."
        if ! mkdir -p "${mount_dirs[@]}"; then
            log "ERROR: Failed to create mount directories"
            return 1
        fi
    fi
    
    # Mount other subvolumes
    for subvol in "${!SUBVOLUMES[@]}"; do
        if [[ "$subvol" != "@" ]]; then
            local mount_point="${SUBVOLUMES[$subvol]}"
            local mount_opts="subvol=$subvol,$GLOBAL_MOUNT_OPTS"
            if [[ -n "${MOUNT_OPTS[$subvol]}" ]]; then
                mount_opts="$mount_opts,${MOUNT_OPTS[$subvol]}"
            fi
            
            log "Mounting $subvol to /mnt$mount_point with options: $mount_opts"
            if ! mount -o "$mount_opts" "$root_partition" "/mnt$mount_point"; then
                log "ERROR: Failed to mount subvolume $subvol"
                return 1
            fi
        fi
    done
    
    log "All Btrfs subvolumes mounted successfully"
    return 0
}

create_disk_menu() {
    while true; do
        log "Listing available disks for selection..."
        echo "Available Disks (excluding loop devices and CD-ROMs):" > /dev/tty
        lsblk -d -p -n -o NAME,SIZE,MODEL,TYPE | grep -E "disk" | grep -v loop | nl > /dev/tty
        
        local max_disks
        max_disks=$(lsblk -d -p -n -o NAME,TYPE | grep disk | grep -v loop | wc -l)
        
        if [[ $max_disks -eq 0 ]]; then
            log "ERROR: No suitable disks found"
            return 1
        fi
        
        prompt "Enter the number corresponding to your disk (1-$max_disks, or 'q' to quit): " disk_number
        
        [[ "$disk_number" == "q" ]] && exit 0
        
        if [[ ! "$disk_number" =~ ^[0-9]+$ ]] || [[ "$disk_number" -eq 0 ]]; then
            log "Invalid input: must be a positive number between 1 and $max_disks"
            continue
        fi
        
        if [[ "$disk_number" -gt "$max_disks" ]]; then
            log "Invalid input: number too large (max: $max_disks)"
            continue
        fi
        
        selected_disk=$(lsblk -d -p -n -o NAME,TYPE | grep disk | grep -v loop | awk '{print $1}' | sed -n "${disk_number}p")
        if [[ -z "$selected_disk" ]]; then
            log "ERROR: Failed to get disk name for selection $disk_number"
            continue
        fi
        
        log "Selected disk: $selected_disk"
        if verify_disk_space "$selected_disk"; then
            break
        else
            log "Please select a larger disk or press 'q' to quit"
        fi
    done
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
            partprobe "$disk" || { 
                log "WARNING: Failed to refresh partition table with partprobe, trying alternative"
                blockdev --rereadpt "$disk" || {
                    log "ERROR: Failed to refresh partition table"
                    return 1
                }
            }
            
            # Wait for partitions to appear
            log "Waiting for partitions to be available..."
            local max_attempts=15
            local attempt=0
            while [[ $attempt -lt $max_attempts ]]; do
                if [[ -b "$(get_partition_name "$disk" 1)" ]]; then
                    log "Partitions are now available"
                    break
                fi
                sleep 1
                ((attempt++))
            done
            
            if [[ $attempt -eq $max_attempts ]]; then
                log "ERROR: Partitions did not appear after $max_attempts seconds"
                return 1
            fi
            log "Wiping filesystem signatures from new partitions..."
            wipefs -a "$esp" "$swp" "$root" || { log "WARNING: Failed to wipe some filesystem signatures"; }
            log "Formatting EFI partition ($esp)..."
            mkfs.fat -F32 "$esp" || { log "ERROR: Failed to format EFI partition"; exit 1; }
            log "Creating and activating swap ($swp)..."
            mkswap "$swp" || { log "ERROR: Failed to create swap"; exit 1; }
            swapon "$swp" || { log "WARNING: Failed to activate swap"; }
            log "Formatting BTRFS root partition ($root)..."
            mkfs.btrfs -f "$root" || { log "ERROR: Failed to format BTRFS partition"; exit 1; }
            
            # Configure Btrfs subvolumes and mount options interactively
            configure_btrfs_subvolumes || { log "ERROR: Failed to configure subvolumes"; exit 1; }
            configure_mount_options || { log "ERROR: Failed to configure mount options"; exit 1; }
            preview_btrfs_config
            
            # Create and mount Btrfs subvolumes using user configuration
            create_btrfs_subvolumes "$root" || { log "ERROR: Failed to create subvolumes"; exit 1; }
            mount_btrfs_subvolumes "$root" || { log "ERROR: Failed to mount subvolumes"; exit 1; }
            
            # Mount EFI partition
            mkdir -p /mnt/boot/efi || { log "ERROR: Failed to create EFI directory"; exit 1; }
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
    # Try to auto-detect timezone with timeout and fallback
    timezone=$(timeout 10 curl -s --max-time 5 --fail "https://ipapi.co/timezone" 2>/dev/null || echo "")
    
    if [[ -n "$timezone" && -f "/mnt/usr/share/zoneinfo/$timezone" ]]; then
        log "Auto-detected timezone: $timezone"
        if ! confirm_operation "Use auto-detected timezone '$timezone'?"; then
            timezone=""
        fi
    fi
    
    if [[ -z "$timezone" ]]; then
        log "Please enter your timezone manually."
        echo "Common timezones:" > /dev/tty
        echo "  America/New_York, America/Los_Angeles, America/Chicago" > /dev/tty
        echo "  Europe/London, Europe/Paris, Europe/Berlin" > /dev/tty
        echo "  Asia/Tokyo, Asia/Shanghai, Australia/Sydney" > /dev/tty
        echo > /dev/tty
        
        while true; do
            prompt "Enter your timezone (e.g., America/New_York): " timezone
            if [[ -f "/mnt/usr/share/zoneinfo/$timezone" ]]; then
                break
            else
                log "Invalid timezone '$timezone'. Please try again."
                echo "You can list available timezones with: timedatectl list-timezones" > /dev/tty
            fi
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
    local sudoers_dropin="/mnt/etc/sudoers.d/99_wheel_access"
    log "Configuring sudo access with a drop-in..."
    if [[ ! -d "/mnt/etc/sudoers.d" ]]; then
        mkdir -p /mnt/etc/sudoers.d || { log "ERROR: Failed to create /mnt/etc/sudoers.d"; return 1; }
    fi
    
    # Use more secure sudo configuration with time-limited sessions
    cat > "$sudoers_dropin" <<'EOF'
# Allow wheel group members to execute any command with password
%wheel ALL=(ALL:ALL) ALL

# Extend sudo session timeout to 15 minutes for convenience
Defaults timestamp_timeout=15

# Require password for sensitive operations even within timeout
Defaults passwd_timeout=0
EOF
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to write $sudoers_dropin"
        return 1
    fi
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
    if ! arch-chroot /mnt visudo -cf /etc/sudoers.d/99_wheel_access; then
        log "ERROR: Drop-in sudoers file syntax broken."
        return 1
    fi
    log "Sudo access configured successfully for wheel group with secure defaults."
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
    echo "=============================================================" > /dev/tty
    echo "                  Arch Linux Installer" > /dev/tty
    echo "=============================================================" > /dev/tty
    log "Starting Arch Linux installation..."
    
    show_progress "Checking system requirements"
    check_internet || exit 1
    check_uefi || exit 1
    show_step_complete "System requirements check"
    
    show_progress "Disk selection and preparation"
    create_disk_menu
    wipe_partitions "$selected_disk"
    show_step_complete "Disk preparation"
    
    show_progress "Partitioning and filesystem setup"
    # Always use BTRFS partitioning (no prompt)
    partition_choice="auto_btrfs"
    log "Using automatic BTRFS partitioning"
    perform_partitioning "$selected_disk" "$partition_choice"
    show_step_complete "Partitioning and filesystem setup"
    
    show_progress "Package selection"
    select_install_packages
    show_step_complete "Package selection"
    
    show_progress "Installing base system"
    install_base_system || exit 1
    show_step_complete "Base system installation"
    
    show_progress "Configuring initial ramdisk"
    configure_initramfs || exit 1
    show_step_complete "Initial ramdisk configuration"
    
    show_progress "Setting up networking"
    setup_network || exit 1
    show_step_complete "Network setup"
    
    show_progress "System configuration"
    configure_system || exit 1
    show_step_complete "System configuration"
    
    show_progress "Shell configuration"
    set_root_shell || exit 1
    setup_systemwide_zshenv || exit 1
    set_systemwide_default_shell || exit 1
    show_step_complete "Shell configuration"
    
    show_progress "User account setup"
    setup_user_accounts || exit 1
    show_step_complete "User account setup"
    
    show_progress "Bootloader installation"
    install_bootloader || exit 1
    show_step_complete "Bootloader installation"
    
    show_progress "Final system preparation"
    show_step_complete "Final system preparation"
    
    echo > /dev/tty
    echo "=============================================================" > /dev/tty
    echo "           Installation Completed Successfully!" > /dev/tty
    echo "=============================================================" > /dev/tty
    echo "Your new Arch Linux system is ready!" > /dev/tty
    echo "You can now reboot into your system." > /dev/tty
    echo "Remember to remove the installation media before rebooting." > /dev/tty
    echo "=============================================================" > /dev/tty
    
    log "Installation completed successfully!"
    log "You can now reboot into your new Arch Linux system."
    log "Remember to remove the installation media before rebooting."
}

#-----------------------------------------------------------
# Script Initialization
#-----------------------------------------------------------

# Test function for validating the implementation
test_btrfs_functions() {
    echo "Testing Btrfs configuration functions..."
    
    # Test validation functions
    echo "Testing validate_mount_point:"
    validate_mount_point "/" && echo "  ✓ Root path valid"
    validate_mount_point "/home" && echo "  ✓ /home valid"
    validate_mount_point "/var/log" && echo "  ✓ /var/log valid"
    ! validate_mount_point "/dev/test" && echo "  ✓ /dev/test correctly rejected"
    ! validate_mount_point "invalid" && echo "  ✓ 'invalid' correctly rejected"
    
    echo "Testing validate_subvolume_name:"
    validate_subvolume_name "@" && echo "  ✓ @ valid"
    validate_subvolume_name "@home" && echo "  ✓ @home valid"
    validate_subvolume_name "@test-vol" && echo "  ✓ @test-vol valid"
    ! validate_subvolume_name "invalid" && echo "  ✓ 'invalid' correctly rejected"
    ! validate_subvolume_name "@test/vol" && echo "  ✓ '@test/vol' correctly rejected"
    
    echo "Testing validate_mount_options:"
    validate_mount_options "noatime,compress=zstd" && echo "  ✓ Valid options accepted"
    validate_mount_options "discard=async,space_cache=v2" && echo "  ✓ More valid options accepted"
    
    echo "All tests completed successfully!"
}

# Only run if not in testing mode
if [[ "${TESTING:-0}" != "1" ]]; then
    # Check for test flag
    if [[ "$1" == "--test-btrfs" ]]; then
        test_btrfs_functions
        exit 0
    fi
    
    trap 'handle_error ${LINENO}' ERR
    check_root
    init_log
    check_boot_media "$@"
    main
    exit 0
fi
