# Testing Documentation for archinstall.sh

This document describes the comprehensive test suite for the Arch Linux installation script.

## Overview

The test suite provides thorough validation of the `archinstall.sh` script through multiple testing approaches:

- **Unit Tests**: Individual function validation
- **Integration Tests**: Complete workflow testing
- **Mock System**: Simulated system commands and environments
- **Input Simulation**: Automated user interaction testing
- **Error Scenarios**: Failure condition testing
- **Security Tests**: Input sanitization and security validation

## Test Files

### Core Test Files

- `test_archinstall.sh` - Main test suite with basic functionality tests
- `test_advanced.sh` - Advanced tests including integration and error scenarios
- `test_config.sh` - Test configuration, mock data, and utility functions
- `run_tests.sh` - Test runner with multiple execution options

### Generated Files

- `/tmp/archinstall_test_*.log` - Test execution logs
- `/tmp/archinstall_mocks/` - Mock system directory structure
- `/tmp/mock_state/` - Mock command state tracking
- `/tmp/mock_calls.log` - Mock command call logging

## Quick Start

### Run Basic Tests
```bash
./run_tests.sh
```

### Run All Tests
```bash
./run_tests.sh all
```

### Run Specific Test Suite
```bash
./run_tests.sh advanced
./run_tests.sh quick
./run_tests.sh security
```

### Generate Test Report
```bash
./run_tests.sh --report
```

## Test Suites

### Basic Test Suite (`test_archinstall.sh`)

Tests core functionality including:

- **Validation Functions**
  - `validate_uefi_boot()` - UEFI boot mode detection
  - `validate_network()` - Network connectivity validation
  - `validate_disk()` - Disk existence and availability
  - `validate_username()` - Username format validation
  - `validate_hostname()` - Hostname format validation

- **Disk Management**
  - Partition creation (GPT)
  - Filesystem formatting (ext4, btrfs)
  - Mount operations

- **System Configuration**
  - Pacman configuration
  - Base system installation
  - Bootloader configuration (GRUB, systemd-boot)
  - User account creation

### Advanced Test Suite (`test_advanced.sh`)

Comprehensive testing including:

- **Interactive Function Testing**
  - Simulated user input for disk selection
  - Filesystem type selection
  - User configuration workflows

- **Integration Testing**
  - Complete installation workflow simulation
  - Multi-component interaction validation

- **Error Scenario Testing**
  - Network failure handling
  - Disk operation failures
  - Package installation failures

- **Performance Testing**
  - Rapid function call validation
  - Large input handling

- **Security Testing**
  - Input sanitization validation
  - Path traversal protection
  - Malicious input rejection

## Mock System

The test suite uses a sophisticated mocking system to simulate system commands and environments without requiring actual system modifications.

### Mock Commands

All system commands are mocked:
- `lsblk`, `blkid`, `mount`, `umount`
- `mkfs.ext4`, `mkfs.btrfs`, `mkfs.fat`, `mkswap`
- `pacstrap`, `arch-chroot`, `genfstab`
- `grub-install`, `grub-mkconfig`, `systemd-boot`
- `useradd`, `usermod`, `passwd`, `chsh`
- `ping` (for network testing)

### Mock System Structure

```
/tmp/archinstall_mocks/
├── bin/                    # Mock executables
├── sys/firmware/efi/       # Mock UEFI environment
├── dev/                    # Mock device files
├── proc/                   # Mock proc filesystem
├── etc/                    # Mock system configuration
└── mnt/                    # Mock mount points
```

### Mock State Tracking

The mock system tracks:
- Command execution counts
- Command arguments and parameters
- System state changes (mounts, installations)
- Failure simulation modes

## Test Configuration

### Test Data (`test_config.sh`)

The configuration file provides:

- **Valid/Invalid Test Data**
  - Usernames, hostnames, passwords
  - Disk devices and filesystem types
  - System configuration options

- **Test Scenarios**
  - Minimal installation configuration
  - Full-featured installation
  - Server installation setup

- **Mock Response Templates**
  - System command outputs
  - Error condition simulations
  - Network response variations

### Environment Variables

Tests use environment variables for configuration:

```bash
export MOCK_EXIT_CODE=0        # Mock command exit code
export DISK="/dev/sda"         # Target disk for testing
export FILESYSTEM_TYPE="ext4"  # Filesystem type
export USERNAME="testuser"     # Test username
export HOSTNAME="testhost"     # Test hostname
```

## Running Tests

### Test Runner Options

