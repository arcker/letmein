#!/bin/sh
# Simple script to reproduce the error

# Create temporary directory
tmpdir=$(mktemp -d)
rundir="$tmpdir/run"
mkdir -p "$rundir"

# Start services
echo "Starting letmeinfwd..."
/app/target/debug/letmeinfwd --test-mode --no-systemd --rundir "$rundir" --seccomp off --config /app/tests/conf/tcp.conf > "$tmpdir/letmeinfwd.log" 2>&1 &
pid_fwd=$!
echo "PID letmeinfwd: $pid_fwd"

echo "Starting letmeind..."
/app/target/debug/letmeind --no-systemd --rundir "$rundir" --seccomp off --config /app/tests/conf/tcp.conf > "$tmpdir/letmeind.log" 2>&1 &
pid_ind=$!
echo "PID letmeind: $pid_ind"

# Wait for services to start
echo "Waiting for services to start..."
sleep 2

# Display logs
echo "--- letmeinfwd log ---"
cat "$tmpdir/letmeinfwd.log"
echo "--- letmeind log ---"
cat "$tmpdir/letmeind.log"

# Try to connect
echo "Testing connection..."
/app/target/debug/letmein --config /app/tests/conf/tcp.conf --debug connect 127.0.0.1 42 tcp

# Save return code
ret=$?

# Show nftables rules
echo "NFT rules:"
nft list ruleset

# Kill services
echo "Cleaning up..."
kill $pid_fwd $pid_ind
rm -rf "$tmpdir"

# Return result
echo "Test result: $ret"
exit $ret 