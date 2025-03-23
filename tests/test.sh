#!/bin/bash
# =========================================================================
# Unified Test Script for Letmein
# =========================================================================
# This script is a unified entry point for all tests:
# - CI mode: executes tests directly (as it's already in a container)
# - Container mode: creates a new Docker container and runs tests in it
# - Debug mode: launches an interactive shell in a container for debugging
echo "starting test.sh"
# Colors for display
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default settings
MODE="container"           # Mode: ci, container, debug
LOG_LEVEL="normal"         # Log level: minimal, normal, verbose
DEBUG_INTERVAL="5"         # Interval for debug state capture (seconds)
WITH_GEN_KEY=""            # Whether to include gen-key test
TEST_ARGS=""               # Additional arguments to pass to run-tests.sh

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --ci)
            MODE="ci"
            shift
            ;;
        --container)
            MODE="container"
            shift
            ;;
        --debug)
            MODE="debug"
            shift
            ;;
        --log-level=*)
            LOG_LEVEL="${1#*=}"
            shift
            ;;
        --log-level)
            LOG_LEVEL="$2"
            shift 2
            ;;
        --debug-interval=*)
            DEBUG_INTERVAL="${1#*=}"
            shift
            ;;
        --debug-interval)
            DEBUG_INTERVAL="$2"
            shift 2
            ;;
        --with-gen-key)
            WITH_GEN_KEY="gen-key"
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS] [TEST_ARGS...]"
            echo "Options:"
            echo "  --ci                Run tests directly (CI mode)"
            echo "  --container         Run tests in a new container (default)"
            echo "  --debug             Start a shell in the container for debugging"
            echo "  --log-level=LEVEL   Set log level (minimal, normal, verbose)"
            echo "  --log-level LEVEL   Same as above"
            echo "  --debug-interval=N  Set debug state capture interval in seconds"
            echo "  --debug-interval N  Same as above"
            echo "  --with-gen-key      Include tests for key generation"
            echo "  --help              Show this help message"
            echo ""
            echo "TEST_ARGS can be one or more of: knock, close, gen-key"
            echo "Example: $0 --ci knock close"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            # This is a test argument to pass to run-tests.sh
            TEST_ARGS="$TEST_ARGS $1"
            shift
            ;;
    esac
done

# Function to run in CI mode
run_ci() {
    echo -e "${GREEN}Running tests in CI mode${NC}"
    
    # Construct the test arguments
    local test_args=""
    
    # Add WITH_GEN_KEY if specified
    if [ -n "$WITH_GEN_KEY" ]; then
        test_args="$test_args $WITH_GEN_KEY"
    fi
    
    # Add any additional arguments from TEST_ARGS
    if [ -n "$TEST_ARGS" ]; then
        test_args="$test_args $TEST_ARGS"
    fi
    
    # Trim leading whitespace
    test_args="${test_args# }"
    
    # Run the tests with the constructed arguments
    if [ -n "$test_args" ]; then
        echo -e "${BLUE}Running tests: $test_args${NC}"
        ./tests/run-tests.sh $test_args
    else
        echo -e "${BLUE}Running all tests${NC}"
        ./tests/run-tests.sh
    fi
    
    exit $?
}

# Function to run in container mode
run_container() {
    echo -e "${BLUE}Building and running tests in container mode${NC}"
    
    # Make sure Docker is available
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Error: Docker is not installed or not in PATH${NC}"
        exit 1
    fi
    
    # Build the test image
    echo -e "${YELLOW}Building test container image...${NC}"
    docker build -f Dockerfile.test -t letmein-test .
    
    # Construct the test arguments
    local test_args=""
    
    # Add WITH_GEN_KEY if specified
    if [ -n "$WITH_GEN_KEY" ]; then
        test_args="$test_args $WITH_GEN_KEY"
    fi
    
    # Add any additional arguments from TEST_ARGS
    if [ -n "$TEST_ARGS" ]; then
        test_args="$test_args $TEST_ARGS"
    fi
    
    # Trim leading whitespace
    test_args="${test_args# }"
    
    # Run tests in the container with the constructed arguments
    echo -e "${GREEN}Running tests in container...${NC}"
    if [ -n "$test_args" ]; then
        echo -e "${BLUE}Running tests: $test_args${NC}"
        docker run --cap-add=NET_ADMIN --privileged -v "$(pwd):/code" --workdir /code letmein-test $test_args
    else
        echo -e "${BLUE}Running all tests${NC}"
        docker run --cap-add=NET_ADMIN --privileged -v "$(pwd):/code" --workdir /code letmein-test
    fi
    
    # Get the exit code
    exit_code=$?
    
    # Check the result
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}All tests passed successfully!${NC}"
    else
        echo -e "${RED}Tests failed with exit code $exit_code${NC}"
    fi
    
    exit $exit_code
}

# Function to run in debug mode
run_debug() {
    echo -e "${YELLOW}Starting debug mode${NC}"
    
    # Make sure Docker is available
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Error: Docker is not installed or not in PATH${NC}"
        exit 1
    fi
    
    # Create a directory for debug logs if it doesn't exist
    mkdir -p nft-logs
    
    # Start a background process to periodically capture debug info
    (
        while true; do
            timestamp=$(date +%Y%m%d-%H%M%S)
            echo -e "${BLUE}[DEBUG] Capturing state at $timestamp${NC}"
            
            # Capture system info
            echo "=== System Info at $timestamp ===" > "nft-logs/sysinfo-$timestamp.log"
            uname -a >> "nft-logs/sysinfo-$timestamp.log"
            
            # Capture process info
            echo "=== Process Info at $timestamp ===" > "nft-logs/procinfo-$timestamp.log"
            ps aux | grep -E 'letmein|nft' >> "nft-logs/procinfo-$timestamp.log"
            
            # Capture nftables rules
            echo "=== NFTables Rules at $timestamp ===" > "nft-logs/nft-$timestamp.log"
            nft list ruleset >> "nft-logs/nft-$timestamp.log" 2>&1
            
            # Capture network state
            echo "=== Network State at $timestamp ===" > "nft-logs/netstat-$timestamp.log"
            netstat -tuln >> "nft-logs/netstat-$timestamp.log"
            
            # Wait for the specified interval
            sleep "$DEBUG_INTERVAL"
        done
    ) &
    DEBUG_PID=$!
    
    # Build the test image if needed
    echo -e "${YELLOW}Building debug container image...${NC}"
    docker build -f Dockerfile.test -t letmein-test .
    
    # Run an interactive shell in the container
    echo -e "${GREEN}Starting interactive debug shell...${NC}"
    echo -e "${YELLOW}Note: Use 'exit' to exit the shell and stop debug mode${NC}"
    
    # Run with appropriate permissions and mount the code directory
    docker run -it --cap-add=NET_ADMIN --privileged -v "$(pwd):/code" --workdir /code letmein-test /bin/bash
    
    # Stop the debug capture process when the shell exits
    if [ -n "$DEBUG_PID" ]; then
        echo -e "${BLUE}Stopping debug capture process...${NC}"
        kill $DEBUG_PID
    fi
    
    echo -e "${GREEN}Debug session ended. Debug logs are in the nft-logs directory.${NC}"
}

# Main logic based on mode
case "$MODE" in
    ci)
        run_ci
        ;;
    container)
        run_container
        ;;
    debug)
        run_debug
        ;;
    *)
        echo -e "${RED}Unknown mode: $MODE${NC}"
        exit 1
        ;;
esac

# This part should not be reached
echo -e "${RED}Error: Script execution reached an unexpected point${NC}"
exit 1 