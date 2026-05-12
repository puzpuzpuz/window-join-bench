#!/usr/bin/env bash
# install_timescale.sh - install PostgreSQL 17 + latest TimescaleDB on
# Ubuntu 24.04 from the official apt repositories, configure for the bench,
# and set the postgres password.
#
# Pins the TimescaleDB binary version to whatever the loader package wants -
# packagecloud sometimes ships a newer loader than binary which causes
# "extension has no installation script" errors on CREATE EXTENSION.
#
# Idempotent: re-runs are harmless.
set -euo pipefail

PG_MAJOR="${PG_MAJOR:-17}"
PG_PORT="${PG_PORT:-5433}"   # PGDG cluster lands on 5433 when system PG exists
PGPASSWORD_BENCH="${PGPASSWORD_BENCH:-bench}"

if ! command -v sudo >/dev/null; then
  echo "this script uses sudo; run as a user with sudo rights" >&2
  exit 1
fi

sudo apt-get update
sudo apt-get install -y gnupg postgresql-common apt-transport-https \
  lsb-release wget curl

# PostgreSQL apt repo (PGDG)
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

# Timescale apt repo (packagecloud.io/timescale/timescaledb)
curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/timescaledb-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/timescaledb-archive-keyring.gpg] https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -c -s) main" \
  | sudo tee /etc/apt/sources.list.d/timescaledb.list >/dev/null

sudo apt-get update

# Install PostgreSQL first, then both Timescale packages without version
# pinning so apt resolves to a matching pair. Pinning only one of the two
# (loader vs extension) leads to a version mismatch where
# `CREATE EXTENSION timescaledb;` fails with "no installation script".
sudo apt-get install -y \
  "postgresql-${PG_MAJOR}" \
  "postgresql-client-${PG_MAJOR}"

sudo apt-get install -y --allow-downgrades \
  "timescaledb-2-loader-postgresql-${PG_MAJOR}" \
  "timescaledb-2-postgresql-${PG_MAJOR}"

# timescaledb-tune appends the shared_preload_libraries config and applies
# sensible memory tuning for the host.
sudo timescaledb-tune --yes --quiet --pg-version "$PG_MAJOR"

sudo systemctl enable --now postgresql
sudo systemctl restart "postgresql@${PG_MAJOR}-main"

# Wait for the cluster to accept connections.
for _ in $(seq 1 30); do
  sudo -u postgres psql --cluster "${PG_MAJOR}/main" -c 'SELECT 1' >/dev/null 2>&1 && break
  sleep 1
done

# Set a password on the postgres role so the bench scripts can connect
# over TCP (peer auth alone would force them through sudo).
sudo -u postgres psql --cluster "${PG_MAJOR}/main" \
  -c "ALTER USER postgres WITH PASSWORD '${PGPASSWORD_BENCH}';"

# Confirm the extension is installable.
sudo -u postgres psql --cluster "${PG_MAJOR}/main" \
  -c "SELECT default_version FROM pg_available_extensions WHERE name='timescaledb';"

echo
echo "PostgreSQL ${PG_MAJOR} + TimescaleDB installed."
echo "  port:          ${PG_PORT} (PGDG cluster, separate from system PG on 5432 if any)"
echo "  superuser:     postgres / ${PGPASSWORD_BENCH}"
echo "  bench script:  PGPASSWORD=${PGPASSWORD_BENCH} ./bench_timescale.sh"
echo
echo "Stop with:  sudo systemctl stop postgresql@${PG_MAJOR}-main"
echo "Start with: sudo systemctl start postgresql@${PG_MAJOR}-main"
