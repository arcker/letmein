#!/bin/bash
# Debug script for tests with detailed nftables logs

# Display colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log directory
LOG_DIR="$(pwd)/nft-logs"

# Default options
MOCK_NFTABLES="1" # By default, use the nftables stub
DEBUG_INTERVAL="5" # Default interval between state captures (seconds)
RUN_TEST="knock close" # Default tests to run

# Environment preparation
export LETMEIN_DISABLE_SECCOMP=1
export DISABLE_STRACE=1

# Help function
usage() {
    echo -e "${YELLOW}Usage: $0 [OPTIONS]${NC}"
    echo -e "Options:"
    echo -e "  --real           Use real nftables rules instead of the stub"
    echo -e "  --interval N     Set the interval between state captures (in seconds, default: 5)"
    echo -e "  --test TESTS     Tests to run (knock, close, or gen-key, default: knock close)"
    echo -e "  --help           Display this help message"
    exit 0
}

# Process command-line options
while [ $# -gt 0 ]; do
    case "$1" in
        --real)
            MOCK_NFTABLES="0"
            echo -e "${YELLOW}Real mode activated (without MOCK_NFTABLES)${NC}"
            ;;
        --interval)
            shift
            DEBUG_INTERVAL="$1"
            echo -e "${YELLOW}Debug interval: $DEBUG_INTERVAL seconds${NC}"
            ;;
        --test)
            shift
            RUN_TEST="$1"
            echo -e "${YELLOW}Tests to run: $RUN_TEST${NC}"
            ;;
        --help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
    shift
done

# Create log directory
mkdir -p "$LOG_DIR"
echo -e "${BLUE}Logs will be saved in $LOG_DIR${NC}"

# Function to capture the state of nftables rules
capture_nft_state() {
    local suffix="$1"
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    local logfile="$LOG_DIR/nft-state-$suffix-$timestamp.log"
    
    echo -e "${BLUE}Capturing nftables state: $suffix${NC}"
    
    echo "========================================================" > "$logfile"
    echo "=== CAPTURE NFTABLES STATE: $suffix $(date) ===" >> "$logfile"
    echo "========================================================" >> "$logfile"
    
    echo -e "\n=== Environment Variables ===" >> "$logfile"
    echo "MOCK_NFTABLES=$MOCK_NFTABLES" >> "$logfile"
    echo "LETMEIN_DISABLE_SECCOMP=$LETMEIN_DISABLE_SECCOMP" >> "$logfile"
    
    echo -e "\n=== Command 'nft list ruleset' (text format) ===" >> "$logfile"
    nft list ruleset 2>&1 >> "$logfile"
    echo "Exit code: $?" >> "$logfile"
    
    echo -e "\n=== Command 'nft -j list ruleset' (JSON format) ===" >> "$logfile"
    nft -j list ruleset 2>&1 >> "$logfile"
    echo "Exit code: $?" >> "$logfile"
    
    echo -e "\n=== Existing nftables tables ===" >> "$logfile"
    nft list tables 2>&1 >> "$logfile"
    
    echo -e "\n=== Existing nftables chains ===" >> "$logfile"
    nft list chains 2>&1 >> "$logfile"
    
    echo -e "\n=== Search for rules for port 42 ===" >> "$logfile"
    nft list ruleset | grep -i "42" 2>&1 >> "$logfile" || echo "No rules found for port 42" >> "$logfile"
    
    echo -e "\n=== Search for rules for addresses ::1 and 127.0.0.1 ===" >> "$logfile"
    nft list ruleset | grep -E "::1|127.0.0.1" 2>&1 >> "$logfile" || echo "No rules found for addresses ::1 or 127.0.0.1" >> "$logfile"
    
    echo -e "${GREEN}Capture saved to: $logfile${NC}"
    return 0
}

