#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_BIN="$ROOT_DIR/podkop/files/usr/bin/podkop"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
CLI_UC="$PODKOP_BIN"
LIFECYCLE_UC="$PODKOP_LIB/service/lifecycle.uc"
ZAPRET_RUNTIME="$PODKOP_LIB/providers/zapret/runtime.uc"
ZAPRET2_RUNTIME="$PODKOP_LIB/providers/zapret2/runtime.uc"
ZAPRET_COMMON="$PODKOP_LIB/providers/zapret/common.uc"
ZAPRET2_COMMON="$PODKOP_LIB/providers/zapret2/common.uc"
NFQUEUE_RUNTIME="$PODKOP_LIB/providers/nfqueue/runtime.uc"
NFQUEUE_CHECK="$PODKOP_LIB/providers/nfqueue/check.uc"
NFQUEUE_VALIDATOR="$PODKOP_LIB/providers/nfqueue/validator.uc"
ZAPRET2_CHECK="$PODKOP_LIB/providers/zapret2/check.uc"
ZAPRET2_VALIDATOR="$PODKOP_LIB/providers/zapret2/validator.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ ! -e "$PODKOP_LIB/zapret.sh" ] ||
  fail "zapret.sh shell owner must be removed"
[ ! -e "$PODKOP_LIB/zapret2.sh" ] ||
  fail "zapret2.sh shell owner must be removed"

grep -Fq '#!/usr/bin/ucode' "$PODKOP_BIN" ||
  fail "podkop entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch lifecycle orchestration through service/lifecycle.uc"
grep -Fq 'providers/zapret/runtime.uc' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must call providers/zapret/runtime.uc"
grep -Fq 'providers/zapret2/runtime.uc' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must call providers/zapret2/runtime.uc"
grep -Fq 'require("providers.nfqueue.runtime")' "$ZAPRET_RUNTIME" ||
  fail "providers/zapret/runtime.uc must use the shared NFQUEUE runtime engine"
grep -Fq 'require("providers.nfqueue.runtime")' "$ZAPRET2_RUNTIME" ||
  fail "providers/zapret2/runtime.uc must use the shared NFQUEUE runtime engine"
grep -Fq 'require("providers.zapret.common")' "$ZAPRET_RUNTIME" ||
  fail "providers/zapret/runtime.uc must load zapret config"
grep -Fq 'require("providers.zapret2.common")' "$ZAPRET2_RUNTIME" ||
  fail "providers/zapret2/runtime.uc must load zapret2 config"
grep -Fq 'providers/zapret/check.uc' "$ZAPRET_COMMON" ||
  fail "providers/zapret/common.uc must point at its provider check wrapper"
grep -Fq 'providers/zapret2/check.uc' "$ZAPRET2_COMMON" ||
  fail "providers/zapret2/common.uc must point at its provider check wrapper"
grep -Fq 'providers.zapret2.validator' "$ZAPRET2_COMMON" ||
  fail "providers/zapret2/common.uc must load its provider validator"
grep -Fq 'function start_runtime' "$NFQUEUE_RUNTIME" ||
  fail "providers/nfqueue/runtime.uc must own NFQUEUE start"
grep -Fq 'function stop_runtime' "$NFQUEUE_RUNTIME" ||
  fail "providers/nfqueue/runtime.uc must own NFQUEUE stop"
grep -Fq 'function status_json' "$NFQUEUE_RUNTIME" ||
  fail "providers/nfqueue/runtime.uc must own NFQUEUE status"
grep -Fq 'function create_nft_rules' "$NFQUEUE_RUNTIME" ||
  fail "providers/nfqueue/runtime.uc must own NFQUEUE nft rules"
grep -Fq 'function validate_strategy' "$NFQUEUE_VALIDATOR" ||
  fail "providers/nfqueue/validator.uc must own shared NFQUEUE strategy validation"
grep -Fq 'function nft_queue_overlap' "$NFQUEUE_CHECK" ||
  fail "providers/nfqueue/check.uc must own shared NFQUEUE overlap checks"
if grep -n -E 'function (start_runtime|stop_runtime|status_json|create_nft_rules|supervisor)\b' "$ZAPRET_COMMON" "$ZAPRET2_COMMON" >/dev/null 2>&1; then
  fail "provider common modules must stay thin config wrappers, not runtime engines"
fi
if grep -R -n -E 'providers/zapret/runtime\.uc" (start-runtime|stop-runtime|status|check|installed|package-installed|package-version|enabled-rule-count) zapret2' \
  "$PODKOP_BIN" "$PODKOP_LIB" --include='*.sh' >/dev/null 2>&1; then
  fail "zapret2 must not be multiplexed through providers/zapret/runtime.uc"
fi
if grep -R -n -E 'providers\.zapret\.|providers/zapret/' "$PODKOP_LIB/providers/zapret2" >/dev/null 2>&1; then
  fail "zapret2 provider modules must not import or execute providers/zapret modules"
fi
if grep -n 'zapret2' "$ZAPRET_COMMON" >/dev/null 2>&1; then
  fail "providers/zapret/common.uc must not contain zapret2 ownership"
