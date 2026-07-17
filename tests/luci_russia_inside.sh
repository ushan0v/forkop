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

if (!main.includes('russia_inside: "Russia inside"')) {
  fail("Russia inside must remain available as a built-in rule set");
}

for (const removed of [
  "ALLOWED_WITH_RUSSIA_INSIDE",
  "Russia inside restrictions",
  "Warning: Russia inside can only",
]) {
  if (section.includes(removed) || main.includes(removed)) {
    fail(`removed Russia inside restriction remains: ${removed}`);
  }
}
NODE

printf 'Russia inside UI checks passed\n'
