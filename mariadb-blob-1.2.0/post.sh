#!/bin/bash
# Stop MariaDB server after each test run
pkill -9 -u "$(id -u)" mariadbd 2>/dev/null || true
for i in $(seq 1 10); do
    pgrep -u "$(id -u)" mariadbd >/dev/null 2>&1 || break
    sleep 1
done
