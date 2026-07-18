#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_BIN="$ROOT_DIR/forkop/files/usr/bin/forkop"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
PACKAGE_UC="$FORKOP_LIB/service/package.uc"
FORKOP_MAKEFILE="$ROOT_DIR/forkop/Makefile"
LUCI_UCI_DEFAULTS="$ROOT_DIR/luci-app-forkop/root/etc/uci-defaults/50_luci-forkop"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
WORK_DIR="$(mktemp -d)"
export FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -r "$PACKAGE_UC" ] ||
  fail "service/package.uc must own package lifecycle logic"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"' "$PACKAGE_UC" >/dev/null 2>&1; then
  fail "service/package.uc must use core.uci instead of direct UCI cursor or CLI access"
fi
grep -Fq 'require("core.uci")' "$PACKAGE_UC" ||
  fail "service/package.uc must import core.uci"
grep -Fq 'package_prerm: [ "service/package.uc", "prerm", 1 ]' "$FORKOP_BIN" ||
  fail "forkop entrypoint must dispatch package prerm cleanup through service/package.uc"
grep -Fq 'package_postinst: [ "service/package.uc", "postinst", 0 ]' "$FORKOP_BIN" ||
  fail "forkop entrypoint must dispatch package postinst recovery through service/package.uc"
grep -Fq 'luci_postinst: [ "service/package.uc", "luci-postinst", 0 ]' "$FORKOP_BIN" ||
  fail "forkop entrypoint must dispatch LuCI postinstall cleanup through service/package.uc"
grep -Fq '#!/bin/sh' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must remain a shell script because OpenWrt default_postinst runs it through shell"
grep -Fq '/usr/bin/forkop luci_postinst' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must delegate cache/rpcd handling to ucode"
if grep -E 'rm -f /var/luci-indexcache|rm -f /tmp/luci-indexcache|logger -t "forkop"' "$LUCI_UCI_DEFAULTS" >/dev/null; then
  fail "LuCI uci-defaults must not own cache/logger shell logic"
fi

if grep -n -E 'grep -q "105 forkop"|sed -i "/105 forkop|forkop_dont_touch_dhcp=.*uci|cp /etc/config/forkop|rm -f /tmp/luci-indexcache|killall -HUP rpcd' "$FORKOP_MAKEFILE" "$BUILD_SCRIPT" >/dev/null; then
  fail "package scripts must not keep backend/LuCI lifecycle business logic in shell"
fi
grep -Fq '#!/usr/bin/ucode' "$FORKOP_MAKEFILE" ||
  fail "forkop Makefile package hooks must use ucode entrypoints"
grep -Fq '/usr/bin/forkop package_prerm' "$FORKOP_MAKEFILE" ||
  fail "forkop Makefile prerm must delegate cleanup to package_prerm"
grep -Fq '/usr/bin/forkop package_postinst' "$FORKOP_MAKEFILE" ||
  fail "forkop Makefile postinst must restore a service that was running before upgrade"
grep -Fq '/usr/bin/forkop package_prerm upgrade' "$BUILD_SCRIPT" ||
  fail "manual APK pre-upgrade must record and stop the running service"
grep -Fq '/usr/bin/forkop package_postinst' "$BUILD_SCRIPT" ||
  fail "manual packages must restore a service that was running before upgrade"
if grep -Fq '/usr/bin/forkop luci_postinst' "$BUILD_SCRIPT"; then
  fail "manual package hooks must let default_postinst run luci_postinst exactly once through uci-defaults"
fi
if grep -n -E 'Package/forkop/preinst|copy_legacy_config|FORKOP_LEGACY_CONFIG|mode == "preinst"' \
  "$FORKOP_MAKEFILE" "$BUILD_SCRIPT" "$PACKAGE_UC" >/dev/null 2>&1; then
  fail "package hooks and runtime service must not own configuration migration"
fi

rt_tables="$WORK_DIR/rt_tables"
cat >"$rt_tables" <<'EOF'
100 main
105 forkop
200 custom
EOF
FORKOP_PACKAGE_TEST_MODE=1 FORKOP_RT_TABLES="$rt_tables" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm
if grep -Fq '105 forkop' "$rt_tables"; then
  fail "package prerm must remove the Forkop routing table entry"
fi
grep -Fq '200 custom' "$rt_tables" ||
  fail "package prerm must preserve unrelated rt_tables entries"

