#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
WORK_DIR="$(mktemp -d)"
LEGACY_BRAND="$(printf '\160\157\144\153\157\160')"
LEGACY_BACKEND="${LEGACY_BRAND}-plus"
LEGACY_CONFIG_ALT="${LEGACY_BRAND}_plus"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -r "$INSTALLER" ] || fail "install.sh is missing"

grep -Fq 'run_with_deadline "$METADATA_TIMEOUT_SECONDS" wget -T "$CONNECT_TIMEOUT_SECONDS" -qO-' "$INSTALLER" ||
  fail "installer wget metadata requests must have portable connect and total timeouts"
grep -Fq 'run_with_deadline "$DOWNLOAD_TIMEOUT_SECONDS" wget -T "$CONNECT_TIMEOUT_SECONDS" -q -O' "$INSTALLER" ||
  fail "installer wget downloads must have portable connect and total timeouts"
if grep -n -E 'wget.*[[:space:]]-t([[:space:]]|$)' "$INSTALLER" >/dev/null; then
  fail "installer wget commands must not use the unsupported OpenWrt -t option"
fi
eval "$(sed -n '/^run_with_deadline()/,/^}/p' "$INSTALLER")"
deadline_started="$(date +%s)"
if run_with_deadline 1 sh -c 'sleep 5'; then
  fail "installer deadline watchdog must fail a command that exceeds its deadline"
fi
deadline_elapsed="$(($(date +%s) - deadline_started))"
[ "$deadline_elapsed" -lt 4 ] ||
  fail "installer deadline watchdog did not stop the command promptly"
run_with_deadline 3 sh -c 'exit 0' ||
  fail "installer deadline watchdog must preserve successful command status"
grep -Fq 'curl --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --max-time "$METADATA_TIMEOUT_SECONDS"' "$INSTALLER" ||
  fail "installer curl metadata requests must have connect and total timeouts"
grep -Fq 'curl --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --max-time "$DOWNLOAD_TIMEOUT_SECONDS"' "$INSTALLER" ||
  fail "installer curl downloads must have connect and total timeouts"

if grep -n -E '(^|[;&|[:space:]])uci[[:space:]]+-q|command_exists[[:space:]]+uci|/usr/bin/uci' "$INSTALLER" >/dev/null; then
  fail "install.sh must not own UCI reads/writes through shell"
fi

shell_sing_box_owner_symbols='REQUIRED_SING_BOX_VERSION|SING_BOX_EXTENDED_|SING_BOX_MANAGED_SERVICE_MARKER|remove_old_sing_box_if_needed|install_managed_sing_box_service_script|remove_managed_sing_box_service_script|disable_sing_box_service_config|prepare_sing_box_service_disabled|prepare_sing_box_package_service_install|stop_forkop_for_sing_box_install|pkg_install_sing_box_variant|pkg_install_name_downgrade|pkg_remove_sing_box_conflict|resolve_sing_box_extended_release|install_sing_box_extended_(package|binary)|restore_sing_box_after_failed|move_file_to_backup|validate_extended_sing_box_binary|archive-member-path|sing-box-extended-arch-suffix|sing-box-extended-asset-url|sing-box-extended-package-asset-url'
if grep -n -E "$shell_sing_box_owner_symbols" "$INSTALLER" >/dev/null; then
  fail "install.sh must not contain shell sing-box install/runtime ownership"
fi

grep -Fq 'ensure_bootstrap_package "ucode-mod-fs"' "$INSTALLER" ||
  fail "install.sh must bootstrap ucode-mod-fs before embedded ucode helper use"
grep -Fq 'ensure_bootstrap_package "ucode-mod-uci"' "$INSTALLER" ||
  fail "install.sh must bootstrap ucode-mod-uci before embedded UCI helper use"

grep -Fq '/usr/bin/forkop component_action sing_box "$action"' "$INSTALLER" ||
  fail "selected sing-box install must delegate to forkop component_action"
