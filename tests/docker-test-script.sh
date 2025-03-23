#!/bin/bash
# Docker test execution script with detailed display

# Enable trace mode
set -x

# Arguments passed to the script
TEST_ARGS="$@"

echo "=== STARTING DOCKER TESTS WITH FULL TRACE ==="
echo "Tests to execute: $TEST_ARGS"

# Configuration for detailed display
export PS4='+ [$(date +%H:%M:%S)] ${BASH_SOURCE}:${LINENO}: '
export LOG_LEVEL=debug
export RUST_LOG=debug
export RUST_BACKTRACE=full
export LETMEIN_DISABLE_SECCOMP=1

# Project compilation
cargo build

# Access the tests directory
cd ./tests

# Display nftables state before tests
echo "=== NFTABLES STATE BEFORE TESTS ==="
nft list ruleset

# Execute tests with trace mode
bash -x ./run-tests.sh $TEST_ARGS

# Capture return code
TEST_RESULT=$?

# Display nftables state after tests
echo "=== NFTABLES STATE AFTER TESTS ==="
nft list ruleset

echo "=== END OF DOCKER TESTS ==="
echo "Result: $TEST_RESULT"

# Return the test exit code
exit $TEST_RESULT 