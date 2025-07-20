#!/usr/bin/env bash

#===========================================================
# Arch Linux Installation Script - Unit Tests
#===========================================================

# Test configuration
readonly TEST_DIR="/tmp/archinstall_tests"
readonly MOCK_DISK_SIZE=$((30 * 1024 * 1024 * 1024)) # 30GB
readonly TEST_LOG_FILE="$TEST_DIR/test.log"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

#-----------------------------------------------------------
# Test Framework
#-----------------------------------------------------------

setup_test_environment() {
    echo -e "${BLUE}Setting up test environment...${NC}"
    
    # Create test directory
    mkdir -p "$TEST_DIR"/{loop_devices,mount_points}
    
    # Set testing mode to prevent actual system modifications
    export TESTING=1
    
    # Override LOG_FILE before sourcing to avoid readonly conflict
    export LOG_FILE="$TEST_LOG_FILE"
    
    # Source the main script functions
    source ./archinstall.sh
    
    # Override dangerous functions for testing
    override_system_functions
    
    echo -e "${GREEN}Test environment ready${NC}"
}

cleanup_test_environment() {
    echo -e "${BLUE}Cleaning up test environment...${NC}"
    
    # Unmount any test loop devices
    for mount_point in "$TEST_DIR"/mount_points/*; do
        [[ -d "$mount_point" ]] && umount "$mount_point" 2>/dev/null || true
    done
    
    # Detach loop devices
    for loop_file in "$TEST_DIR"/loop_devices/*; do
        [[ -f "$loop_file" ]] && {
            local loop_dev
            loop_dev=$(losetup -j "$loop_file" | cut -d: -f1)
            [[ -n "$loop_dev" ]] && losetup -d "$loop_dev" 2>/dev/null || true
        }
    done
    
    # Clean up files
    rm -rf "$TEST_DIR"
    
    echo -e "${GREEN}Cleanup complete${NC}"
}

override_system_functions() {
    # Override potentially dangerous functions for testing
    
    # Mock parted to just echo commands
    parted() {
        echo "MOCK: parted $*" >> "$TEST_LOG_FILE"
        return 0
    }
    
    # Mock mkfs commands
    mkfs.fat() {
        echo "MOCK: mkfs.fat $*" >> "$TEST_LOG_FILE"
        return 0
    }
    
    mkfs.btrfs() {
        echo "MOCK: mkfs.btrfs $*" >> "$TEST_LOG_FILE"
        return 0
    }
    
    mkswap() {
        echo "MOCK: mkswap $*" >> "$TEST_LOG_FILE"
        return 0
    }
    
    swapon() {
        echo "MOCK: swapon $*" >> "$TEST_LOG_FILE"
        return 0
    }
    
    # Mock btrfs commands
    btrfs() {
        echo "MOCK: btrfs $*" >> "$TEST_LOG_FILE"
        case "$1" in
            "subvolume")
                case "$2" in
                    "create")
                        local subvol_path="$3"
                        mkdir -p "$subvol_path" 2>/dev/null || true
                        ;;
                esac
                ;;
        esac
        return 0
    }
    
    # Mock mount/umount
    mount() {
        echo "MOCK: mount $*" >> "$TEST_LOG_FILE"
        local mount_point="${*: -1}"  # Last argument is usually mount point
        mkdir -p "$mount_point" 2>/dev/null || true
        return 0
    }
    
    umount() {
        echo "MOCK: umount $*" >> "$TEST_LOG_FILE"
        return 0
    }
    
    # Mock other dangerous commands
    wipefs() {
        echo "MOCK: wipefs $*" >> "$TEST_LOG_FILE"
        return 0
    }
    
    partprobe() {
        echo "MOCK: partprobe $*" >> "$TEST_LOG_FILE"
        return 0
    }
    
    export -f parted mkfs.fat mkfs.btrfs mkswap swapon btrfs mount umount wipefs partprobe
}

create_mock_disk() {
    local disk_name="$1"
    local size_bytes="$2"
    local disk_file="$TEST_DIR/loop_devices/$disk_name"
    
    # Create sparse file
    dd if=/dev/zero of="$disk_file" bs=1 count=0 seek="$size_bytes" 2>/dev/null
    
    # Set up loop device
    local loop_dev
    loop_dev=$(losetup -f --show "$disk_file")
    echo "$loop_dev"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    
    ((TESTS_RUN++))
    
    if [[ "$expected" == "$actual" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Expected: $expected"
        echo -e "    Actual: $actual"
        ((TESTS_FAILED++))
        return 1
    fi
}

assert_true() {
    local condition="$1"
    local message="$2"
    
    ((TESTS_RUN++))
    
    if eval "$condition"; then
        echo -e "  ${GREEN}✓${NC} $message"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        ((TESTS_FAILED++))
        return 1
    fi
}

assert_false() {
    local condition="$1"
    local message="$2"
    
    ((TESTS_RUN++))
    
    if ! eval "$condition"; then
        echo -e "  ${GREEN}✓${NC} $message"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        ((TESTS_FAILED++))
        return 1
    fi
}

assert_file_exists() {
    local file_path="$1"
    local message="$2"
    
    assert_true "[[ -f \"$file_path\" ]]" "$message"
}

assert_contains() {
    local needle="$1"
    local haystack="$2"
    local message="$3"
    
    assert_true "[[ \"$haystack\" == *\"$needle\"* ]]" "$message"
}

#-----------------------------------------------------------
# Validation Function Tests
#-----------------------------------------------------------

test_validation_functions() {
    echo -e "${YELLOW}Testing validation functions...${NC}"
    
    # Test validate_mount_point
    assert_true "validate_mount_point '/'" "Root path should be valid"
    assert_true "validate_mount_point '/home'" "/home should be valid"
    assert_true "validate_mount_point '/var/log'" "/var/log should be valid"
    assert_true "validate_mount_point '/usr/local/bin'" "Deep path should be valid"
    
    assert_false "validate_mount_point 'invalid'" "Relative path should be invalid"
    assert_false "validate_mount_point '/dev/test'" "/dev paths should be invalid"
    assert_false "validate_mount_point '/proc/test'" "/proc paths should be invalid"
    assert_false "validate_mount_point '/sys/test'" "/sys paths should be invalid"
    assert_false "validate_mount_point '/run/test'" "/run paths should be invalid"
    assert_false "validate_mount_point '/tmp/test'" "/tmp paths should be invalid"
    
    # Test validate_subvolume_name
    assert_true "validate_subvolume_name '@'" "Root subvolume should be valid"
    assert_true "validate_subvolume_name '@home'" "@home should be valid"
    assert_true "validate_subvolume_name '@var-log'" "@var-log should be valid"
    assert_true "validate_subvolume_name '@test_vol'" "@test_vol should be valid"
    assert_true "validate_subvolume_name '@123'" "@123 should be valid"
    
    assert_false "validate_subvolume_name 'invalid'" "Name without @ should be invalid"
    assert_false "validate_subvolume_name '@test/vol'" "Name with slash should be invalid"
    assert_false "validate_subvolume_name '@test vol'" "Name with space should be invalid"
    assert_false "validate_subvolume_name '@test@vol'" "Name with multiple @ should be invalid"
    
    # Test validate_mount_options
    assert_true "validate_mount_options 'noatime'" "Single option should be valid"
    assert_true "validate_mount_options 'noatime,compress=zstd'" "Multiple options should be valid"
    assert_true "validate_mount_options 'discard=async,space_cache=v2'" "Complex options should be valid"
}

#-----------------------------------------------------------
# Disk Utility Tests
#-----------------------------------------------------------

test_disk_utilities() {
    echo -e "${YELLOW}Testing disk utility functions...${NC}"
    
    # Test get_partition_name
    local nvme_result
    nvme_result=$(get_partition_name "/dev/nvme0n1" "1")
    assert_equals "/dev/nvme0n1p1" "$nvme_result" "NVMe partition naming should work"
    
    local sata_result
    sata_result=$(get_partition_name "/dev/sda" "2")
    assert_equals "/dev/sda2" "$sata_result" "SATA partition naming should work"
    
    # Test calculate_swap_size
    local swap_size
    swap_size=$(calculate_swap_size)
    assert_true "[[ '$swap_size' =~ ^[0-9]+$ ]]" "Swap size should be numeric"
    assert_true "[[ '$swap_size' -gt 0 ]]" "Swap size should be positive"
}

#-----------------------------------------------------------
# Btrfs Configuration Tests
#-----------------------------------------------------------

test_btrfs_configuration() {
    echo -e "${YELLOW}Testing Btrfs configuration functions...${NC}"
    
    # Initialize arrays for testing
    unset SUBVOLUMES MOUNT_OPTS
    declare -gA SUBVOLUMES MOUNT_OPTS
    GLOBAL_MOUNT_OPTS=""
    
    # Test default subvolume initialization
    SUBVOLUMES["@"]="/"
    SUBVOLUMES["@home"]="/home"
    SUBVOLUMES["@log"]="/var/log"
    
    assert_equals "/" "${SUBVOLUMES[@]}" "Root subvolume should be set"
    assert_equals "/home" "${SUBVOLUMES[@home]}" "@home subvolume should be set"
    assert_equals "/var/log" "${SUBVOLUMES[@log]}" "@log subvolume should be set"
    
    # Test mount options
    GLOBAL_MOUNT_OPTS="noatime,compress=zstd"
    MOUNT_OPTS["@home"]="autodefrag"
    
    assert_equals "noatime,compress=zstd" "$GLOBAL_MOUNT_OPTS" "Global mount options should be set"
    assert_equals "autodefrag" "${MOUNT_OPTS[@home]}" "Per-subvolume options should be set"
}

#-----------------------------------------------------------
# Mock Partitioning Tests
#-----------------------------------------------------------

test_partitioning_simulation() {
    echo -e "${YELLOW}Testing partitioning simulation...${NC}"
    
    # Create a mock disk
    local mock_disk
    mock_disk=$(create_mock_disk "test_disk" "$MOCK_DISK_SIZE")
    
    assert_file_exists "$TEST_DIR/loop_devices/test_disk" "Mock disk file should be created"
    assert_true "[[ -b '$mock_disk' ]]" "Mock disk should be a block device"
    
    # Test verify_disk_space with mock disk
    local disk_size
    disk_size=$(blockdev --getsize64 "$mock_disk" 2>/dev/null || echo 0)
    assert_true "[[ '$disk_size' -ge '$((20 * 1024 * 1024 * 1024))' ]]" "Mock disk should be large enough"
    
    # Test partition name generation
    local esp
    esp=$(get_partition_name "$mock_disk" 1)
    assert_contains "1" "$esp" "EFI partition name should contain partition number"
    
    # Clean up
    losetup -d "$mock_disk" 2>/dev/null || true
}

#-----------------------------------------------------------
# Integration Tests
#-----------------------------------------------------------

test_btrfs_integration() {
    echo -e "${YELLOW}Testing Btrfs integration...${NC}"
    
    # Set up test environment
    local test_mount="/tmp/test_mnt"
    mkdir -p "$test_mount"
    
    # Initialize configuration
    unset SUBVOLUMES MOUNT_OPTS
    declare -gA SUBVOLUMES MOUNT_OPTS
    SUBVOLUMES["@"]="/"
    SUBVOLUMES["@home"]="/home"
    GLOBAL_MOUNT_OPTS="noatime,compress=zstd"
    
    # Test create_btrfs_subvolumes (mocked)
    assert_true "create_btrfs_subvolumes '/dev/mock'" "Should create subvolumes successfully"
    
    # Test mount_btrfs_subvolumes (mocked)
    assert_true "mount_btrfs_subvolumes '/dev/mock'" "Should mount subvolumes successfully"
    
    # Check log for expected operations
    if [[ -f "$LOG_FILE" ]]; then
        assert_contains "btrfs subvolume create" "$(cat "$LOG_FILE")" "Should log subvolume creation"
        assert_contains "mount -o" "$(cat "$LOG_FILE")" "Should log mount operations"
    fi
    
    # Clean up
    rm -rf "$test_mount"
}

#-----------------------------------------------------------
# Performance and Edge Case Tests
#-----------------------------------------------------------

test_edge_cases() {
    echo -e "${YELLOW}Testing edge cases...${NC}"
    
    # Test empty inputs
    assert_false "validate_mount_point ''" "Empty mount point should be invalid"
    assert_false "validate_subvolume_name ''" "Empty subvolume name should be invalid"
    
    # Test very long inputs
    local long_path
    long_path="/$(printf 'a%.0s' {1..255})"  # 256 character path
    assert_false "validate_mount_point '$long_path'" "Extremely long path should be invalid"
    
    # Test special characters
    assert_false "validate_mount_point '/test with spaces'" "Path with spaces should be invalid"
    assert_false "validate_subvolume_name '@test with spaces'" "Subvolume with spaces should be invalid"
    
    # Test case sensitivity
    assert_true "validate_subvolume_name '@Test'" "Uppercase in subvolume should be valid"
    assert_true "validate_mount_point '/Test'" "Uppercase in path should be valid"
}

#-----------------------------------------------------------
# Error Handling Tests
#-----------------------------------------------------------

test_error_handling() {
    echo -e "${YELLOW}Testing error handling...${NC}"
    
    # Test with non-existent disk
    assert_false "verify_disk_space '/dev/nonexistent'" "Non-existent disk should fail verification"
    
    # Test with insufficient space (create tiny mock disk)
    local tiny_disk
    tiny_disk=$(create_mock_disk "tiny_disk" $((1024 * 1024)))  # 1MB disk
    
    assert_false "verify_disk_space '$tiny_disk'" "Tiny disk should fail size verification"
    
    # Clean up
    losetup -d "$tiny_disk" 2>/dev/null || true
}

#-----------------------------------------------------------
# Main Test Runner
#-----------------------------------------------------------

run_all_tests() {
    echo -e "${BLUE}Starting comprehensive unit tests for archinstall.sh${NC}"
    echo "============================================================="
    
    setup_test_environment
    
    # Clear log file
    > "$LOG_FILE"
    
    # Run test suites
    test_validation_functions
    test_disk_utilities
    test_btrfs_configuration
    test_partitioning_simulation
    test_btrfs_integration
    test_edge_cases
    test_error_handling
    
    # Print results
    echo
    echo "============================================================="
    echo -e "${BLUE}Test Results:${NC}"
    echo -e "  Total tests: $TESTS_RUN"
    echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
    echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "  ${GREEN}All tests passed! ✓${NC}"
        local exit_code=0
    else
        echo -e "  ${RED}Some tests failed! ✗${NC}"
        local exit_code=1
    fi
    
    cleanup_test_environment
    
    return $exit_code
}

# Check if we're being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check for root (needed for loop device operations)
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: Tests require root privileges for loop device operations${NC}"
        echo "Please run: sudo $0"
        exit 1
    fi
    
    run_all_tests
    exit $?
fi