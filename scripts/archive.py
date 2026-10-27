#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["duckdb>=1.1"]
# ///
"""Squash one year of data/snapshots/YYYY-*.ndjson into a single Parquet file.

  uv run scripts/archive.py 2026                 # writes data/archive/snapshots-2026.parquet
  uv run scripts/archive.py 2026 --delete        # also deletes the NDJSON files it consumed

The Parquet keeps the raw NDJSON columns untouched; build.py applies the same
normalisation to archive and live rows, so there is one place to change it.
"""
import argparse
import pathlib
import sys

import duckdb

ROOT = pathlib.Path(__file__).resolve().parent.parent
SNAP = ROOT / "data" / "snapshots"
ARCH = ROOT / "data" / "archive"

ap = argparse.ArgumentParser()
ap.add_argument("year", type=int)
ap.add_argument("--delete", action="store_true", help="remove consumed NDJSON files")
args = ap.parse_args()

files = sorted(SNAP.glob(f"{args.year}-*.ndjson"))
if not files:
    sys.exit(f"no data/snapshots/{args.year}-*.ndjson files; nothing to archive")

ARCH.mkdir(parents=True, exist_ok=True)
out = ARCH / f"snapshots-{args.year}.parquet"
con = duckdb.connect()
con.execute(f"""
COPY (SELECT * FROM read_ndjson({[f.as_posix() for f in files]},
                                union_by_name = true, ignore_errors = true)
      ORDER BY scraped_at, IncidentId)
TO '{out.as_posix()}' (FORMAT PARQUET, COMPRESSION ZSTD)
""")
n = con.execute(f"SELECT count(*), count(DISTINCT scraped_at) FROM '{out.as_posix()}'").fetchone()
print(f"{out.relative_to(ROOT)}: {n[0]} rows, {n[1]} snapshots, {out.stat().st_size // 1024} kB from {len(files)} files")

if args.delete:
    for f in files:
        f.unlink()
    print(f"deleted {len(files)} NDJSON files")
