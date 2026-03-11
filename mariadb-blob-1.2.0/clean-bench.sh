#!/bin/bash
# Benchmark environment cleanup — kills stale processes, removes old results,
# and verifies the machine is ready for a fresh benchmark run.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MY_UID=$(id -u)

echo "=== Benchmark Environment Cleanup ==="
echo ""

# ---- Kill stale processes ----
echo "--- Killing stale processes ---"

kill_procs() {
    local label="$1" signal="${2:-TERM}"
    shift 2
    local pids
    pids=$(pgrep -u "$MY_UID" "$@" 2>/dev/null) || true
    if [ -n "$pids" ]; then
        local count
        count=$(echo "$pids" | wc -l)
        echo "  Killing $label ($count processes, SIG${signal})"
        echo "$pids" | xargs kill -"$signal" 2>/dev/null || true
        return 0
    fi
    return 1
}

# Kill benchmark scripts first (they may respawn children)
for pattern in 'run-comparison' 'run-benchmark' 'mariadb-blob'; do
    kill_procs "$pattern" KILL -f "$pattern"
done

# Kill PTS
kill_procs "PTS" KILL -f phoronix

# Kill PHP (PTS web server and workers)
kill_procs "php" KILL php

# Kill sysbench
kill_procs "sysbench" KILL sysbench

# Kill mariadb clients
kill_procs "mariadb-clients" KILL -f 'mariadb.*sbtest'

# Kill mariadbd (TERM first, then KILL)
if kill_procs "mariadbd" TERM mariadbd; then
    sleep 2
    kill_procs "mariadbd" KILL mariadbd
fi

# Kill SAR
kill_procs "SAR" KILL sar
kill_procs "sadc" KILL sadc

echo "  Done."

# ---- Remove PTS lock ----
echo ""
echo "--- Removing PTS lock ---"
if [ -f /tmp/phoronix-test-suite.active ]; then
    rm -f /tmp/phoronix-test-suite.active
    echo "  Removed stale lock."
else
    echo "  No lock found."
fi

# ---- Clean PTS results ----
echo ""
echo "--- Cleaning PTS results ---"
RESULTS_DIR="$HOME/.phoronix-test-suite/test-results"
if [ -d "$RESULTS_DIR" ]; then
    for d in "$RESULTS_DIR"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        echo "  Removing: $name"
        rm -rf "$d"
    done
else
    echo "  No results directory."
fi

# ---- Clean SAR files ----
echo ""
echo "--- Cleaning SAR data ---"
for f in "$HOME"/sar-*.dat; do
    [ -f "$f" ] || continue
    echo "  Removing: $(basename "$f")"
    rm -f "$f"
done

# ---- Deploy test profile ----
echo ""
echo "--- Deploying test profile ---"
PTS_LOCAL_DIR="$HOME/.phoronix-test-suite/test-profiles/local"
PROFILE_DIR="$SCRIPT_DIR/mariadb-blob-1.2.0"
if [ ! -d "$PROFILE_DIR" ]; then
    # Script is inside the profile dir itself (flat layout)
    PROFILE_DIR="$SCRIPT_DIR"
fi
mkdir -p "$PTS_LOCAL_DIR"
rm -rf "$PTS_LOCAL_DIR/mariadb-blob-1.2.0"
cp -a "$PROFILE_DIR" "$PTS_LOCAL_DIR/mariadb-blob-1.2.0"
echo "  Installed to: $PTS_LOCAL_DIR/mariadb-blob-1.2.0"

# ---- Verify no stale processes remain ----
echo ""
echo "--- Verification ---"
STALE=0
for name in mariadbd phoronix php sysbench mariadb-blob sar sadc; do
    n=$(pgrep -c -u "$MY_UID" "$name" 2>/dev/null) || n=0
    if [ "$n" -gt 0 ]; then
        echo "  WARNING: $n $name process(es) still running!"
        STALE=1
    fi
done

if [ "$STALE" -eq 0 ]; then
    echo "  All clean."
else
    echo ""
    echo "  WARNING: Some processes could not be killed. Check manually."
fi

# ---- Disk space ----
echo ""
echo "--- Disk space ---"
df -h / | tail -1

echo ""
echo "=== Environment ready for benchmark ==="
