#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_MAKEFILE="$ROOT_DIR/forkop/Makefile"
FORKOP_CONFIG="$ROOT_DIR/forkop/files/etc/config/forkop"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
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
require_file "$FORKOP_LIB"

grep -Fq "must use x.y.z format" "$FORKOP_MAKEFILE" ||
  fail "forkop/Makefile must enforce the three-part release version contract"
grep -Fq 'APK_INTERNAL_VERSION="$RELEASE_VERSION"' "$BUILD_SCRIPT" ||
  fail "build.sh must use the exact three-part release version for APK metadata"
grep -Fq "option component_update_check_enabled '1'" "$FORKOP_CONFIG" ||
  fail "new installations must enable component update checks by default"

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
