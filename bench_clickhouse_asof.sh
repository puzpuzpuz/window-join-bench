#!/usr/bin/env bash
# bench_clickhouse_asof.sh - ClickHouse ASOF cumulative-diff rewrite.
# Builds a per-symbol cumulative sum/count over prices, then uses two
# ASOF LEFT JOINs to look up the cumulative state at the window high
# boundary and just-before the low boundary; the per-trade aggregate is
# the difference. Matches WINDOW JOIN semantics exactly: both window
# bounds inclusive, EXCLUDE PREVAILING (when no in-window price exists,
# hi and lo land on the same row so cum-cum and n-n both go to zero,
# nullIf turns the divide into NULL).
#
# ClickHouse ASOF JOIN uses `left_expr OP right_col` to pick the closest
# right row, so the inequalities are flipped relative to the DuckDB
# version: `hi.ts <= t.ts + 1s` becomes `(t.ts + 1s) >= hi.ts`, and
# `lo.ts < t.ts - 1s` becomes `(t.ts - 1s) > lo.ts`.
set -euo pipefail

TIMES_FILE="${TIMES_FILE:-ch.times.asof}"
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

# ASOF cumulative-diff: prefix-sums on prices, then two ASOF LEFT JOINs
# bracket each trade's [-1s, +1s] window. avg = (sum_hi - sum_lo) /
# (count_hi - count_lo); nullIf turns a zero count diff into NULL,
# implementing EXCLUDE PREVAILING for trades with no in-window price.
read -r -d '' QUERY <<'SQL' || true
WITH price_cum AS (
  SELECT
    sym,
    toUnixTimestamp64Micro(ts) AS ts_us,
    sum(bid)   OVER w AS cum_bid,
    sum(ask)   OVER w AS cum_ask,
    count(bid) OVER w AS n_bid,
    count(ask) OVER w AS n_ask
  FROM prices
  WINDOW w AS (PARTITION BY sym ORDER BY ts
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
)
SELECT ts_us, symbol, avg_bid, avg_ask FROM (
  SELECT
    toUnixTimestamp64Micro(t.ts) AS ts_us,
    t.symbol AS symbol,
    (hi.cum_bid - coalesce(lo.cum_bid, 0))
      / nullIf(hi.n_bid - coalesce(lo.n_bid, 0), 0) AS avg_bid,
    (hi.cum_ask - coalesce(lo.cum_ask, 0))
      / nullIf(hi.n_ask - coalesce(lo.n_ask, 0), 0) AS avg_ask
  FROM trades t
  ASOF LEFT JOIN price_cum hi
    ON hi.sym = t.symbol AND (toUnixTimestamp64Micro(t.ts) + 1000000) >= hi.ts_us
  ASOF LEFT JOIN price_cum lo
    ON lo.sym = t.symbol AND (toUnixTimestamp64Micro(t.ts) - 1000000) >  lo.ts_us
)
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
echo "=== ClickHouse (ASOF cumulative-diff) ==="
echo "best wall time: $(grep -E '^[0-9]+\.[0-9]+' "$TIMES_FILE" | sort -n | head -1 || echo DNF)"
