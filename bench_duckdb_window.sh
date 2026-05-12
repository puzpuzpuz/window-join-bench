#!/usr/bin/env bash
# bench_duckdb_window.sh - DuckDB window-function over UNION ALL.
# Closest structural analog to a true WINDOW JOIN: tag trades and prices into
# a single stream, run a windowed avg over (sym, ts), keep trade rows only.
#
# Assumes bench_duckdb.sh has already loaded the database (same DB_FILE).
set -euo pipefail

DB_FILE="${DB_FILE:-bench.duckdb}"
TIMES_FILE="${TIMES_FILE:-duck.times.window}"
RUNS="${RUNS:-3}"
TIMEOUT_S="${TIMEOUT_S:-1800}"
N_TRADES="${N_TRADES:-50000000}"
N_PRICES="${N_PRICES:-150000000}"
rm -f "$TIMES_FILE"

# Verify the data is loaded.
trades=$(duckdb "$DB_FILE" -c "SELECT count(*) FROM trades" -noheader -list 2>/dev/null | tail -1 || echo 0)
prices=$(duckdb "$DB_FILE" -c "SELECT count(*) FROM prices" -noheader -list 2>/dev/null | tail -1 || echo 0)
if [ "$trades" != "$N_TRADES" ] || [ "$prices" != "$N_PRICES" ]; then
  echo "Data not loaded ($trades + $prices). Run bench_duckdb.sh first." >&2
  exit 1
fi

# Window function over UNION ALL. DuckDB accepts INTERVAL offsets in RANGE
# BETWEEN directly (no microsecond cast needed, unlike ClickHouse).
read -r -d '' QUERY <<'SQL' || true
WITH stream AS (
  SELECT ts, sym, bid, ask, FALSE AS is_trade FROM prices
  UNION ALL
  SELECT ts, symbol AS sym, NULL::DOUBLE AS bid, NULL::DOUBLE AS ask, TRUE FROM trades
)
SELECT ts, sym AS symbol, avg_bid, avg_ask FROM (
  SELECT ts, sym, is_trade,
         avg(bid) OVER w AS avg_bid,
         avg(ask) OVER w AS avg_ask
  FROM stream
  WINDOW w AS (
    PARTITION BY sym
    ORDER BY ts
    RANGE BETWEEN INTERVAL 1 SECOND PRECEDING AND INTERVAL 1 SECOND FOLLOWING
  )
) sub
WHERE is_trade
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
echo "=== DuckDB (window function over UNION ALL) ==="
echo "best wall time: $(grep -E '^[0-9]+\.[0-9]+' "$TIMES_FILE" | sort -n | head -1 || echo DNF)"
