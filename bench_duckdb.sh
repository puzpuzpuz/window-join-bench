#!/usr/bin/env bash
# bench_duckdb.sh - DuckDB window-function-over-UNION-ALL rewrite.
# Tags trades and prices into a single per-symbol stream, runs the windowed
# aggregates (avg/min/max for bid and ask) partitioned by sym and ordered by
# ts, then keeps only the trade rows. This is the closest structural analog
# to QuestDB's WINDOW JOIN that DuckDB can express; the ASOF cumulative-diff
# trick used previously does not cover min/max, since those aggregates are
# not prefix-sum-decomposable.
#
# EXCLUDE PREVAILING semantics: trade rows have NULL bid/ask in the stream,
# so when no in-window price exists, the windowed aggregates over NULLs
# evaluate to NULL - matching QuestDB's EXCLUDE PREVAILING output.
set -euo pipefail

DB_FILE="${DB_FILE:-bench.duckdb}"
TIMES_FILE="${TIMES_FILE:-duck.times.window}"
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

# Window function over UNION ALL. DuckDB accepts INTERVAL range offsets
# directly, so no microsecond cast is needed.
read -r -d '' QUERY <<SQL || true
SET memory_limit = '$MEMORY_LIMIT';
SET temp_directory = '$DUCKDB_TEMP_DIR';
WITH stream AS (
  SELECT ts, sym, bid, ask, FALSE AS is_trade FROM prices
  UNION ALL
  SELECT ts, symbol AS sym,
         NULL::DOUBLE AS bid, NULL::DOUBLE AS ask, TRUE
  FROM trades
)
SELECT ts, symbol,
       avg_bid, min_bid, max_bid,
       avg_ask, min_ask, max_ask
FROM (
  SELECT ts, sym AS symbol, is_trade,
         avg(bid) OVER w AS avg_bid,
         min(bid) OVER w AS min_bid,
         max(bid) OVER w AS max_bid,
         avg(ask) OVER w AS avg_ask,
         min(ask) OVER w AS min_ask,
         max(ask) OVER w AS max_ask
  FROM stream
  WINDOW w AS (
    PARTITION BY sym
    ORDER BY ts
    RANGE BETWEEN INTERVAL 1 SECOND PRECEDING AND INTERVAL 1 SECOND FOLLOWING
  )
) sub
WHERE is_trade
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
echo "=== DuckDB (window function over UNION ALL) ==="
echo "best wall time: $(grep -E '^[0-9]+\.[0-9]+' "$TIMES_FILE" | sort -n | head -1 || echo DNF)"
