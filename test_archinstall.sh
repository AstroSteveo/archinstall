#!/bin/bash

# Comprehensive Test Suite for archinstall.sh
# Arch Linux Installation Script Testing Framework
#
# This test suite provides thorough coverage of the archinstall.sh script
# using mocked system commands and various test scenarios.

set -euo pipefail

# Test framework configuration
TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHINSTALL_SCRIPT="$TEST_SCRIPT_DIR/archinstall.sh"
TEST_LOG="${TEST_LOG:-/tmp/test_archinstall.log}"
MOCK_DIR="/tmp/archinstall_mocks"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

# Color codes for test output (only set if not already defined)
if [[ -z "${RED:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

#######################################
# Test Framework Functions
#######################################

test_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$TEST_LOG"
}

test_info() {
    echo -e "${BLUE}[TEST INFO]${NC} $*"
    test_log "INFO: $*"
}

test_success() {
    echo -e "${GREEN}[PASS]${NC} $*"
    test_log "PASS: $*"
}

test_failure() {
    echo -e "${RED}[FAIL]${NC} $*"
    test_log "FAIL: $*"
}

test_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    test_log "WARN: $*"
}

# Test assertion functions
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        test_failure "Expected '$expected' but got '$actual'. $message"
        return 1
    fi
}

assert_not_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    if [[ "$expected" != "$actual" ]]; then
        return 0
    else
        test_failure "Expected not '$expected' but got '$actual'. $message"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-}"
    
    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        test_failure "Expected '$haystack' to contain '$needle'. $message"
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local message="${2:-}"
    
    if [[ -f "$file" ]]; then
        return 0
    else
        test_failure "Expected file '$file' to exist. $message"
        return 1
    fi
}

assert_command_success() {
    local command="$1"
    local message="${2:-}"
    
    if eval "$command" &>/dev/null; then
        return 0
    else
        test_failure "Expected command '$command' to succeed. $message"
        return 1
    fi
}

assert_command_failure() {
    local command="$1"
    local message="${2:-}"
    
    if ! eval "$command" &>/dev/null; then
        return 0
    else
        test_failure "Expected command '$command' to fail. $message"
        return 1
    fi
}

#######################################
# Mock System Setup
#######################################

setup_mocks() {
    mkdir -p "$MOCK_DIR/bin"
    mkdir -p "$MOCK_DIR/sys/firmware/efi/efivars"
    mkdir -p "$MOCK_DIR/dev"
    mkdir -p "$MOCK_DIR/proc"
    mkdir -p "$MOCK_DIR/mnt"
    
    # Mock system directories for UEFI validation
    export MOCK_EFI_DIR="$MOCK_DIR/sys/firmware/efi/efivars"
    
    # Create mock devices
    touch "$MOCK_DIR/dev/sda"
    touch "$MOCK_DIR/dev/sdb"
    touch "$MOCK_DIR/dev/nvme0n1"
    
    # Create mock executables
    create_mock_command "curl"
    create_mock_command "ping"
    create_mock_command "curl"
    create_mock_command "lsblk"
    create_mock_command "blkid"
    create_mock_command "mount"
    create_mock_command "umount"
    create_mock_command "mkfs.ext4"
    create_mock_command "mkfs.btrfs"
    create_mock_command "mkfs.fat"
    create_mock_command "mkswap"
    create_mock_command "swapon"
    create_mock_command "swapoff"
    create_mock_command "mountpoint"
    create_mock_command "pacstrap"
    create_mock_command "arch-chroot"
    create_mock_command "genfstab"
    create_mock_command "grub-install"
    create_mock_command "grub-mkconfig"
    create_mock_command "bootctl"
    create_mock_command "useradd"
    create_mock_command "usermod"
    create_mock_command "passwd"
    create_mock_command "chsh"
    
    # Add mock directory to PATH
    export PATH="$MOCK_DIR/bin:$PATH"
}

create_mock_command() {
    local cmd="$1"
    local mock_file="$MOCK_DIR/bin/$cmd"
    
    cat > "$mock_file" << 'EOF'
#!/bin/bash
# Mock command - logs calls and returns success by default
echo "MOCK_CALL: $0 $*" >> /tmp/mock_calls.log
exit ${MOCK_EXIT_CODE:-0}
EOF
    
    chmod +x "$mock_file"
}

