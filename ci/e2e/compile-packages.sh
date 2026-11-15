#!/usr/bin/env bash
# Compiles packages from a release tarball natively, the way the BOSH agent does:
# each package's files are unpacked into a fresh compile dir and its `packaging`
# script runs there with BOSH_COMPILE_TARGET, BOSH_INSTALL_TARGET and
# BOSH_PACKAGES_PATH set. Packages compile in argument order (dependencies first)
# and the script stops at the first failure.
#
# Usage: PACKAGES_DIR=/var/vcap/packages compile-packages.sh <release.tgz> <package>...
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <release.tgz> <package>..." >&2
  exit 2
fi

release_tgz=$(realpath "$1"); shift
packages_dir="${PACKAGES_DIR:-/var/vcap/packages}"
mkdir -p "$packages_dir"
packages_dir=$(realpath "$packages_dir")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$release_tgz" -C "$work"

for pkg in "$@"; do
  pkg_tgz="${work}/packages/${pkg}.tgz"
  if [ ! -f "$pkg_tgz" ]; then
    echo "package ${pkg} not found in ${release_tgz}" >&2
    exit 1
  fi

  echo "=== Compiling ${pkg} ==="
  compile_dir="${work}/compile/${pkg}"
  mkdir -p "$compile_dir" "${packages_dir}/${pkg}"
  tar -xzf "$pkg_tgz" -C "$compile_dir"
  chmod +x "${compile_dir}/packaging"

  if ! (cd "$compile_dir" && \
        BOSH_COMPILE_TARGET="$compile_dir" \
        BOSH_INSTALL_TARGET="${packages_dir}/${pkg}" \
        BOSH_PACKAGES_PATH="$packages_dir" \
        BOSH_PACKAGE_NAME="$pkg" \
        ./packaging); then
    echo "=== Compiling ${pkg} FAILED ===" >&2
    exit 1
  fi
  echo "=== Compiled ${pkg} into ${packages_dir}/${pkg} ==="
done
