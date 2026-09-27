#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_STYLES="$ROOT_DIR/fe-app-nexroute/src/nexroute/tabs/updates/styles.ts"
BUNDLE="$ROOT_DIR/luci-app-nexroute/htdocs/luci-static/resources/view/nexroute/main.js"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

source_card_styles="$(sed -n '/^\.fkp_updates-page__component {$/,/^}$/p' "$SOURCE_STYLES")"
bundle_card_styles="$(sed -n '/^\.fkp_updates-page__component {$/,/^}$/p' "$BUNDLE")"

[[ -n "$source_card_styles" ]] ||
  fail "component card styles must exist in the frontend source"
[[ -n "$bundle_card_styles" ]] ||
  fail "component card styles must exist in the LuCI bundle"

if grep -Eq '^[[:space:]]*background(-color)?:' <<<"$source_card_styles"; then
  fail "component cards must inherit the active LuCI theme background"
fi
if grep -Eq '^[[:space:]]*background(-color)?:' <<<"$bundle_card_styles"; then
  fail "bundled component cards must inherit the active LuCI theme background"
fi

printf 'LuCI updates theme checks passed\n'