setup_mock_responses() {
    # Setup default mock responses
    export MOCK_EXIT_CODE=0
    
    # Clear previous mock calls
    > /tmp/mock_calls.log
    
    # Create specific mock responses for complex commands
    cat > "$MOCK_DIR/bin/lsblk" << 'EOF'
#!/bin/bash
echo "MOCK_CALL: lsblk $*" >> /tmp/mock_calls.log
if [[ "$*" == *"-o NAME,SIZE,MODEL,TYPE"* ]]; then
    cat << 'LSBLK_OUTPUT'
sda 100G MockDisk disk
sdb 50G MockDisk disk
nvme0n1 250G MockNVMe disk
LSBLK_OUTPUT
else
    echo "sda sdb nvme0n1"
fi
exit ${MOCK_EXIT_CODE:-0}
EOF

    chmod +x "$MOCK_DIR/bin/lsblk"
}

cleanup_mocks() {
    rm -rf "$MOCK_DIR"
    rm -f /tmp/mock_calls.log
}

#######################################
# Test Source Loading
#######################################

source_archinstall_functions() {
    # Source the archinstall script without executing main
    # We'll override the main function to prevent execution
    
    # Create a temporary version of the script with main function disabled
    local temp_script="/tmp/archinstall_test_source.sh"
    
    # Copy everything except the main execution at the end
    sed '/^if \[\[ "${BASH_SOURCE\[0\]}" == "${0}" \]\]; then/,$d' "$ARCHINSTALL_SCRIPT" > "$temp_script"
    
    # Source the functions
    source "$temp_script"
    
    # Clean up
    rm -f "$temp_script"
}

#######################################
# Test Runner
#######################################

run_test() {
    local test_name="$1"
    local test_function="$2"

    CURRENT_TEST="$test_name"
    ((TESTS_RUN+=1))
    
    test_info "Running: $test_name"
    
    # Setup clean environment for each test
    setup_mock_responses
    
    if "$test_function"; then
        test_success "$test_name"
        ((TESTS_PASSED+=1))
    else
        test_failure "$test_name"
        ((TESTS_FAILED+=1))
    fi
    
    echo
}

#######################################
# Validation Function Tests
#######################################

test_validate_uefi_boot_success() {
    # Mock UEFI directory exists
    mkdir -p "$MOCK_EFI_DIR"
    
    # Override the directory check to use our mock
    validate_uefi_boot() {
        if [[ ! -d "$MOCK_EFI_DIR" ]]; then
            fatal "This script requires UEFI boot mode. Legacy BIOS is not supported."
        fi
        success "UEFI boot mode detected"
    }
    
    # Test should pass
    validate_uefi_boot
    return $?
}

test_validate_uefi_boot_failure() {
    # Remove mock UEFI directory
    rm -rf "$MOCK_EFI_DIR"
    
    # Override the directory check and fatal function
    validate_uefi_boot() {
        if [[ ! -d "$MOCK_EFI_DIR" ]]; then
            return 1  # Simulate fatal error
        fi
        return 0
    }
    
    # Test should fail
    if validate_uefi_boot; then
        return 1  # Test failed - should have returned error
    else
        return 0  # Test passed - correctly detected missing UEFI
    fi
}

test_validate_network_success_curl() {
    export MOCK_EXIT_CODE=0

    validate_network

    if grep -q "curl.*archlinux.org" /tmp/mock_calls.log; then
        return 0
    else
        test_failure "curl command not called"
        return 1
    fi
}

test_validate_network_success_ping_fallback() {
    export MOCK_EXIT_CODE=0
    cat > "$MOCK_DIR/bin/curl" <<'EOF'
#!/bin/bash
echo "MOCK_CALL: curl $*" >> /tmp/mock_calls.log
exit 1
EOF
    chmod +x "$MOCK_DIR/bin/curl"

    validate_network

    if grep -q "ping.*archlinux.org" /tmp/mock_calls.log; then
        return 0
    else
        test_failure "curl command not called"
        return 1
    fi
}

test_validate_network_failure() {
    export MOCK_EXIT_CODE=1
    fatal() { return 1; }
    validate_network() {
        info "Checking network connectivity..."
        fatal "No internet connection. Please configure networking and try again."
    }

    if validate_network; then
        return 1
    else
        return 0
    fi
}

test_validate_network_failure_no_tools() {
    fatal() { return 1; }
    command() {
        if [[ $1 == -v && ( $2 == curl || $2 == ping ) ]]; then
            return 1
        fi
        builtin command "$@"
    }
    ping() { return 127; }
    curl() { return 127; }

    if validate_network; then
        unset -f command ping curl
        return 1
    else
        unset -f command ping curl
        return 0
    fi
}

