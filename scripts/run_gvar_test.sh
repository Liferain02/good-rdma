#!/bin/bash
#
# Distributed NUMA GVar Zero-Config Test Runner
#
# This script helps you run the gvar_simple_test with zero configuration.
#
# Usage:
#   On Master (10.10.10.13):
#     ./run_gvar_test.sh --master
#     ./run_gvar_test.sh              # auto-detect master
#
#   On Workers (10.10.10.18, 10.10.10.23):
#     ./run_gvar_test.sh 10.10.10.13
#     ./run_gvar_test.sh --join 10.10.10.13
#
# Options:
#   --master           Run as master
#   --join <ip>        Join specified master
#   --nodes <n>        Wait for n nodes before testing
#   --single           Single-node mode
#   --port <n>         Set port (default: 12345)
#   --help             Show this help
#
# Environment:
#   GRDMA_MASTER_IP    Default master IP if not specified
#   GRDMA_PORT         Default port (default: 12345)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_BIN="${SCRIPT_DIR}/gvar_simple_test"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get local IP
get_local_ip() {
    ip addr | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d'/' -f1 | head -1
}

# Print colored message
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Show usage
show_help() {
    grep "^#" "$0" | head -20 | tail -16 | sed 's/^#//'
}

# Main
main() {
    local master_ip=""
    local join_mode=false
    local wait_nodes=0
    local port="${GRDMA_PORT:-12345}"
    local single_mode=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --master|-m)
                master_ip=""
                join_mode=false
                shift
                ;;
            --join|-j)
                master_ip="$2"
                join_mode=true
                shift 2
                ;;
            --nodes|-n)
                wait_nodes="$2"
                shift 2
                ;;
            --single|-s)
                single_mode=true
                shift
                ;;
            --port|-p)
                port="$2"
                shift 2
                ;;
            -*)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                # Assume it's the master IP
                master_ip="$1"
                join_mode=true
                shift
                ;;
        esac
    done

    # Check if test binary exists
    if [[ ! -x "$TEST_BIN" ]]; then
        print_error "Test binary not found: $TEST_BIN"
        print_info "Please run 'make gvar_simple_test' in the src directory first."
        exit 1
    fi

    # Get local IP
    local local_ip=$(get_local_ip)
    print_info "Local IP: $local_ip"
    print_info "Port: $port"

    # Build command
    local cmd="$TEST_BIN --port $port"

    if [[ "$single_mode" == true ]]; then
        cmd="$cmd --single"
        print_info "Running in single-node mode"
    elif [[ "$join_mode" == true ]]; then
        if [[ -z "$master_ip" ]]; then
            print_error "Master IP required for worker mode"
            exit 1
        fi
        cmd="$cmd --join $master_ip"
        print_info "Worker mode: joining master $master_ip"
    else
        # Auto-detect mode
        if [[ -n "$GRDMA_MASTER_IP" && "$local_ip" != "$GRDMA_MASTER_IP" ]]; then
            cmd="$cmd --join $GRDMA_MASTER_IP"
            print_info "Auto mode: joining master $GRDMA_MASTER_IP"
        else
            cmd="$cmd --master"
            print_info "Master mode: starting as master"
        fi
    fi

    if [[ "$wait_nodes" -gt 0 ]]; then
        cmd="$cmd --nodes $wait_nodes"
        print_info "Waiting for $wait_nodes nodes"
    fi

    print_info "Command: $cmd"
    echo ""

    # Run the test
    eval "$cmd"
}

main "$@"
