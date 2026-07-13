#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGES_UC="${PACKAGES_UC:-$ROOT_DIR/forkop/files/usr/lib/core/packages.uc}"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$WORK_DIR/apk" <<'SH'
#!/usr/bin/env sh
set -eu

case "$*" in
  "info -e zapret")
    exit 0
    ;;
  "list --installed --manifest zapret"|"list --installed --manifest")
    exit 1
    ;;
  "list --installed zapret")
    if [ "${FAKE_APK_LIST_EMPTY:-0}" = "1" ]; then
      exit 1
    fi
    printf '<zapret> zapret-72.20260307-r1 aarch64_cortex-a53 {feeds/base/zapret} [installed]\n'
    ;;
  "info -v zapret")
    printf 'zapret: zapret\n'
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$WORK_DIR/apk"

version="$(PATH="$WORK_DIR:$PATH" ucode "$PACKAGES_UC" apk-version zapret)"
[ "$version" = "72.20260307-r1" ] ||
  fail "APK v3 installed package version was parsed as '$version'"

invalid_version="$(FAKE_APK_LIST_EMPTY=1 PATH="$WORK_DIR:$PATH" ucode "$PACKAGES_UC" apk-version zapret)"
[ -z "$invalid_version" ] ||
  fail "APK v3 description was accepted as package version '$invalid_version'"

printf 'Package version checks passed\n'
