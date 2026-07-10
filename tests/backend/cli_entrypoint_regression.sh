#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_BIN="$ROOT_DIR/podkop/files/usr/bin/podkop"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ ! -e "$PODKOP_LIB/service/cli.uc" ] ||
  fail "service/cli.uc must be removed after /usr/bin ucode entrypoint takeover"
grep -Fq '#!/usr/bin/ucode' "$PODKOP_BIN" ||
  fail "podkop entrypoint must be a direct ucode executable"
if grep -Fq '#!/bin/sh' "$PODKOP_BIN" ||
  grep -Fq '#!/bin/ash' "$PODKOP_BIN" ||
  grep -Fq 'exec ucode' "$PODKOP_BIN"; then
  fail "podkop entrypoint must not keep a shell loader"
fi
if grep -Fq 'PODKOP_COMMAND' "$PODKOP_BIN" ||
  grep -Fq 'run_module()' "$PODKOP_BIN"; then
  fail "podkop entrypoint must not keep legacy shell routing symbols"
fi
grep -Fq 'function command_spec(command)' "$PODKOP_BIN" ||
  fail "podkop ucode entrypoint must own command routing"
grep -Fq 'function show_help()' "$PODKOP_BIN" ||
  fail "podkop ucode entrypoint must own help text"

fake_lib="$WORK_DIR/lib"
mkdir -p "$fake_lib/service" "$fake_lib/diagnostics" "$fake_lib/components" "$fake_lib/dns"

cat >"$fake_lib/diagnostics/runtime.uc" <<'UCODE'
#!/usr/bin/env ucode
print("diagnostics\t", ARGV[0], "\t", ARGV[1] || "", "\t", ARGV[2] || "", "\t", ARGV[3] || "", "\n");
UCODE

cat >"$fake_lib/components/updates.uc" <<'UCODE'
#!/usr/bin/env ucode
print("updates\t", ARGV[0], "\t", ARGV[1] || "", "\t", ARGV[2] || "", "\n");
UCODE

cat >"$fake_lib/components/action.uc" <<'UCODE'
#!/usr/bin/env ucode
print("action\t", ARGV[0], "\t", ARGV[1] || "", "\t", ARGV[2] || "", "\n");
UCODE

cat >"$fake_lib/dns/apply.uc" <<'UCODE'
#!/usr/bin/env ucode
let fs = require("fs");
let marker = getenv("PODKOP_TEST_DNS_RESTORE_MARKER");
if (marker != null && marker != "")
    fs.writefile(marker, ARGV[0] || "");
UCODE

show_version_out="$(PODKOP_LIB="$fake_lib" ucode "$PODKOP_BIN" show_version)"
[ "$show_version_out" = $'diagnostics\tshow-version\t\t\t' ] ||
  fail "show_version must dispatch through diagnostics/runtime.uc"

subscription_out="$(PODKOP_LIB="$fake_lib" ucode "$PODKOP_BIN" subscription_update proxy 2)"
[ "$subscription_out" = $'updates\tsubscription-update\tproxy\t2' ] ||
  fail "subscription_update must dispatch through components/updates.uc with arguments"

component_out="$(PODKOP_LIB="$fake_lib" ucode "$PODKOP_BIN" component_action sing_box update)"
[ "$component_out" = $'action\tcomponent-action\tsing_box\tupdate' ] ||
  fail "component_action must dispatch through components/action.uc with arguments"

component_check_cache_out="$(PODKOP_LIB="$fake_lib" ucode "$PODKOP_BIN" component_update_check_cache)"
[ "$component_check_cache_out" = $'updates\tcomponent-update-check-cache\t\t' ] ||
  fail "component_update_check_cache must dispatch through components/updates.uc"

component_updates_out="$(PODKOP_LIB="$fake_lib" ucode "$PODKOP_BIN" component_updates_if_due)"
[ "$component_updates_out" = $'updates\tcomponent-updates-if-due\t\t' ] ||
  fail "component_updates_if_due must dispatch through components/updates.uc"

rm -f "$fake_lib/service/lifecycle.uc"
set +e
PODKOP_TEST_DNS_RESTORE_MARKER="$WORK_DIR/dns-restore.marker" PODKOP_LIB="$fake_lib" \
  ucode "$PODKOP_BIN" start >/dev/null 2>"$WORK_DIR/missing.err"
status="$?"
set -e
[ "$status" -ne 0 ] ||
  fail "missing lifecycle module must fail"
[ "$(cat "$WORK_DIR/dns-restore.marker")" = "failsafe-restore" ] ||
  fail "missing lifecycle module must trigger dnsmasq failsafe restore"

printf 'CLI entrypoint regression checks passed\n'
