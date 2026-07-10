#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_BIN="$ROOT_DIR/podkop/files/usr/bin/podkop"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
CLI_UC="$PODKOP_BIN"
BYEDPI_RUNTIME_SH="$PODKOP_LIB/byedpi.sh"
LIFECYCLE_UC="$PODKOP_LIB/service/lifecycle.uc"
BYEDPI_RUNTIME_UC="$PODKOP_LIB/providers/byedpi/runtime.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ ! -e "$BYEDPI_RUNTIME_SH" ] ||
  fail "byedpi.sh shell owner must be removed"

grep -Fq '#!/usr/bin/ucode' "$PODKOP_BIN" ||
  fail "podkop entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch lifecycle orchestration through service/lifecycle.uc"
grep -Fq 'providers/byedpi/runtime.uc' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must call providers/byedpi/runtime.uc for ByeDPI runtime operations"

if grep -R -n -E 'start_byedpi_runtime|stop_byedpi_runtime|get_byedpi_status_json|check_byedpi_runtime_json|is_byedpi_installed|get_byedpi_package_version|get_byedpi_rule_|run_byedpi_supervisor' \
  "$PODKOP_BIN" "$PODKOP_LIB" --include='*.sh' >/dev/null 2>&1; then
  fail "ByeDPI runtime shell symbols must not remain"
fi
if grep -n -E 'require\("uci"\)\.cursor|uci -q|"uci", "-q"' "$BYEDPI_RUNTIME_UC" >/dev/null 2>&1; then
  fail "providers/byedpi/runtime.uc must use core.uci instead of direct UCI cursor or CLI access"
fi
grep -Fq 'require("core.uci")' "$BYEDPI_RUNTIME_UC" ||
  fail "providers/byedpi/runtime.uc must use core.uci for runtime UCI access"
grep -Fq 'require("singbox.constants")' "$BYEDPI_RUNTIME_UC" ||
  fail "providers/byedpi/runtime.uc must share the sing-box runtime tag allocator"
grep -Fq 'runtime_constants.tag(base, postfix)' "$BYEDPI_RUNTIME_UC" ||
  fail "providers/byedpi/runtime.uc must allocate section tags through singbox.constants"

grep -Fq 'mode == "start-runtime"' "$BYEDPI_RUNTIME_UC" ||
  fail "providers/byedpi/runtime.uc must own ByeDPI start"
grep -Fq 'mode == "stop-runtime"' "$BYEDPI_RUNTIME_UC" ||
  fail "providers/byedpi/runtime.uc must own ByeDPI stop"
grep -Fq 'mode == "status"' "$BYEDPI_RUNTIME_UC" ||
  fail "providers/byedpi/runtime.uc must own ByeDPI status"
grep -Fq 'mode == "check"' "$BYEDPI_RUNTIME_UC" ||
  fail "providers/byedpi/runtime.uc must own ByeDPI check"

BYEDPI_BIN="$ROOT_DIR/tests/missing-ciadpi" \
  ucode -L "$PODKOP_LIB" "$BYEDPI_RUNTIME_UC" check |
  node -e '
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(0, "utf8"));
if (value.byedpi_installed !== false || value.byedpi_package_installed !== false) {
  console.error("unexpected ByeDPI check JSON");
  process.exit(1);
}
'

printf 'ByeDPI runtime ownership regression checks passed\n'
