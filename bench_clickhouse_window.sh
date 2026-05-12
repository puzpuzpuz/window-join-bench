#!/usr/bin/env bash
# bench_clickhouse_window.sh - ClickHouse window-function over UNION ALL.
# Closest structural analog to a true WINDOW JOIN: tag trades and prices into
# a single stream, run a windowed avg over (sym, ts) on the unioned stream,
# keep only the trade rows. ClickHouse window functions require numeric range
# offsets, so timestamps are pre-converted to microseconds.
#
# Assumes bench_clickhouse.sh has already loaded the data (same tables).
set -euo pipefail

TIMES_FILE="${TIMES_FILE:-ch.times.window}"
RUNS="${RUNS:-3}"
TIMEOUT_S="${TIMEOUT_S:-1800}"
N_TRADES="${N_TRADES:-50000000}"
N_PRICES="${N_PRICES:-150000000}"
rm -f "$TIMES_FILE"

# Verify the data is loaded.
trades=$(clickhouse-client --query "SELECT count() FROM trades" 2>/dev/null || echo 0)
prices=$(clickhouse-client --query "SELECT count() FROM prices" 2>/dev/null || echo 0)
if [ "$trades" != "$N_TRADES" ] || [ "$prices" != "$N_PRICES" ]; then
  echo "Data not loaded ($trades + $prices). Run bench_clickhouse.sh first." >&2
  exit 1
fi

# Window function over UNION ALL. Trades come in with NULL bid/ask so
# avg() ignores them; the window only averages real prices. EXCLUDE PREVAILING
# semantics are implicit because the [-1s, +1s] window has no row before its
# lower bound to include anyway.
read -r -d '' QUERY <<'SQL' || true
WITH stream AS (
  SELECT toUnixTimestamp64Micro(ts) AS ts_us, sym, bid, ask, 0 AS is_trade
  FROM prices
  UNION ALL
  SELECT toUnixTimestamp64Micro(ts) AS ts_us, symbol AS sym,
         CAST(NULL AS Nullable(Float64)) AS bid,
         CAST(NULL AS Nullable(Float64)) AS ask,
         1 AS is_trade
  FROM trades
)
SELECT ts_us, sym AS symbol, avg_bid, avg_ask FROM (
  SELECT ts_us, sym, is_trade,
         avg(bid) OVER w AS avg_bid,
         avg(ask) OVER w AS avg_ask
  FROM stream
  WINDOW w AS (
    PARTITION BY sym
    ORDER BY ts_us
    RANGE BETWEEN 1000000 PRECEDING AND 1000000 FOLLOWING
  )
)
WHERE is_trade = 1
ORDER BY (avg_bid + avg_ask) DESC
LIMIT 10
SQL

echo "[run] $RUNS runs, ${TIMEOUT_S}s cap each"
for i in $(seq 1 "$RUNS"); do
  echo "  run $i / $RUNS"
  if timeout "$TIMEOUT_S" /usr/bin/time -f "%e" \
      clickhouse-client --query "$QUERY" > /dev/null 2>> "$TIMES_FILE"; then
    :
  else
    echo "DNF" >> "$TIMES_FILE"
    break
  fi
done

echo
echo "=== ClickHouse (window function over UNION ALL) ==="
echo "best wall time: $(grep -E '^[0-9]+\.[0-9]+' "$TIMES_FILE" | sort -n | head -1 || echo DNF)"
