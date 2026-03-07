#!/bin/bash
#
# MariaDB MDEV-38975 Benchmark — Build Step
#
# Checks out the specified branch, deploys the PTS test profile,
# and runs the PTS install (which builds MariaDB from source).
#
# Usage:
#   ./build.sh <git-repo-source> <branch>
#
# Examples:
#   ./build.sh ~/mariadb-server 10.11
#   ./build.sh ~/mariadb-server MDEV-38975
#
# Prerequisites:
#   - phoronix-test-suite installed
#   - sysbench installed
#   - MariaDB build dependencies (cmake, gcc/g++, bison, flex, libncurses-dev,
#     libssl-dev, zlib1g-dev, libevent-dev)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/mariadb-blob-1.2.0"
PTS_LOCAL_DIR="$HOME/.phoronix-test-suite/test-profiles/local"

# ---- Arguments ----
REPO_PATH="${1:?Usage: $0 <git-repo-source> <branch>}"
BRANCH="${2:?Usage: $0 <git-repo-source> <branch>}"

REPO_PATH="$(cd "$REPO_PATH" && pwd)"

# ---- Preflight checks ----
if ! command -v phoronix-test-suite &>/dev/null; then
    echo "ERROR: phoronix-test-suite not found. Install it from:"
    echo "  https://github.com/phoronix-test-suite/phoronix-test-suite"
    echo ""
    echo "Quick install:"
    echo "  git clone https://github.com/phoronix-test-suite/phoronix-test-suite.git"
    echo "  cd phoronix-test-suite && sudo ./install-sh"
    exit 1
fi

if ! command -v sysbench &>/dev/null; then
    echo "ERROR: sysbench not found. Install via package manager:"
    echo "  Fedora/RHEL: dnf install sysbench"
    echo "  Debian/Ubuntu: apt install sysbench"
    exit 1
fi

if ! command -v cmake &>/dev/null; then
    echo "ERROR: cmake not found. Install build dependencies first."
    exit 1
fi

if [ ! -d "$REPO_PATH/.git" ]; then
    echo "ERROR: $REPO_PATH is not a git repository"
    exit 1
fi

# Verify branch/ref exists, fetch if needed
cd "$REPO_PATH"
if ! git rev-parse --verify "$BRANCH" &>/dev/null && \
   ! git rev-parse --verify "origin/$BRANCH" &>/dev/null; then
    echo "--- Fetching $BRANCH from origin ---"
    if ! git fetch origin "$BRANCH"; then
        echo "ERROR: Branch '$BRANCH' not found locally or on origin in $REPO_PATH"
        exit 1
    fi
fi

# ---- Deploy PTS test profile ----
echo "=== MariaDB MDEV-38975 Benchmark — Build ==="
echo ""
echo "Repository: $REPO_PATH"
echo "Branch:     $BRANCH"
echo ""

echo "--- Deploying test profile to PTS ---"
mkdir -p "$PTS_LOCAL_DIR"
rm -rf "$PTS_LOCAL_DIR/mariadb-blob-1.2.0"
cp -a "$PROFILE_DIR" "$PTS_LOCAL_DIR/mariadb-blob-1.2.0"
echo "Installed to: $PTS_LOCAL_DIR/mariadb-blob-1.2.0"

# ---- Checkout branch ----
echo "--- Checking out $BRANCH ---"
cd "$REPO_PATH"
git checkout "$BRANCH"
git submodule update --init --recursive

# ---- Build via PTS force-install ----
echo "--- Building MariaDB from $BRANCH (PTS install) ---"
# PTS may not propagate env vars to install.sh; persist for install.sh to read
export MARIADB_SRC_DIR="$REPO_PATH"
echo "$REPO_PATH" > "$HOME/.mariadb-blob-src-dir"
phoronix-test-suite force-install local/mariadb-blob-1.2.0

# Verify install actually succeeded (PTS may return 0 on failure)
PTS_INSTALL_DIR="$HOME/.phoronix-test-suite/installed-tests/local/mariadb-blob-1.2.0"
if [ ! -x "$PTS_INSTALL_DIR/mariadb-blob" ] || [ ! -d "$PTS_INSTALL_DIR/mariadb_/bin" ]; then
    echo "ERROR: PTS install did not produce expected artifacts."
    echo "Check PTS output above for errors."
    exit 1
fi

echo ""
echo "=== Build complete for branch: $BRANCH ==="
echo ""
echo "Run benchmarks with:"
echo "  ./run-benchmark.sh $BRANCH [result-name]"
