#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["duckdb>=1.1"]
# ///
"""Turn data/snapshots/*.ndjson into site/outages.parquet and site/summary.json.

Run locally:  uv run scripts/build.py
Then serve:   python3 -m http.server -d site 8000
"""
import json
import pathlib
import shutil
import sys

import duckdb

ROOT = pathlib.Path(__file__).resolve().parent.parent
SNAP = ROOT / "data" / "snapshots"
SITE = ROOT / "site"

ARCH = ROOT / "data" / "archive"

live = sorted(SNAP.glob("*.ndjson"))
archived = sorted(ARCH.glob("snapshots-*.parquet"))
if not live and not archived:
    sys.exit("no data/snapshots/*.ndjson or data/archive/*.parquet; run scripts/scrape.sh first")

con = duckdb.connect()
con.execute("SET TimeZone='UTC'")

# AIDEV-NOTE: raw rows come from two places with identical columns: live NDJSON
# (this year) and yearly Parquet archives fetched from data-* releases.
parts = []
if live:
    parts.append(f"SELECT * FROM read_ndjson({[f.as_posix() for f in live]}, union_by_name = true, ignore_errors = true)")
if archived:
    parts.append(f"SELECT * FROM read_parquet({[f.as_posix() for f in archived]}, union_by_name = true)")
con.execute("CREATE VIEW raw AS " + " UNION ALL BY NAME ".join(parts))

# AIDEV-NOTE: LastChngDateTime / ERT are naive Pacific-local strings
# ('10/26/2026 03:34:42 PM'); OutageStartDateTime was already ISO-UTC'd by jq.
# timezone('America/Los_Angeles', naive_ts) interprets naive as local -> TIMESTAMPTZ.
con.execute(f"""
CREATE TABLE outages AS
SELECT
  scraped_at::TIMESTAMPTZ                                   AS scraped_at,
  feed,
  IncidentId::BIGINT                                        AS incident_id,
  OanNo::BIGINT                                             AS oan_no,
  Status                                                    AS status,
  OutageType                                                AS outage_type,
  COALESCE(NoOfAffectedCust_Inci, 0)::INTEGER               AS customers,
  MemoCauseCdDesc                                           AS cause,
  CrewStatusCdDesc                                          AS crew_status,
  ResultCdDesc                                              AS result,
  CountyName                                                AS county,
  CityName                                                  AS city,
  ZipcodeName                                               AS zip,
  DistrictNo                                                AS district,
  SectorNo                                                  AS sector,
  Circuit_Number                                            AS circuit,
  lat::DOUBLE                                               AS lat,
  lon::DOUBLE                                               AS lon,
  OutageStartDateTime::TIMESTAMPTZ                          AS start_utc,
  timezone('America/Los_Angeles',
           try_strptime(LastChngDateTime, '%m/%d/%Y %I:%M:%S %p')) AS last_change_utc,
  timezone('America/Los_Angeles',
           try_strptime(ERT, '%m/%d/%Y %I:%M:%S %p'))       AS ert_utc,
  ERT_LOC                                                   AS ert_text,
  RO_Group_Numbers                                          AS ro_groups
FROM raw
ORDER BY scraped_at, incident_id
""")

SITE.mkdir(exist_ok=True)
con.execute(f"COPY outages TO '{(SITE / 'outages.parquet').as_posix()}' (FORMAT PARQUET, COMPRESSION ZSTD)")

# Per-snapshot aggregates: small, drives the timeline without loading DuckDB-WASM.
snapshots = con.execute("""
SELECT strftime(scraped_at, '%Y-%m-%dT%H:%M:%SZ') AS t,
       count(*) FILTER (feed = 'active')                              AS active,
       count(*) FILTER (feed = 'scheduled')                           AS scheduled,
       sum(customers) FILTER (feed = 'active')                        AS customers,
       sum(customers) FILTER (feed = 'active' AND county = 'LOS ANGELES') AS customers_la,
       sum(customers) FILTER (feed = 'active' AND county = 'VENTURA')     AS customers_ventura
FROM outages GROUP BY 1 ORDER BY 1
""").fetchall()

incidents = con.execute("""
SELECT incident_id, any_value(city) AS city, any_value(county) AS county,
       any_value(cause) AS cause, max(customers) AS max_customers,
       strftime(min(scraped_at), '%Y-%m-%dT%H:%M:%SZ') AS first_seen,
       strftime(max(scraped_at), '%Y-%m-%dT%H:%M:%SZ') AS last_seen,
       count(*) AS snapshots
FROM outages WHERE feed = 'active'
GROUP BY 1 ORDER BY first_seen DESC LIMIT 500
""").fetchall()

summary = {
    "generated_at": con.execute("SELECT strftime(now(), '%Y-%m-%dT%H:%M:%SZ')").fetchone()[0],
    "snapshots": [
        {"t": r[0], "active": r[1], "scheduled": r[2], "customers": int(r[3] or 0),
         "la": int(r[4] or 0), "ventura": int(r[5] or 0)} for r in snapshots
    ],
    "incidents": [
        {"id": r[0], "city": r[1], "county": r[2], "cause": r[3], "max_customers": r[4],
         "first_seen": r[5], "last_seen": r[6], "snapshots": r[7]} for r in incidents
    ],
}
(SITE / "summary.json").write_text(json.dumps(summary, separators=(",", ":")))

for name in ("latest.geojson", "psps-latest.geojson"):
    src = ROOT / "data" / name
    if src.exists():
        shutil.copy(src, SITE / name)

n = con.execute("SELECT count(*), count(DISTINCT scraped_at) FROM outages").fetchone()
print(f"outages.parquet: {n[0]} rows across {n[1]} snapshots; summary.json: {len(incidents)} incidents")
