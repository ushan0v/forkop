#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RELEASE_VERSION="${1:-}"
OUTPUT_DIR_INPUT="${2:-}"
SOURCE_ROOT_DIR="${SOURCE_ROOT_DIR:-}"
WINDOWS_ARTIFACTS_DIR="${WINDOWS_ARTIFACTS_DIR:-}"
DEFAULT_BUILD_HOME="${HOME}"

if [[ "$DEFAULT_BUILD_HOME" == "/root" ]]; then
  DEFAULT_BUILD_HOME="$(getent passwd 1000 | cut -d: -f6 || true)"
  DEFAULT_BUILD_HOME="${DEFAULT_BUILD_HOME:-/root}"
fi

if [[ "$RELEASE_VERSION" =~ ^[0-9]+(\.[0-9]+)*-[0-9]+$ ]]; then
  BASE_VERSION="${RELEASE_VERSION%-*}"
  FORK_RELEASE="${RELEASE_VERSION##*-}"
  APK_INTERNAL_VERSION="${APK_INTERNAL_VERSION:-${BASE_VERSION}-r${FORK_RELEASE}}"
elif [[ "$RELEASE_VERSION" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
  BASE_VERSION="${RELEASE_VERSION%.*}"
  FORK_RELEASE="${RELEASE_VERSION##*.}"
  APK_INTERNAL_VERSION="${APK_INTERNAL_VERSION:-${RELEASE_VERSION}}"
else
  echo "Expected release version in the form x.y.z.n; legacy x.y.z-n is also accepted" >&2
  exit 1
fi

WSL_NATIVE_ROOT="${WSL_NATIVE_ROOT:-$DEFAULT_BUILD_HOME/build/podkop-plus}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.wsl-build}"
SDK_WORK_DIR="${SDK_WORK_DIR:-$WORK_DIR/sdk}"
SDK_CACHE_DIR="${SDK_CACHE_DIR:-$DEFAULT_BUILD_HOME/.cache/podkop-plus/openwrt-sdk}"
IPK_SDK_URL="${IPK_SDK_URL:-https://downloads.openwrt.org/releases/24.10.6/targets/x86/64/openwrt-sdk-24.10.6-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst}"
APK_SDK_URL="${APK_SDK_URL:-https://downloads.openwrt.org/releases/25.12.3/targets/x86/64/openwrt-sdk-25.12.3-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst}"

BACKEND_DESCRIPTION="Rule-based Podkop Plus backend with hybrid sing-box + zapret orchestration"
APP_DESCRIPTION="Rule-based Podkop Plus LuCI app with hybrid sing-box + zapret orchestration"
I18N_DESCRIPTION="Translation for luci-app-podkop-plus - Русский (Russian)"
MAINTAINER="ushan0v <ushan0v@users.noreply.github.com>"
PROJECT_URL="https://github.com/ushan0v/podkop-plus"
BACKEND_DEPENDS_IPK="libc, ca-bundle, kmod-inet-diag, kmod-netlink-diag, kmod-tun, curl, ucode, ucode-mod-fs, kmod-nft-tproxy, coreutils-base64, coreutils-sort, bind-dig, nftables, kmod-nft-nat, kmod-nft-offload"
BACKEND_DEPENDS_APK="bind-dig ca-bundle coreutils-base64 coreutils-sort curl kmod-inet-diag kmod-netlink-diag kmod-nft-nat kmod-nft-offload kmod-nft-tproxy kmod-tun libc nftables ucode ucode-mod-fs"
APP_DEPENDS_IPK="libc, luci-base, podkop-plus"
APP_DEPENDS_APK="libc luci-base podkop-plus"

APT_PACKAGES=(
  build-essential
  curl
  fakeroot
  file
  gawk
  git
  patch
  python3
  rsync
  tar
  unzip
  util-linux
  wget
  xz-utils
  zstd
)

copy_to_native_root() {
  local target_root="${WSL_NATIVE_ROOT%/}"
  local target_output
  local source_root="${SOURCE_ROOT_DIR:-$ROOT_DIR}"
  local windows_output="${WINDOWS_ARTIFACTS_DIR:-$source_root/dist/release-final}"

  mkdir -p "$target_root"
  rsync -a --delete \
    --exclude ".git" \
    --exclude ".wsl-build" \
    --exclude "dist" \
    --exclude ".idea" \
    --exclude "sandbox" \
    --exclude "fe-app-podkop/node_modules" \
    --exclude "fe-app-podkop/tests" \
    "$ROOT_DIR/" "$target_root/"
  rm -rf \
    "$target_root/.idea" \
    "$target_root/sandbox" \
    "$target_root/fe-app-podkop/node_modules" \
    "$target_root/fe-app-podkop/tests"

  if [[ -n "$OUTPUT_DIR_INPUT" ]]; then
    target_output="$OUTPUT_DIR_INPUT"
  else
    target_output="$target_root/dist/release-final"
  fi

  echo "Synced repository to native WSL path: $target_root" >&2
  export SOURCE_ROOT_DIR="$source_root"
  export WINDOWS_ARTIFACTS_DIR="$windows_output"
  exec bash "$target_root/scripts/build-openwrt-packages-wsl.sh" "$RELEASE_VERSION" "$target_output"
}

ensure_native_root() {
  case "$ROOT_DIR" in
    /mnt/*)
      copy_to_native_root
      ;;
  esac
}

ensure_host_deps() {
  local missing=()
  local commands=(
    ar
    curl
    fakeroot
    file
    gcc
    git
    make
    python3
    rsync
    sha256sum
    tar
    unshare
    wget
    zstd
  )

  for cmd in "${commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  echo "Installing missing host dependencies: ${APT_PACKAGES[*]}" >&2
  if [[ "$(id -u)" -eq 0 ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"
    return 0
  fi

  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"
    return 0
  fi

  echo "Missing build dependencies and no passwordless sudo/root available: ${missing[*]}" >&2
  exit 1
}

have_passwordless_sudo() {
  command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}

have_unshare_root() {
  command -v unshare >/dev/null 2>&1 && unshare -r true >/dev/null 2>&1
}

download_sdk_archive() {
  local url="$1"
  local archive_path="$SDK_CACHE_DIR/$(basename "$url")"

  mkdir -p "$SDK_CACHE_DIR"
  if [[ ! -f "$archive_path" ]]; then
    echo "Downloading SDK: $url" >&2
    wget -O "$archive_path.part" "$url"
    mv "$archive_path.part" "$archive_path"
  fi

  printf '%s\n' "$archive_path"
}

extract_sdk() {
  local kind="$1"
  local archive_path="$2"
  local sdk_url="$3"
  local destination="$SDK_WORK_DIR/$kind"
  local marker_file="$destination/.podkop-sdk-url"
  local temp_dir
  local extracted_root

  mkdir -p "$SDK_WORK_DIR"
  if [[ -d "$destination" && -f "$marker_file" ]] && [[ "$(cat "$marker_file")" == "$sdk_url" ]]; then
    printf '%s\n' "$destination"
    return 0
  fi

  rm -rf "$destination"
  temp_dir="$(mktemp -d "$SDK_WORK_DIR/.${kind}.XXXXXX")"
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
  make_dir "$output_root/usr/lib/podkop-plus"

  install -m 0755 "$ROOT_DIR/podkop/files/etc/init.d/podkop" "$output_root/etc/init.d/podkop-plus"
  install -m 0644 "$ROOT_DIR/podkop/files/etc/config/podkop" "$output_root/etc/config/podkop-plus"
  install -m 0755 "$ROOT_DIR/podkop/files/usr/bin/podkop" "$output_root/usr/bin/podkop-plus"
  cp -a "$ROOT_DIR/podkop/files/usr/lib/." "$output_root/usr/lib/podkop-plus/"

  sed -i -e "s/__COMPILED_VERSION_VARIABLE__/${RELEASE_VERSION}/g" \
    "$output_root/usr/lib/podkop-plus/constants.sh"

  normalize_package_root_modes "$output_root"
  chmod 0755 "$output_root/etc/init.d/podkop-plus" "$output_root/usr/bin/podkop-plus"
}

build_app_root() {
  local output_root="$1"

  rm -rf "$output_root"
  make_dir "$output_root/www"

  if [[ -d "$ROOT_DIR/luci-app-podkop-plus/htdocs" ]]; then
    cp -a "$ROOT_DIR/luci-app-podkop-plus/htdocs/." "$output_root/www/"
  fi

  if [[ -d "$output_root/www/luci-static/resources/view/podkop" ]]; then
    rm -rf "$output_root/www/luci-static/resources/view/podkop_plus"
    mv "$output_root/www/luci-static/resources/view/podkop" \
      "$output_root/www/luci-static/resources/view/podkop_plus"
  fi

  if [[ -d "$ROOT_DIR/luci-app-podkop-plus/root" ]]; then
    cp -a "$ROOT_DIR/luci-app-podkop-plus/root/." "$output_root/"
  fi

  if [[ -f "$output_root/www/luci-static/resources/view/podkop_plus/main.js" ]]; then
    sed -i -e "s/__COMPILED_VERSION_VARIABLE__/${RELEASE_VERSION}/g" \
      "$output_root/www/luci-static/resources/view/podkop_plus/main.js"
  fi

  normalize_package_root_modes "$output_root"
  find "$output_root/etc/uci-defaults" -type f -exec chmod 0755 {} + 2>/dev/null || true
}

build_i18n_root() {
  local output_root="$1"
  local po2lmo_bin="$2"
  local lmo_path="$output_root/usr/lib/lua/luci/i18n/podkop_plus.ru.lmo"

  rm -rf "$output_root"
  make_dir "$output_root/etc/uci-defaults"
  make_dir "$(dirname "$lmo_path")"

  cat > "$output_root/etc/uci-defaults/luci-i18n-podkop-plus-ru" <<'EOF'
uci set luci.languages.ru='Русский (Russian)'; uci commit luci
EOF

  "$po2lmo_bin" "$ROOT_DIR/luci-app-podkop-plus/po/ru/podkop_plus.po" "$lmo_path"

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
Package: podkop-plus
Version: ${RELEASE_VERSION}
Depends: ${BACKEND_DEPENDS_IPK}
License: GPL-2.0-or-later
Section: net
URL: ${PROJECT_URL}
Maintainer: ${MAINTAINER}
Architecture: all
Installed-Size: ${installed_size}
Description: ${BACKEND_DESCRIPTION}
EOF

  cat > "$control_dir/conffiles" <<'EOF'
/etc/config/podkop-plus
EOF

  cat > "$control_dir/preinst" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0

if [ ! -f /etc/config/podkop-plus ] && [ -f /etc/config/podkop_plus ]; then
	cp /etc/config/podkop_plus /etc/config/podkop-plus || exit 1
	chmod 0644 /etc/config/podkop-plus 2>/dev/null || true
fi

exit 0
EOF

  cat > "$control_dir/prerm" <<'EOF'
#!/bin/sh

grep -q "105 podkopplus" /etc/iproute2/rt_tables && sed -i "/105 podkopplus/d" /etc/iproute2/rt_tables

/etc/init.d/podkop-plus stop >/dev/null 2>&1 || true
podkop_dont_touch_dhcp="$(uci -q get 'podkop-plus.settings.dont_touch_dhcp' 2>/dev/null)"
case "$podkop_dont_touch_dhcp" in
	1|true|yes|on)
		;;
	*)
		/usr/bin/podkop-plus restore_dnsmasq >/dev/null 2>&1 || true
if [ -r /usr/lib/podkop-plus/dnsmasq_failsafe_restore.sh ]; then
	sh /usr/lib/podkop-plus/dnsmasq_failsafe_restore.sh >/dev/null 2>&1 || true
else
	podkop_backup_notinterfaces="$(uci -q get 'dhcp.@dnsmasq[0].podkop_notinterface' 2>/dev/null)"
	uci -q delete dhcp.podkop_plus >/dev/null 2>&1 || true
	if [ -n "$podkop_backup_notinterfaces" ]; then
		uci -q delete 'dhcp.@dnsmasq[0].notinterface' >/dev/null 2>&1 || true
		for podkop_value in $podkop_backup_notinterfaces; do
			uci -q add_list "dhcp.@dnsmasq[0].notinterface=$podkop_value" >/dev/null 2>&1 || true
		done
	else
		uci -q del_list 'dhcp.@dnsmasq[0].notinterface=br-lan' >/dev/null 2>&1 || true
	fi
	uci -q delete 'dhcp.@dnsmasq[0].podkop_notinterface' >/dev/null 2>&1 || true
	podkop_backup_servers="$(uci -q get 'dhcp.@dnsmasq[0].podkop_server' 2>/dev/null)"
	if [ -n "$podkop_backup_servers" ]; then
		uci -q delete 'dhcp.@dnsmasq[0].server' >/dev/null 2>&1 || true
		for podkop_value in $podkop_backup_servers; do
			uci -q add_list "dhcp.@dnsmasq[0].server=$podkop_value" >/dev/null 2>&1 || true
		done
	else
		uci -q del_list 'dhcp.@dnsmasq[0].server=127.0.0.42' >/dev/null 2>&1 || true
	fi
	uci -q delete 'dhcp.@dnsmasq[0].podkop_server' >/dev/null 2>&1 || true
	podkop_noresolv="$(uci -q get 'dhcp.@dnsmasq[0].podkop_noresolv' 2>/dev/null)"
	if [ -n "$podkop_noresolv" ]; then
		uci -q set "dhcp.@dnsmasq[0].noresolv=$podkop_noresolv" >/dev/null 2>&1 || true
	else
		uci -q set 'dhcp.@dnsmasq[0].noresolv=0' >/dev/null 2>&1 || true
	fi
	uci -q delete 'dhcp.@dnsmasq[0].podkop_noresolv' >/dev/null 2>&1 || true
	podkop_cachesize="$(uci -q get 'dhcp.@dnsmasq[0].podkop_cachesize' 2>/dev/null)"
	if [ -n "$podkop_cachesize" ]; then
		uci -q set "dhcp.@dnsmasq[0].cachesize=$podkop_cachesize" >/dev/null 2>&1 || true
	else
		uci -q set 'dhcp.@dnsmasq[0].cachesize=150' >/dev/null 2>&1 || true
	fi
	uci -q delete 'dhcp.@dnsmasq[0].podkop_cachesize' >/dev/null 2>&1 || true
	uci -q commit dhcp >/dev/null 2>&1 || true
	[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
fi
		;;
esac

exit 0
EOF

  chmod 0755 "$control_dir/preinst" "$control_dir/prerm"
}

write_app_ipk_control() {
  local control_dir="$1"
  local installed_size="$2"

  rm -rf "$control_dir"
  make_dir "$control_dir"

  cat > "$control_dir/control" <<EOF
Package: luci-app-podkop-plus
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
[ -n "${IPKG_INSTROOT}" ] || { rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	exit 0
}
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
Package: luci-i18n-podkop-plus-ru
Version: ${RELEASE_VERSION}
Depends: libc, luci-app-podkop-plus
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
  local build_dir="$WORK_DIR/manual/ipk-${package_name}"
  local package_root="$build_dir/pkg"
  local built_file

  rm -rf "$build_dir"
  make_dir "$package_root/CONTROL"

  cp -a "$data_root/." "$package_root/"
  cp -a "$control_root/." "$package_root/CONTROL/"

  rm -f "$output_file"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R 0:0 "$package_root"
    "$ipkg_build_bin" "$package_root" "$build_dir" >/dev/null
  elif have_passwordless_sudo; then
    sudo chown -R 0:0 "$package_root"
    sudo "$ipkg_build_bin" "$package_root" "$build_dir" >/dev/null
    sudo chown "$(id -u):$(id -g)" "$build_dir/${package_name}_${RELEASE_VERSION}_all.ipk"
  else
    fakeroot sh -c "
      chown -R 0:0 '$package_root'
      '$ipkg_build_bin' '$package_root' '$build_dir' >/dev/null
    "
  fi

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
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0

if [ ! -f /etc/config/podkop-plus ] && [ -f /etc/config/podkop_plus ]; then
	cp /etc/config/podkop_plus /etc/config/podkop-plus || exit 1
	chmod 0644 /etc/config/podkop-plus 2>/dev/null || true
fi

exit 0
EOF

  cat > "$scripts_dir/backend-post-install.sh" <<'EOF'
#!/bin/sh
exit 0
EOF

  cat > "$scripts_dir/backend-pre-deinstall.sh" <<'EOF'
#!/bin/sh
grep -q "105 podkopplus" /etc/iproute2/rt_tables && sed -i "/105 podkopplus/d" /etc/iproute2/rt_tables
/etc/init.d/podkop-plus stop >/dev/null 2>&1 || true
podkop_dont_touch_dhcp="$(uci -q get 'podkop-plus.settings.dont_touch_dhcp' 2>/dev/null)"
case "$podkop_dont_touch_dhcp" in
	1|true|yes|on)
		;;
	*)
		/usr/bin/podkop-plus restore_dnsmasq >/dev/null 2>&1 || true
if [ -r /usr/lib/podkop-plus/dnsmasq_failsafe_restore.sh ]; then
	sh /usr/lib/podkop-plus/dnsmasq_failsafe_restore.sh >/dev/null 2>&1 || true
else
	podkop_backup_notinterfaces="$(uci -q get 'dhcp.@dnsmasq[0].podkop_notinterface' 2>/dev/null)"
	uci -q delete dhcp.podkop_plus >/dev/null 2>&1 || true
	if [ -n "$podkop_backup_notinterfaces" ]; then
		uci -q delete 'dhcp.@dnsmasq[0].notinterface' >/dev/null 2>&1 || true
		for podkop_value in $podkop_backup_notinterfaces; do
			uci -q add_list "dhcp.@dnsmasq[0].notinterface=$podkop_value" >/dev/null 2>&1 || true
		done
	else
		uci -q del_list 'dhcp.@dnsmasq[0].notinterface=br-lan' >/dev/null 2>&1 || true
	fi
	uci -q delete 'dhcp.@dnsmasq[0].podkop_notinterface' >/dev/null 2>&1 || true
	podkop_backup_servers="$(uci -q get 'dhcp.@dnsmasq[0].podkop_server' 2>/dev/null)"
	if [ -n "$podkop_backup_servers" ]; then
		uci -q delete 'dhcp.@dnsmasq[0].server' >/dev/null 2>&1 || true
		for podkop_value in $podkop_backup_servers; do
			uci -q add_list "dhcp.@dnsmasq[0].server=$podkop_value" >/dev/null 2>&1 || true
		done
	else
		uci -q del_list 'dhcp.@dnsmasq[0].server=127.0.0.42' >/dev/null 2>&1 || true
	fi
	uci -q delete 'dhcp.@dnsmasq[0].podkop_server' >/dev/null 2>&1 || true
	podkop_noresolv="$(uci -q get 'dhcp.@dnsmasq[0].podkop_noresolv' 2>/dev/null)"
	if [ -n "$podkop_noresolv" ]; then
		uci -q set "dhcp.@dnsmasq[0].noresolv=$podkop_noresolv" >/dev/null 2>&1 || true
	else
		uci -q set 'dhcp.@dnsmasq[0].noresolv=0' >/dev/null 2>&1 || true
	fi
	uci -q delete 'dhcp.@dnsmasq[0].podkop_noresolv' >/dev/null 2>&1 || true
	podkop_cachesize="$(uci -q get 'dhcp.@dnsmasq[0].podkop_cachesize' 2>/dev/null)"
	if [ -n "$podkop_cachesize" ]; then
		uci -q set "dhcp.@dnsmasq[0].cachesize=$podkop_cachesize" >/dev/null 2>&1 || true
	else
		uci -q set 'dhcp.@dnsmasq[0].cachesize=150' >/dev/null 2>&1 || true
	fi
	uci -q delete 'dhcp.@dnsmasq[0].podkop_cachesize' >/dev/null 2>&1 || true
	uci -q commit dhcp >/dev/null 2>&1 || true
	[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
fi
		;;
esac
exit 0
EOF

  cat > "$scripts_dir/backend-pre-upgrade.sh" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0

if [ ! -f /etc/config/podkop-plus ] && [ -f /etc/config/podkop_plus ]; then
	cp /etc/config/podkop_plus /etc/config/podkop-plus || exit 1
	chmod 0644 /etc/config/podkop-plus 2>/dev/null || true
fi

exit 0
EOF

  cat > "$scripts_dir/backend-post-upgrade.sh" <<'EOF'
#!/bin/sh
exit 0
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
export pkgname="luci-app-podkop-plus"
add_group_and_user
default_postinst
[ -n "${IPKG_INSTROOT}" ] || { rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	exit 0
}
EOF

  cat > "$scripts_dir/app-pre-deinstall.sh" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-podkop-plus"
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
export pkgname="luci-app-podkop-plus"
add_group_and_user
default_postinst
[ -n "${IPKG_INSTROOT}" ] || { rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	exit 0
}
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
export pkgname="luci-i18n-podkop-plus-ru"
add_group_and_user
default_postinst
EOF

  cat > "$scripts_dir/i18n-pre-deinstall.sh" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-i18n-podkop-plus-ru"
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
export pkgname="luci-i18n-podkop-plus-ru"
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
  local temp_root="$WORK_DIR/manual/${package_name}.apk-root"
  local temp_scripts="$WORK_DIR/manual/${package_name}.apk-scripts"
  local maintainer="${10}"
  local stderr_file

  rm -rf "$temp_root" "$temp_scripts"
  cp -a "$files_root" "$temp_root"
  cp -a "$scripts_dir" "$temp_scripts"

  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R 0:0 "$temp_root" "$temp_scripts"
    "$apk_bin" mkpkg \
      --files "$temp_root" \
      --output "$output_file" \
      -I "name:${package_name}" \
      -I "version:${package_version}" \
      -I "description:${description}" \
      -I "arch:noarch" \
      -I "license:GPL-2.0-or-later" \
      -I "origin:podkop-plus" \
      -I "maintainer:${maintainer}" \
      -I "url:${PROJECT_URL}" \
      -I "depends:${depends}" \
      -s "pre-install:${temp_scripts}/${script_prefix}-pre-install.sh" \
      -s "post-install:${temp_scripts}/${script_prefix}-post-install.sh" \
      -s "pre-deinstall:${temp_scripts}/${script_prefix}-pre-deinstall.sh" \
      -s "pre-upgrade:${temp_scripts}/${script_prefix}-pre-upgrade.sh" \
      -s "post-upgrade:${temp_scripts}/${script_prefix}-post-upgrade.sh"
  elif have_passwordless_sudo; then
    sudo chown -R 0:0 "$temp_root" "$temp_scripts"
    sudo "$apk_bin" mkpkg \
      --files "$temp_root" \
      --output "$output_file" \
      -I "name:${package_name}" \
      -I "version:${package_version}" \
      -I "description:${description}" \
      -I "arch:noarch" \
      -I "license:GPL-2.0-or-later" \
      -I "origin:podkop-plus" \
      -I "maintainer:${maintainer}" \
      -I "url:${PROJECT_URL}" \
      -I "depends:${depends}" \
      -s "pre-install:${temp_scripts}/${script_prefix}-pre-install.sh" \
      -s "post-install:${temp_scripts}/${script_prefix}-post-install.sh" \
      -s "pre-deinstall:${temp_scripts}/${script_prefix}-pre-deinstall.sh" \
      -s "pre-upgrade:${temp_scripts}/${script_prefix}-pre-upgrade.sh" \
      -s "post-upgrade:${temp_scripts}/${script_prefix}-post-upgrade.sh"
    sudo chown "$(id -u):$(id -g)" "$output_file"
    sudo rm -rf "$temp_root" "$temp_scripts"
  elif have_unshare_root; then
    unshare -r sh -c "
      chown -R 0:0 '$temp_root' '$temp_scripts'
      '$apk_bin' mkpkg \
        --files '$temp_root' \
        --output '$output_file' \
        -I 'name:${package_name}' \
        -I 'version:${package_version}' \
        -I 'description:${description}' \
        -I 'arch:noarch' \
        -I 'license:GPL-2.0-or-later' \
        -I 'origin:podkop-plus' \
        -I 'maintainer:${maintainer}' \
        -I 'url:${PROJECT_URL}' \
        -I 'depends:${depends}' \
        -s pre-install:'$temp_scripts/${script_prefix}-pre-install.sh' \
        -s post-install:'$temp_scripts/${script_prefix}-post-install.sh' \
        -s pre-deinstall:'$temp_scripts/${script_prefix}-pre-deinstall.sh' \
        -s pre-upgrade:'$temp_scripts/${script_prefix}-pre-upgrade.sh' \
        -s post-upgrade:'$temp_scripts/${script_prefix}-post-upgrade.sh'
    "
  else
    stderr_file="$(mktemp)"
    if ! fakeroot sh -c "
      chown -R 0:0 '$temp_root' '$temp_scripts'
      '$apk_bin' mkpkg \
        --files '$temp_root' \
        --output '$output_file' \
        -I 'name:${package_name}' \
        -I 'version:${package_version}' \
        -I 'description:${description}' \
        -I 'arch:noarch' \
        -I 'license:GPL-2.0-or-later' \
        -I 'origin:podkop-plus' \
        -I 'maintainer:${maintainer}' \
        -I 'url:${PROJECT_URL}' \
        -I 'depends:${depends}' \
        -s pre-install:'$temp_scripts/${script_prefix}-pre-install.sh' \
        -s post-install:'$temp_scripts/${script_prefix}-post-install.sh' \
        -s pre-deinstall:'$temp_scripts/${script_prefix}-pre-deinstall.sh' \
        -s pre-upgrade:'$temp_scripts/${script_prefix}-pre-upgrade.sh' \
        -s post-upgrade:'$temp_scripts/${script_prefix}-post-upgrade.sh'
    " 2>"$stderr_file"; then
      grep -v "object 'libfakeroot-.*so' from LD_PRELOAD cannot be preloaded" "$stderr_file" >&2 || true
      rm -f "$stderr_file"
      return 1
    fi
    grep -v "object 'libfakeroot-.*so' from LD_PRELOAD cannot be preloaded" "$stderr_file" >&2 || true
    rm -f "$stderr_file"
  fi
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
  rm -f "$dump_file"
}

cleanup_work_dir() {
  rm -rf "$WORK_DIR/manual" 2>/dev/null || {
    if have_passwordless_sudo; then
      sudo rm -rf "$WORK_DIR/manual"
    else
      return 1
    fi
  }

  rm -f "$WORK_DIR/ipk-build.log" 2>/dev/null || {
    if have_passwordless_sudo; then
      sudo rm -f "$WORK_DIR/ipk-build.log"
    else
      return 1
    fi
  }
}

sync_artifacts_to_windows() {
  local output_dir="$1"
  local output_real
  local windows_real

  [[ -n "$WINDOWS_ARTIFACTS_DIR" ]] || return 0

  mkdir -p "$WINDOWS_ARTIFACTS_DIR"
  output_real="$(readlink -f "$output_dir")"
  windows_real="$(readlink -f "$WINDOWS_ARTIFACTS_DIR")"

  if [[ "$output_real" == "$windows_real" ]]; then
    return 0
  fi

  rm -f \
    "$WINDOWS_ARTIFACTS_DIR"/podkop-plus_* \
    "$WINDOWS_ARTIFACTS_DIR"/luci-app-podkop-plus_* \
    "$WINDOWS_ARTIFACTS_DIR"/luci-i18n-podkop-plus-ru_*

  cp -f \
    "$output_dir"/podkop-plus_"${RELEASE_VERSION}"_all.ipk \
    "$output_dir"/luci-app-podkop-plus_"${RELEASE_VERSION}"_all.ipk \
    "$output_dir"/luci-i18n-podkop-plus-ru_"${RELEASE_VERSION}"_all.ipk \
    "$output_dir"/podkop-plus_"${RELEASE_VERSION}".apk \
    "$output_dir"/luci-app-podkop-plus_"${RELEASE_VERSION}".apk \
    "$output_dir"/luci-i18n-podkop-plus-ru_"${RELEASE_VERSION}".apk \
    "$WINDOWS_ARTIFACTS_DIR"/

  echo "Synced artifacts to Windows path: $WINDOWS_ARTIFACTS_DIR" >&2
}

print_summary() {
  local output_dir="$1"

  echo "Build root: $ROOT_DIR"
  echo "Output dir: $output_dir"
  if [[ -n "$WINDOWS_ARTIFACTS_DIR" ]]; then
    echo "Windows artifacts dir: $WINDOWS_ARTIFACTS_DIR"
  fi
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
  local manual_root="$WORK_DIR/manual"
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

  ensure_native_root
  ensure_host_deps

  mkdir -p "$WORK_DIR"
  output_dir="${OUTPUT_DIR_INPUT:-$ROOT_DIR/dist/release-final}"
  mkdir -p "$output_dir"
  rm -f "$output_dir"/podkop-plus_* "$output_dir"/luci-app-podkop-plus_* "$output_dir"/luci-i18n-podkop-plus-ru_*

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
    "podkop-plus" \
    "$backend_root" \
    "$backend_control" \
    "$output_dir/podkop-plus_${RELEASE_VERSION}_all.ipk"

  build_ipk_package \
    "$ipkg_build_bin" \
    "luci-app-podkop-plus" \
    "$app_root" \
    "$app_control" \
    "$output_dir/luci-app-podkop-plus_${RELEASE_VERSION}_all.ipk"

  build_ipk_package \
    "$ipkg_build_bin" \
    "luci-i18n-podkop-plus-ru" \
    "$i18n_root" \
    "$i18n_control" \
    "$output_dir/luci-i18n-podkop-plus-ru_${RELEASE_VERSION}_all.ipk"

  generate_apk_metadata_files "podkop-plus" "$backend_root" "/etc/config/podkop-plus"
  generate_apk_metadata_files "luci-app-podkop-plus" "$app_root"
  generate_apk_metadata_files "luci-i18n-podkop-plus-ru" "$i18n_root"
  write_backend_apk_scripts "$apk_scripts"
  write_app_apk_scripts "$apk_scripts"
  write_i18n_apk_scripts "$apk_scripts"

  build_apk_package \
    "$apk_bin" \
    "podkop-plus" \
    "$APK_INTERNAL_VERSION" \
    "$BACKEND_DESCRIPTION" \
    "$BACKEND_DEPENDS_APK" \
    "$backend_root" \
    "$apk_scripts" \
    "backend" \
    "$output_dir/podkop-plus_${RELEASE_VERSION}.apk" \
    "$MAINTAINER"

  build_apk_package \
    "$apk_bin" \
    "luci-app-podkop-plus" \
    "$APK_INTERNAL_VERSION" \
    "$APP_DESCRIPTION" \
    "$APP_DEPENDS_APK" \
    "$app_root" \
    "$apk_scripts" \
    "app" \
    "$output_dir/luci-app-podkop-plus_${RELEASE_VERSION}.apk" \
    "$MAINTAINER"

  build_apk_package \
    "$apk_bin" \
    "luci-i18n-podkop-plus-ru" \
    "$APK_INTERNAL_VERSION" \
    "$I18N_DESCRIPTION" \
    "libc luci-app-podkop-plus" \
    "$i18n_root" \
    "$apk_scripts" \
    "i18n" \
    "$output_dir/luci-i18n-podkop-plus-ru_${RELEASE_VERSION}.apk" \
    "$MAINTAINER"

  verify_ipk_metadata "$output_dir/podkop-plus_${RELEASE_VERSION}_all.ipk" "podkop-plus" "$RELEASE_VERSION"
  verify_ipk_metadata "$output_dir/luci-app-podkop-plus_${RELEASE_VERSION}_all.ipk" "luci-app-podkop-plus" "$RELEASE_VERSION"
  verify_ipk_metadata "$output_dir/luci-i18n-podkop-plus-ru_${RELEASE_VERSION}_all.ipk" "luci-i18n-podkop-plus-ru" "$RELEASE_VERSION"
  verify_apk_metadata "$apk_bin" "$output_dir/podkop-plus_${RELEASE_VERSION}.apk" "podkop-plus" "$APK_INTERNAL_VERSION"
  verify_apk_metadata "$apk_bin" "$output_dir/luci-app-podkop-plus_${RELEASE_VERSION}.apk" "luci-app-podkop-plus" "$APK_INTERNAL_VERSION"
  verify_apk_metadata "$apk_bin" "$output_dir/luci-i18n-podkop-plus-ru_${RELEASE_VERSION}.apk" "luci-i18n-podkop-plus-ru" "$APK_INTERNAL_VERSION"

  cleanup_work_dir
  sync_artifacts_to_windows "$output_dir"
  print_summary "$output_dir"
}

main "$@"
