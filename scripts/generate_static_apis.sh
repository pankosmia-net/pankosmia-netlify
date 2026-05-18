#!/bin/bash
# Generate static JSON responses for /client-interfaces and /list-clients
# from the sibling client repos' pankosmia_metadata.json and package.json files.
#
# Output: netlify_dist/api/client-interfaces.json
#         netlify_dist/api/list-clients.json

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIBLING="$(cd "$REPO_ROOT/.." && pwd)"
OUT_DIR="$REPO_ROOT/netlify_dist/api"
mkdir -p "$OUT_DIR"

# Client repos in the same order as app_config.env
CLIENTS=(
  core-client-dashboard
  core-client-content
  core-client-i18n-editor
  core-client-remote-repos
  core-client-settings
  core-client-workspace
  core-contenthandler_obs
  core-contenthandler_version_manager
  core-contenthandler-generic
)

# --- /list-clients ---
echo "[" > "$OUT_DIR/list-clients.json"
first=true
for client in "${CLIENTS[@]}"; do
  client_dir="$SIBLING/$client"
  meta="$client_dir/pankosmia_metadata.json"
  pkg="$client_dir/package.json"

  if [[ ! -f "$meta" ]]; then
    echo "WARNING: $meta not found, skipping" >&2
    continue
  fi

  id=$(jq -r '.id' "$meta")
  net=$(jq -r '.require.net // false' "$meta")
  debug=$(jq -r '.require.debug // false' "$meta")
  exclude_menu=$(jq -r '.exclude_from_menu // false' "$meta")
  exclude_dash=$(jq -r '.exclude_from_dashboard // false' "$meta")
  url=$(jq -r '.homepage // ""' "$pkg")

  if [[ "$first" == "true" ]]; then
    first=false
  else
    echo "," >> "$OUT_DIR/list-clients.json"
  fi

  cat >> "$OUT_DIR/list-clients.json" <<ENTRY
  {
    "id": "$id",
    "requires": {"net": $net, "debug": $debug},
    "exclude_from_menu": $exclude_menu,
    "exclude_from_dashboard": $exclude_dash,
    "url": "$url"
  }
ENTRY
done
echo "]" >> "$OUT_DIR/list-clients.json"

# --- /client-interfaces ---
echo "{" > "$OUT_DIR/client-interfaces.json"
first=true
for client in "${CLIENTS[@]}"; do
  client_dir="$SIBLING/$client"
  meta="$client_dir/pankosmia_metadata.json"

  if [[ ! -f "$meta" ]]; then
    continue
  fi

  endpoints=$(jq '.endpoints // null' "$meta")
  if [[ "$endpoints" == "null" ]]; then
    continue
  fi

  id=$(jq -r '.id' "$meta")

  if [[ "$first" == "true" ]]; then
    first=false
  else
    echo "," >> "$OUT_DIR/client-interfaces.json"
  fi

  jq -c --arg id "$id" '{($id): {endpoints: .endpoints}}' "$meta" \
    | sed 's/^{/  /' | sed 's/}$//' \
    >> "$OUT_DIR/client-interfaces.json"
done
echo "}" >> "$OUT_DIR/client-interfaces.json"

# Pretty-print both files
for f in "$OUT_DIR/list-clients.json" "$OUT_DIR/client-interfaces.json"; do
  tmp=$(mktemp)
  jq '.' "$f" > "$tmp" && mv "$tmp" "$f"
done

echo "Generated:"
echo "  $OUT_DIR/list-clients.json ($(jq length "$OUT_DIR/list-clients.json") clients)"
echo "  $OUT_DIR/client-interfaces.json ($(jq 'keys | length' "$OUT_DIR/client-interfaces.json") clients with endpoints)"
