#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_MAKEFILE="$ROOT_DIR/forkop/Makefile"
FORKOP_CONFIG="$ROOT_DIR/forkop/files/etc/config/forkop"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
BUILD_WORKFLOW="$ROOT_DIR/.github/workflows/build.yml"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_file() {
  local file="$1"

  [ -r "$file" ] || fail "required file is missing: $file"
}

require_make_dep() {
  local package="$1"

  grep -Eq "DEPENDS:=.*(^|[[:space:]])\\+$package([[:space:]]|$)" "$FORKOP_MAKEFILE" ||
    fail "forkop/Makefile DEPENDS is missing +$package"
}

require_build_dep() {
  local variable="$1"
  local package="$2"

  grep -Eq "^${variable}=.*(^|[[:space:],])${package}([[:space:],\"]|$)" "$BUILD_SCRIPT" ||
    fail "build.sh ${variable} is missing $package"
}

require_package_dependency() {
  local package="$1"

  require_make_dep "$package"
  require_build_dep "BACKEND_DEPENDS_IPK" "$package"
  require_build_dep "BACKEND_DEPENDS_APK" "$package"
}

require_file "$FORKOP_MAKEFILE"
require_file "$FORKOP_CONFIG"
require_file "$BUILD_SCRIPT"
require_file "$BUILD_WORKFLOW"
require_file "$FORKOP_LIB"

bash "$BUILD_SCRIPT" --help >/dev/null ||
  fail "build.sh must provide command-line usage"
if bash "$BUILD_SCRIPT" 1.2 >/dev/null 2>&1; then
  fail "build.sh must reject invalid release versions before building"
fi
if grep -Eq 'WSL_|WINDOWS_ARTIFACTS_DIR|SOURCE_ROOT_DIR|\.wsl-build|apt-get|sudo' "$BUILD_SCRIPT"; then
  fail "build.sh must remain a portable unprivileged Linux build entrypoint"
fi
[ "$(grep -Fc 'fakeroot sh -c' "$BUILD_SCRIPT")" -eq 1 ] ||
  fail "build.sh must use fakeroot for IPK ownership"
[ "$(grep -Fc 'unshare -r sh -c' "$BUILD_SCRIPT")" -eq 1 ] ||
  fail "build.sh must use a user namespace for APK ownership"
grep -Fq 'sudo apt-get install -y' "$BUILD_WORKFLOW" ||
  fail "build workflow must own host dependency installation"
grep -Fq './build.sh "$VERSION"' "$BUILD_WORKFLOW" ||
  fail "build workflow must invoke the public build entrypoint"
grep -Fq "replace('\\\\n', '\\n')" "$BUILD_WORKFLOW" ||
  fail "build workflow must normalize escaped release-note line breaks"
grep -Fq 'body: ${{ needs.preparation.outputs.release_notes }}' "$BUILD_WORKFLOW" ||
  fail "release action must receive normalized Markdown notes"

for conflict in https-dns-proxy nextdns luci-app-passwall luci-app-passwall2; do
  grep -E 'CONFLICTS:=' "$FORKOP_MAKEFILE" | grep -Fq "$conflict" ||
    fail "forkop/Makefile conflicts are missing $conflict"
  grep -E '^BACKEND_CONFLICTS_IPK=' "$BUILD_SCRIPT" | grep -Fq "$conflict" ||
    fail "manual IPK conflicts are missing $conflict"
  grep -E '^BACKEND_DEPENDS_APK=' "$BUILD_SCRIPT" | grep -Fq "!$conflict" ||
    fail "manual APK conflicts are missing $conflict"
done

if grep -Fq 'coreutils-sort' "$FORKOP_MAKEFILE" "$BUILD_SCRIPT"; then
  fail "unused coreutils-sort runtime dependency must not be packaged"
fi

grep -Fq "must use x.y.z format" "$FORKOP_MAKEFILE" ||
  fail "forkop/Makefile must enforce the three-part release version contract"
grep -Fq 'APK_INTERNAL_VERSION="$RELEASE_VERSION"' "$BUILD_SCRIPT" ||
  fail "build.sh must use the exact three-part release version for APK metadata"
grep -Fq "option component_update_check_enabled '1'" "$FORKOP_CONFIG" ||
  fail "new installations must enable component update checks by default"
grep -Fq "option config_version '1.0.5'" "$FORKOP_CONFIG" ||
  fail "new installations must start at the current configuration schema version"
grep -Fq "list applied_migrations 'interface_sections'" "$FORKOP_CONFIG" ||
  fail "new installations must mark the interface section migration as applied"
grep -Fq "list applied_migrations 'enable_component_checks'" "$FORKOP_CONFIG" ||
  fail "new installations must mark the component check migration as applied"
grep -Fq "list applied_migrations 'http_connection_urls'" "$FORKOP_CONFIG" ||
  fail "new installations must mark the HTTP connection URL migration as applied"
grep -Fq '/usr/lib/forkop/config/migration.uc migrate' "$FORKOP_MAKEFILE" ||
  fail "OpenWrt package postinst must run configuration migrations"
[ "$(grep -Fc '/usr/lib/forkop/config/migration.uc migrate' "$BUILD_SCRIPT")" -ge 3 ] ||
  fail "manual IPK/APK package scripts must run configuration migrations after install and upgrade"

if grep -Rqs 'require("uci")' "$FORKOP_LIB"; then
  require_package_dependency "ucode-mod-uci"
fi

if grep -Rqs 'require("fs")' "$FORKOP_LIB"; then
  require_package_dependency "ucode-mod-fs"
fi

if grep -Rqs 'forkop_dnsmasq_failsafe_restore_raw' \
  "$ROOT_DIR/forkop/files/usr/bin" \
  "$ROOT_DIR/forkop/files/usr/lib" \
  "$ROOT_DIR/forkop/files/etc/init.d"; then
  fail "duplicated raw dnsmasq failsafe restore shell owner is present"
fi

printf 'package contract checks passed\n'
