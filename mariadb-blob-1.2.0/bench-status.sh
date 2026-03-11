#!/bin/bash
# Benchmark status checker — shows process state, progress, and recent results
set -u

MY_UID=$(id -u)

count_procs() {
    local n
    n=$(pgrep -c -u "$MY_UID" "$@" 2>/dev/null) || n=0
    echo "$n"
}

echo "=== Processes ==="
printf "  mariadbd:  %s\n" "$(count_procs mariadbd)"
printf "  PTS:       %s\n" "$(count_procs -f phoronix)"
printf "  SAR:       %s\n" "$(count_procs sar)"
printf "  clients:   %s\n" "$(count_procs -f 'mariadb.*sbtest')"

echo ""
echo "=== Process Details ==="
# Show unique processes, collapsing repeated mariadb clients into a count
ps -u "$MY_UID" --no-headers -o pid,stat,etime,comm,args | grep -vE 'sshd|bash|systemd|sd-pam|ps |grep|bench-status' | \
    grep -v 'mariadb.*sbtest' || true
CLIENT_COUNT=$(count_procs -f 'mariadb.*sbtest')
if [ "$CLIENT_COUNT" -gt 0 ]; then
    echo "  ($CLIENT_COUNT mariadb client processes)"
fi

echo ""
echo "=== PTS Lock ==="
if [ -f /tmp/phoronix-test-suite.active ]; then
    echo "  LOCKED (PTS running or stale lock)"
else
    echo "  not locked"
fi

echo ""
echo "=== Progress ==="
for d in ~/.phoronix-test-suite/test-results/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    composite="$d/composite.xml"
    if [ -f "$composite" ]; then
        completed=$(grep -c '<Result>' "$composite" 2>/dev/null) || completed=0
        echo "  $name: $completed test results recorded"
    fi
done

echo ""
echo "=== Result Files ==="
for d in ~/.phoronix-test-suite/test-results/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    mod=$(stat -c '%Y' "$d" 2>/dev/null)
    date=$(date -d "@$mod" '+%Y-%m-%d %H:%M' 2>/dev/null)
    echo "  $name  (last modified: $date)"
done

echo ""
echo "=== Results ==="
for d in ~/.phoronix-test-suite/test-results/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    echo "--- $name ---"
    phoronix-test-suite result-file-to-text "$name" 2>/dev/null | grep -E '(Test:|Queries Per Second|^[A-Za-z0-9_.-]+ \.)'
    echo ""
done