fi
if grep -R -n -E 'start_zapret2?_runtime|stop_zapret2?_runtime|get_zapret2?_status_json|check_zapret2?_runtime_json|create_zapret2?_nft_rules|validate_rule_nfqws2?_opt|has_enabled_zapret2?_rules|get_zapret2?_rule_' \
  "$PODKOP_BIN" "$PODKOP_LIB" --include='*.sh' >/dev/null 2>&1; then
  fail "zapret runtime shell symbols must not remain"
fi
if grep -R -n -E 'is_zapret2?_installed|get_zapret2?_package_version' \
  "$PODKOP_BIN" "$PODKOP_LIB" --include='*.sh' >/dev/null 2>&1; then
  fail "zapret installed/version shell predicates must not remain"
fi
if grep -n -E 'require\("uci"\)\.cursor|uci -q|"uci", "-q"|command_output\(command_from_args\(\[ "uci"' "$NFQUEUE_RUNTIME" "$ZAPRET_COMMON" "$ZAPRET2_COMMON" >/dev/null 2>&1; then
  fail "zapret provider runtimes must use core.uci instead of direct UCI cursor or CLI access"
fi
grep -Fq 'require("core.uci")' "$NFQUEUE_RUNTIME" ||
  fail "providers/nfqueue/runtime.uc must use core.uci for runtime UCI access"
grep -Fq 'require("singbox.constants")' "$NFQUEUE_RUNTIME" ||
  fail "providers/nfqueue/runtime.uc must share the sing-box runtime tag allocator"
grep -Fq 'runtime_constants.tag(base, postfix)' "$NFQUEUE_RUNTIME" ||
  fail "providers/nfqueue/runtime.uc must allocate section tags through singbox.constants"

for mode in \
  'mode == "start-runtime"' \
  'mode == "stop-runtime"' \
  'mode == "create-nft-rules"' \
  'mode == "status"' \
  'mode == "check"' \
  'mode == "supervisor"'
do
  grep -Fq "$mode" "$NFQUEUE_RUNTIME" ||
    fail "providers/nfqueue/runtime.uc missing $mode"
done
if grep -Fq 'runtime.run("zapret", ARGV)' "$ZAPRET_RUNTIME"; then
  fail "providers/zapret/runtime.uc must not carry the old hard-coded engine call"
fi
grep -Fq 'runtime.run(provider, ARGV)' "$ZAPRET_RUNTIME" ||
  fail "providers/zapret/runtime.uc must be the zapret entrypoint"
grep -Fq 'require("providers.zapret2.common")' "$ZAPRET2_RUNTIME" ||
  fail "providers/zapret2/runtime.uc must import providers/zapret2/common.uc"
if grep -Fq 'runtime.run("zapret2", ARGV)' "$ZAPRET2_RUNTIME"; then
  fail "providers/zapret2/runtime.uc must not carry the old hard-coded engine call"
fi
grep -Fq 'runtime.run(provider, ARGV)' "$ZAPRET2_RUNTIME" ||
  fail "providers/zapret2/runtime.uc must be the zapret2 entrypoint"
grep -Fq 'providers/zapret2/check.uc' "$ZAPRET2_COMMON" ||
  fail "providers/zapret2/common.uc must use its own check module"
grep -Fq 'providers.zapret2.validator' "$ZAPRET2_COMMON" ||
  fail "providers/zapret2/common.uc must use its own validator module"

status_json="$(PODKOP_CONFIG_NAME=podkop-plus-definitely-missing ucode -L "$PODKOP_LIB" "$ZAPRET_RUNTIME" status)"
JSON_VALUE="$status_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.configured !== false || value.enabled_rule_count !== 0 || typeof value.provider_path !== 'string') {
  console.error('zapret status shape mismatch');
  process.exit(1);
}
NODE

check_json="$(ucode -L "$PODKOP_LIB" "$ZAPRET2_RUNTIME" check)"
JSON_VALUE="$check_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (!Object.prototype.hasOwnProperty.call(value, 'zapret2_installed') ||
    !Object.prototype.hasOwnProperty.call(value, 'zapret2_package_installed') ||
    !Object.prototype.hasOwnProperty.call(value, 'zapret2_provider_path')) {
  console.error('zapret2 check shape mismatch');
  process.exit(1);
}
NODE

ucode -L "$PODKOP_LIB" "$ZAPRET2_VALIDATOR" validate-json nfqws2 '--name podkop --intercept=1' >/dev/null ||
  fail "providers/zapret2/validator.uc must validate nfqws2 strategies"
if ucode -L "$PODKOP_LIB" "$ZAPRET2_VALIDATOR" validate-json nfqws '--dpi-desync=fake' >/dev/null 2>&1; then
  fail "providers/zapret2/validator.uc must not validate nfqws strategies"
fi

printf 'table inet x { chain y { queue num 4301 bypass } }\n' |
  ucode -L "$PODKOP_LIB" "$ZAPRET2_CHECK" nft-queue-overlap PodkopPlusTable 4300 4555 >/dev/null ||
  fail "providers/zapret2/check.uc must own zapret2 queue overlap checks"

printf 'zapret runtime ownership regression checks passed\n'
