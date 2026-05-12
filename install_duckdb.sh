#!/usr/bin/env bash
# install_duckdb.sh - install the DuckDB 1.2.0 CLI from the official release.
# DuckDB is embedded; there is no server to start. The script just drops the
# `duckdb` binary into INSTALL_DIR and verifies the version.
set -euo pipefail

VERSION="${DUCKDB_VERSION:-1.2.0}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  ASSET="duckdb_cli-linux-amd64.zip" ;;
  Linux-aarch64) ASSET="duckdb_cli-linux-aarch64.zip" ;;
  Darwin-*)      ASSET="duckdb_cli-osx-universal.zip" ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

URL="https://github.com/duckdb/duckdb/releases/download/v${VERSION}/${ASSET}"

mkdir -p "$INSTALL_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $URL"
curl -L --fail --retry 3 "$URL" -o "$tmp/duckdb.zip"
unzip -q -o "$tmp/duckdb.zip" -d "$tmp"
install -m 0755 "$tmp/duckdb" "$INSTALL_DIR/duckdb"

echo
"$INSTALL_DIR/duckdb" --version
echo "DuckDB $VERSION installed to $INSTALL_DIR/duckdb"
echo "Add $INSTALL_DIR to PATH if it is not already there."
