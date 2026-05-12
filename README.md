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
- **Query**: top 10 trades by combined surrounding bid+ask, where each
  trade's `avg_bid` / `avg_ask` are computed over the 2-second window
  centered on the trade timestamp, restricted to the trade's symbol.
  The outer top-10 forces every join output row to be considered but
  ships only 10 small rows to the client.

  ```sql
  SELECT ts, symbol, avg_bid, avg_ask FROM (
    SELECT t.timestamp ts, t.symbol,
           avg(p.bid) avg_bid, avg(p.ask) avg_ask
    FROM trades t
    WINDOW JOIN prices p
      ON p.sym = t.symbol
      RANGE BETWEEN '1' second PRECEDING AND '1' second FOLLOWING
      EXCLUDE PREVAILING
  )
  ORDER BY avg_bid + avg_ask DESC
  LIMIT 10;
  ```

The other three engines do not have a direct WINDOW JOIN equivalent; each
`bench_*.sh` spells the closest semantically equivalent query for that
engine, wrapped in the same outer ORDER BY / LIMIT 10. See the blog post
for the rewrites and why they look that way.

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

One script per row of the comparison table. The two Timescale scripts
share schema and data and skip the load step if the data is already
present.

- [`bench_questdb.sh`](bench_questdb.sh) - native `WINDOW JOIN`. Runs
  both the parallel and single-threaded configurations in one go,
  toggling `cairo.sql.parallel.window.join.enabled` in `server.conf`
  between phases and restoring it at the end. Requires `QDB_HOME` to
  point at the install dir.
- [`bench_timescale.sh`](bench_timescale.sh) - lateral subquery over a
  hypertable. Sets up the database, hypertables, and the
  `(sym, ts DESC)` index, then runs the query.
- [`bench_timescale_rangejoin.sh`](bench_timescale_rangejoin.sh) - range
  join + GROUP BY rewrite with all parallel knobs forced.
- [`bench_clickhouse_window.sh`](bench_clickhouse_window.sh) - window
  function over `UNION ALL` of trades + prices, with timestamps
  pre-converted to microseconds (ClickHouse requires numeric range
  offsets). Loads its own data into a `MergeTree ORDER BY (sym, ts)`
  table; CSV ingest uses `--date_time_input_format=best_effort` because
  the CSV has ISO-8601 timestamps with `+00:00` suffix.
- [`bench_duckdb_window.sh`](bench_duckdb_window.sh) - window function
  over `UNION ALL`. DuckDB accepts `INTERVAL` range offsets natively.
  Loads its own data into a self-contained `.duckdb` file.
- [`bench_duckdb_asof.sh`](bench_duckdb_asof.sh) - ASOF cumulative-diff
  rewrite: per-symbol prefix sums over `prices`, then two `ASOF LEFT JOIN`s
  bracket each trade's window so the per-trade aggregate is a subtraction.
  Matches QuestDB's WINDOW JOIN semantics exactly (both bounds inclusive,
  EXCLUDE PREVAILING). Shares the `.duckdb` file with
  `bench_duckdb_window.sh`.
- [`generate_csv.py`](generate_csv.py) - shared CSV generator that
  mimics QuestDB's zipfian symbol distribution. Used by all non-QuestDB
  loaders. The QuestDB script generates data in-database via
  `generate_series` / `long_sequence`.

## Reproducing end-to-end

```sh
# One-time install (Ubuntu 24.04)
./install_questdb.sh
./install_timescale.sh     # needs sudo, sets postgres password to "bench"
./install_duckdb.sh
./install_clickhouse.sh    # needs sudo

# QuestDB (both rows)
QDB_HOME=$HOME/questdb-9.3.5 ./bench_questdb.sh

# Timescale (lateral + range-join rewrite)
PGPASSWORD=bench ./bench_timescale.sh
PGPASSWORD=bench ./bench_timescale_rangejoin.sh

# DuckDB (window + ASOF rewrites)
export PATH="$HOME/.local/bin:$PATH"
./bench_duckdb_window.sh
./bench_duckdb_asof.sh

# ClickHouse (window rewrite)
./bench_clickhouse_window.sh
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

DuckDB-specific (`bench_duckdb_window.sh`, `bench_duckdb_asof.sh`):

| Var | Default | Effect |
| --- | ------- | ------ |
| `DB_FILE` | `bench.duckdb` | DuckDB database file (shared across DuckDB scripts) |
| `MEMORY_LIMIT` | `50GB` | Per-query memory budget passed via `SET memory_limit` |
| `DUCKDB_TEMP_DIR` | `$DATA_DIR/duck_tmp` | Spill directory passed via `SET temp_directory`; point at a fast disk |
