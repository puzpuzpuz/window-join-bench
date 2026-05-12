#!/usr/bin/env bash
# bench_duckdb_asof.sh - DuckDB ASOF cumulative-diff rewrite.
# Builds a per-symbol cumulative sum/count over prices, then uses two
# ASOF LEFT JOINs to look up the cumulative state at the window high
# boundary and just-before the low boundary; the per-trade aggregate is
# the difference. Matches WINDOW JOIN semantics exactly: both window
# bounds inclusive, EXCLUDE PREVAILING (when no in-window price exists,
# hi and lo land on the same row so cum-cum and n-n both go to zero,
# NULLIF turns the divide into NULL).
#
# Reuses the .duckdb file from bench_duckdb_window.sh if data is present.
set -euo pipefail

DB_FILE="${DB_FILE:-bench.duckdb}"
TIMES_FILE="${TIMES_FILE:-duck.times.asof}"
RUNS="${RUNS:-3}"
TIMEOUT_S="${TIMEOUT_S:-1800}"
DATA_DIR="${DATA_DIR:-/tmp}"
N_TRADES="${N_TRADES:-50000000}"
N_PRICES="${N_PRICES:-150000000}"
# DuckDB tuning. The default per-query memory budget is ~80% of RAM but the
# planner is conservative about engaging spill; setting these explicitly keeps
# the query in RAM at this scale and points spill at a fast NVMe if it does
# overflow. Override DUCKDB_TEMP_DIR to a fast disk for best results.
MEMORY_LIMIT="${MEMORY_LIMIT:-50GB}"
DUCKDB_TEMP_DIR="${DUCKDB_TEMP_DIR:-$DATA_DIR/duck_tmp}"
mkdir -p "$DUCKDB_TEMP_DIR"
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

# ASOF cumulative-diff: prefix-sums on prices, then two ASOF LEFT JOINs
# bracket each trade's [-1s, +1s] window. avg = (sum_hi - sum_lo) /
# (count_hi - count_lo); NULLIF turns a zero count diff into NULL,
# implementing EXCLUDE PREVAILING for trades with no in-window price.
read -r -d '' QUERY <<SQL || true
SET memory_limit = '$MEMORY_LIMIT';
SET temp_directory = '$DUCKDB_TEMP_DIR';
WITH price_cum AS (
  SELECT
    sym, ts,
    SUM(bid)   OVER w AS cum_bid,
    SUM(ask)   OVER w AS cum_ask,
    COUNT(bid) OVER w AS n_bid,
    COUNT(ask) OVER w AS n_ask
  FROM prices
  WINDOW w AS (PARTITION BY sym ORDER BY ts
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
)
SELECT ts, symbol, avg_bid, avg_ask FROM (
  SELECT t.ts AS ts, t.symbol AS symbol,
    (hi.cum_bid - COALESCE(lo.cum_bid, 0))
      / NULLIF(hi.n_bid - COALESCE(lo.n_bid, 0), 0) AS avg_bid,
    (hi.cum_ask - COALESCE(lo.cum_ask, 0))
      / NULLIF(hi.n_ask - COALESCE(lo.n_ask, 0), 0) AS avg_ask
  FROM trades t
  ASOF LEFT JOIN price_cum hi
    ON hi.sym = t.symbol AND hi.ts <= t.ts + INTERVAL 1 SECOND
  ASOF LEFT JOIN price_cum lo
    ON lo.sym = t.symbol AND lo.ts <  t.ts - INTERVAL 1 SECOND
)
ORDER BY (avg_bid + avg_ask) DESC
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
echo "=== DuckDB (ASOF cumulative-diff) ==="
echo "best wall time: $(grep -E '^[0-9]+\.[0-9]+' "$TIMES_FILE" | sort -n | head -1 || echo DNF)"
