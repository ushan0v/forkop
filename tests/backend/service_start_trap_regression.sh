#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_BIN="$ROOT_DIR/podkop/files/usr/bin/podkop"
PODKOP_INIT="$ROOT_DIR/podkop/files/etc/init.d/podkop"
CLI_UC="$PODKOP_BIN"
LIFECYCLE_UC="$ROOT_DIR/podkop/files/usr/lib/service/lifecycle.uc"
INITD_UC="$ROOT_DIR/podkop/files/usr/lib/service/initd.uc"
STATE_UC="$ROOT_DIR/podkop/files/usr/lib/service/state.uc"
UI_UC="$ROOT_DIR/podkop/files/usr/lib/service/ui.uc"
UPDATES_UC="$ROOT_DIR/podkop/files/usr/lib/components/updates.uc"
SUBSCRIPTION_CACHE_UC="$ROOT_DIR/podkop/files/usr/lib/subscription/cache.uc"
NFQUEUE_RUNTIME_UC="$ROOT_DIR/podkop/files/usr/lib/providers/nfqueue/runtime.uc"
BYEDPI_RUNTIME_UC="$ROOT_DIR/podkop/files/usr/lib/providers/byedpi/runtime.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_pattern() {
  local pattern="$1"
  local label="$2"

  grep -Fq "$pattern" "$LIFECYCLE_UC" || fail "$label"
}

reject_pattern() {
  local pattern="$1"
  local label="$2"

  ! grep -Fq "$pattern" "$PODKOP_BIN" || fail "$label"
}

require_file_pattern() {
  local file="$1"
  local pattern="$2"
  local label="$3"

  grep -Fq "$pattern" "$file" || fail "$label"
}

[ -r "$PODKOP_BIN" ] || fail "podkop binary source is missing"
[ -r "$PODKOP_BIN" ] || fail "podkop entrypoint is missing"
[ -r "$LIFECYCLE_UC" ] || fail "service/lifecycle.uc is missing"

grep -Fq '#!/usr/bin/ucode' "$PODKOP_BIN" ||
  fail "podkop entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch startup through service/lifecycle.uc"
reject_pattern "trap " \
  "podkop shell entrypoint must not own startup fail-safe traps"
reject_pattern "clear_startup_failsafe_trap" \
  "podkop shell entrypoint must not keep old trap helper"
require_pattern 'module_background(UPDATES_UC, [ "list-update" ])' \
  "startup list_update background job must be owned by service/lifecycle.uc"
require_pattern 'module_background(DIAGNOSTICS_UC, [ "get-system-info" ])' \
  "startup system-info background job must be owned by service/lifecycle.uc"
require_pattern 'startup_config_fingerprint = external_config_fingerprint();' \
  "startup must snapshot runtime-relevant config after validation"
require_pattern 'mark_pending_reload_if_config_changed(startup_config_fingerprint, "config_changed_during_start")' \
  "startup must queue reload when config changes while service is starting"
require_pattern 'pending_reload_log_context(reason)' \
  "startup queued reload must be visible in logs"
require_pattern 'return "current reload";' \
  "reload-time queued reload must be distinguishable in logs"
require_file_pattern "$LIFECYCLE_UC" '>/dev/null 2>&1 1000>&- &' \
  "service/lifecycle.uc background modules must close inherited procd lock fd"
require_file_pattern "$INITD_UC" 'reload pending >/dev/null 2>&1 1000>&- &' \
  "service/initd.uc pending reload worker must close inherited procd lock fd"
require_file_pattern "$STATE_UC" 'reload pending >/dev/null 2>&1 1000>&- &' \
  "service/state.uc pending reload worker must close inherited procd lock fd"
require_file_pattern "$PODKOP_INIT" 'PODKOP_LAST_START_STATUS="$?"' \
  "init.d start_service must preserve backend start status for rc.common"
require_file_pattern "$PODKOP_INIT" 'service_started()' \
  "init.d must return preserved start status through rc.common service_started hook"
require_file_pattern "$UI_UC" '>/dev/null 2>&1 1000>&- & echo $!' \
  "service/ui.uc service action workers must close inherited procd lock fd"
require_file_pattern "$UPDATES_UC" '>/dev/null 2>&1 1000>&- & echo $!' \
  "components/updates.uc async workers must close inherited procd lock fd"
require_file_pattern "$SUBSCRIPTION_CACHE_UC" '>/dev/null 2>&1 1000>&- & echo $!' \
  "subscription/cache.uc retry worker must close inherited procd lock fd"
require_file_pattern "$NFQUEUE_RUNTIME_UC" '>>" + shell_quote(logfile) + " 2>&1 1000>&- & echo $!' \
  "nfqueue provider supervisors must close inherited procd lock fd"
require_file_pattern "$BYEDPI_RUNTIME_UC" '>>" + shell_quote(logfile) + " 2>&1 1000>&- & echo $!' \
  "byedpi supervisor must close inherited procd lock fd"
awk '
  /function cleanup_failed_runtime\(\)/ { in_cleanup = 1 }
  in_cleanup && /stop_main\(\);/ { saw_stop = 1 }
  in_cleanup && /dnsmasq_restore_fail_safe\(\);/ && saw_stop { saw_dns = 1 }
  in_cleanup && /mark_runtime_stopped_clean\(\);/ && saw_dns { ok = 1; exit }
  in_cleanup && /^}/ { exit }
  END { exit ok ? 0 : 1 }
' "$LIFECYCLE_UC" ||
  fail "failed runtime cleanup must stop partial runtime, roll back DNS, and mark clean shutdown"
grep -Fq 'cleanup_failed_runtime();' "$LIFECYCLE_UC" ||
  fail "service failure paths must use failed runtime cleanup"
require_pattern "tproxy-marking-rule4-present" \
  "service stop must use direct ucode IPv4 tproxy marking rule check"
require_pattern "tproxy-marking-rule6-present" \
  "service stop must use direct ucode IPv6 tproxy marking rule check"
require_pattern "tproxy-route4-present" \
  "service stop must use direct ucode IPv4 tproxy route check"
require_pattern "tproxy-route6-present" \
  "service stop must use direct ucode IPv6 tproxy route check"
grep -Fq 'require("core.uci")' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must use core.uci for lifecycle UCI state"
if grep -n -E 'uci -q|require\("uci"\)\.cursor|function uci_|uci_set\(' "$LIFECYCLE_UC" >/dev/null 2>&1; then
  fail "service/lifecycle.uc must not own direct UCI CLI/cursor helpers"
fi
reject_pattern "tproxy_marking_rule_present" \
  "service stop must not call the removed shell tproxy marking helper"
reject_pattern "tproxy_route_present" \
  "service stop must not call the removed shell tproxy route helper"
reject_pattern "has_tproxy_marking_rule" \
  "service stop must not call the removed shell tproxy marking helper"
reject_pattern "has_tproxy_route" \
  "service stop must not call the removed shell tproxy route helper"

printf 'service start trap regression checks passed\n'
