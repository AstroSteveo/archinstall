#!/bin/bash

# Test Configuration for archinstall.sh Test Suite
# This file contains test data, mock responses, and configuration
# for comprehensive testing scenarios.

#######################################
# Mock Data Configuration
#######################################

# Sample disk configurations for testing
declare -A MOCK_DISKS=(
    ["/dev/sda"]="100G disk"
    ["/dev/sdb"]="50G disk" 
    ["/dev/nvme0n1"]="250G nvme"
    ["/dev/vda"]="20G disk"
)

# Sample partition layouts
declare -A MOCK_PARTITIONS=(
    ["/dev/sda1"]="512M EFI"
    ["/dev/sda2"]="2G swap"
    ["/dev/sda3"]="97.5G Linux"
)

# Valid test usernames
VALID_USERNAMES=(
    "user"
    "testuser" 
    "test_user"
    "user123"
    "a"
    "user-name"
    "arch"
    "linux"
    "admin"
)

# Invalid test usernames
INVALID_USERNAMES=(
    "User"           # Capital letter
    "123user"        # Starts with number
    "user@"          # Special character
    "user space"     # Contains space
    ""               # Empty string
    "verylongusernamethatistoolongtobevalidbecauseitexceedsthirtytwocharacters"
    "user."          # Ends with dot
    "-user"          # Starts with dash
    "user-"          # Ends with dash
    "root"           # Reserved username
    "bin"            # System username
)

# Valid test hostnames
VALID_HOSTNAMES=(
    "arch"
    "my-computer"
    "host1"
    "test-123"
    "archlinux"
    "server"
    "desktop"
    "laptop"
    "workstation"
)

# Invalid test hostnames
INVALID_HOSTNAMES=(
    "-arch"          # Starts with dash
    "arch-"          # Ends with dash
    "arch_host"      # Contains underscore
    "arch host"      # Contains space
    ""               # Empty string
    "arch."          # Ends with dot
    ".arch"          # Starts with dot
    "arch..host"     # Double dots
    "verylonghostnamethatistoolongtobevalidbecauseitexceedsthemaximumlengthof63characters"
)

# Test passwords
TEST_PASSWORDS=(
    "password123"
    "StrongP@ssw0rd"
    "simple"
    "verylongpasswordthatshouldalsowork"
)

# Filesystem types for testing
FILESYSTEM_TYPES=(
    "ext4"
    "btrfs"
    "xfs"
)

# CPU vendors for testing
CPU_VENDORS=(
    "intel"
    "amd"
    "other"
)

# Bootloader types
BOOTLOADERS=(
    "grub"
    "systemd-boot"
)

# Shell types
USER_SHELLS=(
    "/bin/bash"
    "/bin/zsh" 
    "/bin/fish"
    "/bin/dash"
)

#######################################
# Mock Command Responses
#######################################

# lsblk output variations
MOCK_LSBLK_SIMPLE="sda sdb nvme0n1"

MOCK_LSBLK_DETAILED="NAME        SIZE TYPE
sda        100G disk
├─sda1     512M part
├─sda2       2G part
└─sda3    97.5G part
sdb         50G disk
nvme0n1    250G disk"

MOCK_LSBLK_EMPTY=""

MOCK_LSBLK_SINGLE_DISK="NAME        SIZE TYPE
sda        100G disk"

# blkid output variations
MOCK_BLKID_OUTPUT="/dev/sda1: UUID=\"1234-5678\" TYPE=\"vfat\" PARTUUID=\"abcd-1234\"
/dev/sda2: UUID=\"12345678-1234-1234-1234-123456789012\" TYPE=\"swap\" PARTUUID=\"abcd-1235\"
/dev/sda3: UUID=\"12345678-1234-1234-1234-123456789013\" TYPE=\"ext4\" PARTUUID=\"abcd-1236\""

# mount output variations  
MOCK_MOUNT_EMPTY=""
MOCK_MOUNT_WITH_DISK="/dev/sda1 on /boot type vfat (rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro)"

# ping responses
MOCK_PING_SUCCESS="PING archlinux.org (95.217.163.246): 56 data bytes
64 bytes from 95.217.163.246: icmp_seq=0 ttl=51 time=20.1 ms"

MOCK_PING_FAILURE="ping: archlinux.org: Name or service not known"

#######################################
# Test Scenario Configurations
#######################################

# Complete installation scenarios
declare -A TEST_SCENARIO_MINIMAL=(
    [DISK]="/dev/sda"
    [FILESYSTEM_TYPE]="ext4"
    [HOSTNAME]="arch"
    [USERNAME]="user"
    [USER_SHELL]="/bin/bash"
    [BOOTLOADER]="grub"
    [CPU_VENDOR]="intel"
    [ENABLE_MULTILIB]="no"
    [ENABLE_SUDO]="yes"
)

declare -A TEST_SCENARIO_FULL=(
    [DISK]="/dev/nvme0n1"
    [FILESYSTEM_TYPE]="btrfs"
    [HOSTNAME]="archlinux"
    [USERNAME]="archuser"
    [USER_SHELL]="/bin/zsh"
    [BOOTLOADER]="systemd-boot"
    [CPU_VENDOR]="amd"
    [ENABLE_MULTILIB]="yes"
    [ENABLE_SUDO]="yes"
    [BTRFS_CUSTOM_LAYOUT]="yes"
)

declare -A TEST_SCENARIO_SERVER=(
    [DISK]="/dev/sdb"
    [FILESYSTEM_TYPE]="ext4"
    [HOSTNAME]="server"
    [USERNAME]="admin"
    [USER_SHELL]="/bin/bash"
    [BOOTLOADER]="grub"
    [CPU_VENDOR]="intel"
    [ENABLE_MULTILIB]="no"
    [ENABLE_SUDO]="yes"
)

