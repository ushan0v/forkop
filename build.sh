#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") <version> [output-directory]

Build Forkop IPK and APK packages. The version must use x.y.z format.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if (( $# < 1 || $# > 2 )); then
  usage >&2
  exit 2
fi

RELEASE_VERSION="$1"
OUTPUT_DIR="${2:-$ROOT_DIR/dist/release-final}"

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Expected release version in the form x.y.z" >&2
  exit 2
fi
APK_INTERNAL_VERSION="$RELEASE_VERSION"

BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build}"
SDK_DIR="$BUILD_DIR/sdk"
SDK_CACHE_DIR="${SDK_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/forkop/openwrt-sdk}"
IPK_SDK_URL="${IPK_SDK_URL:-https://downloads.openwrt.org/releases/24.10.6/targets/x86/64/openwrt-sdk-24.10.6-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst}"
APK_SDK_URL="${APK_SDK_URL:-https://downloads.openwrt.org/releases/25.12.3/targets/x86/64/openwrt-sdk-25.12.3-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst}"

BACKEND_DESCRIPTION="Rule-based Forkop backend with hybrid sing-box + zapret orchestration"
APP_DESCRIPTION="Rule-based Forkop LuCI app with hybrid sing-box + zapret orchestration"
I18N_DESCRIPTION="Translation for luci-app-forkop - Русский (Russian)"
MAINTAINER="ushan0v <ushan0v@users.noreply.github.com>"
PROJECT_URL="https://github.com/ushan0v/forkop"
BACKEND_DEPENDS_IPK="libc, ca-bundle, kmod-inet-diag, kmod-netlink-diag, kmod-tun, curl, ucode, ucode-mod-fs, ucode-mod-uci, kmod-nft-tproxy, coreutils-base64, bind-dig, nftables, kmod-nft-nat, ip-full"
BACKEND_DEPENDS_APK="bind-dig ca-bundle coreutils-base64 curl ip-full kmod-inet-diag kmod-netlink-diag kmod-nft-nat kmod-nft-tproxy kmod-tun libc nftables ucode ucode-mod-fs ucode-mod-uci !https-dns-proxy !nextdns !luci-app-passwall !luci-app-passwall2"
BACKEND_CONFLICTS_IPK="https-dns-proxy, nextdns, luci-app-passwall, luci-app-passwall2"
APP_DEPENDS_IPK="libc, luci-base, forkop"
APP_DEPENDS_APK="libc luci-base forkop"

ensure_host_deps() {
  local missing=()
  local commands=(
    curl
    fakeroot
    file
    gcc
    git
    make
    patch
    perl
    sha256sum
    tar
    unshare
    zstd
  )

  for cmd in "${commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "Missing build dependencies: ${missing[*]}" >&2
    exit 1
  fi

  if ! unshare -r true >/dev/null 2>&1; then
    echo "Unprivileged user namespaces are required to build APK packages" >&2
    exit 1
  fi
}

download_sdk_archive() {
  local url="$1"
  local archive_path="$SDK_CACHE_DIR/$(basename "$url")"

  mkdir -p "$SDK_CACHE_DIR"
  if [[ ! -f "$archive_path" ]]; then
    echo "Downloading SDK: $url" >&2
    curl --fail --location --retry 3 --output "$archive_path.part" "$url"
    mv "$archive_path.part" "$archive_path"
  fi

  printf '%s\n' "$archive_path"
}

extract_sdk() {
  local kind="$1"
  local archive_path="$2"
  local sdk_url="$3"
  local destination="$SDK_DIR/$kind"
  local marker_file="$destination/.forkop-sdk-url"
  local temp_dir
  local extracted_root

  mkdir -p "$SDK_DIR"
  if [[ -d "$destination" && -f "$marker_file" ]] && [[ "$(cat "$marker_file")" == "$sdk_url" ]]; then
    printf '%s\n' "$destination"
    return 0
  fi

  rm -rf "$destination"
  temp_dir="$(mktemp -d "$SDK_DIR/.${kind}.XXXXXX")"
  tar --zstd -xf "$archive_path" -C "$temp_dir"
  extracted_root="$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  mv "$extracted_root" "$destination"
  printf '%s\n' "$sdk_url" > "$marker_file"
  rmdir "$temp_dir" 2>/dev/null || true

  printf '%s\n' "$destination"
}

ensure_po2lmo() {
  local ipk_sdk_dir="$1"
  local po2lmo_bin="$ipk_sdk_dir/staging_dir/hostpkg/bin/po2lmo"
  local luci_src_dir="$ipk_sdk_dir/feeds/luci/modules/luci-base/src"

  if [[ -x "$po2lmo_bin" ]]; then
    printf '%s\n' "$po2lmo_bin"
    return 0
  fi

  (
    cd "$ipk_sdk_dir"
    if [[ ! -d feeds/luci ]]; then
      ./scripts/feeds update luci >&2
    fi
  )

  if [[ ! -f "$luci_src_dir/po2lmo" ]]; then
    make -C "$luci_src_dir" po2lmo >&2
  fi

  printf '%s\n' "$luci_src_dir/po2lmo"
}

make_dir() {
  mkdir -p "$1"
}

normalize_package_root_modes() {
  local package_root="$1"

  find "$package_root" -type d -exec chmod 0755 {} +
  find "$package_root" -type f -exec chmod 0644 {} +
}

build_backend_root() {
  local output_root="$1"

  rm -rf "$output_root"
  make_dir "$output_root/etc/init.d"
  make_dir "$output_root/etc/config"
  make_dir "$output_root/usr/bin"
  make_dir "$output_root/usr/lib/forkop"

  install -m 0755 "$ROOT_DIR/forkop/files/etc/init.d/forkop" "$output_root/etc/init.d/forkop"
  install -m 0644 "$ROOT_DIR/forkop/files/etc/config/forkop" "$output_root/etc/config/forkop"
  install -m 0755 "$ROOT_DIR/forkop/files/usr/bin/forkop" "$output_root/usr/bin/forkop"
  cp -a "$ROOT_DIR/forkop/files/usr/lib/." "$output_root/usr/lib/forkop/"

  sed -i -e "s/__COMPILED_VERSION_VARIABLE__/${RELEASE_VERSION}/g" \
    "$output_root/usr/lib/forkop/core/constants.uc"

  normalize_package_root_modes "$output_root"
  chmod 0755 "$output_root/etc/init.d/forkop" "$output_root/usr/bin/forkop"
}

build_app_root() {
  local output_root="$1"

  rm -rf "$output_root"
  make_dir "$output_root/www"

  cp -a "$ROOT_DIR/luci-app-forkop/htdocs/." "$output_root/www/"
  cp -a "$ROOT_DIR/luci-app-forkop/root/." "$output_root/"
  sed -i -e "s/__COMPILED_VERSION_VARIABLE__/${RELEASE_VERSION}/g" \
    "$output_root/www/luci-static/resources/view/forkop/main.js"

  normalize_package_root_modes "$output_root"
  find "$output_root/etc/uci-defaults" -type f -exec chmod 0755 {} + 2>/dev/null || true
}

build_i18n_root() {
  local output_root="$1"
  local po2lmo_bin="$2"
  local lmo_path="$output_root/usr/lib/lua/luci/i18n/forkop.ru.lmo"

  rm -rf "$output_root"
  make_dir "$output_root/etc/uci-defaults"
  make_dir "$(dirname "$lmo_path")"

  cat > "$output_root/etc/uci-defaults/luci-i18n-forkop-ru" <<'EOF'
uci set luci.languages.ru='Русский (Russian)'; uci commit luci
EOF

  "$po2lmo_bin" "$ROOT_DIR/luci-app-forkop/po/ru/forkop.po" "$lmo_path"

  normalize_package_root_modes "$output_root"
  find "$output_root/etc/uci-defaults" -type f -exec chmod 0755 {} + 2>/dev/null || true
}

generate_apk_metadata_files() {
  local package_name="$1"
  local package_root="$2"
  local conffile_path="${3:-}"
  local list_file="$package_root/lib/apk/packages/${package_name}.list"

  make_dir "$(dirname "$list_file")"
  (
    cd "$package_root"
    find . -type f ! -path './lib/apk/packages/*' | LC_ALL=C sort | sed 's#^\./#/#'
  ) > "$list_file"

  if [[ -n "$conffile_path" ]]; then
    local conffiles_file="$package_root/lib/apk/packages/${package_name}.conffiles"
    local conffiles_static_file="$package_root/lib/apk/packages/${package_name}.conffiles_static"
    local hash_value

    hash_value="$(sha256sum "$package_root$conffile_path" | awk '{print $1}')"
    printf '%s\n' "$conffile_path" > "$conffiles_file"
    printf '%s %s\n' "$conffile_path" "$hash_value" > "$conffiles_static_file"
  fi
}

installed_size_bytes() {
  du -sk "$1" | awk '{print $1 * 1024}'
}

write_backend_ipk_control() {
  local control_dir="$1"
  local installed_size="$2"

  rm -rf "$control_dir"
  make_dir "$control_dir"

  cat > "$control_dir/control" <<EOF
Package: forkop
Version: ${RELEASE_VERSION}
Depends: ${BACKEND_DEPENDS_IPK}
Conflicts: ${BACKEND_CONFLICTS_IPK}
License: GPL-2.0-or-later
Section: net
URL: ${PROJECT_URL}
Maintainer: ${MAINTAINER}
Architecture: all
Installed-Size: ${installed_size}
Description: ${BACKEND_DESCRIPTION}
EOF

  cat > "$control_dir/conffiles" <<'EOF'
/etc/config/forkop
EOF

  cat > "$control_dir/postinst" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
FORKOP_LIB=/usr/lib/forkop ucode -L /usr/lib/forkop /usr/lib/forkop/config/migration.uc migrate || exit $?
/usr/bin/forkop package_postinst
EOF

  cat > "$control_dir/prerm" <<'EOF'
#!/usr/bin/ucode

if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "")
	system("/usr/bin/forkop package_prerm " + (ARGV[0] || "") + " >/dev/null 2>&1");

exit(0);
EOF

  chmod 0755 "$control_dir/postinst" "$control_dir/prerm"
}

