#!/usr/bin/env bash
# Download every snapshots-YYYY.parquet attached to data-* releases into data/archive/.
# Needs `gh` authenticated (GH_TOKEN in Actions; `gh auth login` locally).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
mkdir -p data/archive
gh api "repos/$REPO/releases" --paginate \
  --jq '.[] | select(.tag_name | startswith("data-")) | .assets[] | select(.name | test("^snapshots-[0-9]{4}\\.parquet$")) | .name' \
| sort -u | while read -r name; do
    tag="data-${name#snapshots-}"; tag="${tag%.parquet}"
    gh release download "$tag" --repo "$REPO" --pattern "$name" --dir data/archive --clobber
    echo "fetched $name"
  done
ls -la data/archive 2>/dev/null || echo "no archives yet"