for action in install_stable install_extended install_extended_compressed; do
  grep -Fq "action=\"$action\"" "$INSTALLER" ||
    fail "selected sing-box installer is missing action mapping: $action"
done
grep -Fq 'sing_box_is_present' "$INSTALLER" ||
  fail "installer must detect an existing sing-box before showing the build choice"
grep -Fq 'singbox extended (если нужен xhttp)' "$INSTALLER" ||
  fail "extended sing-box choice must explain that it is needed for xhttp"
grep -Fq 'Русский пакет интерфейса будет установлен автоматически.' "$INSTALLER" ||
  fail "Russian LuCI language must enable the Russian interface package without a prompt"
if grep -n -E 'installer_text (sing_box_tiny|sing_box_extended_compressed)' "$INSTALLER" >/dev/null; then
  fail "fresh sing-box build choice must contain only stable and extended"
fi

grep -Fq 'run_args([ bin_path, "restore_dnsmasq" ])' "$INSTALLER" ||
  fail "installer dnsmasq restore must prefer the active backend entrypoint"
grep -Fq 'else if (mode == "dnsmasq-failsafe-restore")' "$INSTALLER" ||
  fail "dnsmasq restore fallback mode must remain available in embedded ucode helper"
grep -Fq 'else if (mode == "installer-cleanup-legacy")' "$INSTALLER" ||
  fail "installer cleanup must be exposed as an embedded ucode mode"
grep -Fq 'else if (mode == "installer-finalize-legacy")' "$INSTALLER" ||
  fail "installer legacy file cleanup must be exposed as an embedded ucode mode"
grep -Fq 'else if (mode == "installer-post-install")' "$INSTALLER" ||
  fail "installer post-install must be exposed as an embedded ucode mode"
grep -Fq 'install_json_ucode installer-cleanup-legacy' "$INSTALLER" ||
  fail "install.sh cleanup must delegate to embedded ucode"
grep -Fq 'install_json_ucode installer-post-install' "$INSTALLER" ||
  fail "install.sh post-install must delegate to embedded ucode"
if grep -Fq 'installer_config_migration_path()' "$INSTALLER"; then
  fail "install.sh must not embed configuration migration logic"
fi
grep -Fq 'ucode -L /usr/lib/forkop /usr/lib/forkop/config/migration.uc migrate-podkop' "$INSTALLER" ||
  fail "install.sh must delegate the legacy transition to the installed migration module"

if grep -n -E 'restore_forkop_dnsmasq_failsafe|remember_service_state|stop_conflicting_services|deactivate_original_forkop_if_present|remove_conflicting_dns_proxy|pkg_remove_if_installed|pkg_remove_matching_prefix|pkg_list_installed_names' "$INSTALLER" >/dev/null 2>&1; then
  fail "install.sh must not keep shell cleanup/remove service owners"
fi
if grep -n -E 'rm -f /var/luci-indexcache|rm -f /tmp/luci-indexcache|/etc/init\.d/rpcd[[:space:]]+reload|/etc/init\.d/forkop[[:space:]]+(start|stop|disable|enable|restart)|/etc/init\.d/forkop[[:space:]]+(stop|disable)' "$INSTALLER" >/dev/null 2>&1; then
  fail "install.sh shell must not own service/cache lifecycle actions"
fi

awk '
  /^[[:space:]]*main\(\)[[:space:]]*\{/ { in_main = 1 }
  in_main && /select_sing_box_installation/ { select_sing_box = NR }
  in_main && /decide_i18n_installation/ { i18n = NR }
  in_main && /pkg_list_update/ { update = NR }
  in_main && /ensure_bootstrap_ucode_runtime/ { ensure = NR }
  in_main && /detect_legacy_installation/ { detect = NR }
  in_main && /cleanup_legacy_installation/ { cleanup = NR }
  in_main && /install_backend_package/ { backend = NR }
  in_main && /migrate_legacy_configuration/ { migration = NR }
  in_main && /install_ui_packages/ { ui = NR }
  in_main && /install_selected_sing_box/ { sing_box = NR }
  in_main && /^[[:space:]]*\}/ { in_main = 0 }
  END {
    if (detect > 0 && i18n > detect && select_sing_box > i18n &&
        update > select_sing_box && ensure > update && cleanup > ensure &&
        backend > cleanup && migration > backend && ui > migration && sing_box > ui)
      exit 0
    exit 1
  }
