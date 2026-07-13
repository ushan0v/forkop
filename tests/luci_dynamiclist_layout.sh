#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

wrapper_styles="$(sed -n '/^\.fkp-button-add-dynlist > \.add-item {$/,/^}$/p' "$SECTION_JS")"
button_styles="$(sed -n '/^\.fkp-button-add-dynlist > \.add-item > \.cbi-button-add {$/,/^}$/p' "$SECTION_JS")"
urltest_options="$(sed -n '/^function addUrlTestItemOptions(/,/^function priorityLevelSettingsForValidation(/p' "$SECTION_JS")"
priority_options="$(sed -n '/^function addPriorityLevelItemOptions(/,/^function addPriorityGroupItemOptions(/p' "$SECTION_JS")"

grep -Fq 'display: flex;' <<<"$wrapper_styles" ||
  fail "button-only DynamicList add rows must use a content-sized flex wrapper"
grep -Fq 'width: var(--fkp-button-add-width, 210px);' <<<"$wrapper_styles" ||
  fail "button-only DynamicList wrappers must follow the measured button width"
grep -Fq 'max-width: 100%;' <<<"$wrapper_styles" ||
  fail "button-only DynamicList wrappers must stay inside narrow option fields"
grep -Fq 'background: transparent;' <<<"$wrapper_styles" ||
  fail "button-only DynamicList wrappers must not render as empty input groups"
grep -Fq 'border: 0;' <<<"$wrapper_styles" ||
  fail "button-only DynamicList wrappers must leave framing to the button"

grep -Fq 'width: 100% !important;' <<<"$button_styles" ||
  fail "button-only DynamicList buttons must fill their content-sized wrapper"
grep -Fq 'max-width: 100% !important;' <<<"$button_styles" ||
  fail "button-only DynamicList buttons must not overflow narrow wrappers"
grep -Fq 'text-overflow: ellipsis !important;' <<<"$button_styles" ||
  fail "button-only DynamicList labels must truncate instead of overflowing"

grep -Fq 'if (key === "include_regex") {' <<<"$urltest_options" ||
  fail "URLTest include proxy parameters must follow the include regex option"
grep -Fq 'else if (key === "exclude_regex") {' <<<"$urltest_options" ||
  fail "URLTest exclude proxy parameters must follow the exclude regex option"
grep -Fq 'if (key === "regex") {' <<<"$priority_options" ||
  fail "Priority include proxy parameters must follow the include regex option"
grep -Fq 'else if (key === "exclude_regex") {' <<<"$priority_options" ||
  fail "Priority exclude proxy parameters must follow the exclude regex option"
grep -Fq '["direct", "Direct"]' "$SECTION_JS" ||
  fail "proxy protocol choices must keep Direct untranslated"
grep -Fq '["none", "None"]' "$SECTION_JS" ||
  fail "proxy security choices must keep None untranslated"
grep -Fq '_("Security")' "$SECTION_JS" ||
  fail "proxy parameter filters must use the short Security label"
if grep -Fq 'Connection security' "$SECTION_JS"; then
  fail "proxy parameter filter copy must not mention connection security"
fi

printf 'LuCI DynamicList layout checks passed\n'
