#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_BIN="$ROOT_DIR/forkop/files/usr/bin/forkop"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
CLI_UC="$FORKOP_BIN"
HELPERS_SH="$FORKOP_LIB/helpers.sh"
LIFECYCLE_UC="$FORKOP_LIB/service/lifecycle.uc"
PACKAGES_UC="$FORKOP_LIB/core/packages.uc"
RULES_UC="$FORKOP_LIB/providers/rules.uc"
SINGBOX_RUNTIME_UC="$FORKOP_LIB/singbox/runtime.uc"
COMPONENT_ACTION_UC="$FORKOP_LIB/components/action.uc"
DIAGNOSTICS_RUNTIME_UC="$FORKOP_LIB/diagnostics/runtime.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ ! -e "$HELPERS_SH" ] ||
  fail "helpers.sh shell owner must be removed"
if grep -R -n -F 'helpers.sh' "$FORKOP_BIN" "$FORKOP_LIB" --include='*.sh' >/dev/null 2>&1; then
  fail "runtime shell must not reference helpers.sh"
fi
if grep -R -n -E 'helpers_ucode\(|get_(inbound|server_inbound|tailscale_dns_server|outbound)_tag_by_section\(|get_domain_resolver_tag\(|provider_status_ucode\(|is_ipv4\(|is_min_package_version\(|url_get_(scheme|userinfo|host|port|path|query_param)\(' \
  "$FORKOP_BIN" "$FORKOP_LIB" --include='*.sh' >/dev/null 2>&1; then
  fail "helpers.sh wrapper symbols must not remain in runtime shell"
fi

grep -Fq '#!/usr/bin/ucode' "$FORKOP_BIN" ||
  fail "forkop entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch lifecycle through service/lifecycle.uc"
grep -Fq 'core/packages.uc' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must use core/packages.uc directly"
for shell_owner_pattern in \
  'config_load' \
  'config_get' \
  'uci_set'
do
  if grep -Fq "$shell_owner_pattern" "$FORKOP_BIN"; then
    fail "forkop shell entrypoint must not own $shell_owner_pattern logic"
  fi
done
if grep -E -n '(^|[;&|[:space:]])nft[[:space:]]+(list|add|delete|flush)' "$FORKOP_BIN" >/dev/null 2>&1; then
  fail "forkop shell entrypoint must not own nft command logic"
fi
if grep -E -n '(^|[;&|[:space:]])ip[[:space:]]+(rule|route)' "$FORKOP_BIN" >/dev/null 2>&1; then
  fail "forkop shell entrypoint must not own ip rule/route logic"
fi
[ ! -e "$FORKOP_LIB/updater.sh" ] ||
  fail "updater.sh shell owner must be removed"
[ ! -e "$FORKOP_LIB/status_diagnostics.sh" ] ||
  fail "status_diagnostics.sh shell owner must be removed"
grep -Fq 'diagnostics/runtime.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch diagnostics through diagnostics/runtime.uc"
grep -Fq 'mode == "get-system-info"' "$DIAGNOSTICS_RUNTIME_UC" ||
  fail "diagnostics/runtime.uc must own system info"
grep -Fq 'core/packages.uc' "$COMPONENT_ACTION_UC" ||
  fail "component action owner must use core/packages.uc directly"
grep -Fq 'count-uci' "$RULES_UC" ||
  fail "providers/rules.uc must own UCI rule counting"
for mode in \
  'mode == "version"' \
  'mode == "version-output"' \
  'mode == "version-from-output"' \
  'mode == "read-version-state"' \
  'mode == "write-version-state"' \
  'mode == "restore-version-state"' \
  'mode == "read-variant-marker"' \
  'mode == "write-variant-marker"' \
  'mode == "restore-variant-marker"' \
  'mode == "is-extended"' \
  'mode == "is-tiny"' \
  'mode == "supports-tailscale"' \
  'mode == "variant"'
do
  grep -Fq "$mode" "$SINGBOX_RUNTIME_UC" ||
    fail "singbox/runtime.uc missing $mode"
