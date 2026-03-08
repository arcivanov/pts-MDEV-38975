#!/bin/bash
# Restore datadir from snapshot and start MariaDB server before each test run
cd "$HOME/mariadb_"

# Kill any running server — datadir is restored from snapshot so clean shutdown is unnecessary
pkill -9 -u "$(id -u)" mariadbd 2>/dev/null || true
# Wait for process to fully exit (avoid zombie/lingering pid)
for i in $(seq 1 10); do
    pgrep -u "$(id -u)" mariadbd >/dev/null 2>&1 || break
    sleep 1
done

# Fast restore: file copy instead of SQL import
if [ -d "$HOME/mariadb_/.data-snapshot" ]; then
    rm -rf "$HOME/mariadb_/.data"
    cp -a "$HOME/mariadb_/.data-snapshot" "$HOME/mariadb_/.data"
fi

RAM8P="$(($SYS_MEMORY * 75 / 100))"
if [ "$(whoami)" = "root" ] ; then
    setsid "$HOME/mariadb_/bin/mariadbd" --no-defaults \
        --innodb-log-file-size=1G \
        --innodb-buffer-pool-size=${RAM8P}M \
        --query-cache-size=64M \
        --max_connections=800 \
        --max-heap-table-size=16G \
        --tmp-table-size=16G \
        --max_prepared_stmt_count=90000 \
        --user=root \
        --datadir="$HOME/mariadb_/.data" </dev/null >/dev/null 2>&1 &
else
    setsid "$HOME/mariadb_/bin/mariadbd" --no-defaults \
        --innodb-log-file-size=1G \
        --innodb-buffer-pool-size=${RAM8P}M \
        --query-cache-size=64M \
        --max_connections=800 \
        --max-heap-table-size=16G \
        --tmp-table-size=16G \
        --max_prepared_stmt_count=90000 \
        --datadir="$HOME/mariadb_/.data" </dev/null >/dev/null 2>&1 &
fi
sleep 5
"$HOME/mariadb_/bin/mariadb-admin" -u "$(basename "$DEBUG_REAL_HOME")" password 'phoronix' 2>/dev/null || true
