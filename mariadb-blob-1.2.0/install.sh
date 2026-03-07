#!/bin/bash
#
# MariaDB BLOB benchmark — install script
#
# Required environment:
#   MARIADB_SRC_DIR  — path to a MariaDB git checkout (already on desired branch)
#
# Provided by PTS:
#   HOME             — test install directory
#   NUM_CPU_CORES    — CPU core count
#   SYS_MEMORY       — system memory in MB
#   DEBUG_REAL_HOME  — actual user home directory
#

set -e

if [ -z "${MARIADB_SRC_DIR:-}" ]; then
    # PTS may not propagate env vars; read from file written by build.sh
    if [ -f "$DEBUG_REAL_HOME/.mariadb-blob-src-dir" ]; then
        MARIADB_SRC_DIR=$(cat "$DEBUG_REAL_HOME/.mariadb-blob-src-dir")
    else
        echo "ERROR: MARIADB_SRC_DIR must be set to the MariaDB source directory" >&2
        exit 1
    fi
fi

if [ ! -f "$MARIADB_SRC_DIR/CMakeLists.txt" ]; then
    echo "ERROR: $MARIADB_SRC_DIR does not look like a MariaDB source tree" >&2
    exit 1
fi

DB_USER=$(basename "$DEBUG_REAL_HOME")

# ---------------------------------------------------------------------------
# 1. Build MariaDB from source
# ---------------------------------------------------------------------------
rm -rf "$HOME/mariadb_" "$HOME/mariadb-build"
mkdir -p "$HOME/mariadb-build"
cd "$HOME/mariadb-build"

cmake \
    -DCMAKE_INSTALL_PREFIX="$HOME/mariadb_" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-march=native" \
    -DCMAKE_CXX_FLAGS="-march=native" \
    -DWITHOUT_ROCKSDB=1 \
    "$MARIADB_SRC_DIR"

if [ "$OS_TYPE" = "BSD" ]; then
    gmake -j "$NUM_CPU_CORES"
else
    make -j "$NUM_CPU_CORES"
fi

export PATH="$HOME/mariadb_/bin:$HOME/mariadb-build/extra:$PATH"
make install
echo $? > ~/install-exit-status

# ---------------------------------------------------------------------------
# 2. Initialize database
# ---------------------------------------------------------------------------
cd "$HOME/mariadb_"
mkdir -p .data
chmod -R 777 .data

RAM8P="$(($SYS_MEMORY * 75 / 100))"

./scripts/mariadb-install-db --no-defaults \
    --user="$DB_USER" \
    --innodb-log-file-size=1G \
    --innodb-buffer-pool-size=${RAM8P}M \
    --query-cache-size=64M \
    --max-heap-table-size=512M \
    --tmp-table-size=2G \
    --basedir="$HOME/mariadb_" \
    --ldata="$HOME/mariadb_/.data"

# ---------------------------------------------------------------------------
# 3. Start server for data preparation
# ---------------------------------------------------------------------------
if [ "$(whoami)" = "root" ]; then
    ./bin/mariadbd-safe --no-defaults \
        --innodb-log-file-size=1G \
        --innodb-buffer-pool-size=${RAM8P}M \
        --query-cache-size=64M \
        --max_connections=8200 \
        --max-heap-table-size=512M \
        --tmp-table-size=2G \
        --user=root \
        --datadir="$HOME/mariadb_/.data" &
else
    ./bin/mariadbd-safe --no-defaults \
        --innodb-log-file-size=1G \
        --innodb-buffer-pool-size=${RAM8P}M \
        --query-cache-size=64M \
        --max_connections=8200 \
        --max-heap-table-size=512M \
        --tmp-table-size=2G \
        --datadir="$HOME/mariadb_/.data" &
fi
sleep 5

MYSQL="./bin/mariadb"
MYSQLADMIN="./bin/mariadb-admin"
MYSQLDUMP="./bin/mariadb-dump"
MYSQL_OPTS="-u $DB_USER -pphoronix --comments"
SOCKET="/tmp/mysql.sock"

