#!/bin/bash
# Stop MariaDB server after each test run
pkill -u "$(id -u)" mariadbd 2>/dev/null || true
sleep 2