write_app_ipk_control() {
  local control_dir="$1"
  local installed_size="$2"

  rm -rf "$control_dir"
  make_dir "$control_dir"

  cat > "$control_dir/control" <<EOF
Package: luci-app-forkop
Version: ${RELEASE_VERSION}
Depends: ${APP_DEPENDS_IPK}
License: GPL-2.0-or-later
Section: luci
URL: ${PROJECT_URL}
Maintainer: ${MAINTAINER}
Architecture: all
Installed-Size: ${installed_size}
Description: ${APP_DESCRIPTION}
EOF

  cat > "$control_dir/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
EOF

  cat > "$control_dir/postinst-pkg" <<'EOF'
[ -n "${IPKG_INSTROOT}" ] || /usr/bin/forkop luci_postinst >/dev/null 2>&1 || true
EOF

  cat > "$control_dir/prerm" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
EOF

  chmod 0755 "$control_dir/postinst" "$control_dir/prerm"
}

write_i18n_ipk_control() {
  local control_dir="$1"
  local installed_size="$2"

  rm -rf "$control_dir"
  make_dir "$control_dir"

  cat > "$control_dir/control" <<EOF
Package: luci-i18n-forkop-ru
Version: ${RELEASE_VERSION}
Depends: libc, luci-app-forkop
License: GPL-2.0-or-later
Section: luci
URL: ${PROJECT_URL}
Maintainer: ${MAINTAINER}
Architecture: all
Installed-Size: ${installed_size}
Description: ${I18N_DESCRIPTION}
EOF

  cat > "$control_dir/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
EOF

  cat > "$control_dir/prerm" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
EOF

  chmod 0755 "$control_dir/postinst" "$control_dir/prerm"
}

