#!/bin/bash
#
# Kill a running MariaDB MDEV-38975 benchmark
#
# Stops PTS, sysbench workers, custom test workers, and the MariaDB server.
#

echo "Killing benchmark processes..."

pkill -9 -f phoronix-test-suite 2>/dev/null
pkill -9 -f sysbench 2>/dev/null
pkill -9 -f mariadb-blob 2>/dev/null
pkill -9 mariadbd 2>/dev/null
pkill -9 mariadbd-safe 2>/dev/null

echo "Done."
