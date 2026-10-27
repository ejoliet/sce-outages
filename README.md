# sce-outages

Git-scrapes Southern California Edison's public outage map for Los Angeles and
Ventura counties every hour and publishes a map with a time scrubber on
GitHub Pages. Same idea as [simonw/scrape-florida-outages](https://github.com/simonw/scrape-florida-outages),
plus a built site.

## How it works

```
scripts/scrape.sh   curl + jq against SCE's ArcGIS MapServer (no auth)
                    └─► data/snapshots/YYYY-MM-DD.ndjson   one row per (snapshot, outage), committed
                    └─► data/latest.geojson, data/psps-latest.geojson
scripts/build.py    DuckDB: NDJSON history → site/outages.parquet + site/summary.json (CI only, not committed)
site/index.html     Leaflet map, timeline, DuckDB-WASM reading outages.parquet over HTTP range requests
```

Source layers (points, `CountyName` filter server-side):

- `https://sce-outage-ags.esriemcs.com/arcgis/rest/services/43/outage/MapServer/0` active
- `.../outage/MapServer/1` scheduled
- `.../psps/MapServer/{0,1}` PSPS polygons, latest only

## Setup

1. Push this repo to GitHub.
2. Settings → Pages → Source: **GitHub Actions**.
3. Actions → "Scrape SCE outages" → Run workflow. The first run creates the first
   snapshot and deploys the site.

Change counties with the `SCE_WHERE` env var in the workflow, e.g.
`UPPER(CountyName) IN ('ORANGE')`.

## Run locally

```bash
scripts/scrape.sh                       # needs curl + jq
scripts/fetch-archive.sh                # optional: pull data-* release archives (needs gh)
uv run scripts/build.py                 # writes site/outages.parquet, site/summary.json
python3 -m http.server -d site 8000     # http://localhost:8000
```

Query the history directly:

```bash
duckdb -c "SELECT scraped_at, count(*), sum(customers) FROM 'site/outages.parquet' WHERE feed='active' GROUP BY 1 ORDER BY 1"
```

## Notes

- Hourly snapshots miss outages shorter than ~1 h.
- Repo growth is ~1 kB per outage per snapshot. Every Jan 2, `archive.yml`
  squashes the previous year's NDJSON into `snapshots-YYYY.parquet`, attaches
  it to a `data-YYYY` release, and removes the NDJSON from the tree. The hourly
  job downloads those archives before building, so the site keeps full history.
  Run it by hand for any year: Actions → "Archive previous year" → year.
- `LastChngDateTime` and `ERT` arrive as Pacific-local strings without a zone;
  `build.py` converts them to UTC. `OutageStartDateTime` is epoch ms, converted
  to ISO in `scrape.sh`.
- `Circuit_Number` is always null in the public feed; `SectorNo` + `DistrictNo`
  is the finest grouping available.
- PSPS polygons are not kept in history (size); only the current state is shown.
