#!/usr/bin/env bash
# Tests for ci/e2e/prepare-yq-blobs.sh. Needs bosh, curl and network access.
# Each case runs against a fresh export of HEAD, so the working tree is never touched.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="${REPO_ROOT}/ci/e2e/prepare-yq-blobs.sh"
YQ_VERSION=4.54.3
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 - $2"; failures=$((failures + 1)); }

fresh_release() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  git -C "$REPO_ROOT" archive HEAD | tar -x -C "$dir"
  echo "$dir"
}

asset_cache() {
  local dir="$WORK/assets"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    for f in yq_linux_amd64 yq_linux_arm64 checksums checksums_hashes_order; do
      curl -fsSL -o "$dir/$f" "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/$f"
    done
  fi
  echo "$dir"
}

test_adds_both_arch_blobs() {
  local rel; rel=$(fresh_release adds)
  if ! (cd "$rel" && "$SCRIPT") > "$WORK/adds.log" 2>&1; then
    fail "${FUNCNAME[0]}" "script failed: $(tail -5 "$WORK/adds.log")"; return
  fi
  grep -q "^yq/postgres-yq-amd64-${YQ_VERSION}:" "$rel/config/blobs.yml" || { fail "${FUNCNAME[0]}" "amd64 blob missing"; return; }
  grep -q "^yq/postgres-yq-arm64-${YQ_VERSION}:" "$rel/config/blobs.yml" || { fail "${FUNCNAME[0]}" "arm64 blob missing"; return; }
  if grep -q "^yq/postgres-yq-${YQ_VERSION}:" "$rel/config/blobs.yml"; then fail "${FUNCNAME[0]}" "stale blob still listed"; return; fi
  if ! (cd "$rel" && bosh create-release --force --tarball "$WORK/r.tgz") > "$WORK/create.log" 2>&1; then
    fail "${FUNCNAME[0]}" "create-release failed: $(tail -5 "$WORK/create.log")"; return
  fi
  pass "${FUNCNAME[0]}"
}

test_noop_when_present() {
  local rel assets; rel=$(fresh_release noop); assets=$(asset_cache)
  (cd "$rel" && YQ_ASSET_DIR="$assets" "$SCRIPT") > /dev/null 2>&1 || { fail "${FUNCNAME[0]}" "first run failed"; return; }
  cp "$rel/config/blobs.yml" "$WORK/blobs.first"
  (cd "$rel" && YQ_ASSET_DIR="$assets" "$SCRIPT") > /dev/null 2>&1 || { fail "${FUNCNAME[0]}" "second run failed"; return; }
  cmp -s "$WORK/blobs.first" "$rel/config/blobs.yml" || { fail "${FUNCNAME[0]}" "blobs.yml changed on second run"; return; }
  pass "${FUNCNAME[0]}"
}

test_checksum_mismatch_fails() {
  local rel bad; rel=$(fresh_release mismatch)
  bad="$WORK/bad-assets"; mkdir -p "$bad"
  cp "$(asset_cache)"/* "$bad/"
  echo junk > "$bad/yq_linux_arm64"
  cp "$rel/config/blobs.yml" "$WORK/blobs.before"
  if (cd "$rel" && YQ_ASSET_DIR="$bad" "$SCRIPT") > "$WORK/mismatch.log" 2>&1; then
    fail "${FUNCNAME[0]}" "script succeeded with a tampered binary"; return
  fi
  grep -q "SHA-256 verification failed for yq_linux_arm64" "$WORK/mismatch.log" || { fail "${FUNCNAME[0]}" "failed for another reason: $(tail -3 "$WORK/mismatch.log")"; return; }
  cmp -s "$WORK/blobs.before" "$rel/config/blobs.yml" || { fail "${FUNCNAME[0]}" "blobs.yml modified despite failure"; return; }
  pass "${FUNCNAME[0]}"
}

test_adds_missing_arch_without_stale_entry() {
  # amd64 already listed, arm64 missing, no legacy entry: nothing to remove.
  local rel assets; rel=$(fresh_release partial); assets=$(asset_cache)
  (cd "$rel" && YQ_ASSET_DIR="$assets" "$SCRIPT") > /dev/null 2>&1 || { fail "${FUNCNAME[0]}" "setup run failed"; return; }
  (cd "$rel" && bosh remove-blob "yq/postgres-yq-arm64-${YQ_VERSION}") > /dev/null 2>&1
  if ! (cd "$rel" && YQ_ASSET_DIR="$assets" "$SCRIPT") > "$WORK/partial.log" 2>&1; then
    fail "${FUNCNAME[0]}" "script failed: $(tail -3 "$WORK/partial.log")"; return
  fi
  grep -q "^yq/postgres-yq-arm64-${YQ_VERSION}:" "$rel/config/blobs.yml" || { fail "${FUNCNAME[0]}" "arm64 blob not re-added"; return; }
  pass "${FUNCNAME[0]}"
}

test_adds_both_arch_blobs
test_noop_when_present
test_adds_missing_arch_without_stale_entry
test_checksum_mismatch_fails

if [ "$failures" -ne 0 ]; then echo "${failures} FAILED"; exit 1; fi
echo "ALL PASSED"
