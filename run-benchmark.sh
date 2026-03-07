#!/bin/bash
#
# MariaDB MDEV-38975 Benchmark — Run Step
#
# Runs the mariadb-blob PTS test profile against the currently installed
# build. Call build.sh first to build a specific branch.
#
# Usage:
#   ./run-benchmark.sh <identifier> [result-name]
#
# The identifier labels this run in the PTS result file (e.g. "10.11" or
# "MDEV-38975"). Multiple runs with different identifiers in the same
# result-name produce a comparison.
#
# Examples:
#   # Build and run baseline
#   ./build.sh ~/mariadb-server 10.11
#   ./run-benchmark.sh 10.11
#
#   # Rebuild and run feature branch
#   ./build.sh ~/mariadb-server MDEV-38975
#   ./run-benchmark.sh MDEV-38975
#
#   # View comparison
#   phoronix-test-suite result-file-to-text mdev38975-comparison
#
# Environment variables:
#   BENCH_DURATION   — seconds per test run (default: 120)
#   BENCH_TESTS      — comma-separated test names (default: representative mix)
#   BENCH_THREADS    — comma-separated thread counts (default: 1,16,64)
#   FORCE_TIMES_TO_RUN — runs per configuration (default: 3)
#

set -euo pipefail

# ---- Arguments ----
IDENTIFIER="${1:?Usage: $0 <identifier> [result-name]}"
RESULT_NAME="${2:-mdev38975-comparison}"

# ---- Configuration ----
BENCH_DURATION="${BENCH_DURATION:-120}"
BENCH_THREADS="${BENCH_THREADS:-1,16,64}"
FORCE_TIMES="${FORCE_TIMES_TO_RUN:-3}"

DEFAULT_TESTS="oltp_read_write,blob_group_by,blob_distinct,blob_union,blob_count_distinct,blob_group_concat,blob_window_func,blob_cte,blob_recursive_cte,blob_orderby_groupby,blob_rollup,blob_insert_select,blob_case_a,blob_case_b,blob_case_c,blob_mixed,is_columns,is_tables_join,is_routines,is_views,is_triggers,show_columns_loop,is_group_by_complex,geom_distinct"
BENCH_TESTS="${BENCH_TESTS:-$DEFAULT_TESTS}"

# ---- Preflight ----
if ! command -v phoronix-test-suite &>/dev/null; then
    echo "ERROR: phoronix-test-suite not found."
    exit 1
fi

PTS_LOCAL_DIR="$HOME/.phoronix-test-suite/test-profiles/local"
if [ ! -d "$PTS_LOCAL_DIR/mariadb-blob-1.2.0" ]; then
    echo "ERROR: Test profile not installed. Run build.sh first."
    exit 1
fi

echo "=== MariaDB MDEV-38975 Benchmark — Run ==="
echo ""
echo "Identifier:  $IDENTIFIER"
echo "Result file: $RESULT_NAME"
echo "Duration:    ${BENCH_DURATION}s per test"
echo "Threads:     $BENCH_THREADS"
echo "Tests:       $BENCH_TESTS"
echo "Runs/config: $FORCE_TIMES"
echo ""

# ---- Configure PTS batch mode (suppress prompts) ----
phoronix-test-suite batch-setup <<'BATCHEOF' 2>/dev/null
y
y
y
y
y
y
y
n
BATCHEOF

# ---- Run each test+thread combination ----
export TEST_RESULTS_NAME="$RESULT_NAME"
export TEST_RESULTS_IDENTIFIER="$IDENTIFIER"
export FORCE_TIMES_TO_RUN="$FORCE_TIMES"
export BENCH_DURATION

IFS=',' read -ra TESTS <<< "$BENCH_TESTS"
IFS=',' read -ra THREADS <<< "$BENCH_THREADS"

for test in "${TESTS[@]}"; do
    for threads in "${THREADS[@]}"; do
        echo ""
        echo "--- Running: $test / $threads threads ($IDENTIFIER) ---"
        export PRESET_OPTIONS="mariadb-blob.test=$test;mariadb-blob.threads=$threads"
        phoronix-test-suite batch-run local/mariadb-blob-1.2.0
    done
done

# ---- Show results ----
echo ""
echo "====================================================="
echo "  Run complete: $IDENTIFIER"
echo "====================================================="
echo ""
echo "View results:"
echo "  phoronix-test-suite result-file-to-text $RESULT_NAME"
echo ""
echo "Generate comparison PDF:"
echo "  phoronix-test-suite result-file-to-pdf $RESULT_NAME"
echo ""
echo "Upload to OpenBenchmarking.org:"
echo "  phoronix-test-suite upload-result $RESULT_NAME"
echo ""

phoronix-test-suite result-file-to-text "$RESULT_NAME"