# Function to run a background process that periodically captures the state
start_periodic_capture() {
    echo -e "${BLUE}Starting periodic nftables state capture every $DEBUG_INTERVAL seconds${NC}"
    
    # Generate a unique identifier for this debugging session
    SESSION_ID=$(date +"%Y%m%d-%H%M%S")
    
    # Create a temporary script for periodic capture
    TEMP_SCRIPT="$LOG_DIR/capture-$SESSION_ID.sh"
    
    cat > "$TEMP_SCRIPT" << EOF
#!/bin/bash
count=0
while true; do
    count=\$((count+1))
    echo "Periodic capture #\$count at \$(date)" >> "$LOG_DIR/periodic-$SESSION_ID.log"
    
    echo "========================================================" >> "$LOG_DIR/nft-periodic-\$count-$SESSION_ID.log"
    echo "=== PERIODIC CAPTURE #\$count: \$(date) ===" >> "$LOG_DIR/nft-periodic-\$count-$SESSION_ID.log"
    echo "========================================================" >> "$LOG_DIR/nft-periodic-\$count-$SESSION_ID.log"
    
    echo -e "\\n=== Command 'nft list ruleset' ===" >> "$LOG_DIR/nft-periodic-\$count-$SESSION_ID.log"
    nft list ruleset 2>&1 >> "$LOG_DIR/nft-periodic-\$count-$SESSION_ID.log"
    
    echo -e "\\n=== Search for rules for port 42 ===" >> "$LOG_DIR/nft-periodic-\$count-$SESSION_ID.log"
    nft list ruleset | grep -i "42" 2>&1 >> "$LOG_DIR/nft-periodic-\$count-$SESSION_ID.log" || echo "No rules found for port 42" >> "$LOG_DIR/nft-periodic-\$count-$SESSION_ID.log"
    
    sleep $DEBUG_INTERVAL
done
EOF
    
    chmod +x "$TEMP_SCRIPT"
    "$TEMP_SCRIPT" &
    CAPTURE_PID=$!
    echo -e "${GREEN}Periodic capture started with PID: $CAPTURE_PID${NC}"
    echo $CAPTURE_PID > "$LOG_DIR/capture-pid-$SESSION_ID.txt"
}

# Function to stop the periodic capture
stop_periodic_capture() {
    if [ -f "$LOG_DIR/capture-pid-$SESSION_ID.txt" ]; then
        CAPTURE_PID=$(cat "$LOG_DIR/capture-pid-$SESSION_ID.txt")
        echo -e "${BLUE}Stopping periodic capture (PID: $CAPTURE_PID)${NC}"
        kill $CAPTURE_PID 2>/dev/null || echo -e "${YELLOW}Unable to kill capture process${NC}"
        rm "$LOG_DIR/capture-pid-$SESSION_ID.txt"
    else
        echo -e "${YELLOW}No active periodic capture found for this session${NC}"
    fi
}

# Prepare the environment for tests
if [ "$MOCK_NFTABLES" = "1" ]; then
    export MOCK_NFTABLES=1
    echo -e "${YELLOW}Running tests with nftables stub (MOCK_NFTABLES=1)...${NC}"
else
    unset MOCK_NFTABLES
    echo -e "${YELLOW}Running tests with real nftables...${NC}"
fi

# Main execution section
echo -e "${GREEN}=== STARTING NFTABLES DEBUGGING ===${NC}"

# Capture initial state
capture_nft_state "initial"

# Start periodic capture
start_periodic_capture

# Build the project if necessary
echo -e "${YELLOW}Building the project...${NC}"
cargo build

# Run tests with the run-tests.sh script
echo -e "${GREEN}=== EXECUTING TESTS ($RUN_TEST) ===${NC}"

# Capture state before tests
capture_nft_state "before-tests"

# Run specified tests
echo -e "${YELLOW}Running tests: $RUN_TEST${NC}"
./tests/run-tests.sh $RUN_TEST
TEST_EXIT_CODE=$?

# Capture state after tests
capture_nft_state "after-tests"

# Stop periodic capture
stop_periodic_capture

# Display test results
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}=== TESTS SUCCEEDED (exit code: $TEST_EXIT_CODE) ===${NC}"
else
    echo -e "${RED}=== TESTS FAILED (exit code: $TEST_EXIT_CODE) ===${NC}"
fi

# Display log paths
echo -e "${GREEN}=== DEBUGGING COMPLETE ===${NC}"
echo -e "${BLUE}Debug logs are available in: $LOG_DIR${NC}"
echo -e "${BLUE}Important log files:${NC}"
ls -la "$LOG_DIR" | grep -E "initial|before-tests|after-tests" | awk '{print $9}' | while read file; do
    echo -e "${YELLOW}- $LOG_DIR/$file${NC}"
done

# Suggest useful commands
echo -e "\n${GREEN}Useful commands:${NC}"
echo -e "${YELLOW}- To view test output: less -R $LOG_DIR/nft-state-after-tests-*.log${NC}"
echo -e "${YELLOW}- To compare before/after: diff $LOG_DIR/nft-state-before-tests-*.log $LOG_DIR/nft-state-after-tests-*.log${NC}"

# Exit with the test exit code
exit $TEST_EXIT_CODE
