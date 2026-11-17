#!/usr/bin/env bash
# Makes the release buildable in CI when config/blobs.yml does not yet list the
# per-arch yq blobs that packages/postgres-yq-4/spec expects. Downloads the yq
# binaries for the version already in blobs.yml, verifies their SHA-256 against
# the yq release checksums and adds them as *local* blobs. Nothing is uploaded.
#
# Run from the release root. Optional: YQ_ASSET_DIR=<dir> holding pre-downloaded
# yq_linux_amd64, yq_linux_arm64, checksums, checksums_hashes_order.
set -euo pipefail

ARCHES=(amd64 arm64)

version=$(grep -oE '^yq/postgres-yq-(amd64-|arm64-)?[0-9.]+' config/blobs.yml | head -1 | grep -oE '[0-9.]+$')
if [ -z "$version" ]; then
  echo "No yq blob found in config/blobs.yml" >&2
  exit 1
fi

missing=()
for arch in "${ARCHES[@]}"; do
  grep -q "^yq/postgres-yq-${arch}-${version}:" config/blobs.yml || missing+=("$arch")
done

if [ "${#missing[@]}" -eq 0 ]; then
  echo "yq ${version} blobs for ${ARCHES[*]} already present; nothing to do"
  exit 0
fi

assets="${YQ_ASSET_DIR:-}"
if [ -z "$assets" ]; then
  assets=$(mktemp -d)
  trap 'rm -rf "$assets"' EXIT
  for f in checksums checksums_hashes_order "${missing[@]/#/yq_linux_}"; do
    curl -fsSL -o "${assets}/${f}" "https://github.com/mikefarah/yq/releases/download/v${version}/${f}"
  done
fi

# Same lookup as ci/tasks/bump-yq-packages/task.sh. Verify everything before
# touching blobs.yml so a bad download leaves the release untouched.
sha256_col=$(grep -n "^SHA-256$" "${assets}/checksums_hashes_order" | cut -f1 -d:)
for arch in "${missing[@]}"; do
  src="yq_linux_${arch}"
  expected=$(awk -v col="$((sha256_col + 1))" "/^${src}[[:space:]]/{print \$col}" "${assets}/checksums")
  actual=$(sha256sum "${assets}/${src}" | awk '{print $1}')
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "SHA-256 verification failed for ${src} (expected '${expected}', got '${actual}')" >&2
    exit 1
  fi
  echo "SHA-256 verified for ${src}: ${actual}"
done

for arch in "${missing[@]}"; do
  blob="postgres-yq-${arch}-${version}"
  cp "${assets}/yq_linux_${arch}" "${assets}/${blob}"
  bosh add-blob --sha2 "${assets}/${blob}" "yq/${blob}"
done

# Drop yq entries the spec no longer references (e.g. yq/postgres-yq-<version>).
# (grep -v exits 1 when nothing is stale; keep that out of pipefail.)
while IFS= read -r stale; do
  echo "removing unreferenced blob ${stale}"
  bosh remove-blob "$stale"
done < <(grep -oE '^yq/[^:]+' config/blobs.yml \
  | { grep -vxF -e "yq/postgres-yq-amd64-${version}" -e "yq/postgres-yq-arm64-${version}" || true; })
