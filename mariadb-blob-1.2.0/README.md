# MariaDB MDEV-38975 Benchmark Suite

A/B performance comparison of [MDEV-38975](https://jira.mariadb.org/browse/MDEV-38975)
(HEAP engine BLOB/TEXT/JSON/GEOMETRY column support) against the 10.11 baseline,
using the [Phoronix Test Suite](https://github.com/phoronix-test-suite/phoronix-test-suite).

Based on the [pts/mariadb](https://openbenchmarking.org/test/pts/mariadb) test profile
(latest upstream: 1.2.0), extended with custom BLOB/TEXT temp table,
INFORMATION_SCHEMA, GEOMETRY, and BLOB size case benchmarks.

## What it measures

MDEV-38975 allows internal temporary tables with BLOB/TEXT columns to stay in
the HEAP engine (in-memory) instead of falling back to Aria (disk-backed). This
benchmark measures the impact on:

- **Stock sysbench OLTP** — regression check on standard InnoDB workloads
- **BLOB/TEXT temp tables** — `GROUP BY`, `DISTINCT`, `UNION`, subqueries on
  TEXT columns that force internal temp table creation
- **INFORMATION_SCHEMA** — I_S tables contain TEXT columns; queries on them
  create temp tables that previously required Aria
- **GEOMETRY** — `DISTINCT` on geometry columns
- **BLOB size cases** — exercises the three HEAP BLOB continuation chain layouts
  introduced by MDEV-38975 (see [`storage/heap/hp_blob.c`](https://github.com/MariaDB/server/blob/MDEV-38975/storage/heap/hp_blob.c)):
  - Case A (1–5 bytes): single-record inline, zero-copy
  - Case B (1–10KB): single-run contiguous, zero-copy
  - Case C (20–50KB): multi-run, reassembly
  - Mixed: weighted combination of all three

## Prerequisites

On the target machine:

- **MariaDB git repository** cloned locally with both branches/commits available
- **Phoronix Test Suite**, **sysbench**, and **MariaDB build dependencies**

### Fedora / RHEL

```bash
sudo dnf install phoronix-test-suite sysbench \
    cmake gcc gcc-c++ make bison flex \
    ncurses-devel openssl-devel zlib-devel libevent-devel \
    libxml2-devel pcre2-devel systemd-devel \
    libaio-devel libcurl-devel snappy-devel lz4-devel \
    checkpolicy git
```

### Debian / Ubuntu

```bash
sudo apt-get install phoronix-test-suite sysbench \
    cmake gcc g++ make bison flex \
    libncurses-dev libssl-dev zlib1g-dev libevent-dev \
    libxml2-dev libpcre2-dev libsystemd-dev \
    libaio-dev libcurl4-openssl-dev libsnappy-dev liblz4-dev \
    checkpolicy git
```

> **Note:** If `phoronix-test-suite` is not available in your distro's repos,
> install from source: https://github.com/phoronix-test-suite/phoronix-test-suite

## Usage

### 1. Build

```bash
./build.sh <git-repo-source> <branch|commit|PR:N>
```

Checks out the branch, commit, or GitHub PR, deploys the PTS test profile, and
compiles MariaDB from source with `-march=native` optimizations. Also initializes
the database and prepares all benchmark data (sysbench tables, BLOB/TEXT tables,
geometry tables, schema objects for I_S tests).

Builds are stashed in `~/.mariadb-blob-builds/<identifier>/` so multiple builds
can coexist. The run script activates the right build by identifier.

```bash
./build.sh ~/mariadb-server 10.11           # branch name
./build.sh ~/mariadb-server 14f96a2e080     # commit SHA
./build.sh ~/mariadb-server PR:4735         # GitHub PR (fetched from origin)
```

The `TEMP_ENGINE` environment variable controls the engine used by `heap_blob_*`
tests. User-issued `CREATE TEMPORARY TABLE` uses the `default_tmp_storage_engine`
(InnoDB) regardless of column types; it does not go through the optimizer's
`choose_engine()` path that selects HEAP for internal temp tables. On baseline,
`CREATE TEMPORARY TABLE ... ENGINE=MEMORY` with BLOB columns errors out
(`ER_TABLE_CANT_HANDLE_BLOB`) because the HEAP engine sets `HA_NO_BLOBS`. Set
`TEMP_ENGINE=MEMORY` for the MDEV-38975 build so those tests use HEAP:

```bash
./build.sh ~/mariadb-server 10.11                      # baseline: InnoDB temp tables
TEMP_ENGINE=MEMORY ./build.sh ~/mariadb-server PR:4735  # PR: HEAP temp tables
```

If the branch or PR is not available locally, `build.sh` fetches it from origin
automatically.

### 2. Run

```bash
./run-benchmark.sh <identifier> [result-name]
```

Activates the build matching `<identifier>` and runs the benchmark suite against
it. The identifier labels this run in the result file and must match what was
passed to `build.sh`. The optional result-name defaults to `mdev38975-comparison`.

Multiple builds can be run without rebuilding:

```bash
# Build both versions upfront
./build.sh ~/mariadb-server 14f96a2e080
./build.sh ~/mariadb-server PR:4735

# Run in any order — no rebuild needed
BENCH_THREADS="1,44,88,176" ./run-benchmark.sh 14f96a2e080
BENCH_THREADS="1,44,88,176" ./run-benchmark.sh PR:4735
```

### 3. Stop

```bash
./kill-benchmark.sh
```

Force-stops a running benchmark (PTS, sysbench workers, and MariaDB server).

### 4. View results

Both runs are stored in the same PTS result file. PTS generates side-by-side
comparisons automatically:

```bash
# Text summary in terminal
phoronix-test-suite result-file-to-text mdev38975-comparison

# PDF with bar charts
phoronix-test-suite result-file-to-pdf mdev38975-comparison

# HTML (opens in browser)
phoronix-test-suite result-file-to-html mdev38975-comparison

# Interactive browser UI
phoronix-test-suite gui mdev38975-comparison

# Upload to OpenBenchmarking.org (shareable link)
phoronix-test-suite upload-result mdev38975-comparison
```

## Configuration

Environment variables control what gets run:

| Variable | Default | Phase | Description |
|----------|---------|-------|-------------|
| `TEMP_ENGINE` | *(unset)* | Build | Engine for `heap_blob_*` tests (set to `MEMORY` for MDEV-38975) |
| `BENCH_TESTS` | all 28 tests | Run | Comma-separated test names |
| `BENCH_THREADS` | `1,16,64` | Run | Comma-separated thread counts |
| `BENCH_DURATION` | `120` | Run | Seconds per test run |
| `FORCE_TIMES_TO_RUN` | `3` | Run | Runs per configuration (for statistical stability) |

### Full A/B reproduction

```bash
# Build baseline (InnoDB temp tables for heap_blob_* tests)
./build.sh ~/mariadb-server 10.11

# Build MDEV-38975 (HEAP temp tables for heap_blob_* tests)
TEMP_ENGINE=MEMORY ./build.sh ~/mariadb-server MDEV-38975

# Run baseline, then PR — all 28 tests, 120s per test, 3 runs per config
BENCH_THREADS="1,16,64,128" ./run-benchmark.sh 10.11
BENCH_THREADS="1,16,64,128" ./run-benchmark.sh MDEV-38975

# View comparison
phoronix-test-suite result-file-to-text mdev38975-comparison
```

### Quick run with fewer tests

```bash
BENCH_TESTS="oltp_read_write,blob_case_b,is_columns" \
BENCH_THREADS="1,64" \
BENCH_DURATION=60 \
FORCE_TIMES_TO_RUN=2 \
./run-benchmark.sh MDEV-38975
```

## Available tests

### Stock sysbench OLTP (regression check)

| Test | Description |
|------|-------------|
| `oltp_read_write` | Mixed read/write transactions |
| `oltp_read_only` | Read-only transactions |
| `oltp_write_only` | Write-only transactions |
| `oltp_point_select` | Primary key lookups |
| `oltp_update_non_index` | Updates on non-indexed columns |
| `oltp_update_index` | Updates on indexed columns |

### BLOB/TEXT temp table tests

| Test | Description |
|------|-------------|
| `blob_group_by` | `GROUP BY` on TEXT column (50K rows) |
| `blob_distinct` | `DISTINCT` on TEXT column (50K rows) |
| `blob_union` | `UNION` deduplication on TEXT columns |
| `blob_subquery` | Subquery materialization with TEXT |
| `blob_count_distinct` | `COUNT(DISTINCT text_col)` — separate `Aggregator_distinct` path |
| `blob_group_concat` | `GROUP_CONCAT(text_col)` — accumulates TEXT in temp table |
| `blob_window_func` | `ROW_NUMBER() OVER (PARTITION BY k)` — window function temp table |
| `blob_cte` | `WITH ... AS` — CTE materialization with TEXT |
| `blob_cte_materialize` | CTE materialized into HEAP temp table, self-joined with blob comparison |
| `blob_orderby_groupby` | `GROUP BY text_col ORDER BY k` — two-phase temp table |
| `blob_rollup` | `GROUP BY ... WITH ROLLUP` — rollup level temp tables |
| `blob_insert_select` | `INSERT...SELECT` into temp table with TEXT |

### INFORMATION_SCHEMA tests

| Test | Description |
|------|-------------|
| `is_columns` | Full scan of `I_S.COLUMNS` with ordering |
| `is_tables_join` | Join `I_S.COLUMNS` with `I_S.TABLES` |
| `is_routines` | `I_S.ROUTINES` — 60 stored procs with large `ROUTINE_DEFINITION` (LONGTEXT) |
| `is_views` | `I_S.VIEWS` — 30 views with complex `VIEW_DEFINITION` (LONGTEXT) |
| `is_triggers` | `I_S.TRIGGERS` — 50 triggers with large `ACTION_STATEMENT` (LONGTEXT) |
| `show_columns_loop` | `SHOW FULL COLUMNS` for every table — simulates ORM/admin tool startup |
| `is_group_by_complex` | `GROUP BY` + `GROUP_CONCAT` + `HAVING` on I_S.COLUMNS — double temp table |

### GEOMETRY test

| Test | Description |
|------|-------------|
| `geom_distinct` | `DISTINCT` on `ST_AsText(geom)` + TEXT |

### BLOB size case tests

These tests exercise the three HEAP BLOB continuation chain layouts introduced
by MDEV-38975. See [`storage/heap/hp_blob.c`](https://github.com/MariaDB/server/blob/MDEV-38975/storage/heap/hp_blob.c)
for the implementation.

| Test | Blob size | HEAP layout |
|------|-----------|-------------|
| `blob_case_a` | 1–5 bytes | Single-record inline, zero-copy |
| `blob_case_b` | 1–10KB | Single-run contiguous, zero-copy |
| `blob_case_c` | 20–50KB | Multi-run, reassembly |
| `blob_mixed` | All three (30/30/40%) | Mixed |

### Explicit temp table tests

These tests exercise `CREATE TEMPORARY TABLE` with BLOB columns, creating,
populating from source data, querying, and dropping in a loop. The engine is
controlled by the `TEMP_ENGINE` environment variable at build time:

- **Baseline build** (`./build.sh`): no ENGINE clause, uses InnoDB (default)
- **MDEV-38975 build** (`TEMP_ENGINE=MEMORY ./build.sh`): `ENGINE=MEMORY`, uses HEAP

This isolates the HEAP BLOB performance by comparing InnoDB temp tables (baseline)
against HEAP temp tables (MDEV-38975) for the same workload.

| Test | Source table | Description |
|------|-------------|-------------|
| `heap_blob_case_a` | `blob_case_a` (50K rows) | 1–5B blobs |
| `heap_blob_case_b` | `blob_case_b` (10K rows) | 1–10KB blobs |
| `heap_blob_case_c` | `blob_case_c` (10K rows) | 20–50KB blobs |
| `heap_blob_mixed` | `blob_mixed` (20K rows) | All cases mixed |

## Internal temporary table coverage analysis

MariaDB creates internal (implicit) temporary tables automatically to execute
certain SQL operations. MDEV-38975 affects all paths where such a temp table
contains BLOB/TEXT/JSON/GEOMETRY columns, because these previously forced Aria
(disk-backed) instead of HEAP (in-memory).

The following table lists every internal temp table creation path found in the
MariaDB 10.11 source code (`sql/sql_select.cc`, `sql/sql_union.cc`,
`sql/item_sum.cc`, `sql/opt_subselect.cc`, `sql/sql_derived.cc`,
`sql/sql_cte.cc`, `sql/sql_window.cc`, `sql/sql_expression_cache.cc`,
`sql/json_table.cc`, `sql/sql_update.cc`), along with coverage status.

### Covered operations

| # | Operation | Code path | Test(s) |
|---|-----------|-----------|---------|
| 1 | `GROUP BY` (no usable index) | `create_postjoin_aggr_table()` | `blob_group_by` |
| 2 | `DISTINCT` (no usable index) | `create_postjoin_aggr_table()` | `blob_distinct`, `blob_case_a/b/c/mixed` |
| 3 | `UNION` (deduplication) | `sql_union.cc` line 351 | `blob_union` |
| 4 | `COUNT(DISTINCT col)` | `Aggregator_distinct::setup()` in `item_sum.cc` | `blob_count_distinct` |
| 5 | `GROUP_CONCAT(col)` | `Item_func_group_concat::setup()` | `blob_group_concat` |
| 6 | Window functions (`OVER`) | `Window_funcs_computation::setup()` in `sql_window.cc` | `blob_window_func` |
| 7 | CTE (`WITH ... AS`) | `With_element::instantiate_tmp_tables()` in `sql_cte.cc` | `blob_cte` |
| 8 | CTE materialization + self-join | Dual reference forces materialization in `sql_cte.cc` | `blob_cte_materialize` |
| 9 | `ORDER BY` + `GROUP BY` (different columns) | Two-phase: aggr temp table + filesort | `blob_orderby_groupby` |
| 10 | `GROUP BY ... WITH ROLLUP` | Extra rollup level temp tables | `blob_rollup` |
| 11 | `INSERT...SELECT` (same table) | Materialization to separate read/write | `blob_insert_select` |
| 12 | Subquery `IN` materialization | `opt_subselect.cc` line 4203 | `blob_subquery` |
| 13 | Derived table materialization | `sql_derived.cc` line 1146 | Implicit via `COUNT(*) FROM (subquery) t` wrappers |
| 14 | `INFORMATION_SCHEMA` queries | I_S tables have TEXT columns | `is_columns`, `is_tables_join` |
| 15 | I_S.ROUTINES (LONGTEXT bodies) | `fill_schema_proc()` in `sql_show.cc` | `is_routines` |
| 16 | I_S.VIEWS (LONGTEXT definitions) | `get_schema_views_record()` in `sql_show.cc` | `is_views` |
| 17 | I_S.TRIGGERS (LONGTEXT statements) | `get_schema_triggers_record()` in `sql_show.cc` | `is_triggers` |
| 18 | SHOW commands (I_S materialization) | `get_all_tables()` → `create_schema_table()` | `show_columns_loop` |
| 19 | Complex GROUP BY on I_S (double temp) | I_S materialization + aggregation temp table | `is_group_by_complex` |
| 20 | `GEOMETRY` operations | `Field_geom` → `MYSQL_TYPE_GEOMETRY` | `geom_distinct` |
| 21 | Explicit `CREATE TEMPORARY TABLE` with BLOB | InnoDB on baseline; `ENGINE=MEMORY` (HEAP) on MDEV-38975 via `TEMP_ENGINE` | `heap_blob_case_a/b/c/mixed` |

### Intentionally excluded

| # | Operation | Reason |
|---|-----------|--------|
| 22 | Semi-join duplicate weedout | Rowid-only temp table, no BLOB columns involved |
| 23 | Expression cache | Disabled for HEAP+blob by design (key format incompatibility) |
| 24 | Multi-table `UPDATE`/`DELETE` | DML operations; not suitable for read-loop benchmarking |
| 25 | `JSON_TABLE()` | Same `create_tmp_table()` path as derived tables (covered by #13) |
| 26 | `VIEW` with `TEMPTABLE` algorithm | Same materialization path as derived tables (covered by #13) |
| 27 | `HAVING` clause | Uses the GROUP BY temp table, not a separate allocation |
| 28 | `UNION ALL` | No deduplication needed; does not create a temp table for uniqueness |
| 29 | Cursor `FETCH INTO` | Stored procedure construct; same `create_tmp_table()` path |
| 30 | `SELECT` handler / engine pushdown | Engine-specific (Spider); not applicable to standard workloads |
| 31 | I_S privilege tables | No LONGTEXT columns (USER/SCHEMA/TABLE/COLUMN_PRIVILEGES) |
| 32 | `SHOW DATABASES` / `SHOW STATUS` / `SHOW VARIABLES` | I_S.SCHEMATA/STATUS/VARIABLES have no LONGTEXT columns |
| 33 | `SHOW PROCESSLIST` | INFO is LONGTEXT but result depends on concurrent queries; non-deterministic |
| 34 | I_S.EVENTS | Would need event scheduler enabled; niche use case |
| 35 | I_S.PARTITIONS | Partition expressions are typically short LONGTEXT; marginal benefit |
| 36 | FK constraint checking | I_S query is a tiny fraction of the DML operation |

## File structure

```
├── build.sh                 # Build: git checkout + cmake + PTS install
├── run-benchmark.sh         # Run: execute tests against active build
├── kill-benchmark.sh        # Force-stop a running benchmark
├── README.md
└── mariadb-blob-1.2.0/      # PTS local test profile
    ├── test-definition.xml   # Test metadata and menu options
    ├── install.sh            # Build from source + data preparation
    ├── pre.sh                # Start MariaDB server before each run
    ├── post.sh               # Stop server after each run
    └── results-definition.xml# Result parser (sysbench-compatible format)
```

### Runtime directories

| Path | Description |
|------|-------------|
| `~/.mariadb-blob-builds/<id>/` | Build repository — one directory per build |
| `~/.phoronix-test-suite/installed-tests/local/mariadb-blob-1.2.0/` | Symlink to active build |
| `~/.phoronix-test-suite/test-results/` | PTS result files |
| `~/.mariadb-blob-build-meta` | Metadata for auto-generated test description |
