#!/usr/bin/env bash
# bench_clickhouse.sh - ClickHouse, range join + GROUP BY on MergeTree.
# Idempotent: skips schema/load if both tables are already at the expected
# row counts. Run bench_clickhouse_window.sh for the window-function rewrite.
set -euo pipefail

TIMES_FILE="${TIMES_FILE:-ch.times.rangejoin}"
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

# Range join + GROUP BY. INNER JOIN on sym uses parallel_hash; the range
# predicate goes in WHERE. MergeTree ORDER BY (sym, ts) is essential.
read -r -d '' QUERY <<'SQL' || true
SELECT ts, symbol, avg_bid, avg_ask FROM (
  SELECT t.symbol, t.side, t.price, t.amount, t.ts,
         avg(p.bid) AS avg_bid, avg(p.ask) AS avg_ask
  FROM trades t
  INNER JOIN prices p
    ON p.sym = t.symbol
  WHERE p.ts >= t.ts - INTERVAL 1 SECOND
    AND p.ts <  t.ts + INTERVAL 1 SECOND
  GROUP BY t.symbol, t.side, t.price, t.amount, t.ts
) sub
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
echo "=== ClickHouse (range JOIN + GROUP BY) ==="
echo "best wall time: $(grep -E '^[0-9]+\.[0-9]+' "$TIMES_FILE" | sort -n | head -1 || echo DNF)"
