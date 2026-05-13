#!/usr/bin/env bash
# bench_questdb.sh - QuestDB native WINDOW JOIN, both parallel and serial.
# Captures the two QuestDB rows of the comparison table in one run.
set -euo pipefail

PGURL="${PGURL:-postgres://admin:quest@localhost:8812/qdb}"
RUNS_PARALLEL="${RUNS_PARALLEL:-5}"
RUNS_SERIAL="${RUNS_SERIAL:-3}"
TIMEOUT_S="${TIMEOUT_S:-1800}"   # 30-min DNF cap per query

# QuestDB install dir (used to flip the parallel WINDOW JOIN switch via conf).
# Set QDB_HOME to the dir created by install_questdb.sh.
QDB_HOME="${QDB_HOME:-$HOME/questdb-9.3.5}"
QDB_DATA="${QDB_DATA:-$QDB_HOME/.questdb}"
QDB_CONF="$QDB_DATA/conf/server.conf"
QDB_LAUNCHER="$QDB_HOME/bin/questdb.sh"

TIMES_PARALLEL="${TIMES_PARALLEL:-qdb.times.parallel}"
TIMES_SERIAL="${TIMES_SERIAL:-qdb.times.serial}"
rm -f "$TIMES_PARALLEL" "$TIMES_SERIAL"

# ---- data load (idempotent: skip if both tables already at expected size) ----
need_load=1
existing_trades=$(psql "$PGURL" -tAc "SELECT count(*) FROM trades;" 2>/dev/null || echo 0)
existing_prices=$(psql "$PGURL" -tAc "SELECT count(*) FROM prices;" 2>/dev/null || echo 0)
if [ "$existing_trades" = "50000001" ] && [ "$existing_prices" = "150000000" ]; then
  echo "[load] tables already populated, skipping"
  need_load=0
fi

if [ "$need_load" = "1" ]; then
  echo "[load] creating tables + generating data (5-10 min)"
  psql "$PGURL" -c "DROP TABLE IF EXISTS trades;"
  psql "$PGURL" -c "DROP TABLE IF EXISTS prices;"
  psql "$PGURL" <<'SQL'
CREATE TABLE trades (
    symbol SYMBOL CAPACITY 2048 CACHE,
    side   SYMBOL CAPACITY 4 CACHE,
    price  DOUBLE,
    amount DOUBLE,
    timestamp TIMESTAMP
) timestamp(timestamp) PARTITION BY DAY WAL;

-- 50M trades over 1 day (10x scaled down from blog headline)
INSERT INTO trades
SELECT rnd_symbol_zipf(1000, 2.0),
       rnd_symbol('buy', 'sell'),
       rnd_double() * 20 + 10,
       rnd_double() * 20 + 10,
       generate_series
FROM generate_series('2025-01-01', '2025-01-02', '1728u');

CREATE TABLE prices (
    ts  TIMESTAMP,
    sym SYMBOL CAPACITY 1024,
    bid DOUBLE,
    ask DOUBLE
) timestamp(ts) PARTITION BY DAY;

INSERT INTO prices
SELECT '2024-12-31T23'::timestamp + (600 * x) + rnd_long(-20, 20, 0),
       rnd_symbol_zipf(1000, 2.0),
       rnd_double() * 10 + 5,
       rnd_double() * 10 + 5
FROM long_sequence(150000000);
SQL
fi

# The benchmarked query: WINDOW JOIN wrapped in a top-10 over avg_bid+avg_ask.
# The outer top-N forces every join output row to be considered, but only 10
# small rows go to the client - isolates engine cost from protocol cost.
read -r -d '' QUERY <<'SQL' || true
SELECT ts, symbol, avg_bid, avg_ask FROM (
  SELECT t.timestamp ts, t.symbol,
         avg(p.bid) avg_bid, avg(p.ask) avg_ask
  FROM trades t
  WINDOW JOIN prices p
    ON p.sym = t.symbol
    RANGE BETWEEN 1 second PRECEDING AND 1 second FOLLOWING
    EXCLUDE PREVAILING
)
ORDER BY avg_bid + avg_ask DESC
LIMIT 10;
SQL

run_once() {
  local label="$1" out_file="$2" runs="$3"
  echo "[$label] $runs runs, ${TIMEOUT_S}s cap each"
  for i in $(seq 1 "$runs"); do
    echo "  run $i / $runs"
    if timeout "$TIMEOUT_S" /usr/bin/time -f "%e" psql "$PGURL" \
        -c "$QUERY" -o /dev/null 2>> "$out_file"; then
      :
    else
      echo "DNF" >> "$out_file"
      break  # if one run hits the cap, the rest will too
    fi
  done
  echo "  best: $(grep -E '^[0-9]+\.[0-9]+' "$out_file" | sort -n | head -1 || echo DNF)"
}

# ---- parallel (default) ----
run_once "parallel + AVX2" "$TIMES_PARALLEL" "$RUNS_PARALLEL"

# ---- serial: edit conf, restart, run, restore ----
if [ -f "$QDB_CONF" ] && [ -x "$QDB_LAUNCHER" ]; then
  echo "[serial] toggling cairo.sql.parallel.window.join.enabled=false + query.timeout=30m"
  cp "$QDB_CONF" "$QDB_CONF.bak"
  sed -i -E \
    -e 's/^#?cairo\.sql\.parallel\.window\.join\.enabled=.*/cairo.sql.parallel.window.join.enabled=false/' \
    -e 's/^query\.timeout=.*/query.timeout=30m/' \
    "$QDB_CONF"
  "$QDB_LAUNCHER" stop  -d "$QDB_DATA" >/dev/null 2>&1 || true
  sleep 2
  "$QDB_LAUNCHER" start -d "$QDB_DATA" >/dev/null 2>&1
  # wait for PG wire to come back
  for _ in $(seq 1 30); do
    psql "$PGURL" -c "SELECT 1" -o /dev/null 2>/dev/null && break
    sleep 1
  done

  run_once "serial + AVX2" "$TIMES_SERIAL" "$RUNS_SERIAL"

  echo "[serial] restoring conf"
  mv "$QDB_CONF.bak" "$QDB_CONF"
  "$QDB_LAUNCHER" stop  -d "$QDB_DATA" >/dev/null 2>&1
  sleep 2
  "$QDB_LAUNCHER" start -d "$QDB_DATA" >/dev/null 2>&1
else
  echo "[serial] skipped - set QDB_HOME to the install dir to enable" >&2
fi

echo
echo "=== best wall times (seconds) ==="
echo "parallel + AVX2 : $(grep -E '^[0-9]+\.[0-9]+' "$TIMES_PARALLEL" | sort -n | head -1 || echo DNF)"
echo "serial   + AVX2 : $(grep -E '^[0-9]+\.[0-9]+' "$TIMES_SERIAL"   | sort -n | head -1 || echo DNF)"