' "$INSTALLER" || fail "install.sh must ask initial questions before package update, then migrate and finish installation in order"

helper="$WORK_DIR/install-json.uc"
awk '
  /cat > "\$helper_path" <<'\''EOF'\''/ { capture = 1; next }
  capture && /^EOF$/ { exit }
  capture { print }
' "$INSTALLER" > "$helper"
[ -s "$helper" ] || fail "failed to extract embedded installer ucode helper"

printf '%s\n' '{"tag_name":"0.0.1"}' | ucode "$helper" release-tag | grep -Fxq '0.0.1' ||
  fail "embedded helper release-tag mode must parse release JSON"
release_json='{"tag_name":"0.0.1","assets":[{"name":"forkop_0.0.1.ipk","browser_download_url":"https://example.com/forkop.ipk"}]}'
printf '%s' "$release_json" | ucode "$helper" release-asset-url backend ipk | grep -Fxq 'https://example.com/forkop.ipk' ||
  fail "embedded helper must resolve the exact three-part Forkop package name"
if printf '%s' '{"tag_name":"0.0.1","assets":[{"name":"forkop_0.0.1_all.ipk","browser_download_url":"https://example.com/old.ipk"}]}' |
  ucode "$helper" release-asset-url backend ipk | grep -q .; then
  fail "embedded helper must reject package names outside the Forkop release format"
fi

cat >"$WORK_DIR/opkg" <<'SH'
#!/usr/bin/env sh
case "$1" in
  list-installed)
    printf '%s\n' \
      'https-dns-proxy - 1.0' \
      'luci-app-https-dns-proxy - 1.0' \
      'luci-i18n-https-dns-proxy-ru - 1.0'
    if [ -n "${FORKOP_INSTALLER_FAKE_LEGACY_BACKEND:-}" ]; then
      printf '%s\n' \
        "$FORKOP_INSTALLER_FAKE_LEGACY_BACKEND - 1.0" \
        "luci-app-$FORKOP_INSTALLER_FAKE_LEGACY_BACKEND - 1.0" \
        "luci-i18n-$FORKOP_INSTALLER_FAKE_LEGACY_BACKEND-ru - 1.0"
    fi
    ;;
  remove)
    shift
    [ "$1" = "--force-depends" ] && shift
    printf '%s\n' "$1" >> "$FORKOP_INSTALLER_OPKG_LOG"
    [ "${FORKOP_INSTALLER_FAIL_REMOVE:-}" != "$1" ] || exit 1
    ;;
esac
exit 0
SH
chmod 0755 "$WORK_DIR/opkg"

: >"$WORK_DIR/opkg.log"
printf '%s\n' '1' |
  PATH="$WORK_DIR:$PATH" \
  FORKOP_INSTALLER_OPKG_LOG="$WORK_DIR/opkg.log" \
  FORKOP_INSTALLER_INIT="$WORK_DIR/missing-forkop-init" \
  FORKOP_INSTALLER_BIN="$WORK_DIR/missing-forkop-bin" \
  FORKOP_INSTALLER_LIB="$WORK_DIR/missing-forkop-lib" \
  FORKOP_INSTALLER_UCI_DEFAULTS="$WORK_DIR/missing-uci-defaults" \
  FORKOP_INSTALLER_LUCI_VIEW="$WORK_DIR/missing-luci-view" \
  FORKOP_INSTALLER_MENU_JSON="$WORK_DIR/missing-menu.json" \
  FORKOP_INSTALLER_ACL_JSON="$WORK_DIR/missing-acl.json" \
  FORKOP_INSTALLER_RU_LMO="$WORK_DIR/missing-ru.lmo" \
  FORKOP_INSTALLER_EN_LMO="$WORK_DIR/missing-en.lmo" \
  FORKOP_INSTALLER_RU_LUA="$WORK_DIR/missing-ru.lua" \
  FORKOP_INSTALLER_EN_LUA="$WORK_DIR/missing-en.lua" \
  FORKOP_INSTALLER_LEGACY_BASE_INIT="$WORK_DIR/missing-original-init" \
  FORKOP_INSTALLER_LEGACY_BRAND="$LEGACY_BRAND" \
  FORKOP_INSTALLER_LEGACY_BACKEND="$LEGACY_BACKEND" \
  FORKOP_UCI_STATE_FILE="$WORK_DIR/empty-uci.state" \
    ucode "$helper" installer-cleanup-legacy >"$WORK_DIR/conflict-state.env" 2>"$WORK_DIR/conflict.err"

grep -Fxq 'https-dns-proxy' "$WORK_DIR/opkg.log" ||
  fail "installer cleanup must remove confirmed https-dns-proxy conflict"
grep -Fxq 'luci-app-https-dns-proxy' "$WORK_DIR/opkg.log" ||
  fail "installer cleanup must remove confirmed https-dns-proxy LuCI package"
grep -Fxq 'luci-i18n-https-dns-proxy-ru' "$WORK_DIR/opkg.log" ||
  fail "installer cleanup must remove confirmed https-dns-proxy i18n packages"

write_fake_service_init() {
  service_path="$1"
  cat >"$service_path" <<'SH'
#!/usr/bin/env sh
case "$1" in
  enabled) exit 0 ;;
  status) printf '%s\n' running; exit 0 ;;
  stop|disable|enable|start|restart) printf '%s\n' "$1" >> "$FORKOP_INSTALLER_INIT_LOG"; exit 0 ;;
esac
exit 0
SH
  chmod 0755 "$service_path"
}

write_fake_service_init "$WORK_DIR/legacy-init"

cat >"$WORK_DIR/legacy-bin" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$FORKOP_INSTALLER_BIN_LOG"
case "$1" in
  get_status) printf '%s\n' '{"running":1}' ;;
esac
exit 0
SH
chmod 0755 "$WORK_DIR/legacy-bin"

: >"$WORK_DIR/init.log"
: >"$WORK_DIR/bin.log"
state="$WORK_DIR/state.env"
PATH="$WORK_DIR:$PATH" \
FORKOP_INSTALLER_INIT="$WORK_DIR/missing-forkop-init" \
FORKOP_INSTALLER_BIN="$WORK_DIR/missing-forkop-bin" \
FORKOP_INSTALLER_LIB="$WORK_DIR/missing-forkop-lib" \
FORKOP_INSTALLER_UCI_DEFAULTS="$WORK_DIR/uci-defaults" \
FORKOP_INSTALLER_LUCI_VIEW="$WORK_DIR/luci-view" \
FORKOP_INSTALLER_MENU_JSON="$WORK_DIR/menu.json" \
FORKOP_INSTALLER_ACL_JSON="$WORK_DIR/acl.json" \
FORKOP_INSTALLER_RU_LMO="$WORK_DIR/ru.lmo" \
FORKOP_INSTALLER_EN_LMO="$WORK_DIR/en.lmo" \
FORKOP_INSTALLER_RU_LUA="$WORK_DIR/ru.lua" \
FORKOP_INSTALLER_EN_LUA="$WORK_DIR/en.lua" \
FORKOP_INSTALLER_LEGACY_BASE_INIT="$WORK_DIR/missing-original-init" \
FORKOP_INSTALLER_LEGACY_BRAND="$LEGACY_BRAND" \
FORKOP_INSTALLER_LEGACY_BACKEND="$LEGACY_BACKEND" \
FORKOP_INSTALLER_LEGACY_CONFIG_ALT="$LEGACY_CONFIG_ALT" \
FORKOP_INSTALLER_LEGACY_INIT="$WORK_DIR/legacy-init" \
FORKOP_INSTALLER_LEGACY_BIN="$WORK_DIR/legacy-bin" \
FORKOP_INSTALLER_LEGACY_LIB="$WORK_DIR/legacy-lib" \
FORKOP_INSTALLER_FAKE_LEGACY_BACKEND="$LEGACY_BACKEND" \
FORKOP_INSTALLER_OPKG_LOG="$WORK_DIR/opkg.log" \
FORKOP_INSTALLER_INIT_LOG="$WORK_DIR/init.log" \
FORKOP_INSTALLER_BIN_LOG="$WORK_DIR/bin.log" \
FORKOP_UCI_STATE_FILE="$WORK_DIR/empty-uci.state" \
  ucode "$helper" installer-cleanup-legacy >"$state"