cat >"$WORK_DIR/forkop-init" <<'SH'
#!/usr/bin/env bash
grep -Fq '105 forkop' "${FORKOP_RT_TABLES:?}" || exit 1
printf '%s\n' 'stop-with-route-table' >>"${FORKOP_STOP_LOG:?}"
SH
chmod 0755 "$WORK_DIR/forkop-init"
cat >"$WORK_DIR/stop-order.state" <<'EOF_UCI'
forkop.settings=settings
forkop.settings.dont_touch_dhcp=1
EOF_UCI
printf '105 forkop\n' >"$WORK_DIR/rt_tables_stop_order"
: >"$WORK_DIR/stop-order.log"
FORKOP_UCI_STATE_FILE="$WORK_DIR/stop-order.state" \
FORKOP_INIT="$WORK_DIR/forkop-init" \
FORKOP_STOP_LOG="$WORK_DIR/stop-order.log" \
FORKOP_BIN="$WORK_DIR/missing-forkop-bin" \
FORKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
FORKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
FORKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
FORKOP_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_stop_order" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm
grep -Fxq 'stop-with-route-table' "$WORK_DIR/stop-order.log" ||
  fail "package prerm must stop Forkop before removing its routing table name"
[ ! -s "$WORK_DIR/rt_tables_stop_order" ] ||
  fail "package prerm must remove the routing table name after Forkop stops"

touch "$WORK_DIR/luci-indexcache.one" "$WORK_DIR/luci-indexcache.two"
FORKOP_PACKAGE_TEST_MODE=1 FORKOP_LUCI_CACHE_GLOBS="$WORK_DIR/luci-indexcache*" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" luci-postinst
if compgen -G "$WORK_DIR/luci-indexcache*" >/dev/null; then
  fail "luci-postinst must remove LuCI index cache files"
fi

cat >"$WORK_DIR/forkop-bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FORKOP_RESTORE_LOG:?}"
SH
chmod 0755 "$WORK_DIR/forkop-bin"

cat >"$WORK_DIR/dont-touch.state" <<'EOF_UCI'
forkop.settings=settings
forkop.settings.dont_touch_dhcp=1
EOF_UCI
printf '105 forkop\n' >"$WORK_DIR/rt_tables_dont_touch"
: >"$WORK_DIR/restore-dont-touch.log"
FORKOP_UCI_STATE_FILE="$WORK_DIR/dont-touch.state" \
FORKOP_RESTORE_LOG="$WORK_DIR/restore-dont-touch.log" \
FORKOP_BIN="$WORK_DIR/forkop-bin" \
FORKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
FORKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
FORKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
FORKOP_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_dont_touch" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm
[ ! -s "$WORK_DIR/restore-dont-touch.log" ] ||
  fail "package prerm must skip dnsmasq restore when dont_touch_dhcp is enabled"

cat >"$WORK_DIR/restore.state" <<'EOF_UCI'
forkop.settings=settings
forkop.settings.dont_touch_dhcp=0
EOF_UCI
printf '105 forkop\n' >"$WORK_DIR/rt_tables_restore"
: >"$WORK_DIR/restore.log"
FORKOP_UCI_STATE_FILE="$WORK_DIR/restore.state" \
FORKOP_RESTORE_LOG="$WORK_DIR/restore.log" \
FORKOP_BIN="$WORK_DIR/forkop-bin" \
FORKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
FORKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
FORKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
FORKOP_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_restore" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm
grep -Fxq 'restore_dnsmasq' "$WORK_DIR/restore.log" ||
  fail "package prerm must restore dnsmasq when dont_touch_dhcp is disabled"

cat >"$WORK_DIR/upgrade-init" <<'SH'
#!/usr/bin/env bash
case "$1" in
  status) exit "${FORKOP_FAKE_STATUS:-0}" ;;
  start) printf '%s\n' start >>"${FORKOP_START_LOG:?}" ;;
esac
SH
chmod 0755 "$WORK_DIR/upgrade-init"
: >"$WORK_DIR/upgrade-start.log"
: >"$WORK_DIR/rt_tables_upgrade"
FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_INIT="$WORK_DIR/upgrade-init" \
FORKOP_START_LOG="$WORK_DIR/upgrade-start.log" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm upgrade
[ -f "$FORKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must remember a running service"
FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_INIT="$WORK_DIR/upgrade-init" \
FORKOP_START_LOG="$WORK_DIR/upgrade-start.log" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" postinst
grep -Fxq start "$WORK_DIR/upgrade-start.log" ||
  fail "package postinst must restart a service that was running before upgrade"
[ ! -e "$FORKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package postinst must clear the consumed upgrade state"

FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_FAKE_STATUS=1 \
FORKOP_INIT="$WORK_DIR/upgrade-init" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm upgrade
[ ! -e "$FORKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must not mark an already stopped service"

printf 'package lifecycle checks passed\n'