#######################################
# Error Simulation Configurations
#######################################

# Network failure scenarios
NETWORK_FAILURE_MODES=(
    "no_internet"
    "dns_failure"
    "timeout"
)

# Disk failure scenarios
DISK_FAILURE_MODES=(
    "disk_not_found"
    "disk_mounted"
    "insufficient_space"
    "read_only"
)

# System failure scenarios
SYSTEM_FAILURE_MODES=(
    "pacstrap_failure"
    "chroot_failure"
    "bootloader_failure"
    "user_creation_failure"
)

#######################################
# Utility Functions for Test Configuration
#######################################

get_test_scenario() {
    local scenario_name="$1"
    
    case "$scenario_name" in
        "minimal")
            for key in "${!TEST_SCENARIO_MINIMAL[@]}"; do
                export "$key"="${TEST_SCENARIO_MINIMAL[$key]}"
            done
            ;;
        "full")
            for key in "${!TEST_SCENARIO_FULL[@]}"; do
                export "$key"="${TEST_SCENARIO_FULL[$key]}"
            done
            ;;
        "server")
            for key in "${!TEST_SCENARIO_SERVER[@]}"; do
                export "$key"="${TEST_SCENARIO_SERVER[$key]}"
            done
            ;;
        *)
            echo "Unknown test scenario: $scenario_name" >&2
            return 1
            ;;
    esac
}

simulate_failure_mode() {
    local failure_mode="$1"
    
    case "$failure_mode" in
        "no_internet")
            export MOCK_EXIT_CODE=1
            ;;
        "disk_not_found")
            # Remove mock disk files
            rm -f "$MOCK_DIR/dev"/*
            ;;
        "pacstrap_failure")
            # Make pacstrap return failure
            echo 'exit 1' > "$MOCK_DIR/bin/pacstrap"
            ;;
        *)
            echo "Unknown failure mode: $failure_mode" >&2
            return 1
            ;;
    esac
}

#######################################
# Test Data Generators
#######################################

generate_random_valid_username() {
    echo "${VALID_USERNAMES[$((RANDOM % ${#VALID_USERNAMES[@]}))]}"
}

generate_random_invalid_username() {
    echo "${INVALID_USERNAMES[$((RANDOM % ${#INVALID_USERNAMES[@]}))]}"
}

generate_random_valid_hostname() {
    echo "${VALID_HOSTNAMES[$((RANDOM % ${#VALID_HOSTNAMES[@]}))]}"
}

generate_random_invalid_hostname() {
    echo "${INVALID_HOSTNAMES[$((RANDOM % ${#INVALID_HOSTNAMES[@]}))]}"
}

generate_test_password() {
    echo "${TEST_PASSWORDS[$((RANDOM % ${#TEST_PASSWORDS[@]}))]}"
}

#######################################
# Mock Response Generators
#######################################

generate_lsblk_response() {
    local response_type="${1:-detailed}"
    
    case "$response_type" in
        "simple")
            echo "$MOCK_LSBLK_SIMPLE"
            ;;
        "detailed")
            echo "$MOCK_LSBLK_DETAILED"
            ;;
        "empty")
            echo "$MOCK_LSBLK_EMPTY"
            ;;
        "single")
            echo "$MOCK_LSBLK_SINGLE_DISK"
            ;;
        *)
            echo "$MOCK_LSBLK_DETAILED"
            ;;
    esac
}

generate_mount_response() {
    local has_mounted_disk="${1:-false}"
    
    if [[ "$has_mounted_disk" == "true" ]]; then
        echo "$MOCK_MOUNT_WITH_DISK"
    else
        echo "$MOCK_MOUNT_EMPTY"
    fi
}

generate_ping_response() {
    local success="${1:-true}"
    
    if [[ "$success" == "true" ]]; then
        echo "$MOCK_PING_SUCCESS"
    else
        echo "$MOCK_PING_FAILURE"
    fi
}

#######################################
# Test Environment Verification
#######################################

verify_test_environment() {
    local errors=0
    
    # Check if archinstall.sh exists
    if [[ ! -f "$TEST_SCRIPT_DIR/archinstall.sh" ]]; then
        echo "ERROR: archinstall.sh not found in $TEST_SCRIPT_DIR" >&2
        ((errors++))
    fi
    
    # Check if we can create mock directory
    if ! mkdir -p "/tmp/test_verify_$$"; then
        echo "ERROR: Cannot create temporary directories" >&2
        ((errors++))
    else
        rmdir "/tmp/test_verify_$$"
    fi
    
    # Check if bash version supports required features
    if [[ "${BASH_VERSION%%.*}" -lt 4 ]]; then
        echo "ERROR: Bash 4.0 or higher required" >&2
        ((errors++))
    fi
    
    return $errors
}

#######################################
# Test Reporting Functions
#######################################

generate_test_report() {
    local test_log_file="$1"
    local report_file="${2:-/tmp/archinstall_test_report.txt}"
    
    {
        echo "Arch Linux Installation Script Test Report"
        echo "Generated: $(date)"
        echo "========================================"
        echo
        
        echo "Test Environment:"
        echo "- Bash Version: $BASH_VERSION"
        echo "- Test Script: $TEST_SCRIPT_DIR/test_archinstall.sh"
        echo "- Target Script: $TEST_SCRIPT_DIR/archinstall.sh"
        echo
        
        if [[ -f "$test_log_file" ]]; then
            echo "Test Results:"
            grep -E "(PASS|FAIL|INFO):" "$test_log_file" || echo "No test results found"
        else
            echo "No test log file found at: $test_log_file"
        fi
        
    } > "$report_file"
    
    echo "Test report generated: $report_file"
}