grep -Fxq 'FORKOP_WAS_ENABLED=1' "$state" ||
  fail "installer cleanup must export previous enabled state"
grep -Fxq 'FORKOP_WAS_RUNNING=1' "$state" ||
  fail "installer cleanup must export previous running state"
grep -Fxq 'FORKOP_LEGACY_DETECTED=1' "$state" ||
  fail "installer cleanup must report the legacy package transition"
grep -Fxq 'stop' "$WORK_DIR/init.log" ||
  fail "installer cleanup must stop the legacy service through ucode owner"
grep -Fxq 'disable' "$WORK_DIR/init.log" ||
  fail "installer cleanup must disable the legacy service through ucode owner"
grep -Fxq 'restore_dnsmasq' "$WORK_DIR/bin.log" ||
  fail "installer cleanup must prefer backend restore_dnsmasq"
grep -Fxq "$LEGACY_BACKEND" "$WORK_DIR/opkg.log" ||
  fail "installer cleanup must remove the legacy backend package"
grep -Fxq "luci-app-$LEGACY_BACKEND" "$WORK_DIR/opkg.log" ||
  fail "installer cleanup must remove the legacy LuCI package"

if printf '%s\n' '1' |
  PATH="$WORK_DIR:$PATH" \
  FORKOP_INSTALLER_OPKG_LOG="$WORK_DIR/opkg.log" \
  FORKOP_INSTALLER_FAIL_REMOVE="$LEGACY_BACKEND" \
  FORKOP_INSTALLER_FAKE_LEGACY_BACKEND="$LEGACY_BACKEND" \
  FORKOP_INSTALLER_LEGACY_BRAND="$LEGACY_BRAND" \
  FORKOP_INSTALLER_LEGACY_BACKEND="$LEGACY_BACKEND" \
  FORKOP_UCI_STATE_FILE="$WORK_DIR/empty-uci.state" \
    ucode "$helper" installer-cleanup-legacy >/dev/null 2>&1; then
  fail "installer cleanup must stop when the package manager cannot remove the legacy backend"
fi

