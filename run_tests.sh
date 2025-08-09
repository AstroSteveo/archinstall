#!/bin/bash

# Test Runner for Arch Linux Installation Script
# Provides easy execution of different test suites with various options

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_LOG="/tmp/archinstall_test_run_$(date +%Y%m%d_%H%M%S).log"

# Color codes (only set if not already defined)
if [[ -z "${RED:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

#######################################
# Test Runner Functions
#######################################

info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$TEST_LOG"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$TEST_LOG"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$TEST_LOG"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$TEST_LOG"
}

show_usage() {
    cat << 'EOF'
Usage: ./run_tests.sh [OPTIONS] [TEST_SUITE]

Test Runner for archinstall.sh Test Suites

TEST_SUITES:
    basic       Run basic test suite (default)
    advanced    Run advanced test suite with comprehensive testing
    all         Run all test suites
    quick       Run quick validation tests only
    integration Run integration tests only
    security    Run security-focused tests only

OPTIONS:
    -h, --help      Show this help message
    -v, --verbose   Enable verbose output
    -q, --quiet     Suppress non-essential output
    -l, --log FILE  Specify custom log file
    -r, --report    Generate detailed test report
    --dry-run       Show what would be tested without execution
    --clean         Clean up test artifacts before running
    --keep-artifacts Keep test artifacts after completion

EXAMPLES:
    ./run_tests.sh                    # Run basic test suite
    ./run_tests.sh advanced           # Run advanced test suite
    ./run_tests.sh all --verbose      # Run all tests with verbose output
    ./run_tests.sh quick --quiet      # Run quick tests quietly
    ./run_tests.sh --report           # Run basic tests and generate report

EOF
}

check_dependencies() {
    local missing_deps=()
    
    # Check for required commands
    local required_commands=("bash" "grep" "sed" "awk")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    # Check bash version
    if [[ "${BASH_VERSION%%.*}" -lt 4 ]]; then
        error "Bash 4.0 or higher required (current: $BASH_VERSION)"
        return 1
    fi
    
    # Check for test files
    local test_files=("$SCRIPT_DIR/test_archinstall.sh" "$SCRIPT_DIR/archinstall.sh")
    
    for file in "${test_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            missing_deps+=("$file")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error "Missing dependencies:"
        printf '  - %s\n' "${missing_deps[@]}"
        return 1
    fi
    
    return 0
}

clean_artifacts() {
    info "Cleaning up test artifacts..."
    
    # Remove temporary files and directories
    rm -rf /tmp/archinstall_mocks
    rm -rf /tmp/mock_state
    rm -f /tmp/mock_calls.log
    rm -f /tmp/test_input_*
    rm -f /tmp/archinstall_test_source.sh
    
    success "Test artifacts cleaned"
}

run_basic_tests() {
    info "Running basic test suite..."
    
    if [[ -f "$SCRIPT_DIR/test_archinstall.sh" ]]; then
        bash "$SCRIPT_DIR/test_archinstall.sh" 2>&1 | tee -a "$TEST_LOG"
        return ${PIPESTATUS[0]}
    else
        error "Basic test script not found: $SCRIPT_DIR/test_archinstall.sh"
        return 1
    fi
}

run_advanced_tests() {
    info "Running advanced test suite..."
    
    if [[ -f "$SCRIPT_DIR/test_advanced.sh" ]]; then
        bash "$SCRIPT_DIR/test_advanced.sh" 2>&1 | tee -a "$TEST_LOG"
        return ${PIPESTATUS[0]}
    else
        error "Advanced test script not found: $SCRIPT_DIR/test_advanced.sh"
        return 1
    fi
}

run_quick_tests() {
    info "Running quick validation tests..."
    
    # Source the test framework
    source "$SCRIPT_DIR/test_archinstall.sh"
    
    # Run only validation tests
    setup_mocks
    source_archinstall_functions
    
    local quick_tests=(
        "UEFI Boot Validation" test_validate_uefi_boot_success
        "Username Validation (Valid)" test_validate_username_valid
        "Username Validation (Invalid)" test_validate_username_invalid
        "Hostname Validation (Valid)" test_validate_hostname_valid
        "Hostname Validation (Invalid)" test_validate_hostname_invalid
    )
    
    for ((i=0; i<${#quick_tests[@]}; i+=2)); do
        run_test "${quick_tests[i]}" "${quick_tests[i+1]}"
    done
    
    cleanup_mocks
    print_test_summary
}

run_integration_tests() {
    info "Running integration tests..."
    
    # Source both test frameworks
    source "$SCRIPT_DIR/test_archinstall.sh"
    source "$SCRIPT_DIR/test_advanced.sh"
    
    setup_advanced_mocks
    source_archinstall_functions
    setup_mock_responses
    
    local integration_tests=(
        "Complete Configuration Workflow" test_complete_configuration_workflow
        "Complete Installation Simulation" test_complete_installation_simulation
        "Complete Disk Workflow" test_disk_workflow
    )
    
    for ((i=0; i<${#integration_tests[@]}; i+=2)); do
        run_test "${integration_tests[i]}" "${integration_tests[i+1]}"
    done
    
    cleanup_mocks
    print_test_summary
}

run_security_tests() {
    info "Running security-focused tests..."
    
    source "$SCRIPT_DIR/test_advanced.sh"
    source "$SCRIPT_DIR/test_archinstall.sh"
    
    setup_advanced_mocks
    source_archinstall_functions
    
    local security_tests=(
        "Input Sanitization" test_input_sanitization
        "Path Traversal Protection" test_path_traversal_protection
        "Special Characters Input" test_special_characters_input
        "Very Long Input" test_very_long_input
    )
    
    for ((i=0; i<${#security_tests[@]}; i+=2)); do
        run_test "${security_tests[i]}" "${security_tests[i+1]}"
    done
    
    cleanup_mocks
    print_test_summary
}

run_all_tests() {
    info "Running all test suites..."
    
    local suite_results=()
    
    # Run basic tests
    if run_basic_tests; then
        suite_results+=("Basic: PASSED")
    else
        suite_results+=("Basic: FAILED")
    fi
    
    # Run advanced tests
    if run_advanced_tests; then
        suite_results+=("Advanced: PASSED")
    else
        suite_results+=("Advanced: FAILED")
    fi
    
    # Print summary
    echo
    echo "=========================================="
    echo "All Test Suites Summary"
    echo "=========================================="
    for result in "${suite_results[@]}"; do
        if [[ "$result" == *"PASSED"* ]]; then
            echo -e "${GREEN}$result${NC}"
        else
            echo -e "${RED}$result${NC}"
        fi
    done
    
    # Return success only if all suites passed
    for result in "${suite_results[@]}"; do
        if [[ "$result" == *"FAILED"* ]]; then
            return 1
        fi
    done
    
    return 0
}

generate_test_report() {
    local report_file="${1:-/tmp/archinstall_test_report_$(date +%Y%m%d_%H%M%S).txt}"
    
    info "Generating test report: $report_file"
    
    {
        echo "Arch Linux Installation Script Test Report"
        echo "=========================================="
        echo "Generated: $(date)"
        echo "Test Log: $TEST_LOG"
        echo
        
        echo "System Information:"
        echo "- OS: $(uname -s)"
        echo "- Kernel: $(uname -r)"
        echo "- Bash Version: $BASH_VERSION"
        echo "- Test Script Directory: $SCRIPT_DIR"
        echo
        
        echo "Test Results:"
        if [[ -f "$TEST_LOG" ]]; then
            grep -E "\[(PASS|FAIL|INFO)\]" "$TEST_LOG" | tail -50
        else
            echo "No test log available"
        fi
        
        echo
        echo "Test Coverage Summary:"
        if [[ -f "$TEST_LOG" ]]; then
            local total_tests
            local passed_tests
            local failed_tests
            
            total_tests=$(grep -c "\[PASS\]\|\[FAIL\]" "$TEST_LOG" 2>/dev/null || echo 0)
            passed_tests=$(grep -c "\[PASS\]" "$TEST_LOG" 2>/dev/null || echo 0)
            failed_tests=$(grep -c "\[FAIL\]" "$TEST_LOG" 2>/dev/null || echo 0)
            
            echo "- Total Tests: $total_tests"
            echo "- Passed: $passed_tests"
            echo "- Failed: $failed_tests"
            
            if [[ $total_tests -gt 0 ]]; then
                local success_rate=$((passed_tests * 100 / total_tests))
                echo "- Success Rate: ${success_rate}%"
            fi
        fi
        
    } > "$report_file"
    
    success "Test report generated: $report_file"
}

dry_run() {
    local test_suite="$1"
    
    echo "Dry Run: Would execute test suite '$test_suite'"
    echo
    echo "Files that would be used:"
    echo "- Main test script: $SCRIPT_DIR/test_archinstall.sh"
    echo "- Advanced test script: $SCRIPT_DIR/test_advanced.sh"
    echo "- Target script: $SCRIPT_DIR/archinstall.sh"
    echo "- Test configuration: $SCRIPT_DIR/test_config.sh"
    echo
    echo "Temporary files that would be created:"
    echo "- Mock directory: /tmp/archinstall_mocks"
    echo "- Mock state: /tmp/mock_state"
    echo "- Mock calls log: /tmp/mock_calls.log"
    echo "- Test log: $TEST_LOG"
    echo
    echo "Dependencies check:"
    if check_dependencies; then
        echo "All dependencies satisfied"
    else
        echo "Missing dependencies (see above)"
    fi
}

main() {
    local test_suite="basic"
    local verbose=false
    local quiet=false
    local generate_report=false
    local dry_run_mode=false
    local clean_first=false
    local keep_artifacts=false
    local custom_log=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                verbose=true
                set -x
                shift
                ;;
            -q|--quiet)
                quiet=true
                shift
                ;;
            -l|--log)
                custom_log="$2"
                shift 2
                ;;
            -r|--report)
                generate_report=true
                shift
                ;;
            --dry-run)
                dry_run_mode=true
                shift
                ;;
            --clean)
                clean_first=true
                shift
                ;;
            --keep-artifacts)
                keep_artifacts=true
                shift
                ;;
            basic|advanced|all|quick|integration|security)
                test_suite="$1"
                shift
                ;;
            *)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Set custom log file if specified
    if [[ -n "$custom_log" ]]; then
        TEST_LOG="$custom_log"
    fi
    
    # Quiet mode setup
    if [[ "$quiet" == true ]]; then
        exec 1>/dev/null
    fi
    
    # Header
    echo "Arch Linux Installation Script Test Runner"
    echo "Test Suite: $test_suite"
    echo "Log File: $TEST_LOG"
    echo "=========================================="
    echo
    
    # Clean artifacts if requested
    if [[ "$clean_first" == true ]]; then
        clean_artifacts
    fi
    
    # Dry run mode
    if [[ "$dry_run_mode" == true ]]; then
        dry_run "$test_suite"
        exit 0
    fi
    
    # Check dependencies
    if ! check_dependencies; then
        error "Dependency check failed"
        exit 1
    fi
    
    # Make test scripts executable
    chmod +x "$SCRIPT_DIR/test_archinstall.sh" 2>/dev/null || true
    chmod +x "$SCRIPT_DIR/test_advanced.sh" 2>/dev/null || true
    
    # Initialize test log
    echo "Test run started: $(date)" > "$TEST_LOG"
    
    # Run the specified test suite
    local test_result=0
    
    case "$test_suite" in
        basic)
            run_basic_tests || test_result=$?
            ;;
        advanced)
            run_advanced_tests || test_result=$?
            ;;
        all)
            run_all_tests || test_result=$?
            ;;
        quick)
            run_quick_tests || test_result=$?
            ;;
        integration)
            run_integration_tests || test_result=$?
            ;;
        security)
            run_security_tests || test_result=$?
            ;;
        *)
            error "Unknown test suite: $test_suite"
            exit 1
            ;;
    esac
    
    # Generate report if requested
    if [[ "$generate_report" == true ]]; then
        generate_test_report
    fi
    
    # Clean up artifacts unless keeping them
    if [[ "$keep_artifacts" == false ]]; then
        clean_artifacts
    fi
    
    # Final status
    echo
    if [[ $test_result -eq 0 ]]; then
        success "Test suite '$test_suite' completed successfully"
    else
        error "Test suite '$test_suite' completed with failures"
    fi
    
    exit $test_result
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi