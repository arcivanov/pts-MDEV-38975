#!/bin/bash
# Kill ALL benchmark-related processes and clean up PTS locks
set -u
echo "Killing all benchmark processes..."
MY_UID=$(id -u)

pkill -9 -u "$MY_UID" -f "mariadb.*sbtest" 2>/dev/null
pkill -9 -u "$MY_UID" -f "mariadb-blob" 2>/dev/null
pkill -9 -u "$MY_UID" mariadbd 2>/dev/null
pkill -9 -u "$MY_UID" -f phoronix 2>/dev/null
pkill -9 -u "$MY_UID" -f "Phoronix" 2>/dev/null
pkill -9 -u "$MY_UID" sar 2>/dev/null
pkill -9 -u "$MY_UID" -f "run-cte" 2>/dev/null
pkill -9 -u "$MY_UID" -f "run-all" 2>/dev/null
pkill -9 -u "$MY_UID" -f "run-benchmark" 2>/dev/null
pkill -9 -u "$MY_UID" -f "php.*dynamic-result-viewer" 2>/dev/null
pkill -9 -u "$MY_UID" sleep 2>/dev/null

sleep 2

rm -f /tmp/phoronix-test-suite.active

remaining=$(ps -u "$MY_UID" --no-headers -o pid,comm | grep -cvE "sshd|bash|systemd|sd-pam|ps|grep|kill-bench")
if [ "$remaining" -gt 0 ]; then
    echo "WARNING: $remaining processes still running:"
    ps -u "$MY_UID" --no-headers -o pid,comm,args | grep -vE "sshd|bash|systemd|sd-pam|ps|grep|kill-bench"
else
    echo "All clean."
fi