legacy_config="$WORK_DIR/legacy-config"
legacy_config_alt="$WORK_DIR/legacy-config-alt"
legacy_persistent="$WORK_DIR/legacy-persistent"
forkop_persistent="$WORK_DIR/forkop-persistent"
legacy_runtime="$WORK_DIR/legacy-runtime"
legacy_tmp="$WORK_DIR/legacy-tmp"
legacy_tmp_alt="$WORK_DIR/legacy-tmp-alt"
legacy_base_config="$WORK_DIR/legacy-base-config"
legacy_base_persistent="$WORK_DIR/legacy-base-persistent"
legacy_base_runtime="$WORK_DIR/legacy-base-runtime"
legacy_base_tmp="$WORK_DIR/legacy-base-tmp"
legacy_base_init="$WORK_DIR/legacy-base-init"
legacy_base_bin="$WORK_DIR/legacy-base-bin"
legacy_base_lib="$WORK_DIR/legacy-base-lib"
legacy_base_uci_defaults="$WORK_DIR/legacy-base-uci-defaults"
legacy_base_luci_view="$WORK_DIR/legacy-base-luci-view"
legacy_base_menu="$WORK_DIR/legacy-base-menu"
legacy_base_acl="$WORK_DIR/legacy-base-acl"
legacy_base_i18n="$WORK_DIR/legacy-base-i18n"
legacy_tmp_package="$WORK_DIR/luci-app-${LEGACY_BRAND}.ipk"
legacy_scan_root="$WORK_DIR/legacy-scan-root"
legacy_nested_uci="$legacy_scan_root/.uci/${LEGACY_BACKEND}"
legacy_nested_lock="$legacy_scan_root/lock/procd_${LEGACY_BACKEND}.lock"
legacy_nested_backup="$legacy_scan_root/audit/${LEGACY_BACKEND}.config"
mkdir -p \
  "$legacy_persistent/tailscale/server-new" \
  "$legacy_persistent/tailscale/server-existing" \
  "$forkop_persistent/tailscale/server-existing" \
  "$legacy_runtime" "$legacy_tmp" "$legacy_tmp_alt"
printf '%s\n' 'legacy-node-identity' >"$legacy_persistent/tailscale/server-new/node.key"
printf '%s\n' 'stale-legacy-identity' >"$legacy_persistent/tailscale/server-existing/node.key"
printf '%s\n' 'current-forkop-identity' >"$forkop_persistent/tailscale/server-existing/node.key"
mkdir -p "$(dirname "$legacy_nested_uci")" "$(dirname "$legacy_nested_lock")" "$(dirname "$legacy_nested_backup")"
touch "$legacy_config" "$legacy_config_alt" "$legacy_config-opkg"
touch \
  "$legacy_base_config.backup" \
  "$legacy_base_persistent.cache" \
  "$legacy_base_runtime.internal" \
  "$legacy_base_tmp.log" \
  "$legacy_base_init.old" \
  "$legacy_base_bin.bak" \
  "$legacy_base_lib.prev" \
  "$legacy_base_uci_defaults.done" \
  "$legacy_base_luci_view.old" \
  "$legacy_base_menu.json" \
  "$legacy_base_acl.json" \
  "$legacy_base_i18n.ru.lmo" \
  "$legacy_tmp_package" \
  "$legacy_nested_uci" \
  "$legacy_nested_lock" \
  "$legacy_nested_backup"
