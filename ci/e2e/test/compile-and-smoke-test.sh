#!/usr/bin/env bash
# Tests for ci/e2e/compile-packages.sh and ci/e2e/smoke-postgres.sh.
# Needs bosh, a C/C++ toolchain, libssl-dev, libreadline-dev, zlib1g-dev, network.
# Compiles ICU + PostgreSQL 18 natively (~10-15 min). Must not run as root (initdb).
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
COMPILE="${REPO_ROOT}/ci/e2e/compile-packages.sh"
SMOKE="${REPO_ROOT}/ci/e2e/smoke-postgres.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 - $2"; failures=$((failures + 1)); }

build_release() {
  local rel="$WORK/release"
  mkdir -p "$rel"
  git -C "$REPO_ROOT" archive HEAD | tar -x -C "$rel"
  (cd "$rel" && "${REPO_ROOT}/ci/e2e/prepare-yq-blobs.sh" && bosh create-release --force --tarball "$WORK/r.tgz") \
    > "$WORK/release.log" 2>&1 || { echo "release build failed:"; tail -20 "$WORK/release.log"; exit 1; }
}

test_compile_without_libicu_fails() {
  local pkgs="$WORK/pkgs-noicu"; mkdir -p "$pkgs"
  if PACKAGES_DIR="$pkgs" "$COMPILE" "$WORK/r.tgz" postgres-18 > "$WORK/noicu.log" 2>&1; then
    fail "${FUNCNAME[0]}" "compiled postgres-18 without postgres-libicu"; return
  fi
  grep -q "postgres-18" "$WORK/noicu.log" || { fail "${FUNCNAME[0]}" "failed before compiling: $(tail -3 "$WORK/noicu.log")"; return; }
  pass "${FUNCNAME[0]}"
}

test_compile_and_smoke_18() {
  local pkgs="$WORK/pkgs"; mkdir -p "$pkgs"
  if ! PACKAGES_DIR="$pkgs" "$COMPILE" "$WORK/r.tgz" postgres-libicu postgres-18 postgres-yq-4 > "$WORK/compile.log" 2>&1; then
    fail "${FUNCNAME[0]}" "compile failed: $(tail -10 "$WORK/compile.log")"; return
  fi
  "$pkgs/postgres-yq-4/bin/yq" --version | grep -q "4.54.3" || { fail "${FUNCNAME[0]}" "yq version wrong"; return; }
  if ! EXPECT_ARCH="$(uname -m)" PACKAGES_DIR="$pkgs" "$SMOKE" 18 > "$WORK/smoke.log" 2>&1; then
    fail "${FUNCNAME[0]}" "smoke failed: $(tail -10 "$WORK/smoke.log")"; return
  fi
  grep -q "PostgreSQL 18\." "$WORK/smoke.log" || { fail "${FUNCNAME[0]}" "version not reported"; return; }
  pass "${FUNCNAME[0]}"
}

test_smoke_cleans_up_on_failure() {
  # postgres-17 binaries are absent, but point the 17 path at the built 18 so the
  # server starts and the major-version assertion fails *after* startup.
  local pkgs="$WORK/pkgs"
  [ -d "$pkgs/postgres-18" ] || { fail "${FUNCNAME[0]}" "needs postgres-18 from previous test"; return; }
  ln -sfn "$pkgs/postgres-18" "$pkgs/postgres-17"
  if PACKAGES_DIR="$pkgs" "$SMOKE" 17 > "$WORK/cleanup.log" 2>&1; then
    fail "${FUNCNAME[0]}" "smoke passed for the wrong major"; rm -f "$pkgs/postgres-17"; return
  fi
  rm -f "$pkgs/postgres-17"
  grep -q "server started" "$WORK/cleanup.log" || { fail "${FUNCNAME[0]}" "server never started: $(tail -5 "$WORK/cleanup.log")"; return; }
  if pgrep -f "$pkgs/postgres-18/bin/postgres" > /dev/null; then
    fail "${FUNCNAME[0]}" "postgres still running after failure"; pkill -f "$pkgs/postgres-18/bin/postgres"; return
  fi
  pass "${FUNCNAME[0]}"
}

build_release
test_compile_without_libicu_fails
test_compile_and_smoke_18
test_smoke_cleans_up_on_failure

if [ "$failures" -ne 0 ]; then echo "${failures} FAILED"; exit 1; fi
echo "ALL PASSED"
