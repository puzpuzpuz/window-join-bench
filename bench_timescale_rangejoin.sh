#!/usr/bin/env bash
# bench_timescale_rangejoin.sh - TimescaleDB range join + GROUP BY (parallel).
# Same shape as DuckDB/ClickHouse, with all parallel knobs forced. Note: the
# Postgres planner cost-estimates this plan as 10x more expensive than the
# lateral but the parallelism can dominate; in our measurements it spilled
# hundreds of GB to temp files and didn't finish inside 30 min.
#
# Assumes bench_timescale.sh has already loaded the data (same DB + tables).
set -euo pipefail

DB="${DB:-bench}"
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5433}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:?Set PGPASSWORD before running (e.g. PGPASSWORD=bench)}"
PGURL="postgres://$PGUSER@$PGHOST:$PGPORT/$DB"

RUNS="${RUNS:-3}"
TIMEOUT_S="${TIMEOUT_S:-1800}"
TIMES_FILE="${TIMES_FILE:-ts.times.rangejoin}"
rm -f "$TIMES_FILE"

# Verify the data is loaded by bench_timescale.sh.
trades=$(psql "$PGURL" -tAc "SELECT count(*) FROM trades;" 2>/dev/null || echo 0)
prices=$(psql "$PGURL" -tAc "SELECT count(*) FROM prices;" 2>/dev/null || echo 0)
if [ "$trades" -lt 1000000 ] || [ "$prices" -lt 1000000 ]; then
  echo "Data not loaded - run bench_timescale.sh first." >&2
  exit 1
fi

# Force parallelism + range-join + GROUP BY. PG's lateral nested loop is
# single-threaded by design; this rewrite tricks the planner into a Parallel
# Index Scan + Partial HashAggregate + Gather Merge + Finalize GroupAggregate.
read -r -d '' QUERY <<'SQL' || true
SET max_parallel_workers_per_gather = 12;
SET min_parallel_table_scan_size = '0';
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SELECT ts, symbol, avg_bid, avg_ask FROM (
  SELECT t.ts, t.symbol,
         avg(p.bid) AS avg_bid, avg(p.ask) AS avg_ask
  FROM trades t
  LEFT JOIN prices p
    ON p.sym = t.symbol
   AND p.ts >= t.ts - INTERVAL '1 second'
   AND p.ts <= t.ts + INTERVAL '1 second'
  GROUP BY t.ts, t.symbol
) sub
ORDER BY (avg_bid + avg_ask) DESC
LIMIT 10;
SQL

echo "[run] $RUNS runs, ${TIMEOUT_S}s cap each"
for i in $(seq 1 "$RUNS"); do
  echo "  run $i / $RUNS"
  if timeout "$TIMEOUT_S" /usr/bin/time -f "%e" psql "$PGURL" \
      -c "$QUERY" -o /dev/null 2>> "$TIMES_FILE"; then
    :
  else
    echo "DNF" >> "$TIMES_FILE"
    break
  fi
done

echo
echo "=== TimescaleDB (range join + GROUP BY, parallel) ==="
echo "best wall time: $(grep -E '^[0-9]+\.[0-9]+' "$TIMES_FILE" | sort -n | head -1 || echo DNF)"