build_ipk_package() {
  local ipkg_build_bin="$1"
  local package_name="$2"
  local data_root="$3"
  local control_root="$4"
  local output_file="$5"
  local build_dir="$BUILD_DIR/manual/ipk-${package_name}"
  local package_root="$build_dir/pkg"
  local built_file

  rm -rf "$build_dir"
  make_dir "$package_root/CONTROL"

  cp -a "$data_root/." "$package_root/"
  cp -a "$control_root/." "$package_root/CONTROL/"

  rm -f "$output_file"
  fakeroot sh -c '
    chown -R 0:0 "$1"
    exec "$2" "$1" "$3"
  ' sh "$package_root" "$ipkg_build_bin" "$build_dir" >/dev/null

  built_file="$build_dir/${package_name}_${RELEASE_VERSION}_all.ipk"
  [ -f "$built_file" ] || {
    echo "Expected IPK artifact not found: $built_file" >&2
    exit 1
  }

  mv "$built_file" "$output_file"
}

write_backend_apk_scripts() {
  local scripts_dir="$1"

  rm -rf "$scripts_dir"
  make_dir "$scripts_dir"

  cat > "$scripts_dir/backend-pre-install.sh" <<'EOF'
#!/usr/bin/ucode
exit(0);
EOF

  cat > "$scripts_dir/backend-post-install.sh" <<'EOF'
#!/usr/bin/ucode
if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "")
    exit(system("FORKOP_LIB=/usr/lib/forkop ucode -L /usr/lib/forkop /usr/lib/forkop/config/migration.uc migrate && /usr/bin/forkop package_postinst"));