FORKOP_INSTALLER_LEGACY_BRAND="$LEGACY_BRAND" \
FORKOP_INSTALLER_LEGACY_BACKEND="$LEGACY_BACKEND" \
FORKOP_INSTALLER_LEGACY_CONFIG_ALT="$LEGACY_CONFIG_ALT" \
FORKOP_INSTALLER_LEGACY_CONFIG="$legacy_config" \
FORKOP_INSTALLER_LEGACY_CONFIG_FILE_ALT="$legacy_config_alt" \
FORKOP_INSTALLER_LEGACY_PERSISTENT_DIR="$legacy_persistent" \
FORKOP_INSTALLER_PERSISTENT_DIR="$forkop_persistent" \
FORKOP_INSTALLER_LEGACY_RUNTIME_DIR="$legacy_runtime" \
FORKOP_INSTALLER_LEGACY_TMP_DIR="$legacy_tmp" \
FORKOP_INSTALLER_LEGACY_TMP_ALT_DIR="$legacy_tmp_alt" \
FORKOP_INSTALLER_LEGACY_BASE_CONFIG="$legacy_base_config" \
FORKOP_INSTALLER_LEGACY_BASE_PERSISTENT_DIR="$legacy_base_persistent" \
FORKOP_INSTALLER_LEGACY_BASE_RUNTIME_DIR="$legacy_base_runtime" \
FORKOP_INSTALLER_LEGACY_BASE_TMP_DIR="$legacy_base_tmp" \
FORKOP_INSTALLER_LEGACY_BASE_INIT="$legacy_base_init" \
FORKOP_INSTALLER_LEGACY_BASE_BIN="$legacy_base_bin" \
FORKOP_INSTALLER_LEGACY_BASE_LIB="$legacy_base_lib" \
FORKOP_INSTALLER_LEGACY_BASE_UCI_DEFAULTS="$legacy_base_uci_defaults" \
FORKOP_INSTALLER_LEGACY_BASE_LUCI_VIEW="$legacy_base_luci_view" \
FORKOP_INSTALLER_LEGACY_BASE_MENU_JSON="$legacy_base_menu" \
FORKOP_INSTALLER_LEGACY_BASE_ACL_JSON="$legacy_base_acl" \
FORKOP_INSTALLER_LEGACY_BASE_I18N="$legacy_base_i18n" \
FORKOP_INSTALLER_LEGACY_TMP_PACKAGE_GLOB="$WORK_DIR/*${LEGACY_BRAND}*" \
FORKOP_INSTALLER_LEGACY_SCAN_ROOTS="$legacy_scan_root" \
  ucode "$helper" installer-finalize-legacy
[ "$(cat "$forkop_persistent/tailscale/server-new/node.key")" = 'legacy-node-identity' ] ||
  fail "installer finalization must migrate legacy Tailscale node identity"
[ "$(cat "$forkop_persistent/tailscale/server-existing/node.key")" = 'current-forkop-identity' ] ||
  fail "installer finalization must not overwrite existing Forkop Tailscale state"
for path in "$legacy_config" "$legacy_config_alt" "$legacy_config-opkg" \
  "$legacy_persistent" "$legacy_runtime" "$legacy_tmp" "$legacy_tmp_alt" \
  "$legacy_base_config.backup" "$legacy_base_persistent.cache" \
  "$legacy_base_runtime.internal" "$legacy_base_tmp.log" \
  "$legacy_base_init.old" "$legacy_base_bin.bak" "$legacy_base_lib.prev" \
  "$legacy_base_uci_defaults.done" "$legacy_base_luci_view.old" \
  "$legacy_base_menu.json" "$legacy_base_acl.json" "$legacy_base_i18n.ru.lmo" \
  "$legacy_tmp_package" "$legacy_nested_uci" "$legacy_nested_lock" \
  "$legacy_nested_backup"; do
  [ ! -e "$path" ] || fail "installer finalization left a legacy path behind: $path"
done

