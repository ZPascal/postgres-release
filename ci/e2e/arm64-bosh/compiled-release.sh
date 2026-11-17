#!/usr/bin/env bash
# Turns a source release tarball into a compiled release for one stemcell, from
# packages already compiled into <packages-dir>/<name> (compile-packages.sh with
# PACKAGES_DIR=/var/vcap/packages, so install paths match the VM's).
#
# Package names, versions, fingerprints and dependencies are kept from the
# source release.MF; each package's digest (sha256, in the release.MF's `sha1`
# field like `bosh create-release` writes it) is that of its compiled tarball.
#
# Usage: compiled-release.sh <release.tgz> <packages-dir> <os/version> <out.tgz>
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <release.tgz> <packages-dir> <os/version> <out.tgz>" >&2
  exit 2
fi

release_tgz=$(realpath "$1")
packages_dir=$(realpath "$2")
stemcell="$3"
out=$(realpath -m "$4")
yq="${YQ:-yq}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/src" "${work}/out"
tar -xzf "$release_tgz" -C "${work}/src"

# Everything but the source packages (jobs, license, LICENSE/NOTICE) carries over.
cp -R "${work}/src/." "${work}/out/"
rm -rf "${work}/out/packages" "${work}/out/release.MF"
mkdir -p "${work}/out/compiled_packages"

manifest="${work}/out/release.MF"
STEMCELL="$stemcell" "$yq" '.compiled_packages = (.packages | map(. + {"stemcell": strenv(STEMCELL)})) | del(.packages)' \
  "${work}/src/release.MF" > "$manifest"

for pkg in $("$yq" '.compiled_packages[].name' "$manifest"); do
  if [ ! -d "${packages_dir}/${pkg}" ]; then
    echo "package ${pkg} is not compiled in ${packages_dir}" >&2
    exit 1
  fi
  tar -czf "${work}/out/compiled_packages/${pkg}.tgz" -C "${packages_dir}/${pkg}" .
  P="$pkg" S="sha256:$(sha256sum "${work}/out/compiled_packages/${pkg}.tgz" | awk '{print $1}')" \
    "$yq" -i '(.compiled_packages[] | select(.name == strenv(P))).sha1 = strenv(S)' "$manifest"
done

mkdir -p "$(dirname "$out")"
(cd "${work}/out" && tar -czf "$out" ./*)
echo "built ${out} ($("$yq" '.name + "/" + .version' "$manifest"), $("$yq" '.compiled_packages | length' "$manifest") compiled packages for ${stemcell})"
