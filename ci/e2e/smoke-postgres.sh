#!/usr/bin/env bash
# Starts a throwaway PostgreSQL from a compiled postgres-<major> package and
# queries it: checks the reported major version (and CPU architecture when
# EXPECT_ARCH is set) and, for 16+, that ICU collations work. The server and
# its data directory are always removed on exit.
#
# Usage: PACKAGES_DIR=/var/vcap/packages [PORT=55432] [EXPECT_ARCH=aarch64] smoke-postgres.sh <major>
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <major>" >&2
  exit 2
fi

major=$1
bin="${PACKAGES_DIR:-/var/vcap/packages}/postgres-${major}/bin"
port="${PORT:-55432}"
dir=$(mktemp -d)

cleanup() {
  "${bin}/pg_ctl" -D "${dir}/data" -m immediate stop > /dev/null 2>&1 || true
  rm -rf "$dir"
}
trap cleanup EXIT

# UTF8 explicitly: ICU collations reject SQL_ASCII, which initdb picks under the C locale.
"${bin}/initdb" -D "${dir}/data" -U postgres --auth=trust -E UTF8 --locale=C > "${dir}/initdb.log"
"${bin}/pg_ctl" -D "${dir}/data" -l "${dir}/server.log" -w \
  -o "-p ${port} -k ${dir} -c listen_addresses=''" start

psql() { "${bin}/psql" -h "$dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 -Atc "$1"; }

version=$(psql 'SELECT version();')
echo "$version"

case "$version" in
  "PostgreSQL ${major}."*) ;;
  *) echo "expected PostgreSQL ${major}.x, got: ${version}" >&2; exit 1 ;;
esac

if [ -n "${EXPECT_ARCH:-}" ] && [[ "$version" != *"${EXPECT_ARCH}"* ]]; then
  echo "expected architecture ${EXPECT_ARCH} in: ${version}" >&2
  exit 1
fi

if [ "$major" -ge 16 ]; then
  psql "CREATE COLLATION e2e_icu (provider = icu, locale = 'de-DE');"
  psql "SELECT 'a' < 'B' COLLATE e2e_icu;" | grep -qx t
  echo "ICU collation OK"
fi

echo "smoke test passed for PostgreSQL ${major}"