mkdir -p "$legacy_persistent/tailscale/server-failed"
printf '%s\n' 'preserve-on-failure' >"$legacy_persistent/tailscale/server-failed/node.key"
forkop_persistent_file="$WORK_DIR/forkop-persistent-file"
touch "$forkop_persistent_file"
if FORKOP_INSTALLER_LEGACY_BRAND="$LEGACY_BRAND" \
  FORKOP_INSTALLER_LEGACY_BACKEND="$LEGACY_BACKEND" \
  FORKOP_INSTALLER_LEGACY_CONFIG_ALT="$LEGACY_CONFIG_ALT" \
  FORKOP_INSTALLER_LEGACY_CONFIG="$legacy_config" \
  FORKOP_INSTALLER_LEGACY_CONFIG_FILE_ALT="$legacy_config_alt" \
  FORKOP_INSTALLER_LEGACY_PERSISTENT_DIR="$legacy_persistent" \
  FORKOP_INSTALLER_PERSISTENT_DIR="$forkop_persistent_file" \
  FORKOP_INSTALLER_LEGACY_RUNTIME_DIR="$legacy_runtime" \
  FORKOP_INSTALLER_LEGACY_TMP_DIR="$legacy_tmp" \
  FORKOP_INSTALLER_LEGACY_TMP_ALT_DIR="$legacy_tmp_alt" \
  FORKOP_INSTALLER_LEGACY_BASE_CONFIG="$legacy_base_config" \
  FORKOP_INSTALLER_LEGACY_BASE_PERSISTENT_DIR="$legacy_base_persistent" \
  FORKOP_INSTALLER_LEGACY_BASE_RUNTIME_DIR="$legacy_base_runtime" \
  FORKOP_INSTALLER_LEGACY_BASE_TMP_DIR="$legacy_base_tmp" \
  FORKOP_INSTALLER_LEGACY_BASE_INIT="$legacy_base_init" \
  FORKOP_INSTALLER_LEGACY_BASE_BIN="$legacy_base_bin" \
  FORKOP_INSTALLER_LEGACY_BASE_LIB="$legacy_base_lib" \
  FORKOP_INSTALLER_LEGACY_BASE_UCI_DEFAULTS="$legacy_base_uci_defaults" \
  FORKOP_INSTALLER_LEGACY_BASE_LUCI_VIEW="$legacy_base_luci_view" \
  FORKOP_INSTALLER_LEGACY_BASE_MENU_JSON="$legacy_base_menu" \
  FORKOP_INSTALLER_LEGACY_BASE_ACL_JSON="$legacy_base_acl" \
  FORKOP_INSTALLER_LEGACY_BASE_I18N="$legacy_base_i18n" \
  FORKOP_INSTALLER_LEGACY_TMP_PACKAGE_GLOB="$WORK_DIR/missing-${LEGACY_BRAND}*" \
  FORKOP_INSTALLER_LEGACY_SCAN_ROOTS="$legacy_scan_root" \
    ucode "$helper" installer-finalize-legacy >/dev/null 2>&1; then
  fail "installer finalization must fail when legacy Tailscale state cannot be migrated"
fi
[ "$(cat "$legacy_persistent/tailscale/server-failed/node.key")" = 'preserve-on-failure' ] ||
  fail "failed Tailscale migration must preserve the legacy identity"

write_fake_service_init "$WORK_DIR/forkop-init"
touch "$WORK_DIR/luci-indexcache.one" "$WORK_DIR/luci-indexcache.two"
: >"$WORK_DIR/init.log"
FORKOP_INSTALLER_INIT="$WORK_DIR/forkop-init" \
FORKOP_INSTALLER_RPCD_INIT="$WORK_DIR/missing-rpcd" \
FORKOP_INSTALLER_LUCI_CACHE_GLOBS="$WORK_DIR/luci-indexcache*" \
FORKOP_INSTALLER_LATEST_VERSION_CACHE="$WORK_DIR/latest.cache" \
FORKOP_INSTALLER_SYSTEM_INFO_CACHE="$WORK_DIR/system-info.json" \
FORKOP_INSTALLER_SERVER_COUNTRY_CACHE="$WORK_DIR/server-country.json" \
FORKOP_INSTALLER_SING_BOX_VERSION_CACHE="$WORK_DIR/sing-box-version" \
FORKOP_INSTALLER_TMP_SYSTEM_INFO_CACHE="$WORK_DIR/tmp-system-info.json" \
FORKOP_WAS_ENABLED=1 \
FORKOP_WAS_RUNNING=1 \
FORKOP_INSTALLER_INIT_LOG="$WORK_DIR/init.log" \
  ucode "$helper" installer-post-install

if compgen -G "$WORK_DIR/luci-indexcache*" >/dev/null; then
  fail "installer post-install must clear LuCI caches through ucode owner"
fi
grep -Fxq 'enable' "$WORK_DIR/init.log" ||
  fail "installer post-install must restore enabled state through ucode owner"
grep -Fxq 'start' "$WORK_DIR/init.log" ||
  fail "installer post-install must restore running state through ucode owner"

printf 'installer ownership checks passed\n'
