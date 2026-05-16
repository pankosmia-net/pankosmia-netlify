#!/usr/bin/env bash
set -euo pipefail

# Assemble the Netlify publish directory from built clients + assets.
#
# Run from: scripts/
# Prereqs:  ./clone.zsh + ./build_clients.zsh must have run first.
#
# Output:   ../netlify_dist/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST="$REPO_ROOT/netlify_dist"
SIBLING="$(cd "$REPO_ROOT/.." && pwd)"

# Source app_config.env for client/asset lists
set -a
source "$REPO_ROOT/app_config.env"
set +a

echo "=== Assembling Netlify publish directory ==="
echo "Output: $DIST"

# Clean previous output
rm -rf "$DIST"
mkdir -p "$DIST"

# --- Install build.js npm deps if needed ---
if [ ! -d "$SCRIPT_DIR/node_modules" ] && [ -d "$REPO_ROOT/node_modules" ]; then
    echo "(npm deps found at repo root)"
elif [ ! -d "$REPO_ROOT/node_modules" ]; then
    echo "> npm install (repo root)..."
    (cd "$REPO_ROOT" && npm install)
fi

# --- Copy assets ---
echo
echo "--- Assets ---"

# resource-core/runtime_resources → app_resources
if [ -d "$SIBLING/resource-core/runtime_resources" ]; then
    echo "> Copying app_resources..."
    cp -R "$SIBLING/resource-core/runtime_resources" "$DIST/app_resources"
else
    echo "WARNING: resource-core/runtime_resources not found"
fi

# resource-core/templates → templates
if [ -d "$SIBLING/resource-core/templates" ]; then
    echo "> Copying templates..."
    cp -R "$SIBLING/resource-core/templates" "$DIST/templates"
else
    echo "WARNING: resource-core/templates not found"
fi

# webfonts-core → webfonts
if [ -d "$SIBLING/webfonts-core" ]; then
    echo "> Copying webfonts..."
    mkdir -p "$DIST/webfonts"
    cp -R "$SIBLING/webfonts-core/"* "$DIST/webfonts/" 2>/dev/null || true
    # Remove .git if present
    rm -rf "$DIST/webfonts/.git"
else
    echo "WARNING: webfonts-core not found"
fi

# --- Patch i18n ---
I18N_FILE="$DIST/templates/i18n.json"
I18N_PATCH="$REPO_ROOT/globalBuildResources/i18nPatch.json"
if [ -f "$I18N_FILE" ] && [ -f "$I18N_PATCH" ]; then
    echo "> Patching i18n.json..."
    node -e "
const fs = require('fs');
const i18n = JSON.parse(fs.readFileSync('$I18N_FILE', 'utf8'));
const patch = JSON.parse(fs.readFileSync('$I18N_PATCH', 'utf8'));
for (const [l1, l1v] of Object.entries(patch)) {
    for (const [l2, l2v] of Object.entries(l1v)) {
        for (const [l3, val] of Object.entries(l2v)) {
            if (i18n[l1] && i18n[l1][l2] && i18n[l1][l2][l3] !== undefined) {
                i18n[l1][l2][l3] = val;
            }
        }
    }
}
fs.writeFileSync('$I18N_FILE', JSON.stringify(i18n));
"
fi

# --- Copy theme, product, client_config ---
echo "> Copying product config..."
mkdir -p "$DIST/app_resources/themes"
mkdir -p "$DIST/app_resources/product"

if [ -f "$REPO_ROOT/globalBuildResources/theme.json" ]; then
    cp "$REPO_ROOT/globalBuildResources/theme.json" "$DIST/app_resources/themes/default.json"
fi
if [ -f "$REPO_ROOT/globalBuildResources/product.json" ]; then
    cp "$REPO_ROOT/globalBuildResources/product.json" "$DIST/app_resources/product/product.json"
fi
if [ -f "$REPO_ROOT/globalBuildResources/client_config.json" ]; then
    cp "$REPO_ROOT/globalBuildResources/client_config.json" "$DIST/app_resources/product/client_config.json"
fi
if [ -d "$REPO_ROOT/globalBuildResources/product_resources" ]; then
    cp -R "$REPO_ROOT/globalBuildResources/product_resources" "$DIST/app_resources/product/product_resources"
fi

# --- Copy clients ---
echo
echo "--- Clients ---"
mkdir -p "$DIST/clients"

# Map from repo name to the homepage path (last segment)
declare -A CLIENT_DIRS
CLIENT_DIRS=(
    [core-client-dashboard]="main"
    [core-client-content]="content"
    [core-client-i18n-editor]="i18n-editor"
    [core-client-remote-repos]="download"
    [core-client-settings]="settings"
    [core-client-workspace]="core-local-workspace"
    [core-contenthandler_obs]="core-contenthandler_obs"
    [core-contenthandler_version_manager]="core-contenthandler_version_manager"
    [core-contenthandler-generic]="core-contenthandler-generic"
)

# Count clients from app_config.env
count=$(wc -l < "$REPO_ROOT/app_config.env")
CLIENT_COUNT=0
CLIENT_FAIL=0

for ((i=1; i<=count; i++)); do
    eval client='$'"CLIENT$i"
    if [ -n "${client:-}" ]; then
        client=$(echo "$client" | tr -d ' ')
        dir_name="${CLIENT_DIRS[$client]:-$client}"
        build_dir="$SIBLING/$client/build"

        if [ -d "$build_dir" ]; then
            echo "> $client → clients/$dir_name/"
            cp -R "$build_dir" "$DIST/clients/$dir_name"
            # Copy pankosmia_metadata.json alongside build output
            if [ -f "$SIBLING/$client/pankosmia_metadata.json" ]; then
                cp "$SIBLING/$client/pankosmia_metadata.json" "$DIST/clients/$dir_name/"
            fi
            # Override favicon if configured
            if [ -f "$REPO_ROOT/globalBuildResources/favicon.ico" ]; then
                cp "$REPO_ROOT/globalBuildResources/favicon.ico" "$DIST/clients/$dir_name/favicon.ico"
            fi
            CLIENT_COUNT=$((CLIENT_COUNT + 1))
        else
            echo "WARNING: $client/build not found — did you run build_clients.zsh?"
            CLIENT_FAIL=$((CLIENT_FAIL + 1))
        fi
    fi
done

# --- Summary ---
echo
echo "=== Done ==="
echo "Clients assembled: $CLIENT_COUNT"
if [ "$CLIENT_FAIL" -gt 0 ]; then
    echo "Clients missing:   $CLIENT_FAIL (see warnings above)"
fi
echo "Output directory:  $DIST"
echo
echo "To deploy:  netlify deploy --dir=netlify_dist --prod"
