#!/usr/bin/env bash
# bench_clickhouse.sh - ClickHouse window-function-over-UNION-ALL rewrite.
# Tags trades and prices into a single per-symbol stream, runs the windowed
# aggregates (avg/min/max for bid and ask) partitioned by sym and ordered by
# ts, then keeps only the trade rows. This is the closest structural analog
# to QuestDB's WINDOW JOIN that ClickHouse can express; the ASOF
# cumulative-diff trick used previously does not cover min/max, since those
# aggregates are not prefix-sum-decomposable.
#
# EXCLUDE PREVAILING semantics: trade rows have NULL bid/ask in the stream,
# so when no in-window price exists, the windowed aggregates over NULLs
# evaluate to NULL - matching QuestDB's EXCLUDE PREVAILING output.
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

# Window function over UNION ALL. Timestamps pre-converted to microseconds
# because ClickHouse window RANGE offsets require numeric values.
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
SELECT ts_us, symbol,
       avg_bid, min_bid, max_bid,
       avg_ask, min_ask, max_ask
FROM (
  SELECT ts_us, sym AS symbol, is_trade,
         avg(bid) OVER w AS avg_bid,
         min(bid) OVER w AS min_bid,
         max(bid) OVER w AS max_bid,
         avg(ask) OVER w AS avg_ask,
         min(ask) OVER w AS min_ask,
         max(ask) OVER w AS max_ask
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
