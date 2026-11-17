#!/usr/bin/env bash
# Builds an ARM64 warden-tar stemcell for the Docker CPI from a checkout of
# aws-samples/sample-cloud-foundry-graviton: its stemcell image, plus the
# overlay in this directory, exported as a rootfs tarball.
#
# The sample's prerequisite binaries (patched bosh-agent, davcli, nats-server)
# must already be in <sample-dir>/bin (scripts/build-binaries.sh there).
#
# Usage: build-stemcell.sh <sample-dir> <out.tgz>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <sample-dir> <out.tgz>" >&2
  exit 2
fi

sample_dir=$(realpath "$1")
out=$(realpath -m "$2")
here=$(cd "$(dirname "$0")" && pwd)
name="${STEMCELL_NAME:-bosh-docker-ubuntu-noble-arm64-e2e}"
version="${STEMCELL_VERSION:-1.0-arm64}"

docker build --platform linux/arm64 -t bosh-stemcell-arm64:sample \
  -f "${sample_dir}/Dockerfile.stemcell" "$sample_dir"
docker build --platform linux/arm64 -t bosh-stemcell-arm64:e2e \
  --build-arg BASE=bosh-stemcell-arm64:sample \
  -f "${here}/Dockerfile.stemcell" "$here"

arch=$(docker inspect bosh-stemcell-arm64:e2e --format '{{.Architecture}}')
[ "$arch" = arm64 ] || { echo "stemcell image is ${arch}, expected arm64" >&2; exit 1; }

work=$(mktemp -d)
cid=""
trap '[ -n "$cid" ] && docker rm "$cid" >/dev/null; rm -rf "$work"' EXIT

# The Docker CPI imports a flat rootfs tarball: docker export, not docker save.
cid=$(docker create --platform linux/arm64 bosh-stemcell-arm64:e2e /bin/true)
docker export "$cid" | gzip > "${work}/image"

cat > "${work}/stemcell.MF" <<EOF
---
name: ${name}
version: '${version}'
bosh_protocol: 1
api_version: 3
sha1: $(sha1sum "${work}/image" | awk '{print $1}')
operating_system: ubuntu-noble
stemcell_formats:
- warden-tar
cloud_properties:
  infrastructure: docker
  architecture: arm64
EOF

mkdir -p "$(dirname "$out")"
tar -czf "$out" -C "$work" stemcell.MF image
echo "built ${out} (${name}/${version}, $(du -h "$out" | cut -f1))"
