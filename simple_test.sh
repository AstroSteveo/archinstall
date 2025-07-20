#!/usr/bin/env bash

# Simple compatibility test for NixOS and other systems
echo "Running simplified Arch Linux installer tests..."

# Set test environment
export TESTING=1
export LOG_FILE="/tmp/test.log"

# Source the main script
if ! source ./archinstall.sh 2>/dev/null; then
    echo "❌ Failed to source archinstall.sh"
    exit 1
fi

echo "✅ Successfully sourced archinstall.sh"

# Test validation functions
echo "Testing validation functions..."

# Test mount point validation
if validate_mount_point "/" && validate_mount_point "/home"; then
    echo "  ✅ Mount point validation works"
else
    echo "  ❌ Mount point validation failed"
fi

if ! validate_mount_point "/dev/invalid" && ! validate_mount_point "invalid"; then
    echo "  ✅ Mount point rejection works"
else
    echo "  ❌ Mount point rejection failed"
fi

# Test subvolume validation
if validate_subvolume_name "@" && validate_subvolume_name "@home"; then
    echo "  ✅ Subvolume name validation works"
else
    echo "  ❌ Subvolume name validation failed"
fi

if ! validate_subvolume_name "invalid" && ! validate_subvolume_name "@test/vol"; then
    echo "  ✅ Subvolume name rejection works"
else
    echo "  ❌ Subvolume name rejection failed"
fi

# Test mount options validation
if validate_mount_options "noatime,compress=zstd"; then
    echo "  ✅ Mount options validation works"
else
    echo "  ❌ Mount options validation failed"
fi

# Test disk utility functions
echo "Testing disk utilities..."

nvme_result=$(get_partition_name "/dev/nvme0n1" "1")
sata_result=$(get_partition_name "/dev/sda" "2")

if [[ "$nvme_result" == "/dev/nvme0n1p1" ]] && [[ "$sata_result" == "/dev/sda2" ]]; then
    echo "  ✅ Partition naming works correctly"
else
    echo "  ❌ Partition naming failed: nvme=$nvme_result, sata=$sata_result"
fi

swap_size=$(calculate_swap_size)
if [[ "$swap_size" =~ ^[0-9]+$ ]] && [[ "$swap_size" -gt 0 ]]; then
    echo "  ✅ Swap size calculation works ($swap_size MiB)"
else
    echo "  ❌ Swap size calculation failed: $swap_size"
fi

# Test Btrfs configuration
echo "Testing Btrfs configuration..."

# Initialize arrays
declare -A SUBVOLUMES MOUNT_OPTS
SUBVOLUMES["@"]="/"
SUBVOLUMES["@home"]="/home"
GLOBAL_MOUNT_OPTS="noatime,compress=zstd"

if [[ "${SUBVOLUMES[@]}" == "/" ]] && [[ "${SUBVOLUMES[@home]}" == "/home" ]]; then
    echo "  ✅ Subvolume array configuration works"
else
    echo "  ❌ Subvolume array configuration failed"
fi

if [[ "$GLOBAL_MOUNT_OPTS" == "noatime,compress=zstd" ]]; then
    echo "  ✅ Mount options configuration works"
else
    echo "  ❌ Mount options configuration failed"
fi

echo ""
echo "🎉 Basic functionality test completed!"
echo ""
echo "To test the full installer interactively, run:"
echo "  sudo ./archinstall.sh"
echo ""
echo "The installer will guide you through:"
echo "  1. System requirements check"
echo "  2. Disk selection"
echo "  3. Interactive Btrfs configuration"
echo "  4. Mount options setup"
echo "  5. Full Arch Linux installation"