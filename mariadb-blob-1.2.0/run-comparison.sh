#!/bin/bash
#
# MariaDB MDEV-38975 Benchmark — A/B Comparison Runner
#
# Runs the benchmark suite against two builds (baseline and PR) with SAR
# recording, producing a side-by-side PTS comparison.
#
# Usage:
#   ./run-comparison.sh [result-name]
#
# Environment variables:
#   BENCH_TESTS      — comma-separated test names (default: all)
#   BENCH_THREADS    — comma-separated thread counts (default: 1,16,64,128)
#   BENCH_DURATION   — seconds per test run (default: 120)
#   FORCE_TIMES_TO_RUN — runs per configuration (default: 3)
#   BASELINE_ID      — baseline build identifier (default: 14f96a2e080)
#   PR_ID            — PR build identifier (default: MDEV-38975)
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RESULT_NAME="${1:-mdev38975-comparison}"
BASELINE_ID="${BASELINE_ID:-14f96a2e080}"
PR_ID="${PR_ID:-MDEV-38975}"
BENCH_THREADS="${BENCH_THREADS:-1,16,64,128}"

export BENCH_THREADS

echo "=== A/B Comparison: $BASELINE_ID vs $PR_ID ==="
echo "Result file: $RESULT_NAME"
echo "Threads:     $BENCH_THREADS"
echo ""

echo "=== Running baseline: $BASELINE_ID ==="
SAR_OUTPUT="$HOME/sar-${BASELINE_ID}.dat" \
    "$SCRIPT_DIR/run-benchmark.sh" "$BASELINE_ID" "$RESULT_NAME"
RET_BASE=$?
echo "Baseline exit: $RET_BASE"

echo ""
echo "=== Running PR: $PR_ID ==="
SAR_OUTPUT="$HOME/sar-${PR_ID}.dat" \
    "$SCRIPT_DIR/run-benchmark.sh" "$PR_ID" "$RESULT_NAME"
RET_PR=$?
echo "PR exit: $RET_PR"

echo ""
echo "=== All done ==="
phoronix-test-suite result-file-to-text "$RESULT_NAME"
exit $(( RET_BASE | RET_PR ))
