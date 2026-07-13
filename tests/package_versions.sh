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
  "list --available --manifest sing-box-tiny")
    if [ -n "${FAKE_APK_LOG:-}" ]; then
      printf '%s\n' "$*" >>"$FAKE_APK_LOG"
    fi
    exit 0
    ;;
  "query --from repositories --available --format json --fields name,version sing-box-tiny")
    printf '%s\n' "$*" >>"${FAKE_APK_LOG:?}"
    case "${FAKE_APK_QUERY_RESULT:-valid}" in
      valid) printf '%s\n' '[{"name":"sing-box-tiny","version":"1.12.17-r1"}]' ;;
      empty) printf '%s\n' '[]' ;;
      malformed) printf '%s\n' 'not-json' ;;
      wrong-name) printf '%s\n' '[{"name":"sing-box","version":"9.9.9-r1"}]' ;;
      provider-first) printf '%s\n' '[{"name":"sing-box","version":"9.9.9-r1"},{"name":"sing-box-tiny","version":"1.12.17-r1"}]' ;;
    esac
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

: >"$WORK_DIR/apk.log"
available_version="$(FAKE_APK_LOG="$WORK_DIR/apk.log" PATH="$WORK_DIR:$PATH" ucode "$PACKAGES_UC" apk-available-version sing-box-tiny)"
[ "$available_version" = "1.12.17-r1" ] ||
  fail "APK v3 available package version was parsed as '$available_version'"
grep -Fxq 'query --from repositories --available --format json --fields name,version sing-box-tiny' "$WORK_DIR/apk.log" ||
  fail "APK available version lookup must query repository packages explicitly"
if grep -Fq 'list --available --manifest sing-box-tiny' "$WORK_DIR/apk.log"; then
  fail "APK available version lookup must not use installed-only manifest mode"
fi

provider_version="$(FAKE_APK_QUERY_RESULT=provider-first FAKE_APK_LOG="$WORK_DIR/apk.log" PATH="$WORK_DIR:$PATH" ucode "$PACKAGES_UC" apk-available-version sing-box-tiny)"
[ "$provider_version" = "1.12.17-r1" ] ||
  fail "APK provider result replaced the exact package version '$provider_version'"

for result in empty malformed wrong-name; do
  invalid_available_version="$(FAKE_APK_QUERY_RESULT="$result" FAKE_APK_LOG="$WORK_DIR/apk.log" PATH="$WORK_DIR:$PATH" ucode "$PACKAGES_UC" apk-available-version sing-box-tiny)"
  [ -z "$invalid_available_version" ] ||
    fail "APK v3 $result query result was accepted as version '$invalid_available_version'"
done

printf 'Package version checks passed\n'
