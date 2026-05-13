#!/usr/bin/env python3
"""Generate CSV that mirrors the QuestDB SQL data distribution.

Usage:
    generate_csv.py trades 502325582 > trades.csv
    generate_csv.py prices 1500000000 > prices.csv

Notes:
- The QuestDB SQL uses rnd_symbol_zipf(1000, 2.0); this generator uses a
  Zipf(2.0) distribution truncated to 1000 distinct symbols.
- Timestamps for `trades` start at 2025-01-01T00:00:00 and step by 1728us
  (50M rows span exactly one day, matching bench_questdb.sh).
- Timestamps for `prices` start at 2024-12-31T23:59:59, step by 576us, and
  receive a uniform jitter of [-20us, +20us] (150M rows span 24h, matching
  bench_questdb.sh).

Output schema (CSV, no header):
  trades: symbol, side, price, amount, ts
  prices: ts, sym, bid, ask
"""

import csv
import random
import sys
from datetime import datetime, timedelta, timezone

ZIPF_S = 2.0
N_SYMBOLS = 1000


def zipf_table(n: int, s: float):
    """Return cumulative weights for Zipf(s) over n ranks."""
    weights = [1.0 / (k ** s) for k in range(1, n + 1)]
    total = sum(weights)
    cum = []
    running = 0.0
    for w in weights:
        running += w / total
        cum.append(running)
    return cum


def make_symbols(n: int):
    # Matches QuestDB's rnd_symbol_zipf(N, ...) symbol naming: lowercase "sym"
    # prefix, no zero-padding, indices 0..N-1. Keeps the CSV-loaded engines
    # bit-equal to QuestDB for symbol-keyed joins.
    return [f"sym{i}" for i in range(n)]


def sample_zipf(cum, rng):
    r = rng.random()
    lo, hi = 0, len(cum) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if cum[mid] < r:
            lo = mid + 1
        else:
            hi = mid
    return lo


def gen_trades(n: int, out):
    rng = random.Random(0)
    cum = zipf_table(N_SYMBOLS, ZIPF_S)
    syms = make_symbols(N_SYMBOLS)
    sides = ("buy", "sell")
    t0 = datetime(2025, 1, 1, tzinfo=timezone.utc)
    step = timedelta(microseconds=1728)
    w = csv.writer(out)
    for i in range(n):
        sym = syms[sample_zipf(cum, rng)]
        side = sides[rng.getrandbits(1)]
        price = rng.random() * 20 + 10
        amount = rng.random() * 20 + 10
        ts = t0 + i * step
        w.writerow([sym, side, f"{price:.10f}", f"{amount:.10f}",
                    ts.isoformat()])


def gen_prices(n: int, out):
    rng = random.Random(1)
    cum = zipf_table(N_SYMBOLS, ZIPF_S)
    syms = make_symbols(N_SYMBOLS)
    t0 = datetime(2024, 12, 31, 23, 59, 59, tzinfo=timezone.utc)
    w = csv.writer(out)
    for x in range(1, n + 1):
        jitter = rng.randint(-20, 20)
        ts = t0 + timedelta(microseconds=576 * x + jitter)
        sym = syms[sample_zipf(cum, rng)]
        bid = rng.random() * 10 + 5
        ask = rng.random() * 10 + 5
        w.writerow([ts.isoformat(), sym, f"{bid:.10f}", f"{ask:.10f}"])


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    kind, n_str = sys.argv[1], sys.argv[2]
    n = int(n_str)
    if kind == "trades":
        gen_trades(n, sys.stdout)
    elif kind == "prices":
        gen_prices(n, sys.stdout)
    else:
        print(f"unknown kind: {kind}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
