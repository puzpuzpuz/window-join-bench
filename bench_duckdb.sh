#!/usr/bin/env bash
# bench_duckdb.sh - DuckDB, range join + GROUP BY.
# Idempotent: skips schema/load if the database file exists with expected
# row counts. Run bench_duckdb_window.sh for the window-function rewrite.
set -euo pipefail

DB_FILE="${DB_FILE:-bench.duckdb}"
TIMES_FILE="${TIMES_FILE:-duck.times.rangejoin}"
RUNS="${RUNS:-3}"
TIMEOUT_S="${TIMEOUT_S:-1800}"
DATA_DIR="${DATA_DIR:-/tmp}"
N_TRADES="${N_TRADES:-50000000}"
N_PRICES="${N_PRICES:-150000000}"

rm -f "$TIMES_FILE"

# ---- schema + load (idempotent) ----
trades=$(duckdb "$DB_FILE" -c "SELECT count(*) FROM trades" -noheader -list 2>/dev/null | tail -1 || echo 0)
prices=$(duckdb "$DB_FILE" -c "SELECT count(*) FROM prices" -noheader -list 2>/dev/null | tail -1 || echo 0)

if [ "$trades" != "$N_TRADES" ] || [ "$prices" != "$N_PRICES" ]; then
  echo "[setup] (re)creating $DB_FILE"
  rm -f "$DB_FILE"

  [ -s "$DATA_DIR/trades.csv" ] || \
    { python3 ./generate_csv.py trades "$N_TRADES" > "$DATA_DIR/trades.csv.tmp" \
      && mv "$DATA_DIR/trades.csv.tmp" "$DATA_DIR/trades.csv"; }
  [ -s "$DATA_DIR/prices.csv" ] || \
    { python3 ./generate_csv.py prices "$N_PRICES" > "$DATA_DIR/prices.csv.tmp" \
      && mv "$DATA_DIR/prices.csv.tmp" "$DATA_DIR/prices.csv"; }

  echo "[load] copying CSVs into DuckDB (2-5 min)"
  duckdb "$DB_FILE" <<SQL
CREATE TABLE trades (
    symbol VARCHAR, side VARCHAR,
    price  DOUBLE, amount DOUBLE,
    ts     TIMESTAMP
);
CREATE TABLE prices (
    ts  TIMESTAMP, sym VARCHAR,
    bid DOUBLE, ask DOUBLE
);
COPY trades FROM '$DATA_DIR/trades.csv' (FORMAT csv);
COPY prices FROM '$DATA_DIR/prices.csv' (FORMAT csv);
SQL
else
  echo "[load] tables already populated ($trades + $prices rows), skipping"
fi

# Range join + GROUP BY. DuckDB plans this as a range join with per-row index
# probing, then a parallel hash aggregate.
read -r -d '' QUERY <<'SQL' || true
SELECT ts, symbol, avg_bid, avg_ask FROM (
  SELECT t.symbol, t.side, t.price, t.amount, t.ts,
         avg(p.bid) AS avg_bid, avg(p.ask) AS avg_ask
  FROM trades t
  LEFT JOIN prices p
    ON  p.sym = t.symbol
    AND p.ts >= t.ts - INTERVAL 1 SECOND
    AND p.ts <  t.ts + INTERVAL 1 SECOND
  GROUP BY t.symbol, t.side, t.price, t.amount, t.ts
) sub
ORDER BY (avg_bid + avg_ask) DESC NULLS LAST
LIMIT 10;
SQL

echo "[run] $RUNS runs, ${TIMEOUT_S}s cap each"
for i in $(seq 1 "$RUNS"); do
  echo "  run $i / $RUNS"
  if timeout "$TIMEOUT_S" /usr/bin/time -f "%e" duckdb "$DB_FILE" -c "$QUERY" \
      > /dev/null 2>> "$TIMES_FILE"; then
    :
  else
    echo "DNF" >> "$TIMES_FILE"
    break
  fi
done

echo
echo "=== DuckDB (range JOIN + GROUP BY) ==="
echo "best wall time: $(grep -E '^[0-9]+\.[0-9]+' "$TIMES_FILE" | sort -n | head -1 || echo DNF)"