```bash
./run_tests.sh [OPTIONS] [TEST_SUITE]

Options:
  -h, --help      Show help message
  -v, --verbose   Enable verbose output
  -q, --quiet     Suppress non-essential output
  -l, --log FILE  Specify custom log file
  -r, --report    Generate detailed test report
  --dry-run       Show what would be tested
  --clean         Clean up artifacts before running
  --keep-artifacts Keep artifacts after completion

Test Suites:
  basic       Basic functionality tests (default)
  advanced    Comprehensive testing with mocks
  all         All test suites
  quick       Quick validation tests only
  integration Integration tests only
  security    Security-focused tests only
```

### Examples

```bash
# Basic test run
./run_tests.sh

# Comprehensive testing with report
./run_tests.sh all --verbose --report

# Security testing only
./run_tests.sh security --quiet

# Dry run to see what would be tested
./run_tests.sh advanced --dry-run

# Custom log file
./run_tests.sh --log /tmp/my_test.log
```

## Test Results

### Success Criteria

Tests pass when:
- All validation functions correctly accept/reject inputs
- Mock system commands are called with correct parameters
- Error conditions are properly handled
- Security checks prevent malicious input
- Integration workflows complete successfully

### Failure Analysis

Test failures indicate:
- Function logic errors
- Missing error handling
- Incorrect parameter validation
- Security vulnerabilities
- Integration issues

### Test Output

```
[INFO] Running: Username Validation (Valid)
[PASS] Username Validation (Valid)

[INFO] Running: Network Validation (Failure)
[PASS] Network Validation (Failure)

==================================
Test Suite Summary
==================================
Total Tests: 25
Passed: 24
Failed: 1
```

## Extending Tests

### Adding New Tests

1. **Create Test Function**
```bash
test_new_functionality() {
    # Setup test environment
    local test_input="example"
    
    # Execute function under test
    if my_function "$test_input"; then
        return 0
    else
        test_failure "Function failed with input: $test_input"
        return 1
    fi
}
```

2. **Add to Test Runner**
```bash
run_test "New Functionality Test" test_new_functionality
```

### Mock New Commands

1. **Create Mock Command**
```bash
create_mock_command "new_command"
```

2. **Define Command Behavior**
```bash
cat > "$MOCK_DIR/bin/new_command" << 'EOF'
#!/bin/bash
echo "MOCK_CALL: new_command $*" >> /tmp/mock_calls.log
# Custom behavior here
exit ${MOCK_EXIT_CODE:-0}
EOF
```

### Add Test Scenarios

1. **Define in test_config.sh**
```bash
declare -A TEST_SCENARIO_NEW=(
    [PARAM1]="value1"
    [PARAM2]="value2"
)
```

2. **Use in Tests**
```bash
get_test_scenario "new"
# Variables are now available
```

## Continuous Integration

The test suite is designed for CI/CD integration:

### Exit Codes
- `0` - All tests passed
- `1` - Some tests failed
- `2` - Test environment setup failed

### Automated Reports
```bash
# Generate report for CI
./run_tests.sh all --quiet --report > test_results.txt
```

### Parallel Execution
Tests can be run in parallel environments as they:
- Use unique temporary directories
- Don't modify system state
- Are completely isolated

## Troubleshooting

### Common Issues

1. **Permission Errors**
```bash
chmod +x test_*.sh run_tests.sh
```

2. **Missing Dependencies**
```bash
# Check bash version
bash --version

# Verify required commands
which grep sed awk
```

3. **Mock Failures**
```bash
# Clean up previous test artifacts
./run_tests.sh --clean
```

### Debug Mode

Enable debug output:
```bash
./run_tests.sh --verbose
# or
bash -x ./run_tests.sh
```

### Log Analysis

Check detailed logs:
```bash
tail -f /tmp/archinstall_test_*.log
grep FAIL /tmp/archinstall_test_*.log
```

## Best Practices

### Test Development
- Write tests before implementing features
- Test both success and failure conditions
- Use descriptive test names
- Include edge case testing
- Validate error messages

### Mock Usage
- Keep mocks simple and focused
- Simulate realistic system responses
- Test with various mock configurations
- Clean up mock state between tests

### Maintenance
- Update tests when script functionality changes
- Add regression tests for bug fixes
- Review test coverage regularly
- Update mock data for new system versions

## Security Considerations

The test suite includes security-focused testing:

- **Input Validation**: Ensures malicious input is rejected
- **Path Traversal**: Prevents directory traversal attacks
- **Command Injection**: Validates against command injection
- **Resource Limits**: Tests with large inputs and resource constraints

Security tests help ensure the installation script is robust against:
- Malicious user input
- System environment attacks
- Resource exhaustion
- Privilege escalation attempts