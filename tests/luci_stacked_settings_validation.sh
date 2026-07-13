#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

modal_source="$(sed -n '/^function renderStackedJsonSettingsModal(/,/^function renderJsonOutboundSettingsModal(/p' "$SECTION_JS")"

grep -Fq '.catch((error) => {' <<<"$modal_source" ||
  fail "stacked settings Save must retain the validation error"
grep -Fq 'fkp-stacked-settings-validation-summary' <<<"$modal_source" ||
  fail "stacked settings Save must render a visible validation summary"
grep -Fq '_("Cannot save settings")' <<<"$modal_source" ||
  fail "stacked settings validation summary must explain that Save failed"
grep -Fq '_("Fix the highlighted fields and save again.")' <<<"$modal_source" ||
  fail "stacked settings validation summary must tell the user how to recover"
grep -Fq 'const invalidInput = nodes.querySelector(".cbi-input-invalid");' <<<"$modal_source" ||
  fail "stacked settings validation must target only the active nested form"
grep -Fq 'invalidInput.scrollIntoView({ block: "center", behavior: "smooth" });' <<<"$modal_source" ||
  fail "stacked settings validation must reveal the first invalid field"
grep -Fq 'invalidInput.focus({ preventScroll: true });' <<<"$modal_source" ||
  fail "stacked settings validation must focus the first invalid field"
[[ "$(grep -Fc 'clearValidationSummary();' <<<"$modal_source")" -ge 3 ]] ||
  fail "stacked settings validation summary must be cleared before retry and close"

printf 'LuCI stacked settings validation checks passed\n'
