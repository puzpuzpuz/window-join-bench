#!/usr/bin/env bash
# bench_timescale.sh - TimescaleDB lateral-subquery plan (idiomatic).
# Captures one row of the comparison table. For the alternative range-join +
# GROUP BY plan, see bench_timescale_rangejoin.sh; both scripts share the
# same schema/data load so running this first leaves the data ready.
set -euo pipefail

DB="${DB:-bench}"
# libpq env vars - propagated to dropdb/createdb/psql.
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5433}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:?Set PGPASSWORD before running (e.g. PGPASSWORD=bench)}"
PGURL="postgres://$PGUSER@$PGHOST:$PGPORT/$DB"

RUNS="${RUNS:-3}"
TIMEOUT_S="${TIMEOUT_S:-1800}"
DATA_DIR="${DATA_DIR:-/tmp}"
N_TRADES="${N_TRADES:-50000000}"
N_PRICES="${N_PRICES:-150000000}"
TIMES_FILE="${TIMES_FILE:-ts.times.lateral}"
rm -f "$TIMES_FILE"

# ---- schema + data load (idempotent) ----
existing=$(psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB';" 2>/dev/null || echo "")
trades_count=0
prices_count=0
if [ "$existing" = "1" ]; then
  trades_count=$(psql "$PGURL" -tAc "SELECT count(*) FROM trades;" 2>/dev/null || echo 0)
  prices_count=$(psql "$PGURL" -tAc "SELECT count(*) FROM prices;" 2>/dev/null || echo 0)
fi

if [ "$trades_count" != "$N_TRADES" ] || [ "$prices_count" != "$N_PRICES" ]; then
  echo "[setup] (re)creating database $DB"
  dropdb --if-exists "$DB"
  createdb "$DB"

  psql "$PGURL" <<'SQL'
CREATE EXTENSION timescaledb;

CREATE TABLE trades (
    symbol text, side text,
    price  double precision, amount double precision,
    ts     timestamptz
);
SELECT create_hypertable('trades', 'ts',
                        chunk_time_interval => INTERVAL '1 day');

CREATE TABLE prices (
    ts  timestamptz, sym text,
    bid double precision, ask double precision
);
SELECT create_hypertable('prices', 'ts',
                        chunk_time_interval => INTERVAL '1 day');

-- Without this index the lateral collapses into a full chunk scan per trade.
CREATE INDEX ON prices (sym, ts DESC);
SQL

  # Atomic CSV generation: write to .tmp first, rename on success.
  [ -s "$DATA_DIR/trades.csv" ] || \
    { python3 ./generate_csv.py trades "$N_TRADES" > "$DATA_DIR/trades.csv.tmp" \
      && mv "$DATA_DIR/trades.csv.tmp" "$DATA_DIR/trades.csv"; }
  [ -s "$DATA_DIR/prices.csv" ] || \
    { python3 ./generate_csv.py prices "$N_PRICES" > "$DATA_DIR/prices.csv.tmp" \
      && mv "$DATA_DIR/prices.csv.tmp" "$DATA_DIR/prices.csv"; }

  echo "[load] copying CSVs into hypertables (10-30 min)"
  psql "$PGURL" -c "\copy trades FROM '$DATA_DIR/trades.csv' CSV"
  psql "$PGURL" -c "\copy prices FROM '$DATA_DIR/prices.csv' CSV"
  psql "$PGURL" -c "VACUUM ANALYZE;"
else
  echo "[load] tables already populated ($trades_count + $prices_count rows), skipping"
fi

# Lateral plan: per-trade index lookup into prices. Single-threaded inside
# the lateral RHS by design (PG cannot parallelize lateral subqueries).
read -r -d '' QUERY <<'SQL' || true
SELECT ts, symbol, avg_bid, avg_ask FROM (
  SELECT t.ts, t.symbol, w.avg_bid, w.avg_ask
  FROM trades t
  LEFT JOIN LATERAL (
    SELECT avg(bid) AS avg_bid, avg(ask) AS avg_ask
    FROM prices p
    WHERE p.sym  = t.symbol
      AND p.ts  >= t.ts - INTERVAL '1 second'
      AND p.ts  <= t.ts + INTERVAL '1 second'
  ) w ON true
) sub
ORDER BY (avg_bid + avg_ask) DESC
LIMIT 10;
SQL

echo "[run] $RUNS runs, ${TIMEOUT_S}s cap each"
for i in $(seq 1 "$RUNS"); do
  echo "  run $i / $RUNS"
  if timeout "$TIMEOUT_S" /usr/bin/time -f "%e" psql "$PGURL" \
      -c "$QUERY" -o /dev/null 2>> "$TIMES_FILE"; then
    :
  else
    echo "DNF" >> "$TIMES_FILE"
    break
  fi
done

echo
echo "=== TimescaleDB (lateral) ==="
echo "best wall time: $(grep -E '^[0-9]+\.[0-9]+' "$TIMES_FILE" | sort -n | head -1 || echo DNF)"
