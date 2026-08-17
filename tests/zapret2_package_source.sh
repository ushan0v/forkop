#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
ACTION_UC="$FORKOP_LIB/components/action.uc"
UPDATER="$FORKOP_LIB/components/updater.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

grep -Fq 'fetch_github_release_json("1andrevich", "zapret2-openwrt")' "$ACTION_UC" ||
  fail "zapret2 packages must be resolved from 1andrevich/zapret2-openwrt"
if grep -n 'zapret2' "$ACTION_UC" | grep -Fq 'remittor'; then
  fail "zapret2 must not be resolved from the unmaintained remittor bundles"
fi
if grep -Fq 'named-release-select-asset' "$ACTION_UC" "$UPDATER"; then
  fail "the zapret2 bundle release selector must be removed with the remittor source"
fi

# 1andrevich publishes one plain package per architecture and keeps the version
# out of the asset name, so only the release tag carries it.
release_json="$(cat <<'JSON'
{
  "tag_name": "v1.0.3",
  "html_url": "https://example.com/zapret2-release",
  "assets": [
    {"name": "luci-app-zapret2.ipk", "browser_download_url": "https://example.com/luci.ipk"},
    {"name": "zapret2-1andrevich.pub", "browser_download_url": "https://example.com/key.pub"},
    {"name": "zapret2_x86_64.apk", "browser_download_url": "https://example.com/x86_64.apk"},
    {"name": "zapret2_x86_64.ipk", "browser_download_url": "https://example.com/x86_64.ipk"},
    {"name": "zapret2_aarch64_generic.ipk", "browser_download_url": "https://example.com/aarch64.ipk"}
  ]
}
JSON
)"

assert_eq "$(printf 'x86_64\tzapret2_x86_64.ipk\thttps://example.com/x86_64.ipk\thttps://example.com/zapret2-release\tv1.0.3')" \
  "$(printf '%s' "$release_json" | ucode "$UPDATER" release-select-arch-suffix-asset ipk 'x86_64')" \
  "zapret2 ipk asset selection"
assert_eq "$(printf 'x86_64\tzapret2_x86_64.apk\thttps://example.com/x86_64.apk\thttps://example.com/zapret2-release\tv1.0.3')" \
  "$(printf '%s' "$release_json" | ucode "$UPDATER" release-select-arch-suffix-asset apk 'x86_64')" \
  "zapret2 apk asset selection"
[ -z "$(printf '%s' "$release_json" | ucode "$UPDATER" release-select-arch-suffix-asset ipk 'mipsel_24kc')" ] ||
  fail "zapret2 asset selection must stay empty for an unsupported architecture"
assert_eq "1.0.3" "$(ucode "$UPDATER" updates-normalize-zapret-version v1.0.3)" \
  "zapret2 release tag normalization"

fake_lib="$WORK_DIR/lib"
fake_bin="$WORK_DIR/bin"
mkdir -p "$fake_lib/components" "$fake_lib/core" "$fake_lib/providers/zapret2" "$fake_bin"
cp "$UPDATER" "$fake_lib/components/updater.uc"

cat >"$fake_lib/core/constants.uc" <<'UCODE'
function module_exports() {
  return {};
}

if (sourcepath(1) != null && sourcepath(1) != "")
  return module_exports();
UCODE

cat >"$fake_lib/core/uci.uc" <<'UCODE'
function module_exports() {
  return {
    available: function() { return false; }
  };
}

if (sourcepath(1) != null && sourcepath(1) != "")
  return module_exports();
UCODE

cat >"$fake_lib/providers/zapret2/runtime.uc" <<'UCODE'
let mode = ARGV[0] || "";
if (mode == "installed")
  exit(getenv("FAKE_ZAPRET2_INSTALLED") == "0" ? 1 : 0);
if (mode == "package-version") {
  print(getenv("FAKE_ZAPRET2_VERSION") || "", "\n");
  exit(0);
}
exit(1);
UCODE

printf '%s' "$release_json" >"$WORK_DIR/release.json"

cat >"$fake_bin/curl" <<'SH'
#!/usr/bin/env sh
set -eu

url=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\n' "$url" >>"${FAKE_CURL_LOG:?}"
case "$url" in
  https://api.github.com/repos/1andrevich/zapret2-openwrt/releases/latest)
    cat "${FAKE_RELEASE_JSON:?}" >"$output"
    ;;
  https://example.com/x86_64.ipk|https://example.com/x86_64.apk)
    printf 'fake zapret2 package\n' >"$output"
    ;;
  *)
    exit 22
    ;;
esac
SH