done
if grep -R -n -E 'get_sing_box_version\(|sing_box_version_from_output\(|sing_box_version_output\(|sing_box_output_has_build_tag\(|sing_box_has_build_tag\(|is_sing_box_extended\(|is_sing_box_tiny_package_installed\(|is_sing_box_full_package_installed\(|is_sing_box_compressed_marker_set\(|is_sing_box_extended_marker_set\(|read_sing_box_version_state\(|is_sing_box_tiny_marker_set\(|is_sing_box_tiny\(|sing_box_supports_tailscale\(|get_sing_box_variant\(|updates_(write|read|clear|restore)_sing_box_(variant_marker|version_state)\(' \
  "$FORKOP_BIN" "$FORKOP_LIB" --include='*.sh' >/dev/null 2>&1; then
  fail "sing-box helper/state shell symbols must not remain"
fi

if ucode -L "$FORKOP_LIB" "$PACKAGES_UC" installed forkop-definitely-missing >/dev/null 2>&1; then
  fail "missing package must not be reported installed"
fi

mkdir -p "$WORK_DIR/apk-bin"
cat >"$WORK_DIR/apk-bin/apk" <<'SH'
#!/usr/bin/env sh
if [ "$1 $2 $3 $4" = "list --available --manifest sing-box" ]; then
  printf '%s\n' \
    'P:sing-box-extended' \
    'V:9.9.9-r1' \
    'p:sing-box' \
    'P:sing-box' \
    'V:1.2.3-r1'
  exit 0
fi
exit 1
SH
chmod +x "$WORK_DIR/apk-bin/apk"
[ "$(PATH="$WORK_DIR/apk-bin:$PATH" ucode -L "$FORKOP_LIB" "$PACKAGES_UC" apk-available-version sing-box)" = "1.2.3-r1" ] ||
  fail "APK available version lookup must select the exact package name, not a higher-priority provider"

mark_hex="$(ucode -L "$FORKOP_LIB" "$RULES_UC" mark-hex 0x01000000 2)"
[ "$mark_hex" = "0x01000002" ] ||
  fail "providers/rules.uc mark math changed"

version="$(printf 'sing-box version 1.12.4-extended\nEnvironment: test\n' |
  ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" version-from-output)"
[ "$version" = "1.12.4-extended" ] ||
  fail "singbox/runtime.uc version-from-output changed"

ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" is-extended "1.12.4-extended" >/dev/null ||
  fail "extended sing-box version should be detected"
if ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" is-extended "1.12.4" >/dev/null 2>&1; then
  fail "stable sing-box version must not be detected as extended"
fi
ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" supports-tailscale "" "$(printf 'Tags: with_quic,with_tailscale\n')" >/dev/null ||
  fail "with_tailscale build tag should be detected"

SB_VERSION_STATE_FILE="$WORK_DIR/version" \
  ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" write-version-state 1.2.3 >/dev/null ||
  fail "version state write failed"
[ "$(SB_VERSION_STATE_FILE="$WORK_DIR/version" ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" read-version-state)" = "1.2.3" ] ||
  fail "version state read failed"
SB_VERSION_STATE_FILE="$WORK_DIR/version" \
  ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" restore-version-state "" >/dev/null ||
  fail "version state restore-clear failed"
[ ! -e "$WORK_DIR/version" ] ||
  fail "empty version state restore must clear the state file"

SB_VARIANT_STATE_FILE="$WORK_DIR/variant" \
  ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" write-variant-marker extended-compressed >/dev/null ||
  fail "variant marker write failed"
SB_VARIANT_STATE_FILE="$WORK_DIR/variant" \
  ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" marker-is extended-compressed >/dev/null ||
  fail "variant marker check failed"
[ "$(SB_VARIANT_STATE_FILE="$WORK_DIR/variant" ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" read-variant-marker)" = "extended-compressed" ] ||
  fail "variant marker read failed"
SB_VARIANT_STATE_FILE="$WORK_DIR/variant" \
  ucode -L "$FORKOP_LIB" "$SINGBOX_RUNTIME_UC" restore-variant-marker "" >/dev/null ||
  fail "variant marker restore-clear failed"
[ ! -e "$WORK_DIR/variant" ] ||
  fail "empty variant marker restore must clear the marker file"

printf 'helpers ownership checks passed\n'
