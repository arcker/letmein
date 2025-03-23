#!/bin/sh
# Debugging script for Docker with Alpine Linux (uses /bin/sh instead of /bin/bash)

# Create a temporary script for Docker tests with detailed output
TEMP_DIR=$(mktemp -d)
DOCKER_SCRIPT="$TEMP_DIR/run-docker-tests.sh"

cat > "$DOCKER_SCRIPT" << 'EOF'
#!/bin/sh
set -x  # Display all executed commands

echo "=== INITIALIZING TEST ENVIRONMENT ==="
echo "Content of tests directory:"
ls -la ./tests

echo "=== PREPARING TESTS ==="
cd ./tests
echo "Initial nftables state:"
sudo nft list ruleset

echo "=== EXECUTING KNOCK TEST ==="
# Run the test with full display of commands
sudo -E sh -x ./run-tests.sh

# Get the exit code
TEST_RESULT=$?

echo "=== TEST RESULT: $TEST_RESULT ==="
echo "Final nftables state:"
sudo nft list ruleset

# Check for specific errors in logs
echo "=== CHECKING FOR COMMON ERRORS ==="
echo "Looking for nftables issues:"
dmesg | grep -i nft

echo "Contents of letmeinfwd.log (if exists):"
[ -f letmeinfwd.log ] && cat letmeinfwd.log

exit $TEST_RESULT
EOF

# Make the script executable
chmod +x "$DOCKER_SCRIPT"

echo "=== BUILDING DOCKER IMAGE ==="
docker build -f Dockerfile.test -t letmein-test-debug .

echo "=== RUNNING DOCKER CONTAINER WITH DEBUG SCRIPT ==="
docker run --rm \
    --cap-add=NET_ADMIN \
    --cap-add=SYS_ADMIN \
    --privileged \
    -v "$(pwd):/code" \
    -v "$DOCKER_SCRIPT:/test-script.sh" \
    letmein-test-debug \
    /test-script.sh

# Get the Docker command result
DOCKER_RESULT=$?

echo "=== DOCKER TEST COMPLETE (Exit code: $DOCKER_RESULT) ==="
echo "Docker container output is shown above."

# Cleanup
rm -rf "$TEMP_DIR"

# Return Docker result
exit $DOCKER_RESULT 