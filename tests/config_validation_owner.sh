#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_FILES="$ROOT_DIR/forkop/files"
FORKOP_BIN="$FORKOP_FILES/usr/bin/forkop"
FORKOP_LIB="$FORKOP_FILES/usr/lib"
CLI_UC="$FORKOP_BIN"
VALIDATOR="$FORKOP_LIB/config/validator.uc"
RULE_CONFIG="$FORKOP_LIB/config/rule.uc"
GENERATOR="$FORKOP_LIB/singbox/generator.uc"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"
LIFECYCLE="$FORKOP_LIB/service/lifecycle.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ ! -e "$FORKOP_LIB/config_validation.sh" ] ||
  fail "config_validation.sh shell owner must be removed"

if grep -R -n "config_validation.sh" "$FORKOP_FILES" >/dev/null 2>&1; then
  fail "runtime files must not reference config_validation.sh"
fi

legacy_symbols='(^|[^A-Za-z0-9_])(config_validate_runtime|check_requirements|commit_forkop_config|mwan3_is_active|get_inline_remote_ruleset_format|detect_inline_ruleset_reference_kind)([^A-Za-z0-9_]|$)'
if grep -R -n -E "$legacy_symbols" "$FORKOP_BIN" "$FORKOP_LIB" --include='*.sh' >/dev/null 2>&1; then
  fail "runtime shell must not keep config_validation.sh symbols"
fi

grep -Fq 'mode == "check-requirements"' "$VALIDATOR" ||
  fail "config validator must own requirement checks"
grep -Fq 'mode == "mwan3-is-active"' "$VALIDATOR" ||
  fail "config validator must own mwan3 runtime predicate"
grep -Fq 'require("core.uci")' "$VALIDATOR" ||
  fail "config validator must use core.uci for runtime UCI access"
grep -Fq 'text_list_values,' "$RULE_CONFIG" ||
  fail "config.rule must export the shared comment-aware text parser"
grep -Fq 'rule_config.text_list_values(value, "comma-space")' "$VALIDATOR" ||
  fail "domain validation must use the shared comment-aware text parser"
grep -Fq 'rule_config.text_list_values(option(section, "domain", ""), "comma-space")' "$GENERATOR" ||
  fail "sing-box domain generation must use the shared comment-aware text parser"
grep -Fq 'return appendUniqueDomainTextValues(textValue, values);' "$SECTION_JS" ||
  fail "Domains field loading must preserve the original combined text"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"|command_output\("uci' "$VALIDATOR" >/dev/null 2>&1; then
  fail "config validator must not own direct UCI cursor or CLI access"
fi
grep -Fq '#!/usr/bin/ucode' "$FORKOP_BIN" ||
  fail "forkop entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch service lifecycle through service/lifecycle.uc"
if grep -n -E 'MIGRATION_UC|config[./]migration|"migrate"' "$LIFECYCLE" >/dev/null 2>&1; then
  fail "service/lifecycle.uc must not run configuration migration"
fi
grep -Fq 'mark_internal_config_guard();' "$LIFECYCLE" ||
  fail "service/lifecycle.uc must preserve the internal config trigger guard"
grep -Fq 'VALIDATOR_UC' "$LIFECYCLE" &&
grep -Fq '"validate-runtime"' "$LIFECYCLE" ||
  fail "service/lifecycle.uc must run runtime validation directly through ucode"

printf 'config validation ownership checks passed\n'