exit(0);
EOF

  cat > "$scripts_dir/backend-pre-deinstall.sh" <<'EOF'
#!/usr/bin/ucode

if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "")
	system("/usr/bin/forkop package_prerm remove >/dev/null 2>&1");

exit(0);
EOF

  cat > "$scripts_dir/backend-pre-upgrade.sh" <<'EOF'
#!/usr/bin/ucode
if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "")
    exit(system("/usr/bin/forkop package_prerm upgrade >/dev/null 2>&1"));
exit(0);
EOF

  cat > "$scripts_dir/backend-post-upgrade.sh" <<'EOF'
#!/usr/bin/ucode
if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "")
    exit(system("FORKOP_LIB=/usr/lib/forkop ucode -L /usr/lib/forkop /usr/lib/forkop/config/migration.uc migrate && /usr/bin/forkop package_postinst"));
exit(0);
EOF

  chmod 0755 "$scripts_dir"/backend-*.sh
}

write_app_apk_scripts() {
  local scripts_dir="$1"

  make_dir "$scripts_dir"

  cat > "$scripts_dir/app-pre-install.sh" <<'EOF'
#!/bin/sh
exit 0
EOF

  cat > "$scripts_dir/app-post-install.sh" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-forkop"
add_group_and_user
default_postinst
[ -n "${IPKG_INSTROOT}" ] || /usr/bin/forkop luci_postinst >/dev/null 2>&1 || true
EOF

  cat > "$scripts_dir/app-pre-deinstall.sh" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-forkop"
default_prerm
exit 0
EOF

  cat > "$scripts_dir/app-pre-upgrade.sh" <<'EOF'
#!/bin/sh
exit 0
EOF

  cat > "$scripts_dir/app-post-upgrade.sh" <<'EOF'
#!/bin/sh
export PKG_UPGRADE=1
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-forkop"
add_group_and_user
default_postinst
[ -n "${IPKG_INSTROOT}" ] || /usr/bin/forkop luci_postinst >/dev/null 2>&1 || true
EOF

  chmod 0755 "$scripts_dir"/app-*.sh
}

write_i18n_apk_scripts() {
  local scripts_dir="$1"

  make_dir "$scripts_dir"

  cat > "$scripts_dir/i18n-pre-install.sh" <<'EOF'
#!/bin/sh
exit 0
EOF

  cat > "$scripts_dir/i18n-post-install.sh" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-i18n-forkop-ru"
add_group_and_user
default_postinst
EOF

  cat > "$scripts_dir/i18n-pre-deinstall.sh" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-i18n-forkop-ru"
default_prerm
EOF

  cat > "$scripts_dir/i18n-pre-upgrade.sh" <<'EOF'
#!/bin/sh
exit 0
EOF

  cat > "$scripts_dir/i18n-post-upgrade.sh" <<'EOF'
#!/bin/sh
export PKG_UPGRADE=1
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-i18n-forkop-ru"
add_group_and_user
default_postinst
EOF

  chmod 0755 "$scripts_dir"/i18n-*.sh
}