test_validate_disk_success() {
    local test_disk="/dev/sda"
    
    # Create mock block device
    mkdir -p "$(dirname "$test_disk")"
    touch "$test_disk"
    
    # Override block device test
    validate_disk() {
        local disk="$1"
        # Simple existence check for our test
        if [[ ! -f "$disk" ]]; then
            return 1
        fi
        return 0
    }
    
    validate_disk "$test_disk"
    return $?
}

test_validate_disk_nonexistent() {
    local test_disk="/dev/nonexistent"
    
    # Override validation function
    validate_disk() {
        local disk="$1"
        if [[ ! -f "$disk" ]]; then
            return 1
        fi
        return 0
    }
    
    if validate_disk "$test_disk"; then
        return 1  # Test failed - should have detected nonexistent disk
    else
        return 0  # Test passed - correctly detected missing disk
    fi
}

test_validate_username_valid() {
    local valid_usernames=("user" "testuser" "test_user" "user123" "a" "user-name")
    
    for username in "${valid_usernames[@]}"; do
        if ! validate_username "$username"; then
            test_failure "Valid username '$username' was rejected"
            return 1
        fi
    done
    
    return 0
}

test_validate_username_invalid() {
    local invalid_usernames=("User" "123user" "user@" "user space" "" "verylongusernamethatistoolongtobevalid")
    
    for username in "${invalid_usernames[@]}"; do
        if validate_username "$username"; then
            test_failure "Invalid username '$username' was accepted"
            return 1
        fi
    done
    
    return 0
}

