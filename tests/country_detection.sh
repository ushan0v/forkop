#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXROUTE_LIB="$ROOT_DIR/nexroute/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin"

cat >"$WORK_DIR/bin/dig" <<'SH'
#!/usr/bin/env sh
case " $* " in
  *' alpha.example A '*) printf '8.8.8.8\n' ;;
  *' beta.example A '*) printf '1.1.1.1\n' ;;
  *' @9.9.9.9 country.invalid A '*) printf '8.6.112.0\n' ;;
esac
SH
chmod +x "$WORK_DIR/bin/dig"

cat >"$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env sh
output=""
payload=""
resolve=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -d)
      payload="$2"
      shift 2
      ;;
    --resolve)
      resolve="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf '%s\n' "$payload" >"$FAKE_COUNTRY_PAYLOAD"
printf '%s\n' "$resolve" >"$FAKE_COUNTRY_RESOLVE"
printf '[{"ip":"8.8.8.8","country":"DE"},{"ip":"1.1.1.1","country":"NL"}]\n' >"$output"
printf '200'
SH
chmod +x "$WORK_DIR/bin/curl"

cat >"$WORK_DIR/runner.uc" <<'UCODE'
let country = require("singbox.country");

function fail(message) {
    die(message + "\n");
}

let detected = country.detect({
    alpha: "alpha.example",
    beta: "beta.example",
    zero: "0.0.0.0",
    private: "192.168.1.1",
    fakeip: "198.18.6.9",
    documentation: "203.0.113.10"
}, {}, "9.9.9.9");
if (detected.alpha != "DE" || detected.beta != "NL")
    fail("country.is response was not mapped to outbound tags");
if (detected.zero != null || detected.private != null || detected.fakeip != null || detected.documentation != null)
    fail("non-public server addresses must not receive country metadata");

if (!country.public_ip("8.8.8.8") || !country.public_ip("2606:4700:4700::1111"))
    fail("public address classification changed");
if (country.public_ip("0.0.0.0") || country.public_ip("192.168.1.1") || country.public_ip("198.18.6.9") || country.public_ip("fc00::1"))
    fail("non-public address classification changed");

let cached = country.detect({
    renamed: "alpha.example"
}, {
    servers: { old: "alpha.example" },
    outboundMetadata: { countries: { old: "DE" } }
});
if (cached.renamed != "DE")
    fail("country cache should be reused by server after an outbound tag changes");
UCODE

FAKE_COUNTRY_PAYLOAD="$WORK_DIR/payload.json" \
FAKE_COUNTRY_RESOLVE="$WORK_DIR/resolve.txt" \
NEXROUTE_COUNTRY_IS_URL="https://country.invalid/" \
PATH="$WORK_DIR/bin:$PATH" \
  ucode -L "$NEXROUTE_LIB" "$WORK_DIR/runner.uc"

grep -Fq '8.8.8.8' "$WORK_DIR/payload.json" ||
  fail "country.is request did not contain the first resolved IP"
grep -Fq '1.1.1.1' "$WORK_DIR/payload.json" ||
  fail "country.is request did not contain the second resolved IP"
grep -Fq 'country.invalid:443:8.6.112.0' "$WORK_DIR/resolve.txt" ||
  fail "country.is request did not bypass the router FakeIP resolver"
grep -Eq '0\.0\.0\.0|192\.168\.1\.1|198\.18\.6\.9|203\.0\.113\.10' "$WORK_DIR/payload.json" &&
  fail "country.is request contained a non-public address"

printf 'country detection checks passed\n'
