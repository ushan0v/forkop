#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"
CACHE_UC="$ROOT_DIR/forkop/files/usr/lib/subscription/cache.uc"

for key in custom_device_headers device_os ver_os device_model device_locale app_version accept_language; do
  grep -Fq "\"$key\"" "$SECTION_JS" || {
    printf 'FAIL: missing subscription header field %s\n' "$key" >&2
    exit 1
  }
done

for header in X-Device-OS X-Ver-OS X-Device-Model X-Device-Locale X-App-Version Accept-Language; do
  grep -Fq "$header" "$CACHE_UC" || {
    printf 'FAIL: missing request header %s\n' "$header" >&2
    exit 1
  }
done

kernel_version_line="$(grep -n '^function get_kernel_version' "$CACHE_UC" | cut -d: -f1)"
device_headers_line="$(grep -n '^function device_request_headers' "$CACHE_UC" | cut -d: -f1)"
if [ "$kernel_version_line" -ge "$device_headers_line" ]; then
  printf 'FAIL: get_kernel_version must be declared before device_request_headers\n' >&2
  exit 1
fi

source="$(sed -n '/^function generateHwid16(/,/^}/p' "$SECTION_JS")"
HWID_SOURCE="$source" node <<'NODE'
global.window = {
  crypto: {
    getRandomValues(bytes) {
      for (let i = 0; i < bytes.length; i += 1) bytes[i] = i + 1;
      return bytes;
    },
  },
};

const generate = Function(`${process.env.HWID_SOURCE}; return generateHwid16`)();
const hwid = generate();
if (hwid !== '0102030405060708') {
  throw new Error(`unexpected generated HWID: ${hwid}`);
}
if (!/^[0-9a-f]{16}$/.test(hwid)) {
  throw new Error(`generated HWID is not 16 lowercase hex characters: ${hwid}`);
}
NODE

printf 'LuCI subscription header checks passed\n'
