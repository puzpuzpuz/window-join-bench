# WINDOW JOIN benchmark

Companion scripts for the blog post on parallel + vectorized WINDOW JOIN
([window-join-parallel-vectorized](https://questdb.com/blog/window-join-parallel-vectorized/)).
The same workload is run against QuestDB, TimescaleDB, DuckDB, and
ClickHouse, with each engine getting the closest-equivalent rewrite of
the canonical WINDOW JOIN query.

## Workload

- **`trades`**: 50,000,000 rows over one day. 1000 zipfian-distributed
  symbols (`rnd_symbol_zipf(1_000, 2.0)`), one row every 1728 microseconds.
- **`prices`**: 150,000,000 rows over ~25 hours. 1000 zipfian-distributed
  symbols, one row every 600 microseconds plus jitter.
- **Query**: top 10 trades by combined surrounding `avg_bid + avg_ask`,
  where each trade's `avg` / `min` / `max` of `bid` and `ask` are
  computed over the 2-second window centered on the trade timestamp,
  restricted to the trade's symbol. The outer top-10 forces every join
  output row to be considered but ships only 10 small rows to the
  client.

  ```sql
  SELECT ts, symbol,
         avg_bid, min_bid, max_bid,
         avg_ask, min_ask, max_ask
  FROM (
    SELECT t.timestamp ts, t.symbol,
           avg(p.bid) avg_bid, min(p.bid) min_bid, max(p.bid) max_bid,
           avg(p.ask) avg_ask, min(p.ask) min_ask, max(p.ask) max_ask
    FROM trades t
    WINDOW JOIN prices p
      ON p.sym = t.symbol
      RANGE BETWEEN 1 second PRECEDING AND 1 second FOLLOWING
      EXCLUDE PREVAILING
  )
  ORDER BY avg_bid + avg_ask DESC
  LIMIT 10;
  ```

The other three engines do not have a direct WINDOW JOIN equivalent;
each `bench_*.sh` spells the closest semantically equivalent query
for that engine, wrapped in the same outer ORDER BY / LIMIT 10. All
rewrites have been verified bit-exact against QuestDB (within 1e-9
FP tolerance) on a parity-scale subset.

## Hardware (this run)

- AMD Ryzen 9 7900 (12 cores / 24 threads), 61 GiB RAM, NVMe SSD
- Ubuntu 24.04

This is a workstation-class repro - the scale is sized to fit in RAM on
this box.

## Engine versions

| Engine     | Version |
| ---------- | ------- |
| QuestDB    | 9.3.5   |
| TimescaleDB | 2.26.x on PostgreSQL 17 |
| DuckDB     | 1.5.2   |
| ClickHouse | 26.4    |

## Methodology

- Each script creates the schema if missing, loads data if missing,
  then runs the query 3-5 times with a 30-minute cap per run.
- Best wall time is printed at the end. Runs that hit the cap are
  recorded as `DNF`; if one run hits the cap we don't waste time on
  subsequent runs.
- The outer `ORDER BY ... LIMIT 10` is what isolates engine cost from
  client/protocol cost - the engine must consider every join output
  row, but only 10 small rows are returned.
- Default engine configurations except where the script header notes a
  specific tuning needed to keep the plan competitive (`timescaledb-tune`,
  ClickHouse `MergeTree ORDER BY`, etc.).

## Scripts

### Install / start each engine

The install scripts target Ubuntu 24.04 and pin the versions listed
above. They are idempotent; rerunning is harmless. The TimescaleDB and
ClickHouse installers need `sudo`.

- [`install_questdb.sh`](install_questdb.sh) - downloads the official
  Linux x86-64 tarball with the bundled OpenJDK runtime, unpacks it under
  `$HOME/questdb-<version>`, and starts the server. No `sudo` needed.
- [`install_timescale.sh`](install_timescale.sh) - adds the PGDG and
  Timescale apt repos, installs PostgreSQL 17 + TimescaleDB (loader +
  binary in matching versions), runs `timescaledb-tune`, sets a password
  on the `postgres` role (default `bench`) and enables the systemd unit.
- [`install_duckdb.sh`](install_duckdb.sh) - drops the DuckDB CLI binary
  into `$HOME/.local/bin`. No server. No `sudo` needed.
- [`install_clickhouse.sh`](install_clickhouse.sh) - adds the official
  ClickHouse apt repo, installs server + client at the pinned version,
  enables the systemd unit.

### Run the benchmark

One script per row of the comparison table.

- [`bench_questdb.sh`](bench_questdb.sh) - native `WINDOW JOIN`. Runs
  both the parallel and single-threaded configurations in one go,
  toggling `cairo.sql.parallel.window.join.enabled` in `server.conf`
  between phases and restoring it at the end. Requires `QDB_HOME` to
  point at the install dir.
- [`bench_timescale.sh`](bench_timescale.sh) - range-join + GROUP BY
  rewrite with all parallel knobs forced. Sets up the database,
  hypertables, and a `(sym, ts DESC)` index. The lateral-subquery
  alternative was dropped: at parity scale it was an order of magnitude
  slower than the range-join + parallel-hash-aggregate plan, and at
  full scale both rewrites DNF.
- [`bench_clickhouse.sh`](bench_clickhouse.sh) - window
  function over a `UNION ALL` of trades and prices. Trade rows carry
  NULL `bid`/`ask`, so when the window contains no in-window price the
  aggregates are NULL - matching QuestDB's `EXCLUDE PREVAILING`. Loads
  its own data into a `MergeTree ORDER BY (sym, ts)` table; CSV ingest
  uses `--date_time_input_format=best_effort` because the CSV has
  ISO-8601 timestamps with a `+00:00` suffix.
- [`bench_duckdb.sh`](bench_duckdb.sh) - same window
  function over `UNION ALL` rewrite, ported to DuckDB. Loads its own
  data into a self-contained `.duckdb` file.
- [`generate_csv.py`](generate_csv.py) - shared CSV generator that
  mimics QuestDB's zipfian symbol distribution. Used by all non-QuestDB
  loaders. The QuestDB script generates data in-database via
  `generate_series` / `long_sequence`.

We previously tried `ASOF JOIN` cumulative-diff rewrites for DuckDB and
ClickHouse (per-symbol prefix sums + two `ASOF LEFT JOIN`s bracketing
each trade's window). They are dramatically faster than the window
function rewrite *for `avg` alone*, because `sum` and `count` are
prefix-sum-decomposable. They cannot handle `min` / `max`, so the
window function rewrite is the only semantically correct shape once
those aggregates are in the query.

## Reproducing end-to-end

```sh
# One-time install (Ubuntu 24.04)
./install_questdb.sh
./install_timescale.sh     # needs sudo, sets postgres password to "bench"
./install_duckdb.sh
./install_clickhouse.sh    # needs sudo

# QuestDB (both rows of the table)
QDB_HOME=$HOME/questdb-9.3.5 ./bench_questdb.sh

# Timescale (range-join + GROUP BY rewrite)
PGPASSWORD=bench ./bench_timescale.sh

# DuckDB (window over UNION ALL)
export PATH="$HOME/.local/bin:$PATH"
./bench_duckdb.sh

# ClickHouse (window over UNION ALL)
./bench_clickhouse.sh
```

Each script writes per-run timings to a `*.times.<rewrite>` file and
prints the best to stdout.

## Knobs

All `bench_*.sh` scripts honour the following env vars:

| Var          | Default | Effect |
| ------------ | ------- | ------ |
| `RUNS`       | 3 (5 for QuestDB parallel) | Number of timed runs |
| `TIMEOUT_S`  | 1800 (30 min) | Per-run cap; first DNF aborts the loop |
| `N_TRADES`   | 50000000  | Trades row count |
| `N_PRICES`   | 150000000 | Prices row count |
| `DATA_DIR`   | /tmp      | Where the shared CSVs live |
| `TIMES_FILE` | per-script default | Where to write per-run wall times |

QuestDB-specific:

| Var          | Default | Effect |
| ------------ | ------- | ------ |
| `PGURL`      | `postgres://admin:quest@localhost:8812/qdb` | psql connection string |
| `QDB_HOME`   | `$HOME/questdb-9.3.5` | Install dir (for the conf toggle) |
| `RUNS_PARALLEL` / `RUNS_SERIAL` | 5 / 3 | Per-mode run counts |

PostgreSQL/Timescale-specific:

| Var | Default | Effect |
| --- | ------- | ------ |
| `PGHOST` / `PGPORT` / `PGUSER` | `localhost` / `5433` / `postgres` | libpq connection |
| `PGPASSWORD` | (required) | Set to the password from `install_timescale.sh` |
| `DB` | `bench` | Database name |

DuckDB-specific (`bench_duckdb.sh`):

| Var | Default | Effect |
| --- | ------- | ------ |
| `DB_FILE` | `bench.duckdb` | DuckDB database file |
| `MEMORY_LIMIT` | `50GB` | Per-query memory budget passed via `SET memory_limit` |
| `DUCKDB_TEMP_DIR` | `$DATA_DIR/duck_tmp` | Spill directory passed via `SET temp_directory`; point at a fast disk |