build_apk_package() {
  local apk_bin="$1"
  local package_name="$2"
  local package_version="$3"
  local description="$4"
  local depends="$5"
  local files_root="$6"
  local scripts_dir="$7"
  local script_prefix="$8"
  local output_file="$9"
  local temp_root="$BUILD_DIR/manual/${package_name}.apk-root"
  local temp_scripts="$BUILD_DIR/manual/${package_name}.apk-scripts"
  local maintainer="${10}"

  rm -rf "$temp_root" "$temp_scripts"
  cp -a "$files_root" "$temp_root"
  cp -a "$scripts_dir" "$temp_scripts"

  unshare -r sh -c '
    chown -R 0:0 "$1" "$2"
    shift 2
    exec "$@"
  ' sh "$temp_root" "$temp_scripts" \
    "$apk_bin" mkpkg \
    --files "$temp_root" \
    --output "$output_file" \
    -I "name:${package_name}" \
    -I "version:${package_version}" \
    -I "description:${description}" \
    -I "arch:noarch" \
    -I "license:GPL-2.0-or-later" \
    -I "origin:forkop" \
    -I "maintainer:${maintainer}" \
    -I "url:${PROJECT_URL}" \
    -I "depends:${depends}" \
    -s "pre-install:${temp_scripts}/${script_prefix}-pre-install.sh" \
    -s "post-install:${temp_scripts}/${script_prefix}-post-install.sh" \
    -s "pre-deinstall:${temp_scripts}/${script_prefix}-pre-deinstall.sh" \
    -s "pre-upgrade:${temp_scripts}/${script_prefix}-pre-upgrade.sh" \
    -s "post-upgrade:${temp_scripts}/${script_prefix}-post-upgrade.sh"
}

verify_ipk_metadata() {
  local package_file="$1"
  local expected_package="$2"
  local expected_version="$3"
  local tmp_dir

  tmp_dir="$(mktemp -d)"
  tar -xzf "$package_file" -C "$tmp_dir"
  tar -xzf "$tmp_dir/control.tar.gz" -C "$tmp_dir"
  grep -q "^Package: ${expected_package}$" "$tmp_dir/control"
  grep -q "^Version: ${expected_version}$" "$tmp_dir/control"
  if [[ "$expected_package" == "forkop" ]]; then
    grep -q "^Conflicts: ${BACKEND_CONFLICTS_IPK}$" "$tmp_dir/control"
  fi
  rm -rf "$tmp_dir"
}

verify_apk_metadata() {
  local apk_bin="$1"
  local package_file="$2"
  local expected_package="$3"
  local expected_version="$4"
  local dump_file

  dump_file="$(mktemp)"
  "$apk_bin" adbdump "$package_file" > "$dump_file"
  grep -q "^  name: ${expected_package}$" "$dump_file"
  grep -q "^  version: ${expected_version}$" "$dump_file"
  if [[ "$expected_package" == "forkop" ]]; then
    for conflict in https-dns-proxy nextdns luci-app-passwall luci-app-passwall2; do
      grep -q "^[[:space:]]*- '!${conflict}'$" "$dump_file"
    done
  fi
  rm -f "$dump_file"
}

cleanup_work_dir() {
  rm -rf "$BUILD_DIR/manual" "$BUILD_DIR/ipk-build.log"
}

print_summary() {
  local output_dir="$1"

  echo "Build root: $ROOT_DIR"
  echo "Output dir: $output_dir"
  echo "Artifacts:"
  find "$output_dir" -maxdepth 1 -type f \( -name '*.ipk' -o -name '*.apk' \) | sort
}