$MYSQLADMIN -u "$DB_USER" password 'phoronix'
sleep 1

# ---------------------------------------------------------------------------
# 4. Prepare sysbench OLTP data (stock workload)
# ---------------------------------------------------------------------------
echo "DROP DATABASE IF EXISTS sbtest;" | $MYSQL -h localhost $MYSQL_OPTS
echo "CREATE DATABASE sbtest;" | $MYSQL -h localhost $MYSQL_OPTS

sysbench oltp_common \
    --threads="$NUM_CPU_CORES" \
    --rand-type=uniform \
    --db-driver=mysql \
    --mysql-db=sbtest \
    --mysql-host=localhost \
    --mysql-port=3306 \
    --mysql-user="$DB_USER" \
    --mysql-socket="$SOCKET" \
    --mysql-password=phoronix \
    prepare --tables=16 --table-size=1000000

# ---------------------------------------------------------------------------
# 5. Prepare custom BLOB/TEXT/GEOMETRY test data
# ---------------------------------------------------------------------------
$MYSQL -h localhost $MYSQL_OPTS sbtest <<'BLOBSQL'

-- InnoDB table with TEXT columns (50K rows, ~5K unique text values)
CREATE TABLE blob_data (
  id INT AUTO_INCREMENT PRIMARY KEY,
  k INT NOT NULL DEFAULT 0,
  text_col TEXT NOT NULL,
  text_col2 MEDIUMTEXT,
  KEY idx_k (k)
) ENGINE=InnoDB;

INSERT INTO blob_data (k, text_col, text_col2)
SELECT
  seq % 1000,
  CONCAT('text-', seq % 5000, '-', REPEAT(MD5(seq % 5000), 3 + (seq % 5000) % 10)),
  CONCAT('medium-', seq % 2000, '-', REPEAT(SHA2(seq % 2000, 256), 2 + (seq % 2000) % 5))
FROM seq_1_to_50000;

-- Second table for UNION/subquery tests (25K rows, partially overlapping)
CREATE TABLE blob_data2 (
  id INT AUTO_INCREMENT PRIMARY KEY,
  k INT NOT NULL DEFAULT 0,
  text_col TEXT NOT NULL,
  text_col2 MEDIUMTEXT,
  KEY idx_k (k)
) ENGINE=InnoDB;

INSERT INTO blob_data2 (k, text_col, text_col2)
SELECT k, text_col, text_col2 FROM blob_data WHERE id <= 25000;

UPDATE blob_data2
SET text_col = CONCAT('alt-', text_col)
WHERE id <= 12500;

-- InnoDB table with GEOMETRY columns (10K rows)
CREATE TABLE geom_data (
  id INT AUTO_INCREMENT PRIMARY KEY,
  geom GEOMETRY NOT NULL,
  description TEXT
) ENGINE=InnoDB;

INSERT INTO geom_data (geom, description)
SELECT
  ST_GeomFromText(CONCAT('POINT(',
    ROUND(-180 + (seq % 36000) * 0.01, 6), ' ',
    ROUND(-90 + (seq % 18000) * 0.01, 6), ')')),
  CONCAT('Point-', seq, ': ', MD5(seq))
FROM seq_1_to_10000;

-- Additional schema objects to make I_S queries more substantial
-- 50 extra tables with varied column types
DELIMITER //
CREATE PROCEDURE create_schema_tables()
BEGIN
  DECLARE i INT DEFAULT 1;
  WHILE i <= 50 DO
    SET @sql = CONCAT(
      'CREATE TABLE extra_schema_', i, ' (',
      'id INT AUTO_INCREMENT PRIMARY KEY, ',
      'val1 VARCHAR(100), ',
      'val2 TEXT, ',
      'val3 DECIMAL(10,2), ',
      'val4 DATETIME DEFAULT CURRENT_TIMESTAMP, ',
      'val5 BLOB, ',
      'val6 JSON, ',
      'KEY idx_val1 (val1)',
      ') ENGINE=InnoDB'
    );
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;

