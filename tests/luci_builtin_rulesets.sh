#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"
MAIN_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js"

node - "$SECTION_JS" "$MAIN_JS" <<'NODE'
const fs = require("fs");
const section = fs.readFileSync(process.argv[2], "utf8");
const main = fs.readFileSync(process.argv[3], "utf8");

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

for (const option of ["russia_inside", "russia_outside", "ukraine_inside"]) {
  if (!main.includes(`${option}:`)) {
    fail(`${option} must remain available as a built-in rule set`);
  }
}

for (const removed of [
  "REGIONAL_OPTIONS",
  "builtInRulesetOption.onchange",
  "Regional options cannot be used together",
  "Previous selections have been removed",
]) {
  if (section.includes(removed) || main.includes(removed)) {
    fail(`built-in rule set restriction remains: ${removed}`);
  }
}
NODE

printf 'Built-in rule set UI checks passed\n'