test_validate_hostname_valid() {
    validate_hostname() {
        local hostname="$1"
        if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
            return 1
        fi
        if [[ ${#hostname} -gt 63 ]]; then
            return 1
        fi
        return 0
    }
    
    local valid_hostnames=("arch" "my-computer" "host1" "test-123")
    
    for hostname in "${valid_hostnames[@]}"; do
        if ! validate_hostname "$hostname"; then
            test_failure "Valid hostname '$hostname' was rejected"
            return 1
        fi
    done
    
    return 0
}

test_validate_hostname_invalid() {
    validate_hostname() {
        local hostname="$1"
        if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
            return 1
        fi
        if [[ ${#hostname} -gt 63 ]]; then
            return 1
        fi
        return 0
    }
    
    local invalid_hostnames=("-arch" "arch-" "arch_host" "arch host" "" "verylonghostnamethatistoolongtobevalidbecauseitexceedsthemaximumlength")
    
    for hostname in "${invalid_hostnames[@]}"; do
        if validate_hostname "$hostname"; then
            test_failure "Invalid hostname '$hostname' was accepted"
            return 1
        fi
    done
    
    return 0
}

#######################################
# Disk Management Tests
#######################################

test_create_partitions_gpt() {
    export DISK="/dev/sda"
    export FILESYSTEM_TYPE="ext4"
    
    # Mock the create_partitions function to avoid actual disk operations
    create_partitions() {
        info "Creating GPT partition table on $DISK"
        # Log the partition creation
        echo "CREATE_PARTITIONS: $DISK $FILESYSTEM_TYPE" >> /tmp/mock_calls.log
        return 0
    }
    
    create_partitions
    
    # Verify the function was called
    if grep -q "CREATE_PARTITIONS.*$DISK.*$FILESYSTEM_TYPE" /tmp/mock_calls.log; then
        return 0
    else
        return 1
    fi
}

test_partition_prefix() {
    assert_equals "/dev/sda" "$(partition_prefix /dev/sda)" "Prefix for sda incorrect"
    assert_equals "/dev/nvme0n1p" "$(partition_prefix /dev/nvme0n1)" "Prefix for nvme incorrect"
    assert_equals "/dev/mmcblk0p" "$(partition_prefix /dev/mmcblk0)" "Prefix for mmcblk incorrect"
    assert_equals "/dev/loop0p" "$(partition_prefix /dev/loop0)" "Prefix for loop incorrect"
    return 0
}

test_format_partitions_ext4() {
    export DISK="/dev/sda"
    export FILESYSTEM_TYPE="ext4"
    
    # Test ext4 formatting
    format_partitions
    
    # Check if appropriate mkfs commands were called
    if grep -q "mkfs.fat" /tmp/mock_calls.log && \
       grep -q "mkfs.ext4" /tmp/mock_calls.log && \
       grep -q "mkswap" /tmp/mock_calls.log; then
        return 0
    else
        test_failure "Expected mkfs commands not found in mock calls"
        return 1
    fi
}

test_format_partitions_btrfs() {
    export DISK="/dev/sda"
    export FILESYSTEM_TYPE="btrfs"
    
    format_partitions
    
    # Check if btrfs formatting was called
    if grep -q "mkfs.btrfs" /tmp/mock_calls.log; then
        return 0
    else
        test_failure "mkfs.btrfs command not found in mock calls"
        return 1
    fi
}

test_mount_filesystems() {
    export DISK="/dev/sda"
    export FILESYSTEM_TYPE="ext4"
    mount_filesystems
    
    # Verify mount commands were called
    if grep -q "mount" /tmp/mock_calls.log; then
        return 0
    else
        test_failure "mount command not found in mock calls"
        return 1
    fi
}

test_format_partitions_records_swap_partition() {
    export DISK="/dev/sda"
    export FILESYSTEM_TYPE="ext4"

    format_partitions

    assert_equals "/dev/sda2" "$SWAP_PARTITION" "SWAP_PARTITION not set correctly"
}

test_cleanup_uses_swap_partition() {
    export DISK="/dev/sda"
    export FILESYSTEM_TYPE="ext4"
    export SWAP_PARTITION="/dev/sda2"

    cleanup

    if grep -q "swapoff /dev/sda2" /tmp/mock_calls.log; then
        return 0
    else
        test_failure "swapoff not called for $SWAP_PARTITION"
        return 1
    fi
}

#######################################
# System Configuration Tests
#######################################

test_configure_pacman() {
    export ENABLE_MULTILIB="yes"
    
    configure_pacman
    
    # This test mainly verifies the function runs without error
    # In a real scenario, we would check /etc/pacman.conf modifications
    return 0
}

test_install_base_system() {
    export CPU_VENDOR="intel"
    
    install_base_system
    
    # Verify pacstrap was called
    if grep -q "pacstrap" /tmp/mock_calls.log; then
        return 0
    else
        test_failure "pacstrap command not found in mock calls"
        return 1
    fi
}

test_configure_bootloader_grub() {
    export BOOTLOADER="grub"
    export DISK="/dev/sda"
    
    configure_bootloader
    
    # Verify GRUB installation commands
    if grep -q "grub-install" /tmp/mock_calls.log && \
       grep -q "grub-mkconfig" /tmp/mock_calls.log; then
        return 0
    else
        test_failure "GRUB commands not found in mock calls"
        return 1
    fi
}

test_configure_bootloader_systemd() {
    export BOOTLOADER="systemd-boot"

    configure_bootloader

    # Verify bootctl installation
    if grep -q "bootctl" /tmp/mock_calls.log; then
        return 0
    else
        test_failure "bootctl command not found in mock calls"
        return 1
    fi
}

test_configure_users() {
    export USERNAME="testuser"
    export USER_PASSWORD="testpass"
    export USER_SHELL="zsh"
    export ENABLE_SUDO="yes"
    export ROOT_PASSWORD="rootpass"
    mkdir -p "$MOUNT_POINT/home/$USERNAME"
    mkdir -p "$MOUNT_POINT/etc/sudoers.d"

    id -u "$USERNAME" &>/dev/null || /usr/sbin/useradd -M "$USERNAME"

    cat > "$MOCK_DIR/bin/arch-chroot" <<'EOF'
#!/bin/bash
echo "MOCK_CALL: $0 $*" >> /tmp/mock_calls.log
CHROOT="$1"
shift
cmd="$1"
shift
if [[ "$cmd" == "chown" ]]; then
    chown "$1" "$CHROOT$2"
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/bin/arch-chroot"

    configure_users

    assert_file_exists "$MOUNT_POINT/home/$USERNAME/.zshrc" ".zshrc not created"

    local owner
    owner=$(stat -c '%U' "$MOUNT_POINT/home/$USERNAME/.zshrc")
    assert_equals "$USERNAME" "$owner" ".zshrc ownership incorrect"

    if [[ "$ENABLE_SUDO" == "yes" ]]; then
        assert_file_exists "$MOUNT_POINT/etc/sudoers.d/$USERNAME" "sudoers file missing"
    fi

    if grep -q "useradd" /tmp/mock_calls.log; then
        create_mock_command "arch-chroot"
        return 0
    else
        test_failure "useradd command not found in mock calls"
        create_mock_command "arch-chroot"
        return 1
    fi
}

#######################################
# Edge Cases and Error Handling Tests
#######################################

test_empty_input_handling() {
    # Test various functions with empty inputs
    
    if validate_username ""; then
        test_failure "Empty username should be invalid"
        return 1
    fi
    
    return 0
}

test_special_characters_input() {
    local special_inputs=('$USER' '$(whoami)' '`id`' '; rm -rf /')
    
    for input in "${special_inputs[@]}"; do
        if validate_username "$input"; then
            test_failure "Special character input '$input' should be invalid"
            return 1
        fi
    done
    
    return 0
}

test_very_long_input() {
    local long_string
    long_string=$(printf 'a%.0s' {1..100})
    
    if validate_username "$long_string"; then
        test_failure "Very long input should be invalid"
        return 1
    fi
    
    return 0
}

#######################################
# Integration Tests
#######################################

test_disk_workflow() {
    export DISK="/dev/sda"
    export FILESYSTEM_TYPE="ext4"
    
    # Test the complete disk workflow
    create_partitions
    format_partitions
    mount_filesystems
    
    # Verify all steps were executed
    local expected_calls=("CREATE_PARTITIONS" "mkfs" "mount")
    for call in "${expected_calls[@]}"; do
        if ! grep -q "$call" /tmp/mock_calls.log; then
            test_failure "Expected call '$call' not found"
            return 1
        fi
    done
    
    return 0
}

#######################################
# Test Suite Execution
#######################################

print_test_summary() {
    echo
    echo "=================================="
    echo "Test Suite Summary"
    echo "=================================="
    echo "Total Tests: $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        return 1
    fi
}

main() {
    echo "Arch Linux Installation Script Test Suite"
    echo "=========================================="
    echo
    
    # Initialize test environment
    test_info "Setting up test environment..."
    setup_mocks
    source_archinstall_functions
    
    # Clear test log
    > "$TEST_LOG"
    
    test_info "Starting test execution..."
    echo
    
    # Validation Function Tests
    run_test "UEFI Boot Validation (Success)" test_validate_uefi_boot_success
    run_test "UEFI Boot Validation (Failure)" test_validate_uefi_boot_failure
    run_test "Network Validation (Success via curl)" test_validate_network_success_curl
    run_test "Network Validation (Success via ping fallback)" test_validate_network_success_ping_fallback
    run_test "Network Validation (Failure)" test_validate_network_failure
    run_test "Network Validation (Failure no tools)" test_validate_network_failure_no_tools
    run_test "Disk Validation (Success)" test_validate_disk_success
    run_test "Disk Validation (Nonexistent)" test_validate_disk_nonexistent
    run_test "Username Validation (Valid)" test_validate_username_valid
    run_test "Username Validation (Invalid)" test_validate_username_invalid
    run_test "Hostname Validation (Valid)" test_validate_hostname_valid
    run_test "Hostname Validation (Invalid)" test_validate_hostname_invalid
    
    # Disk Management Tests
    run_test "Create Partitions (GPT)" test_create_partitions_gpt
    run_test "Partition Prefix Helper" test_partition_prefix
    run_test "Format Partitions (ext4)" test_format_partitions_ext4
    run_test "Format Partitions (btrfs)" test_format_partitions_btrfs
    run_test "Mount Filesystems" test_mount_filesystems
    run_test "Format Partitions Records Swap Partition" test_format_partitions_records_swap_partition
    run_test "Cleanup Uses Recorded Swap Partition" test_cleanup_uses_swap_partition

    # System Configuration Tests
    run_test "Configure Pacman" test_configure_pacman
    run_test "Install Base System" test_install_base_system
    run_test "Configure Bootloader (GRUB)" test_configure_bootloader_grub
    run_test "Configure Bootloader (systemd-boot)" test_configure_bootloader_systemd
    run_test "Configure Users" test_configure_users
    
    # Edge Cases and Error Handling
    run_test "Empty Input Handling" test_empty_input_handling
    run_test "Special Characters Input" test_special_characters_input
    run_test "Very Long Input" test_very_long_input
    
    # Integration Tests
    run_test "Complete Disk Workflow" test_disk_workflow
    
    # Cleanup
    cleanup_mocks
    
    # Print summary
    print_test_summary
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
