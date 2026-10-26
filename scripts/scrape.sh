#!/usr/bin/env bash
# Scrape SCE's public ArcGIS outage feeds for LA + Ventura counties.
# Appends one NDJSON row per (snapshot, outage) to data/snapshots/YYYY-MM-DD.ndjson
# and rewrites data/latest.geojson + data/psps-latest.geojson.
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="https://sce-outage-ags.esriemcs.com/arcgis/rest/services/43"
WHERE="${SCE_WHERE:-UPPER(CountyName) IN ('LOS ANGELES','VENTURA')}"
UA="sce-outages git-scraper (+https://github.com/${GITHUB_REPOSITORY:-local})"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DAY="${TS:0:10}"
PAGE=2000
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p data/snapshots

# AIDEV-NOTE: ArcGIS caps at maxRecordCount=2000; page on resultOffset until
# exceededTransferLimit is absent/false. Outputs a single JSON array of features.
query_all() {  # $1 = service/layer path, $2 = where clause, $3 = out file
  local offset=0 more=true
  : > "$3.parts"
  while [ "$more" = true ]; do
    curl -sfS --retry 3 --retry-delay 5 -A "$UA" "$BASE/$1/query" \
      --data-urlencode "where=$2" \
      --data-urlencode 'outFields=*' \
      --data-urlencode 'returnGeometry=true' \
      --data-urlencode 'outSR=4326' \
      --data-urlencode 'orderByFields=OBJECTID' \
      --data-urlencode "resultOffset=$offset" \
      --data-urlencode "resultRecordCount=$PAGE" \
      --data-urlencode 'f=json' > "$TMP/page.json"
    if jq -e '.error' "$TMP/page.json" >/dev/null; then
      echo "ArcGIS error on $1: $(jq -c .error "$TMP/page.json")" >&2; return 1
    fi
    jq -c '.features[]' "$TMP/page.json" >> "$3.parts"
    more="$(jq -r '.exceededTransferLimit // false' "$TMP/page.json")"
    offset=$((offset + PAGE))
  done
  jq -s . "$3.parts" > "$3"
}

# --- outages (points) --------------------------------------------------------
query_all outage/MapServer/0 "$WHERE" "$TMP/active.json"
query_all outage/MapServer/1 "$WHERE" "$TMP/scheduled.json"

# Flatten to NDJSON, drop publish-cycle churn fields, convert epoch ms to ISO.
for feed in active scheduled; do
  jq -c --arg ts "$TS" --arg feed "$feed" '
    .[] | {scraped_at: $ts, feed: $feed, lon: .geometry.x, lat: .geometry.y}
        + (.attributes
           | del(.PublishDate, .VersionDt, .created_user, .created_date,
                 .last_edited_user, .last_edited_date, .VTK, .Shape)
           | .OutageStartDateTime |= (if . then (. / 1000 | todate) else null end))
  ' "$TMP/$feed.json" >> "data/snapshots/$DAY.ndjson"
done

# Latest GeoJSON for quick looks (both feeds, raw attributes).
jq -n --arg ts "$TS" \
   --slurpfile a "$TMP/active.json" --slurpfile s "$TMP/scheduled.json" '
  {type: "FeatureCollection", scraped_at: $ts,
   features: ([($a[0][] | .attributes.feed = "active"),
               ($s[0][] | .attributes.feed = "scheduled")]
              | map({type: "Feature",
                     geometry: {type: "Point", coordinates: [.geometry.x, .geometry.y]},
                     properties: (.attributes | del(.PublishDate, .VersionDt, .VTK))}))}
' > data/latest.geojson

# --- PSPS (polygons, territory-wide, latest only) -----------------------------
# Polygons are large; keep only the current state, not history.
if query_all psps/MapServer/1 "1=1" "$TMP/psps-active.json" \
   && query_all psps/MapServer/0 "1=1" "$TMP/psps-considered.json"; then
  jq -n --arg ts "$TS" \
     --slurpfile a "$TMP/psps-active.json" --slurpfile c "$TMP/psps-considered.json" '
    def ring_to_geo: {type: "Polygon", coordinates: .};
    {type: "FeatureCollection", scraped_at: $ts,
     features: ([($a[0][] | .attributes.psps_state = "active"),
                 ($c[0][] | .attributes.psps_state = "considered")]
                | map({type: "Feature",
                       geometry: (.geometry.rings | ring_to_geo),
                       properties: (.attributes | del(.PublishDate, .VersionDt, .VTK))}))}
  ' > data/psps-latest.geojson
else
  echo "PSPS fetch failed; keeping previous data/psps-latest.geojson" >&2
fi

echo "snapshot $TS: $(jq length "$TMP/active.json") active, $(jq length "$TMP/scheduled.json") scheduled"