cat >"$fake_bin/opkg" <<'SH'
#!/usr/bin/env sh
set -eu
printf 'opkg %s\n' "$*" >>"${FAKE_PKG_LOG:?}"
case "${1:-}" in
  print-architecture)
    printf 'arch all 1\narch noarch 1\narch x86_64 10\n'
    ;;
  install)
    ;;
  *)
    exit 1
    ;;
esac
SH

cat >"$fake_bin/logger" <<'SH'
#!/usr/bin/env sh
exit 0
SH

cat >"$fake_bin/unzip" <<'SH'
#!/usr/bin/env sh
printf 'zapret2 must not unpack bundles\n' >&2
exit 1
SH

chmod +x "$fake_bin/curl" "$fake_bin/opkg" "$fake_bin/logger" "$fake_bin/unzip"

component_action() {
  set +e
  PATH="$fake_bin:$PATH" \
  FORKOP_LIB="$fake_lib" \
  FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/state" \
  FORKOP_BIN="$WORK_DIR/missing-forkop" \
  FORKOP_SERVICE_INIT="$WORK_DIR/missing-init" \
  FAKE_CURL_LOG="$WORK_DIR/curl.log" \
  FAKE_PKG_LOG="$WORK_DIR/pkg.log" \
  FAKE_RELEASE_JSON="$WORK_DIR/release.json" \
    ucode -L "$fake_lib" "$ACTION_UC" component-action "$@"
  set -e
}

: >"$WORK_DIR/curl.log"
: >"$WORK_DIR/pkg.log"
install_json="$(FAKE_ZAPRET2_INSTALLED=0 FAKE_ZAPRET2_VERSION=1.0.3 component_action zapret2 install)"

grep -Fxq 'https://api.github.com/repos/1andrevich/zapret2-openwrt/releases/latest' "$WORK_DIR/curl.log" ||
  fail "zapret2 install must query the 1andrevich release feed"
grep -Fxq 'https://example.com/x86_64.ipk' "$WORK_DIR/curl.log" ||
  fail "zapret2 install must download the architecture package directly"
grep -Eq '^opkg install .*zapret2_x86_64\.ipk$' "$WORK_DIR/pkg.log" ||
  fail "zapret2 install must hand the downloaded ipk to the package manager"
if grep -Fq 'opkg install unzip' "$WORK_DIR/pkg.log"; then
  fail "zapret2 install must not bootstrap unzip for a plain package"
fi

JSON_VALUE="$install_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.success !== true || value.component !== "zapret2" || value.action !== "install" ||
    value.latest_version !== "1.0.3" ||
    value.release_url !== "https://example.com/zapret2-release") {
  console.error(`unexpected zapret2 install response: ${process.env.JSON_VALUE}`);
  process.exit(1);
}
NODE

check_json="$(FAKE_ZAPRET2_INSTALLED=1 FAKE_ZAPRET2_VERSION=0.9.20260307-r1 component_action zapret2 check_update)"
JSON_VALUE="$check_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.success !== true || value.status !== "outdated" ||
    value.current_version !== "0.9.20260307-r1" || value.latest_version !== "1.0.3") {
  console.error(`unexpected zapret2 check response: ${process.env.JSON_VALUE}`);
  process.exit(1);
}
NODE

up_to_date_json="$(FAKE_ZAPRET2_INSTALLED=1 FAKE_ZAPRET2_VERSION=1.0.3 component_action zapret2 check_update)"
JSON_VALUE="$up_to_date_json" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.success !== true || value.status !== "latest") {
  console.error(`unexpected zapret2 up to date response: ${process.env.JSON_VALUE}`);
  process.exit(1);
}
NODE

cat >"$fake_bin/apk" <<'SH'
#!/usr/bin/env sh
set -eu
printf 'apk %s\n' "$*" >>"${FAKE_PKG_LOG:?}"
case "${1:-}" in
  add)
    ;;
  --print-arch)
    printf 'x86_64\n'
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$fake_bin/apk"

: >"$WORK_DIR/curl.log"
: >"$WORK_DIR/pkg.log"
FAKE_ZAPRET2_INSTALLED=0 FAKE_ZAPRET2_VERSION=1.0.3 component_action zapret2 install >/dev/null
grep -Fxq 'https://example.com/x86_64.apk' "$WORK_DIR/curl.log" ||
  fail "APK routers must download the apk asset of the same release"
grep -Eq '^apk add --allow-untrusted .*zapret2_x86_64\.apk$' "$WORK_DIR/pkg.log" ||
  fail "APK routers must install the downloaded apk package"

printf 'zapret2 package source checks passed\n'
