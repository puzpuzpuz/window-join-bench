#!/usr/bin/env bash
# bench_clickhouse_window.sh - ClickHouse window-function over UNION ALL.
# Closest structural analog to a true WINDOW JOIN: tag trades and prices into
# a single stream, run a windowed avg over (sym, ts) on the unioned stream,
# keep only the trade rows. ClickHouse window functions require numeric range
# offsets, so timestamps are pre-converted to microseconds.
set -euo pipefail

TIMES_FILE="${TIMES_FILE:-ch.times.window}"
RUNS="${RUNS:-3}"
TIMEOUT_S="${TIMEOUT_S:-1800}"
DATA_DIR="${DATA_DIR:-/tmp}"
N_TRADES="${N_TRADES:-50000000}"
N_PRICES="${N_PRICES:-150000000}"
rm -f "$TIMES_FILE"

# ---- schema + load (idempotent) ----
trades=$(clickhouse-client --query "SELECT count() FROM trades" 2>/dev/null || echo 0)
prices=$(clickhouse-client --query "SELECT count() FROM prices" 2>/dev/null || echo 0)

if [ "$trades" != "$N_TRADES" ] || [ "$prices" != "$N_PRICES" ]; then
  echo "[setup] creating tables"
  clickhouse-client --multiquery --query "
    DROP TABLE IF EXISTS trades;
    DROP TABLE IF EXISTS prices;
    CREATE TABLE trades (
        symbol LowCardinality(String),
        side   LowCardinality(String),
        price  Float64,
        amount Float64,
        ts     DateTime64(6)
    ) ENGINE = MergeTree ORDER BY (symbol, ts);
    CREATE TABLE prices (
        ts  DateTime64(6),
        sym LowCardinality(String),
        bid Float64,
        ask Float64
    ) ENGINE = MergeTree ORDER BY (sym, ts);"

  # Atomic CSV generation
  [ -s "$DATA_DIR/trades.csv" ] || \
    { python3 ./generate_csv.py trades "$N_TRADES" > "$DATA_DIR/trades.csv.tmp" \
      && mv "$DATA_DIR/trades.csv.tmp" "$DATA_DIR/trades.csv"; }
  [ -s "$DATA_DIR/prices.csv" ] || \
    { python3 ./generate_csv.py prices "$N_PRICES" > "$DATA_DIR/prices.csv.tmp" \
      && mv "$DATA_DIR/prices.csv.tmp" "$DATA_DIR/prices.csv"; }

  echo "[load] inserting CSVs (5-15 min)"
  # date_time_input_format=best_effort needed for the +00:00 TZ suffix our
  # CSV emits; ClickHouse's default DateTime64 parser rejects it otherwise.
  clickhouse-client --date_time_input_format=best_effort \
    --query "INSERT INTO trades FORMAT CSV" < "$DATA_DIR/trades.csv"
  clickhouse-client --date_time_input_format=best_effort \
    --query "INSERT INTO prices FORMAT CSV" < "$DATA_DIR/prices.csv"
else
  echo "[load] tables already populated ($trades + $prices rows), skipping"
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