main() {
  local output_dir
  local ipk_archive
  local apk_archive
  local ipk_sdk_dir
  local apk_sdk_dir
  local po2lmo_bin
  local ipkg_build_bin
  local apk_bin
  local manual_root="$BUILD_DIR/manual"
  local backend_root="$manual_root/backend-root"
  local app_root="$manual_root/app-root"
  local i18n_root="$manual_root/i18n-root"
  local backend_control="$manual_root/backend-ipk-control"
  local app_control="$manual_root/app-ipk-control"
  local i18n_control="$manual_root/i18n-ipk-control"
  local apk_scripts="$manual_root/apk-scripts"
  local backend_size
  local app_size
  local i18n_size

  ensure_host_deps

  mkdir -p "$BUILD_DIR"
  output_dir="$OUTPUT_DIR"
  mkdir -p "$output_dir"
  rm -f "$output_dir"/forkop_* "$output_dir"/luci-app-forkop_* "$output_dir"/luci-i18n-forkop-ru_*

  ipk_archive="$(download_sdk_archive "$IPK_SDK_URL")"
  apk_archive="$(download_sdk_archive "$APK_SDK_URL")"
  ipk_sdk_dir="$(extract_sdk ipk "$ipk_archive" "$IPK_SDK_URL")"
  apk_sdk_dir="$(extract_sdk apk "$apk_archive" "$APK_SDK_URL")"

  po2lmo_bin="$(ensure_po2lmo "$ipk_sdk_dir")"
  ipkg_build_bin="$ipk_sdk_dir/scripts/ipkg-build"
  apk_bin="$apk_sdk_dir/staging_dir/host/bin/apk"
  [[ -x "$ipkg_build_bin" ]] || { echo "ipkg-build not found at $ipkg_build_bin" >&2; exit 1; }
  [[ -x "$apk_bin" ]] || { echo "apk host tool not found at $apk_bin" >&2; exit 1; }

  build_backend_root "$backend_root"
  build_app_root "$app_root"
  build_i18n_root "$i18n_root" "$po2lmo_bin"

  backend_size="$(installed_size_bytes "$backend_root")"
  app_size="$(installed_size_bytes "$app_root")"
  i18n_size="$(installed_size_bytes "$i18n_root")"

  write_backend_ipk_control "$backend_control" "$backend_size"
  write_app_ipk_control "$app_control" "$app_size"
  write_i18n_ipk_control "$i18n_control" "$i18n_size"

  build_ipk_package \
    "$ipkg_build_bin" \
    "forkop" \
    "$backend_root" \
    "$backend_control" \
    "$output_dir/forkop_${RELEASE_VERSION}.ipk"

  build_ipk_package \
    "$ipkg_build_bin" \
    "luci-app-forkop" \
    "$app_root" \
    "$app_control" \
    "$output_dir/luci-app-forkop_${RELEASE_VERSION}.ipk"

  build_ipk_package \
    "$ipkg_build_bin" \
    "luci-i18n-forkop-ru" \
    "$i18n_root" \
    "$i18n_control" \
    "$output_dir/luci-i18n-forkop-ru_${RELEASE_VERSION}.ipk"

  generate_apk_metadata_files "forkop" "$backend_root" "/etc/config/forkop"
  generate_apk_metadata_files "luci-app-forkop" "$app_root"
  generate_apk_metadata_files "luci-i18n-forkop-ru" "$i18n_root"
  write_backend_apk_scripts "$apk_scripts"
  write_app_apk_scripts "$apk_scripts"
  write_i18n_apk_scripts "$apk_scripts"

  build_apk_package \
    "$apk_bin" \
    "forkop" \
    "$APK_INTERNAL_VERSION" \
    "$BACKEND_DESCRIPTION" \
    "$BACKEND_DEPENDS_APK" \
    "$backend_root" \
    "$apk_scripts" \
    "backend" \
    "$output_dir/forkop_${RELEASE_VERSION}.apk" \
    "$MAINTAINER"

  build_apk_package \
    "$apk_bin" \
    "luci-app-forkop" \
    "$APK_INTERNAL_VERSION" \
    "$APP_DESCRIPTION" \
    "$APP_DEPENDS_APK" \
    "$app_root" \
    "$apk_scripts" \
    "app" \
    "$output_dir/luci-app-forkop_${RELEASE_VERSION}.apk" \
    "$MAINTAINER"

  build_apk_package \
    "$apk_bin" \
    "luci-i18n-forkop-ru" \
    "$APK_INTERNAL_VERSION" \
    "$I18N_DESCRIPTION" \
    "libc luci-app-forkop" \
    "$i18n_root" \
    "$apk_scripts" \
    "i18n" \
    "$output_dir/luci-i18n-forkop-ru_${RELEASE_VERSION}.apk" \
    "$MAINTAINER"

  verify_ipk_metadata "$output_dir/forkop_${RELEASE_VERSION}.ipk" "forkop" "$RELEASE_VERSION"
  verify_ipk_metadata "$output_dir/luci-app-forkop_${RELEASE_VERSION}.ipk" "luci-app-forkop" "$RELEASE_VERSION"
  verify_ipk_metadata "$output_dir/luci-i18n-forkop-ru_${RELEASE_VERSION}.ipk" "luci-i18n-forkop-ru" "$RELEASE_VERSION"
  verify_apk_metadata "$apk_bin" "$output_dir/forkop_${RELEASE_VERSION}.apk" "forkop" "$APK_INTERNAL_VERSION"
  verify_apk_metadata "$apk_bin" "$output_dir/luci-app-forkop_${RELEASE_VERSION}.apk" "luci-app-forkop" "$APK_INTERNAL_VERSION"
  verify_apk_metadata "$apk_bin" "$output_dir/luci-i18n-forkop-ru_${RELEASE_VERSION}.apk" "luci-i18n-forkop-ru" "$APK_INTERNAL_VERSION"

  cleanup_work_dir
  print_summary "$output_dir"
}

main "$@"