CALL create_schema_tables();
DROP PROCEDURE create_schema_tables;

-- =========================================================================
-- Stored procedures with large bodies for I_S.ROUTINES benchmarks
-- ROUTINE_DEFINITION is LONGTEXT — materializing these into temp tables
-- is where MDEV-38975 wins (HEAP vs Aria)
-- =========================================================================
DELIMITER //
CREATE PROCEDURE create_stored_procs()
BEGIN
  DECLARE i INT DEFAULT 1;
  WHILE i <= 60 DO
    SET @body = CONCAT(
      'CREATE PROCEDURE bench_proc_', i, '(IN p_id INT)\n',
      'BEGIN\n',
      '  DECLARE v_result TEXT;\n',
      '  DECLARE v_count INT DEFAULT 0;\n',
      REPEAT(CONCAT(
        '  SELECT COUNT(*) INTO v_count FROM sbtest1 WHERE id > ', i, ';\n',
        '  SET v_result = CONCAT(IFNULL(v_result,''''), ''-chunk-'', v_count);\n',
        '  IF v_count > ', i * 100, ' THEN\n',
        '    SELECT v_result;\n',
        '  END IF;\n'
      ), 20 + (i % 40)),
      '  SELECT v_count;\n',
      'END'
    );
    PREPARE stmt FROM @body;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;

CALL create_stored_procs();
DROP PROCEDURE create_stored_procs;

-- =========================================================================
-- Views with complex definitions for I_S.VIEWS benchmarks
-- VIEW_DEFINITION is LONGTEXT
-- =========================================================================
DELIMITER //
CREATE PROCEDURE create_views()
BEGIN
  DECLARE i INT DEFAULT 1;
  WHILE i <= 30 DO
    SET @vdef = CONCAT(
      'CREATE VIEW bench_view_', i, ' AS ',
      'SELECT s1.id, s1.k, s1.c, s1.pad, ',
      'CONCAT(s1.c, ''-'', s1.pad) AS combined, ',
      'LENGTH(s1.c) + LENGTH(s1.pad) AS total_len, ',
      'CASE WHEN s1.k > 500 THEN ''high'' ELSE ''low'' END AS k_category ',
      'FROM sbtest', (i % 16) + 1, ' s1 ',
      'JOIN sbtest', ((i + 3) % 16) + 1, ' s2 ON s1.k = s2.k ',
      'WHERE s1.id BETWEEN ', i * 1000, ' AND ', i * 1000 + 5000,
      ' ORDER BY s1.id'
    );
    PREPARE stmt FROM @vdef;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;

CALL create_views();
DROP PROCEDURE create_views;

-- =========================================================================
-- Triggers for I_S.TRIGGERS benchmarks
-- ACTION_STATEMENT is LONGTEXT
-- =========================================================================
DELIMITER //
CREATE PROCEDURE create_triggers()
BEGIN
  DECLARE i INT DEFAULT 1;
  WHILE i <= 50 DO
    SET @tdef = CONCAT(
      'CREATE TRIGGER bench_trigger_', i,
      ' BEFORE INSERT ON extra_schema_', i,
      ' FOR EACH ROW\n',
      'BEGIN\n',
      '  DECLARE v_check INT;\n',
      REPEAT(CONCAT(
        '  SET v_check = COALESCE(NEW.val3, 0) + ', i, ';\n',
        '  IF v_check < 0 THEN\n',
        '    SET NEW.val1 = CONCAT(NEW.val1, ''-validated-'', v_check);\n',
        '  END IF;\n'
      ), 10 + (i % 20)),
      'END'
    );
    PREPARE stmt FROM @tdef;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;

CALL create_triggers();
DROP PROCEDURE create_triggers;

-- =========================================================================
-- BLOB size case tables: exercise specific HEAP continuation chain layouts
-- Case boundaries for typical temp tables (recbuffer=16, visible=15):
--   Case A: blob <= 5 bytes    (single-record inline, zero-copy)
--   Case B: blob 6B .. ~16KB   (single-run contiguous, zero-copy)
--   Case C: blob > ~16KB       (multi-run, reassembly into blob_buff)
-- =========================================================================

-- Case A: tiny blobs (1-5 bytes) — 50K rows, ~10K unique values
CREATE TABLE blob_case_a (
  id INT AUTO_INCREMENT PRIMARY KEY,
  text_col TEXT NOT NULL
) ENGINE=InnoDB;

INSERT INTO blob_case_a (text_col)
SELECT LEFT(MD5(seq % 10000), 1 + (seq % 5))
FROM seq_1_to_50000;

-- Case B: medium blobs (1-10KB) — 10K rows, ~2K unique values
CREATE TABLE blob_case_b (
  id INT AUTO_INCREMENT PRIMARY KEY,
  text_col TEXT NOT NULL
) ENGINE=InnoDB;

INSERT INTO blob_case_b (text_col)
SELECT REPEAT(MD5(seq % 2000), 30 + (seq % 2000) % 280)
FROM seq_1_to_10000;

-- Case C: large blobs (20-50KB) — 2K rows, ~500 unique values
CREATE TABLE blob_case_c (
  id INT AUTO_INCREMENT PRIMARY KEY,
  text_col MEDIUMTEXT NOT NULL
) ENGINE=InnoDB;

INSERT INTO blob_case_c (text_col)
SELECT REPEAT(MD5(seq % 500), 600 + (seq % 500) * 2)
FROM seq_1_to_2000;

-- Mixed: all three cases — 10K rows
-- 40% Case A (1-5B), 40% Case B (1-10KB), 20% Case C (20-50KB)
CREATE TABLE blob_mixed (
  id INT AUTO_INCREMENT PRIMARY KEY,
  text_col MEDIUMTEXT NOT NULL
) ENGINE=InnoDB;

INSERT INTO blob_mixed (text_col)
SELECT CASE
  WHEN seq % 5 < 2 THEN LEFT(MD5(seq % 10000), 1 + (seq % 5))
  WHEN seq % 5 < 4 THEN REPEAT(MD5(seq % 2000), 30 + (seq % 200))
  ELSE REPEAT(MD5(seq % 500), 600 + (seq % 500) * 2)
END
FROM seq_1_to_10000;

BLOBSQL

# ---------------------------------------------------------------------------
# 6. Dump database and shut down
# ---------------------------------------------------------------------------
$MYSQLDUMP -h localhost -u "$DB_USER" -pphoronix --comments sbtest > ~/mysql-dumped
echo $? > ~/install-exit-status
echo "DROP DATABASE sbtest;" | $MYSQL -h localhost $MYSQL_OPTS

$MYSQLADMIN -u "$DB_USER" -pphoronix shutdown
sleep 3

# ---------------------------------------------------------------------------
# 7. Generate run script: mariadb-blob
# ---------------------------------------------------------------------------
cd ~

cat > mariadb-blob <<'RUNSCRIPT_OUTER'
#!/bin/bash
TEST="$1"
THREADS="$2"
RUNSCRIPT_OUTER

# Inject resolved values into the run script
cat >> mariadb-blob <<RUNSCRIPT_VARS
DB_USER="$DB_USER"
SOCKET="$SOCKET"
RUNSCRIPT_VARS

cat >> mariadb-blob <<'RUNSCRIPT_BODY'
MYSQL="$HOME/mariadb_/bin/mariadb"
MYSQL_OPTS="-u $DB_USER -pphoronix --socket=$SOCKET -B -N"
DURATION=${BENCH_DURATION:-120}

# ---- Restore database from dump ----
echo "DROP DATABASE IF EXISTS sbtest;" | $MYSQL $MYSQL_OPTS
echo "CREATE DATABASE sbtest;" | $MYSQL $MYSQL_OPTS
$MYSQL $MYSQL_OPTS sbtest < ~/mysql-dumped
sleep 3

# ---- Sysbench OLTP tests ----
if echo "$TEST" | grep -q "^oltp_"; then
    sysbench "$TEST" \
        --threads="$THREADS" \
        --time="$DURATION" \
        --rand-type=uniform \
        --db-driver=mysql \
        --mysql-db=sbtest \
        --mysql-host=localhost \
        --mysql-user="$DB_USER" \
        --mysql-password=phoronix \
        --mysql-socket="$SOCKET" \
        run --tables=16 --table-size=1000000 > $LOG_FILE 2>&1
    echo $? > ~/test-exit-status
    echo "DROP DATABASE sbtest;" | $MYSQL $MYSQL_OPTS
    exit 0
fi

# ---- Custom BLOB/I_S/GEOMETRY tests ----
# Map test name to SQL query
case "$TEST" in
    blob_group_by)
        QUERY="SELECT SQL_NO_CACHE text_col, COUNT(*) cnt FROM blob_data GROUP BY text_col ORDER BY cnt DESC LIMIT 10"
        ;;
    blob_distinct)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT DISTINCT text_col FROM blob_data) t"
        ;;
    blob_union)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT text_col FROM blob_data UNION SELECT text_col FROM blob_data2) t"
        ;;
    blob_subquery)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM blob_data WHERE text_col IN (SELECT DISTINCT text_col FROM blob_data2)"
        ;;
    is_columns)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, COLUMN_DEFAULT FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'sbtest' ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION) t"
        ;;
    is_tables_join)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE, t.ENGINE, t.TABLE_ROWS FROM INFORMATION_SCHEMA.COLUMNS c JOIN INFORMATION_SCHEMA.TABLES t ON c.TABLE_SCHEMA = t.TABLE_SCHEMA AND c.TABLE_NAME = t.TABLE_NAME WHERE c.TABLE_SCHEMA = 'sbtest') t"
        ;;
    geom_distinct)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT DISTINCT ST_AsText(geom), description FROM geom_data) t"
        ;;
    blob_count_distinct)
        QUERY="SELECT SQL_NO_CACHE COUNT(DISTINCT text_col) FROM blob_data"
        ;;
    blob_group_concat)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT k, GROUP_CONCAT(text_col ORDER BY id SEPARATOR '|') gc FROM blob_data GROUP BY k) t"
        ;;
    blob_window_func)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT id, text_col, ROW_NUMBER() OVER (PARTITION BY k ORDER BY id) rn FROM blob_data WHERE id <= 10000) t"
        ;;
    blob_cte)
        QUERY="WITH blob_cte AS (SELECT text_col, k FROM blob_data WHERE id <= 10000) SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT DISTINCT a.text_col FROM blob_cte a JOIN blob_cte b ON a.k = b.k AND a.text_col <> b.text_col) t"
        ;;
    blob_recursive_cte)
        QUERY="WITH RECURSIVE rcte AS (SELECT id, text_col, k FROM blob_data WHERE id = 1 UNION ALL SELECT b.id, b.text_col, b.k FROM blob_data b JOIN rcte r ON b.id = r.id + 1 WHERE b.id <= 500) SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT DISTINCT text_col FROM rcte) t"
        ;;
    blob_orderby_groupby)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT text_col, COUNT(*) cnt FROM blob_data GROUP BY text_col ORDER BY k LIMIT 100) t"
        ;;
    blob_rollup)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT k, text_col, COUNT(*) FROM blob_data WHERE id <= 10000 GROUP BY k, text_col WITH ROLLUP) t"
        ;;
    blob_insert_select)
        QUERY="CREATE TEMPORARY TABLE blob_tmp_ins (id INT AUTO_INCREMENT PRIMARY KEY, text_col TEXT) ENGINE=InnoDB; INSERT INTO blob_tmp_ins (text_col) SELECT text_col FROM blob_data WHERE id <= 5000; SELECT COUNT(*) FROM blob_tmp_ins; DROP TEMPORARY TABLE blob_tmp_ins"
        ;;
    is_routines)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_DEFINITION, DATA_TYPE, ROUTINE_COMMENT FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_SCHEMA = 'sbtest' ORDER BY ROUTINE_NAME) t"
        ;;
    is_views)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT TABLE_SCHEMA, TABLE_NAME, VIEW_DEFINITION, CHECK_OPTION, IS_UPDATABLE FROM INFORMATION_SCHEMA.VIEWS WHERE TABLE_SCHEMA = 'sbtest' ORDER BY TABLE_NAME) t"
        ;;
    is_triggers)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT TRIGGER_SCHEMA, TRIGGER_NAME, EVENT_OBJECT_TABLE, ACTION_STATEMENT, ACTION_TIMING FROM INFORMATION_SCHEMA.TRIGGERS WHERE TRIGGER_SCHEMA = 'sbtest' ORDER BY TRIGGER_NAME) t"
        ;;
    show_columns_loop)
        # Simulates ORM/admin tool startup: SHOW FULL COLUMNS for every table
        # Build a multi-statement script that runs SHOW for each table
        TABLES=$($MYSQL $MYSQL_OPTS -e "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='sbtest' AND TABLE_TYPE='BASE TABLE'" sbtest 2>/dev/null)
        QUERY=""
        for tbl in $TABLES; do
            QUERY="${QUERY}SHOW FULL COLUMNS FROM \`${tbl}\`; "
        done
        ;;
    is_group_by_complex)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT DATA_TYPE, COUNT(*) cnt, GROUP_CONCAT(DISTINCT COLUMN_TYPE ORDER BY COLUMN_TYPE) types FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'sbtest' GROUP BY DATA_TYPE HAVING cnt > 1 ORDER BY cnt DESC) t"
        ;;
    blob_case_a)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT DISTINCT text_col FROM blob_case_a) t"
        ;;
    blob_case_b)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT DISTINCT text_col FROM blob_case_b) t"
        ;;
    blob_case_c)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT DISTINCT text_col FROM blob_case_c) t"
        ;;
    blob_mixed)
        QUERY="SELECT SQL_NO_CACHE COUNT(*) FROM (SELECT DISTINCT text_col FROM blob_mixed) t"
        ;;
    *)
        echo "Unknown test: $TEST" >&2
        echo 1 > ~/test-exit-status
        exit 1
        ;;
esac

# ---- Run custom benchmark: N threads for DURATION seconds ----
TMPDIR=$(mktemp -d)
END_TIME=$(($(date +%s) + DURATION))

worker() {
    local id=$1
    local count=0
    while [ $(date +%s) -lt $END_TIME ]; do
        echo "$QUERY" | $MYSQL $MYSQL_OPTS sbtest > /dev/null 2>&1
        count=$((count + 1))
    done
    echo $count > "$TMPDIR/w${id}"
}

for i in $(seq 1 "$THREADS"); do
    worker "$i" &
done
wait

total=0
for i in $(seq 1 "$THREADS"); do
    c=$(cat "$TMPDIR/w${i}")
    total=$((total + c))
done
rm -rf "$TMPDIR"

qps=$(echo "scale=2; $total / $DURATION" | bc)

# Output in sysbench-compatible format for the result parser
cat > $LOG_FILE <<RESULTEOF
SQL statistics:
    queries performed:
        read:                                $total
        write:                               0
        other:                               0
        total:                               $total
    queries:                             $total ($qps per sec.)
    transactions:                        $total ($qps per sec.)
RESULTEOF

echo $? > ~/test-exit-status
echo "DROP DATABASE sbtest;" | $MYSQL $MYSQL_OPTS

RUNSCRIPT_BODY

chmod +x mariadb-blob
