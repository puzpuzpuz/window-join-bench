#!/usr/bin/env bash
# install_questdb.sh - install and start QuestDB 9.3.5 from the official tarball.
# Idempotent: re-runs reuse the existing install dir.
set -euo pipefail

VERSION="${QDB_VERSION:-9.3.5}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/questdb-$VERSION}"
DATA_DIR="${QDB_DATA_DIR:-$INSTALL_DIR/.questdb}"
# linux-x86-64 build with the bundled OpenJDK runtime; no system Java needed.
TARBALL="questdb-${VERSION}-rt-linux-x86-64.tar.gz"
URL="https://github.com/questdb/questdb/releases/download/${VERSION}/${TARBALL}"

if [ ! -d "$INSTALL_DIR" ]; then
  mkdir -p "$INSTALL_DIR"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading $URL"
  curl -L --fail --retry 3 "$URL" -o "$tmp/$TARBALL"
  tar -xzf "$tmp/$TARBALL" -C "$INSTALL_DIR" --strip-components=1
fi

BIN="$INSTALL_DIR/bin/questdb.sh"
mkdir -p "$DATA_DIR"

# Stop any running instance from a previous run, then start fresh.
"$BIN" stop -d "$DATA_DIR" 2>/dev/null || true
"$BIN" start -d "$DATA_DIR"

echo
echo "QuestDB $VERSION started."
echo "  HTTP/console: http://localhost:9000"
echo "  PG wire:      postgres://admin:quest@localhost:8812/qdb"
echo "  data dir:     $DATA_DIR"
echo
echo "Stop with: $BIN stop -d $DATA_DIR"
echo
echo "bench_questdb.sh expects QDB_HOME pointing here so it can toggle the"
echo "parallel WINDOW JOIN switch for the serial baseline:"
echo "  QDB_HOME=$INSTALL_DIR ./bench_questdb.sh"
