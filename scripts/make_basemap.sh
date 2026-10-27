#!/usr/bin/env bash
# One-time: build site/base.geojson (counties, city limits, primary roads) from
# Census TIGERweb (public domain, ArcGIS REST, f=geojson) and vendor Leaflet.
# Commit the outputs; the page then needs no tile server.
set -euo pipefail
cd "$(dirname "$0")/.."
TW="https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p site/vendor

# Bounding box: LA + Ventura counties with margin (lon/lat, WGS84).
BBOX='{"xmin":-119.6,"ymin":33.3,"xmax":-117.4,"ymax":35.0,"spatialReference":{"wkid":4326}}'

# AIDEV-NOTE: layer ids differ per TIGERweb service; resolve by name instead of hardcoding.
layer_id() {  # $1 = service, $2 = layer name
  curl -sfS "$TW/$1/MapServer?f=json" | jq -r --arg n "$2" '.layers[] | select(.name == $n) | .id' | head -1
}

fetch() {  # $1 service, $2 layer name, $3 where, $4 tolerance (deg), $5 kind, $6 outFields
  local id; id="$(layer_id "$1" "$2")"
  [ -n "$id" ] || { echo "layer '$2' not found in $1" >&2; exit 1; }
  curl -sfS "$TW/$1/MapServer/$id/query" \
    --data-urlencode "where=$3" \
    --data-urlencode "geometry=$BBOX" \
    --data-urlencode 'geometryType=esriGeometryEnvelope' \
    --data-urlencode 'spatialRel=esriSpatialRelIntersects' \
    --data-urlencode "outFields=$6" \
    --data-urlencode "maxAllowableOffset=$4" \
    --data-urlencode 'outSR=4326' \
    --data-urlencode 'f=geojson' \
  | jq -c --arg k "$5" '.features[] | .properties.kind = $k'
}

{
  fetch State_County   "Counties"       "STATE='06'" 0.002 county "NAME,GEOID"
  fetch Places_CouSub_ConCity_SubMCD "Incorporated Places" "STATE='06'" 0.001 place "NAME,GEOID"
  fetch Transportation "Primary Roads"  "1=1"        0.001 road   "FULLNAME,RTTYP"
} > "$TMP/features.ndjson"

jq -s '{type: "FeatureCollection", features: .}' "$TMP/features.ndjson" \
  | jq -c '.features |= map(.geometry.coordinates |= walk(if type == "number" then (. * 10000 | round / 10000) else . end))' \
  > site/base.geojson

# Vendor Leaflet 1.9.4 (BSD-2) so the page has no map-related CDN dependency.
curl -sfS -o site/vendor/leaflet.js  https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js
curl -sfS -o site/vendor/leaflet.css https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css

echo "base.geojson: $(jq '.features | group_by(.properties.kind) | map({(.[0].properties.kind): length}) | add' site/base.geojson), $(du -h site/base.geojson | cut -f1)"
