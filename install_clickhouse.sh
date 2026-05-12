#!/usr/bin/env bash
# install_clickhouse.sh - install and start ClickHouse 26.4 on Ubuntu 24.04
# from the official apt repository.
# Idempotent: re-runs are harmless.
set -euo pipefail

CH_VERSION="${CH_VERSION:-26.4.*}"

if ! command -v sudo >/dev/null; then
  echo "this script uses sudo; run as a user with sudo rights" >&2
  exit 1
fi

sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

curl -fsSL https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key \
  | sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/clickhouse.list >/dev/null

sudo apt-get update

# Non-interactive install: pre-set an empty default password.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "clickhouse-server=${CH_VERSION}" \
  "clickhouse-client=${CH_VERSION}" \
  "clickhouse-common-static=${CH_VERSION}"

sudo systemctl enable --now clickhouse-server

clickhouse-client --query "SELECT version()"

echo
echo "ClickHouse $CH_VERSION installed."
echo "  TCP:  localhost:9000"
echo "  HTTP: localhost:8123"
echo
echo "Stop with:  sudo systemctl stop clickhouse-server"
echo "Start with: sudo systemctl start clickhouse-server"
