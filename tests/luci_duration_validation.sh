#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for file in settings.js section.js; do
  source="$(sed -n '/^function isSingBoxDuration(/,/^}/p' \
    "$ROOT_DIR/luci-app-nexroute/htdocs/luci-static/resources/view/nexroute/$file")"

  DURATION_SOURCE="$source" node <<'NODE'
const validate = Function(`${process.env.DURATION_SOURCE}; return isSingBoxDuration`)();

for (const value of ['1s', '0.5s', '2m30s']) {
  if (!validate(value)) throw new Error(`valid duration rejected: ${value}`);
}
for (const value of ['0s', '0h0m', '0.0s']) {
  if (validate(value)) throw new Error(`zero duration accepted: ${value}`);
}
NODE
done

printf 'LuCI duration validation checks passed\n'
