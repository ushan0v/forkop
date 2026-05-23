#!/bin/sh
# shellcheck shell=dash

REPO_OWNER="ushan0v"
REPO_NAME="podkop-plus"

REQUIRED_SPACE_KB=15360

PKG_IS_APK=0
FETCHER=""
TMP_DIR=""
PODKOP_WAS_ENABLED=0
PODKOP_WAS_RUNNING=0
TARGET_ARCH=""
ZAPRET_ARCH=""
ZAPRET_ARCH_CANDIDATES=""
ZAPRET_ALREADY_PRESENT=0
ZAPRET_INSTALLED=0
ZAPRET_UP_TO_DATE=0
ZAPRET_INSTALLED_VERSION=""
ZAPRET_REQUESTED=0
ZAPRET_SKIPPED_REASON=""
ZAPRET_INSTALL_CHOICE="${PODKOP_PLUS_INSTALL_ZAPRET:-${INSTALL_ZAPRET:-}}"
BYEDPI_ARCH=""
BYEDPI_ALREADY_PRESENT=0
BYEDPI_INSTALLED=0
BYEDPI_UP_TO_DATE=0
BYEDPI_INSTALLED_VERSION=""
BYEDPI_REQUESTED=0
BYEDPI_SKIPPED_REASON=""
BYEDPI_INSTALL_CHOICE="${PODKOP_PLUS_INSTALL_BYEDPI:-${INSTALL_BYEDPI:-}}"
AWG_ALREADY_PRESENT=0
AWG_INSTALLED=0
AWG_UP_TO_DATE=0
AWG_REQUESTED=0
AWG_SKIPPED_REASON=""
AWG_INSTALL_CHOICE="${PODKOP_PLUS_INSTALL_AWG:-${INSTALL_AWG:-}}"
AWG_OPENWRT_VERSION=""
AWG_TARGET=""
AWG_SUBTARGET=""
AWG_ARCH=""
AWG_VERSION=""
AWG_RELEASE_TAG_RESOLVED=""
AWG_BASE_URL=""
AWG_PACKAGE_EXT=""
AWG_LUCI_PACKAGE_NAME=""
AWG_PACKAGE_FILES=""
AWG_PACKAGE_VERSION=""
SING_BOX_INSTALL_CHOICE="${PODKOP_PLUS_SING_BOX:-${SING_BOX_FLAVOR:-}}"
SING_BOX_ACTION="keep"
SING_BOX_CURRENT_VERSION=""
SING_BOX_CURRENT_IS_EXTENDED=0
SING_BOX_EXTENDED_RELEASE_JSON=""
SING_BOX_EXTENDED_RELEASE_TAG=""
SING_BOX_EXTENDED_ARCH_SUFFIX=""
SING_BOX_EXTENDED_ASSET_NAME=""
SING_BOX_EXTENDED_ASSET_URL=""
SING_BOX_EXTENDED_BACKUP_FILE=""
SING_BOX_EXTENDED_WORK_DIR=""
PODKOP_PLUS_I18N_REQUESTED=0

PODKOP_PLUS_RELEASE_JSON=""
PODKOP_PLUS_RELEASE_TAG=""
PODKOP_PLUS_BACKEND_URL=""
PODKOP_PLUS_BACKEND_NAME=""
PODKOP_PLUS_BACKEND_FILE=""
PODKOP_PLUS_APP_URL=""
PODKOP_PLUS_APP_NAME=""
PODKOP_PLUS_APP_FILE=""
PODKOP_PLUS_I18N_URL=""
PODKOP_PLUS_I18N_NAME=""
PODKOP_PLUS_I18N_FILE=""
PODKOP_PLUS_PACKAGE_VERSION=""
PODKOP_PLUS_SUPPORTED_MIGRATION_VERSION="0.7.17-8"
PODKOP_PLUS_INSTALLED_VERSION=""
PODKOP_PLUS_RESET_CONFIG=0

ZAPRET_RELEASE_JSON=""
ZAPRET_RELEASE_TAG_RESOLVED=""
ZAPRET_BUNDLE_URL=""
ZAPRET_BUNDLE_NAME=""
ZAPRET_PACKAGE_NAME=""
ZAPRET_PACKAGE_FILE=""
ZAPRET_PACKAGE_VERSION=""

BYEDPI_RELEASE_JSON=""
BYEDPI_RELEASE_TAG_RESOLVED=""
BYEDPI_PACKAGE_URL=""
BYEDPI_PACKAGE_NAME=""
BYEDPI_PACKAGE_FILE=""
BYEDPI_PACKAGE_VERSION=""

OPTIONAL_INSTALLED_VERSION=""
INSTALLER_LANG="en"

command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

msg() {
    printf '\033[32;1m%s\033[0m\n' "$1"
}

warn() {
    printf '\033[33;1m%s\033[0m\n' "$1"
}

fail() {
    printf '\033[31;1m%s\033[0m\n' "$1" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 [--with-zapret|--without-zapret] [--with-byedpi|--without-byedpi] [--with-awg|--without-awg] [--sing-box=stock|extended|keep]

Options:
  --with-zapret       Install the optional external zapret provider package.
  --without-zapret    Install Podkop Plus without the zapret provider.
  --with-byedpi       Install the optional external ByeDPI provider package.
  --without-byedpi    Install Podkop Plus without the ByeDPI provider.
  --with-awg          Install optional AmneziaWG OpenWrt packages.
  --without-awg       Install Podkop Plus without AmneziaWG packages.
  --sing-box=stock    Use the regular stable sing-box package from OpenWrt.
  --sing-box=extended Install or refresh sing-box-extended for XHTTP support.
  --sing-box=keep     Keep the current sing-box flavor.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --with-zapret)
                ZAPRET_INSTALL_CHOICE=1
                ;;
            --without-zapret)
                ZAPRET_INSTALL_CHOICE=0
                ;;
            --with-byedpi)
                BYEDPI_INSTALL_CHOICE=1
                ;;
            --without-byedpi)
                BYEDPI_INSTALL_CHOICE=0
                ;;
            --with-awg)
                AWG_INSTALL_CHOICE=1
                ;;
            --without-awg)
                AWG_INSTALL_CHOICE=0
                ;;
            --with-sing-box-extended)
                SING_BOX_INSTALL_CHOICE="extended"
                ;;
            --with-stock-sing-box)
                SING_BOX_INSTALL_CHOICE="stock"
                ;;
            --sing-box=*)
                SING_BOX_INSTALL_CHOICE="${1#--sing-box=}"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown installer option: $1"
                ;;
        esac
        shift
    done
}

cleanup() {
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    [ -n "$SING_BOX_EXTENDED_WORK_DIR" ] && rm -rf "$SING_BOX_EXTENDED_WORK_DIR"
}

clear_zapret_download_state() {
    ZAPRET_RELEASE_JSON=""
    ZAPRET_RELEASE_TAG_RESOLVED=""
    ZAPRET_BUNDLE_URL=""
    ZAPRET_BUNDLE_NAME=""
    ZAPRET_PACKAGE_NAME=""
    ZAPRET_PACKAGE_FILE=""
    ZAPRET_PACKAGE_VERSION=""
    ZAPRET_ARCH=""
    ZAPRET_INSTALLED=0
    ZAPRET_UP_TO_DATE=0
    ZAPRET_INSTALLED_VERSION=""
}

clear_byedpi_download_state() {
    BYEDPI_RELEASE_JSON=""
    BYEDPI_RELEASE_TAG_RESOLVED=""
    BYEDPI_PACKAGE_URL=""
    BYEDPI_PACKAGE_NAME=""
    BYEDPI_PACKAGE_FILE=""
    BYEDPI_PACKAGE_VERSION=""
    BYEDPI_ARCH=""
    BYEDPI_INSTALLED=0
    BYEDPI_UP_TO_DATE=0
    BYEDPI_INSTALLED_VERSION=""
}

clear_awg_download_state() {
    AWG_OPENWRT_VERSION=""
    AWG_TARGET=""
    AWG_SUBTARGET=""
    AWG_ARCH=""
    AWG_VERSION=""
    AWG_RELEASE_TAG_RESOLVED=""
    AWG_BASE_URL=""
    AWG_PACKAGE_EXT=""
    AWG_LUCI_PACKAGE_NAME=""
    AWG_PACKAGE_FILES=""
    AWG_PACKAGE_VERSION=""
    AWG_INSTALLED=0
    AWG_UP_TO_DATE=0
}

read_openwrt_release_value() {
    key="$1"

    [ -f /etc/openwrt_release ] || return 0
    sed -n "s/^${key}='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

init_tmp_dir() {
    TMP_DIR="$(mktemp -d /tmp/podkop-plus.XXXXXX 2>/dev/null || true)"

    if [ -z "$TMP_DIR" ]; then
        TMP_DIR="/tmp/podkop-plus.$$"
        mkdir -p "$TMP_DIR" || fail "Failed to create temporary directory: $TMP_DIR"
    fi
}

detect_fetcher() {
    if command_exists wget; then
        FETCHER="wget"
        return 0
    fi

    if command_exists curl; then
        FETCHER="curl"
        return 0
    fi

    fail "wget or curl is required to download Podkop Plus"
}

http_get() {
    case "$FETCHER" in
        wget)
            wget -qO- "$1"
            ;;
        curl)
            curl -fsSL "$1"
            ;;
        *)
            return 1
            ;;
    esac
}

download_file_once() {
    case "$FETCHER" in
        wget)
            wget -q -O "$2" "$1"
            ;;
        curl)
            curl -fsSL "$1" -o "$2"
            ;;
        *)
            return 1
            ;;
    esac
}

download_with_retry() {
    url="$1"
    output_path="$2"
    label="$3"
    attempt=1
    max_attempts=3

    while [ "$attempt" -le "$max_attempts" ]; do
        msg "Downloading $label ($attempt/$max_attempts)"

        if download_file_once "$url" "$output_path" && [ -s "$output_path" ]; then
            return 0
        fi

        rm -f "$output_path"
        warn "Retrying $label"
        attempt=$((attempt + 1))
    done

    return 1
}

pkg_list_installed_names() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info 2>/dev/null
    else
        opkg list-installed 2>/dev/null | awk '{print $1}'
    fi
}

pkg_is_installed() {
    pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info -e "$pkg_name" >/dev/null 2>&1
    else
        opkg list-installed 2>/dev/null | grep -Eq "^${pkg_name}([[:space:]-]|$)"
    fi
}

get_installed_package_version() {
    pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info -e "$pkg_name" >/dev/null 2>&1 || return 0
        apk info -v "$pkg_name" 2>/dev/null | sed "s/^${pkg_name}-//" | sed -n '1p'
    else
        opkg list-installed 2>/dev/null | awk -v pkg="$pkg_name" '$1 == pkg && $2 == "-" {print $3; exit}'
    fi
}

package_version_newer() {
    candidate_version="$1"
    installed_version="$2"
    apk_compare_result=""

    [ -n "$candidate_version" ] || return 1
    [ -n "$installed_version" ] || return 1
    [ "$candidate_version" != "$installed_version" ] || return 1

    if [ "$PKG_IS_APK" -eq 1 ] && command_exists apk; then
        apk_compare_result="$(apk version -t "$candidate_version" "$installed_version" 2>/dev/null || true)"
        [ "$apk_compare_result" = ">" ]
        return $?
    fi

    if command_exists opkg; then
        opkg compare-versions "$candidate_version" ">" "$installed_version" >/dev/null 2>&1
        return $?
    fi

    version_ge "$candidate_version" "$installed_version"
}

optional_package_update_needed() {
    provider_label="$1"
    package_name="$2"
    candidate_version="$3"

    if [ -z "$candidate_version" ]; then
        warn "$provider_label release was found, but the package version could not be parsed."
        return 2
    fi

    OPTIONAL_INSTALLED_VERSION="$(get_installed_package_version "$package_name")"

    if [ -z "$OPTIONAL_INSTALLED_VERSION" ]; then
        warn "$provider_label is already present, but the installed package version could not be detected."
        return 2
    fi

    if package_version_newer "$candidate_version" "$OPTIONAL_INSTALLED_VERSION"; then
        msg "Found $provider_label update: $OPTIONAL_INSTALLED_VERSION -> $candidate_version"
        return 0
    fi

    msg "$provider_label is already up to date ($OPTIONAL_INSTALLED_VERSION)"
    return 1
}

is_zapret_present() {
    pkg_is_installed "zapret" || [ -x /opt/zapret/nfq/nfqws ]
}

is_byedpi_present() {
    pkg_is_installed "byedpi" || [ -x /usr/bin/ciadpi ] || [ -x /etc/init.d/byedpi ]
}

is_awg_present() {
    pkg_is_installed "kmod-amneziawg" ||
        pkg_is_installed "amneziawg-tools" ||
        pkg_is_installed "luci-proto-amneziawg" ||
        pkg_is_installed "luci-app-amneziawg" ||
        command_exists awg ||
        command_exists awg-quick ||
        [ -d /sys/module/amneziawg ]
}

warn_zapret_unavailable() {
    reason="$1"

    if [ "$ZAPRET_ALREADY_PRESENT" -eq 1 ]; then
        warn "$reason Keeping the existing zapret provider."
    else
        warn "$reason Continuing without zapret provider."
    fi
}

warn_byedpi_unavailable() {
    reason="$1"

    if [ "$BYEDPI_ALREADY_PRESENT" -eq 1 ]; then
        warn "$reason Keeping the existing ByeDPI provider."
    else
        warn "$reason Continuing without ByeDPI provider."
    fi
}

warn_awg_unavailable() {
    reason="$1"

    if [ "$AWG_ALREADY_PRESENT" -eq 1 ]; then
        warn "$reason Keeping the existing AmneziaWG installation."
    else
        warn "$reason Continuing without AmneziaWG packages."
    fi
}

pkg_list_update() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk update </dev/null
    else
        opkg update </dev/null
    fi
}

pkg_install_name() {
    pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add "$pkg_name" </dev/null
    else
        opkg install "$pkg_name" </dev/null
    fi
}

pkg_remove_if_installed() {
    pkg_name="$1"

    if ! pkg_is_installed "$pkg_name"; then
        return 0
    fi

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk del "$pkg_name" >/dev/null 2>&1 </dev/null || true
    else
        opkg remove --force-depends "$pkg_name" >/dev/null 2>&1 </dev/null || true
    fi
}

pkg_remove_matching_prefix() {
    prefix="$1"

    for pkg_name in $(pkg_list_installed_names | grep "^$prefix" 2>/dev/null); do
        pkg_remove_if_installed "$pkg_name"
    done
}

pkg_install_files() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted "$@" </dev/null
    else
        opkg install --force-overwrite --force-downgrade "$@" </dev/null
    fi
}

ensure_bootstrap_tool() {
    tool_name="$1"
    package_name="$2"

    if command_exists "$tool_name"; then
        return 0
    fi

    msg "Installing bootstrap dependency: $package_name"
    pkg_install_name "$package_name" || fail "Failed to install $package_name"
}

sync_time() {
    current_year=""

    if ! command_exists ntpd; then
        return 0
    fi

    current_year="$(date +%Y 2>/dev/null || true)"
    case "$current_year" in
        ''|*[!0-9]*) current_year=0 ;;
    esac

    if [ "$current_year" -ge 2024 ]; then
        return 0
    fi

    ntpd -q \
        -p 194.190.168.1 \
        -p 216.239.35.0 \
        -p 216.239.35.4 \
        -p 162.159.200.1 \
        -p 162.159.200.123 >/dev/null 2>&1 || true
}

check_root() {
    if command_exists id && [ "$(id -u)" != "0" ]; then
        fail "Please run this installer as root"
    fi
}

check_system() {
    release=""
    major=""
    model=""
    available_space=""

    [ -f /etc/openwrt_release ] || fail "This installer supports OpenWrt only"

    model="$(cat /tmp/sysinfo/model 2>/dev/null || true)"
    [ -n "$model" ] && msg "Router model: $model"

    release="$(read_openwrt_release_value "DISTRIB_RELEASE")"
    major="$(printf '%s' "$release" | sed 's/[^0-9].*$//' | cut -d. -f1)"

    if [ -n "$major" ] && [ "$major" -lt 24 ]; then
        fail "Podkop Plus requires OpenWrt 24.10 or newer"
    fi

    available_space="$(df /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
    [ -n "$available_space" ] || available_space="$(df / 2>/dev/null | awk 'NR==2 {print $4}')"

    if [ -n "$available_space" ] && [ "$available_space" -lt "$REQUIRED_SPACE_KB" ]; then
        fail "Not enough free flash space. Available: $((available_space / 1024)) MB, required: $((REQUIRED_SPACE_KB / 1024)) MB"
    fi
}

confirm_prompt() {
    prompt_text="$1"
    answer=""

    if [ ! -t 0 ]; then
        msg "$prompt_text [y/N]: y (non-interactive)"
        return 0
    fi

    while :; do
        printf '%s [y/N]: ' "$prompt_text"
        read -r answer || return 1

        case "$answer" in
            y|Y)
                return 0
                ;;
            n|N|"")
                return 1
                ;;
            *)
                warn "Please answer y or n."
                ;;
        esac
    done
}

localized_prompt() {
    prompt_id="$1"

    case "${INSTALLER_LANG:-en}:$prompt_id" in
        ru:remove_dns_proxy)
            printf '%s' "Удалить конфликтующий пакет https-dns-proxy и продолжить?"
            ;;
        *:remove_dns_proxy)
            printf '%s' "Remove the conflicting https-dns-proxy package and continue?"
            ;;
        ru:install_awg)
            printf '%s' "Установить службу AmneziaWG?"
            ;;
        *:install_awg)
            printf '%s' "Install the AmneziaWG service?"
            ;;
        ru:install_zapret)
            printf '%s' "Установить службу Zapret?"
            ;;
        *:install_zapret)
            printf '%s' "Install the Zapret service?"
            ;;
        ru:install_byedpi)
            printf '%s' "Установить службу ByeDPI?"
            ;;
        *:install_byedpi)
            printf '%s' "Install the ByeDPI service?"
            ;;
        ru:install_sing_box_extended)
            printf '%s' "Установить неофициальный sing-box-extended для поддержки XHTTP вместо обычного стабильного sing-box?"
            ;;
        *:install_sing_box_extended)
            printf '%s' "Install unofficial sing-box-extended for XHTTP support instead of the regular stable sing-box?"
            ;;
        ru:replace_sing_box_extended)
            printf '%s' "Заменить установленный sing-box-extended на обычный стабильный sing-box?"
            ;;
        *:replace_sing_box_extended)
            printf '%s' "Replace the installed sing-box-extended with the regular stable sing-box?"
            ;;
        ru:reset_unsupported_config)
            printf '%s' "Миграция конфигурации Podkop Plus из установленной версии не поддерживается. Удалить /etc/config/podkop-plus и продолжить установку с чистой конфигурацией?"
            ;;
        *:reset_unsupported_config)
            printf '%s' "Podkop Plus config migration from the installed version is not supported. Remove /etc/config/podkop-plus and continue with a clean configuration?"
            ;;
    esac
}

get_luci_main_lang() {
    command_exists uci || return 0
    uci -q get luci.main.lang 2>/dev/null || true
}

sanitize_semver() {
    printf '%s\n' "$1" | sed 's/^v//;s/-.*$//;s/[^0-9.].*$//'
}

version_ge() {
    lhs_major=0
    lhs_minor=0
    lhs_patch=0
    rhs_major=0
    rhs_minor=0
    rhs_patch=0

    lhs_version="$(sanitize_semver "$1")"
    rhs_version="$(sanitize_semver "$2")"

    old_ifs="$IFS"
    IFS='.'
    set -- $lhs_version
    IFS="$old_ifs"
    [ -n "$1" ] && lhs_major="$1"
    [ -n "$2" ] && lhs_minor="$2"
    [ -n "$3" ] && lhs_patch="$3"

    IFS='.'
    set -- $rhs_version
    IFS="$old_ifs"
    [ -n "$1" ] && rhs_major="$1"
    [ -n "$2" ] && rhs_minor="$2"
    [ -n "$3" ] && rhs_patch="$3"

    if [ "$lhs_major" -gt "$rhs_major" ]; then
        return 0
    fi
    if [ "$lhs_major" -lt "$rhs_major" ]; then
        return 1
    fi

    if [ "$lhs_minor" -gt "$rhs_minor" ]; then
        return 0
    fi
    if [ "$lhs_minor" -lt "$rhs_minor" ]; then
        return 1
    fi

    [ "$lhs_patch" -ge "$rhs_patch" ]
}

normalize_podkop_plus_release_version() {
    printf '%s\n' "$1" | sed 's/^v//;s/-r\([0-9][0-9]*\)$/-\1/'
}

podkop_plus_release_version_parts() {
    version="$(normalize_podkop_plus_release_version "$1")"
    release=0

    case "$version" in
        *-*)
            release="${version##*-}"
            version="${version%-*}"
            ;;
        *.*.*.*)
            release="${version##*.}"
            version="${version%.*}"
            ;;
    esac

    case "$version" in ''|*[!0-9.]*|.*|*.) return 1 ;; esac
    case "$release" in ''|*[!0-9]*) return 1 ;; esac

    old_ifs="$IFS"
    IFS='.'
    set -- $version
    IFS="$old_ifs"

    [ -n "$1" ] || return 1
    case "$1" in *[!0-9]*) return 1 ;; esac
    case "${2:-0}" in *[!0-9]*) return 1 ;; esac
    case "${3:-0}" in *[!0-9]*) return 1 ;; esac

    printf '%s %s %s %s\n' "$1" "${2:-0}" "${3:-0}" "$release"
}

podkop_plus_release_version_lt() {
    lhs_parts="$(podkop_plus_release_version_parts "$1")" || return 1
    rhs_parts="$(podkop_plus_release_version_parts "$2")" || return 1

    set -- $lhs_parts
    lhs_major="$1"
    lhs_minor="$2"
    lhs_patch="$3"
    lhs_release="$4"

    set -- $rhs_parts
    rhs_major="$1"
    rhs_minor="$2"
    rhs_patch="$3"
    rhs_release="$4"

    [ "$lhs_major" -lt "$rhs_major" ] && return 0
    [ "$lhs_major" -gt "$rhs_major" ] && return 1
    [ "$lhs_minor" -lt "$rhs_minor" ] && return 0
    [ "$lhs_minor" -gt "$rhs_minor" ] && return 1
    [ "$lhs_patch" -lt "$rhs_patch" ] && return 0
    [ "$lhs_patch" -gt "$rhs_patch" ] && return 1
    [ "$lhs_release" -lt "$rhs_release" ]
}

extract_package_version() {
    package_name="$1"

    case "$package_name" in
        podkop-plus_*.ipk)
            printf '%s\n' "$package_name" | sed 's/^podkop-plus_//;s/_[^_]*\.ipk$//'
            ;;
        podkop-plus_*.apk)
            printf '%s\n' "$package_name" | sed 's/^podkop-plus_//;s/\.apk$//'
            ;;
        podkop-plus-*.ipk)
            printf '%s\n' "$package_name" | sed 's/^podkop-plus-//;s/-[^-]*\.ipk$//'
            ;;
        podkop-plus-*.apk)
            printf '%s\n' "$package_name" | sed 's/^podkop-plus-//;s/\.apk$//'
            ;;
        luci-app-podkop-plus_*.ipk)
            printf '%s\n' "$package_name" | sed 's/^luci-app-podkop-plus_//;s/_[^_]*\.ipk$//'
            ;;
        luci-app-podkop-plus_*.apk)
            printf '%s\n' "$package_name" | sed 's/^luci-app-podkop-plus_//;s/\.apk$//'
            ;;
        luci-app-podkop-plus-*.ipk)
            printf '%s\n' "$package_name" | sed 's/^luci-app-podkop-plus-//;s/-[^-]*\.ipk$//'
            ;;
        luci-app-podkop-plus-*.apk)
            printf '%s\n' "$package_name" | sed 's/^luci-app-podkop-plus-//;s/\.apk$//'
            ;;
        zapret_*.ipk)
            printf '%s\n' "$package_name" | sed 's/^zapret_//;s/_[^_]*\.ipk$//'
            ;;
        zapret-*.apk)
            printf '%s\n' "$package_name" | sed 's/^zapret-//;s/\.apk$//'
            ;;
        byedpi_*.ipk)
            printf '%s\n' "$package_name" | sed 's/^byedpi_//;s/_[^_]*\.ipk$//'
            ;;
        byedpi_*.apk)
            printf '%s\n' "$package_name" | sed 's/^byedpi_//;s/\.apk$//'
            ;;
        byedpi-*.ipk)
            printf '%s\n' "$package_name" | sed 's/^byedpi-//;s/-[^-]*\.ipk$//'
            ;;
        byedpi-*.apk)
            printf '%s\n' "$package_name" | sed 's/^byedpi-//;s/\.apk$//'
            ;;
        *)
            printf '%s\n' "$package_name"
            ;;
    esac
}

extract_arch_package_version() {
    package_name="$1"
    package_arch="$2"
    version=""

    version="$(printf '%s\n' "$package_name" | sed 's/\.ipk$//;s/\.apk$//')"

    case "$version" in
        zapret_*)
            version="${version#zapret_}"
            ;;
        zapret-*)
            version="${version#zapret-}"
            ;;
        byedpi_*)
            version="${version#byedpi_}"
            ;;
        byedpi-*)
            version="${version#byedpi-}"
            ;;
    esac

    if [ -n "$package_arch" ]; then
        case "$version" in
            *_$package_arch)
                version="${version%_$package_arch}"
                ;;
            *-$package_arch)
                version="${version%-$package_arch}"
                ;;
        esac
    fi

    printf '%s\n' "$version"
}

fetch_github_release_json() {
    owner="$1"
    repo="$2"
    response=""
    message=""
    url="https://api.github.com/repos/${owner}/${repo}/releases/latest"

    response="$(http_get "$url" 2>/dev/null || true)"
    [ -n "$response" ] || fail "Failed to query GitHub release metadata for ${owner}/${repo}"

    printf '%s' "$response" | jq -e . >/dev/null 2>&1 || fail "GitHub returned an invalid response for ${owner}/${repo}"

    message="$(printf '%s' "$response" | jq -r 'if type == "object" then (.message // empty) else empty end' 2>/dev/null)"
    case "$message" in
        *"API rate limit"*|*"rate limit exceeded"*)
            fail "GitHub API rate limit reached. Try again later."
            ;;
        "Not Found")
            fail "No published releases found for ${owner}/${repo}"
            ;;
    esac

    printf '%s' "$response"
}

fetch_github_releases_json() {
    owner="$1"
    repo="$2"
    response=""
    message=""
    url="https://api.github.com/repos/${owner}/${repo}/releases?per_page=50"

    response="$(http_get "$url" 2>/dev/null || true)"
    [ -n "$response" ] || fail "Failed to query GitHub releases metadata for ${owner}/${repo}"

    printf '%s' "$response" | jq -e . >/dev/null 2>&1 || fail "GitHub returned an invalid response for ${owner}/${repo}"

    message="$(printf '%s' "$response" | jq -r 'if type == "object" then (.message // empty) else empty end' 2>/dev/null)"
    case "$message" in
        *"API rate limit"*|*"rate limit exceeded"*)
            fail "GitHub API rate limit reached. Try again later."
            ;;
        "Not Found")
            fail "No published releases found for ${owner}/${repo}"
            ;;
    esac

    printf '%s' "$response"
}

select_latest_podkop_plus_release_json() {
    asset_ext="$1"
    releases_file=""
    best_tag=""
    tag=""

    releases_file="$(mktemp)"
    cat > "$releases_file"

    for tag in $(jq -r --arg ext "$asset_ext" '
        .[]
        | select(((.draft // false) | not) and ((.prerelease // false) | not))
        | select(any(.assets[]?; ((.name | startswith("podkop-plus_")) or (.name | startswith("podkop-plus-"))) and (.name | endswith("." + $ext))))
        | select(any(.assets[]?; ((.name | startswith("luci-app-podkop-plus_")) or (.name | startswith("luci-app-podkop-plus-"))) and (.name | endswith("." + $ext))))
        | .tag_name // empty
    ' "$releases_file"); do
        podkop_plus_release_version_parts "$tag" >/dev/null 2>&1 || continue

        if [ -z "$best_tag" ] || podkop_plus_release_version_lt "$best_tag" "$tag"; then
            best_tag="$tag"
        fi
    done

    if [ -n "$best_tag" ]; then
        jq -c --arg tag "$best_tag" '.[] | select(.tag_name == $tag)' "$releases_file" | sed -n '1p'
    fi

    rm -f "$releases_file"
}

resolve_podkop_plus_release() {
    asset_ext="ipk"

    [ "$PKG_IS_APK" -eq 1 ] && asset_ext="apk"

    PODKOP_PLUS_RELEASE_JSON="$(fetch_github_releases_json "$REPO_OWNER" "$REPO_NAME" | select_latest_podkop_plus_release_json "$asset_ext")"
    PODKOP_PLUS_RELEASE_TAG="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | jq -r '.tag_name // empty')"
    [ -n "$PODKOP_PLUS_RELEASE_TAG" ] || fail "Failed to detect the Podkop Plus release tag"

    PODKOP_PLUS_BACKEND_URL="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | jq -r --arg ext "$asset_ext" '.assets[] | select(((.name | startswith("podkop-plus_")) or (.name | startswith("podkop-plus-"))) and (.name | endswith("." + $ext))) | .browser_download_url' | sed -n '1p')"
    [ -n "$PODKOP_PLUS_BACKEND_URL" ] || fail "The Podkop Plus release does not contain a podkop-plus .$asset_ext package"

    PODKOP_PLUS_APP_URL="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | jq -r --arg ext "$asset_ext" '.assets[] | select(((.name | startswith("luci-app-podkop-plus_")) or (.name | startswith("luci-app-podkop-plus-"))) and (.name | endswith("." + $ext))) | .browser_download_url' | sed -n '1p')"
    [ -n "$PODKOP_PLUS_APP_URL" ] || fail "The Podkop Plus release does not contain a luci-app-podkop-plus .$asset_ext package"

    PODKOP_PLUS_BACKEND_NAME="$(basename "$PODKOP_PLUS_BACKEND_URL")"
    PODKOP_PLUS_APP_NAME="$(basename "$PODKOP_PLUS_APP_URL")"
    PODKOP_PLUS_PACKAGE_VERSION="$(extract_package_version "$PODKOP_PLUS_BACKEND_NAME")"

    PODKOP_PLUS_I18N_URL=""
    PODKOP_PLUS_I18N_NAME=""

    if [ "$PODKOP_PLUS_I18N_REQUESTED" -eq 1 ]; then
        PODKOP_PLUS_I18N_URL="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | jq -r --arg ext "$asset_ext" '.assets[] | select(((.name | startswith("luci-i18n-podkop-plus-ru_")) or (.name | startswith("luci-i18n-podkop-plus-ru-"))) and (.name | endswith("." + $ext))) | .browser_download_url' | sed -n '1p')"
        [ -n "$PODKOP_PLUS_I18N_URL" ] || fail "The Podkop Plus release does not contain a luci-i18n-podkop-plus-ru .$asset_ext package"
        PODKOP_PLUS_I18N_NAME="$(basename "$PODKOP_PLUS_I18N_URL")"
    fi
}

remove_conflicting_dns_proxy() {
    if ! pkg_is_installed "https-dns-proxy"; then
        return 0
    fi

    warn "Detected conflicting package: https-dns-proxy"
    confirm_prompt "$(localized_prompt remove_dns_proxy)" || fail "Please remove https-dns-proxy manually and run the installer again"

    pkg_remove_if_installed "luci-app-https-dns-proxy"
    pkg_remove_if_installed "https-dns-proxy"
    pkg_remove_matching_prefix "luci-i18n-https-dns-proxy"
}

remove_old_sing_box_if_needed() {
    installed_version=""
    required_version="1.12.4"

    pkg_is_installed "sing-box" || return 0
    command_exists sing-box || return 0

    installed_version="$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')"
    [ -n "$installed_version" ] || return 0

    if version_ge "$installed_version" "$required_version"; then
        return 0
    fi

    warn "sing-box $installed_version is older than the required version $required_version. Removing the old package first."
    [ -x /etc/init.d/podkop-plus ] && /etc/init.d/podkop-plus stop >/dev/null 2>&1 || true
    [ -x /etc/init.d/podkop ] && /etc/init.d/podkop stop >/dev/null 2>&1 || true
    pkg_remove_if_installed "sing-box"
}

get_sing_box_binary_version() {
    command_exists sing-box || return 0
    sing-box version 2>/dev/null | head -n 1 | awk '{print $NF}'
}

sing_box_version_is_extended() {
    case "$1" in
        *extended*)
            return 0
            ;;
    esac

    return 1
}

detect_sing_box_flavor() {
    SING_BOX_CURRENT_VERSION="$(get_sing_box_binary_version)"
    SING_BOX_CURRENT_IS_EXTENDED=0

    if [ -n "$SING_BOX_CURRENT_VERSION" ] && sing_box_version_is_extended "$SING_BOX_CURRENT_VERSION"; then
        SING_BOX_CURRENT_IS_EXTENDED=1
    fi
}

normalize_sing_box_choice() {
    case "$1" in
        extended|sing-box-extended|xhttp|yes|YES|true|TRUE|y|Y|1)
            printf 'extended'
            ;;
        stock|regular|stable|original|official|sing-box|no|NO|false|FALSE|n|N|0)
            printf 'stock'
            ;;
        keep|"")
            printf 'keep'
            ;;
        *)
            fail "Unknown sing-box flavor: $1"
            ;;
    esac
}

decide_sing_box_installation() {
    choice="$(normalize_sing_box_choice "$SING_BOX_INSTALL_CHOICE")"
    detect_sing_box_flavor

    case "$choice" in
        extended)
            SING_BOX_ACTION="install_extended"
            return 0
            ;;
        stock)
            SING_BOX_ACTION="install_stock"
            return 0
            ;;
        keep)
            ;;
    esac

    if [ "$SING_BOX_CURRENT_IS_EXTENDED" -eq 1 ]; then
        msg "Detected sing-box-extended $SING_BOX_CURRENT_VERSION."

        if [ ! -t 0 ]; then
            SING_BOX_ACTION="preserve_extended"
            msg "Keeping sing-box-extended in non-interactive mode."
            return 0
        fi

        if confirm_prompt "$(localized_prompt replace_sing_box_extended)"; then
            SING_BOX_ACTION="install_stock"
        else
            SING_BOX_ACTION="preserve_extended"
            msg "Keeping sing-box-extended after Podkop Plus installation."
        fi
        return 0
    fi

    if [ -n "$SING_BOX_CURRENT_VERSION" ]; then
        msg "Detected regular sing-box $SING_BOX_CURRENT_VERSION."

        if [ ! -t 0 ]; then
            SING_BOX_ACTION="keep"
            return 0
        fi

        if confirm_prompt "$(localized_prompt install_sing_box_extended)"; then
            SING_BOX_ACTION="install_extended"
        fi
        return 0
    fi

    msg "sing-box is not installed yet."

    if [ ! -t 0 ]; then
        SING_BOX_ACTION="keep"
        msg "Using the regular sing-box dependency in non-interactive mode."
        return 0
    fi

    if confirm_prompt "$(localized_prompt install_sing_box_extended)"; then
        SING_BOX_ACTION="install_extended"
    else
        SING_BOX_ACTION="keep"
        msg "The regular sing-box package will be installed as a dependency."
    fi
}

decide_unsupported_config_migration() {
    [ -f /etc/config/podkop-plus ] || return 0

    PODKOP_PLUS_INSTALLED_VERSION="$(get_installed_package_version "podkop-plus")"
    [ -n "$PODKOP_PLUS_INSTALLED_VERSION" ] || return 0

    if ! podkop_plus_release_version_lt "$PODKOP_PLUS_INSTALLED_VERSION" "$PODKOP_PLUS_SUPPORTED_MIGRATION_VERSION"; then
        return 0
    fi

    warn "Podkop Plus config migration from $PODKOP_PLUS_INSTALLED_VERSION is not supported."
    warn "Supported in-place migration starts from $PODKOP_PLUS_SUPPORTED_MIGRATION_VERSION. /etc/config/podkop-plus will be removed and recreated clean."
    warn "Миграция конфигурации Podkop Plus из версии $PODKOP_PLUS_INSTALLED_VERSION не поддерживается."
    warn "Поддерживаемая миграция начинается с $PODKOP_PLUS_SUPPORTED_MIGRATION_VERSION. /etc/config/podkop-plus будет удален и создан заново."

    if [ ! -t 0 ]; then
        fail "Unsupported config migration requires interactive confirmation. Run the installer from a TTY and answer y to reset /etc/config/podkop-plus."
    fi

    if confirm_prompt "$(localized_prompt reset_unsupported_config)"; then
        PODKOP_PLUS_RESET_CONFIG=1
        return 0
    fi

    fail "Installation stopped because unsupported config migration was not confirmed."
}

resolve_sing_box_extended_arch_suffix() {
    host_arch="$(uname -m 2>/dev/null || true)"
    distrib_arch=""

    if [ -f "/etc/openwrt_release" ]; then
        distrib_arch=$(. /etc/openwrt_release 2>/dev/null && echo "$DISTRIB_ARCH")
        case "$distrib_arch" in
            *mipsel*|*mipsle*) host_arch="mipsel" ;;
            *mips64el*|*mips64le*) host_arch="mips64el" ;;
        esac
    fi

    case "$host_arch" in
        aarch64) SING_BOX_EXTENDED_ARCH_SUFFIX="arm64" ;;
        armv7*) SING_BOX_EXTENDED_ARCH_SUFFIX="armv7" ;;
        armv6*) SING_BOX_EXTENDED_ARCH_SUFFIX="armv6" ;;
        x86_64) SING_BOX_EXTENDED_ARCH_SUFFIX="amd64" ;;
        i386|i686) SING_BOX_EXTENDED_ARCH_SUFFIX="386" ;;
        mips) SING_BOX_EXTENDED_ARCH_SUFFIX="mips-softfloat" ;;
        mipsel|mipsle) SING_BOX_EXTENDED_ARCH_SUFFIX="mipsle-softfloat" ;;
        mips64) SING_BOX_EXTENDED_ARCH_SUFFIX="mips64" ;;
        mips64el|mips64le) SING_BOX_EXTENDED_ARCH_SUFFIX="mips64le" ;;
        riscv64) SING_BOX_EXTENDED_ARCH_SUFFIX="riscv64" ;;
        s390x) SING_BOX_EXTENDED_ARCH_SUFFIX="s390x" ;;
        *)
            fail "Unsupported sing-box-extended architecture: ${host_arch:-unknown}"
            ;;
    esac
}

resolve_sing_box_extended_release() {
    response=""
    tag=""
    asset_pattern=""

    resolve_sing_box_extended_arch_suffix

    response="$(http_get "https://api.github.com/repos/shtorm-7/sing-box-extended/releases?per_page=30" 2>/dev/null || true)"
    [ -n "$response" ] || fail "Failed to query sing-box-extended release metadata"
    printf '%s' "$response" | jq -e . >/dev/null 2>&1 || fail "GitHub returned an invalid response for sing-box-extended"

    tag="$(printf '%s' "$response" | jq -r '
        .[]
        | select(((.prerelease // false) | not) and ((.draft // false) | not))
        | .tag_name // empty
    ' | while IFS= read -r candidate_tag; do
        candidate_tag_lc="$(printf '%s' "$candidate_tag" | tr '[:upper:]' '[:lower:]')"
        case "$candidate_tag_lc" in
            *alpha* | *beta* | *rc*) continue ;;
        esac
        printf '%s\n' "$candidate_tag"
        break
    done)"
    [ -n "$tag" ] || fail "No stable sing-box-extended release was found"

    SING_BOX_EXTENDED_RELEASE_TAG="$tag"
    SING_BOX_EXTENDED_RELEASE_JSON="$(fetch_github_release_json "shtorm-7" "sing-box-extended")"
    if [ "$(printf '%s' "$SING_BOX_EXTENDED_RELEASE_JSON" | jq -r '.tag_name // empty')" != "$tag" ]; then
        SING_BOX_EXTENDED_RELEASE_JSON="$(http_get "https://api.github.com/repos/shtorm-7/sing-box-extended/releases/tags/$tag" 2>/dev/null || true)"
        [ -n "$SING_BOX_EXTENDED_RELEASE_JSON" ] || fail "Failed to query sing-box-extended release $tag"
        printf '%s' "$SING_BOX_EXTENDED_RELEASE_JSON" | jq -e . >/dev/null 2>&1 || fail "GitHub returned an invalid sing-box-extended release response"
    fi

    asset_pattern="linux-${SING_BOX_EXTENDED_ARCH_SUFFIX}.tar.gz"
    SING_BOX_EXTENDED_ASSET_URL="$(printf '%s' "$SING_BOX_EXTENDED_RELEASE_JSON" | jq -r --arg pattern "$asset_pattern" '
        .assets[]
        | select(.name | endswith($pattern))
        | .browser_download_url
    ' | sed -n '1p')"
    [ -n "$SING_BOX_EXTENDED_ASSET_URL" ] || fail "No sing-box-extended asset was found for architecture suffix $SING_BOX_EXTENDED_ARCH_SUFFIX"

    SING_BOX_EXTENDED_ASSET_NAME="$(basename "$SING_BOX_EXTENDED_ASSET_URL")"
}

select_sing_box_extended_work_dir() {
    free_ram_kb="$(awk '/MemAvailable/ {print $2; exit} /MemFree/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
    case "$free_ram_kb" in
        ''|*[!0-9]*) free_ram_kb=0 ;;
    esac

    if [ "$free_ram_kb" -gt 81920 ]; then
        SING_BOX_EXTENDED_WORK_DIR="$TMP_DIR/sing-box-extended"
    else
        SING_BOX_EXTENDED_WORK_DIR="${HOME:-/root}/podkop-plus-sing-box-extended.$$"
    fi

    rm -rf "$SING_BOX_EXTENDED_WORK_DIR"
    mkdir -p "$SING_BOX_EXTENDED_WORK_DIR" || fail "Failed to create sing-box-extended work directory"
}

stop_sing_box_dependant_services() {
    [ -x /etc/init.d/podkop-plus ] && /etc/init.d/podkop-plus stop >/dev/null 2>&1 || true
    [ -x /etc/init.d/podkop ] && /etc/init.d/podkop stop >/dev/null 2>&1 || true
    [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box stop >/dev/null 2>&1 || true
}

prepare_sing_box_action_before_install() {
    [ "$SING_BOX_ACTION" = "preserve_extended" ] || return 0
    [ -x /usr/bin/sing-box ] || return 0

    SING_BOX_EXTENDED_BACKUP_FILE="$TMP_DIR/sing-box.extended.backup"
    cp /usr/bin/sing-box "$SING_BOX_EXTENDED_BACKUP_FILE" || fail "Failed to back up the current sing-box-extended binary"
    chmod 0755 "$SING_BOX_EXTENDED_BACKUP_FILE" 2>/dev/null || true
}

install_sing_box_extended_binary() {
    archive_file=""
    binary_path=""
    new_version=""

    resolve_sing_box_extended_release
    select_sing_box_extended_work_dir

    archive_file="$SING_BOX_EXTENDED_WORK_DIR/$SING_BOX_EXTENDED_ASSET_NAME"
    download_with_retry "$SING_BOX_EXTENDED_ASSET_URL" "$archive_file" "$SING_BOX_EXTENDED_ASSET_NAME" || fail "Failed to download sing-box-extended"

    tar -xzf "$archive_file" -C "$SING_BOX_EXTENDED_WORK_DIR" || fail "Failed to extract sing-box-extended archive"
    binary_path="$(find "$SING_BOX_EXTENDED_WORK_DIR" -type f -name sing-box | sed -n '1p')"
    [ -n "$binary_path" ] || fail "sing-box binary was not found in the sing-box-extended archive"

    stop_sing_box_dependant_services
    mv -f "$binary_path" /usr/bin/sing-box || fail "Failed to install sing-box-extended binary"
    chmod 0755 /usr/bin/sing-box || fail "Failed to mark sing-box binary executable"

    new_version="$(get_sing_box_binary_version)"
    msg "Installed sing-box-extended ${new_version:-unknown} from shtorm-7/sing-box-extended@$SING_BOX_EXTENDED_RELEASE_TAG"
}

restore_preserved_sing_box_extended() {
    current_version=""

    [ -n "$SING_BOX_EXTENDED_BACKUP_FILE" ] || return 0
    [ -f "$SING_BOX_EXTENDED_BACKUP_FILE" ] || return 0

    current_version="$(get_sing_box_binary_version)"
    if sing_box_version_is_extended "$current_version"; then
        msg "sing-box-extended $current_version is still installed."
        return 0
    fi

    stop_sing_box_dependant_services
    cp "$SING_BOX_EXTENDED_BACKUP_FILE" /usr/bin/sing-box || fail "Failed to restore sing-box-extended after package installation"
    chmod 0755 /usr/bin/sing-box || fail "Failed to mark restored sing-box binary executable"
    msg "Restored sing-box-extended after package installation"
}

install_stock_sing_box_package() {
    stop_sing_box_dependant_services
    pkg_remove_if_installed "sing-box"
    pkg_install_name "sing-box" || fail "Failed to install the regular sing-box package"
    msg "Installed the regular sing-box package ${SING_BOX_CURRENT_VERSION:+(previously $SING_BOX_CURRENT_VERSION)}"
}

apply_sing_box_action_after_install() {
    case "$SING_BOX_ACTION" in
        install_extended)
            install_sing_box_extended_binary
            ;;
        preserve_extended)
            restore_preserved_sing_box_extended
            ;;
        install_stock)
            install_stock_sing_box_package
            ;;
        keep)
            ;;
    esac
}

remember_service_state() {
    service_status=""

    if [ -x /etc/init.d/podkop-plus ] && /etc/init.d/podkop-plus enabled >/dev/null 2>&1; then
        PODKOP_WAS_ENABLED=1
    fi

    if [ -x /etc/init.d/podkop-plus ]; then
        service_status="$(/etc/init.d/podkop-plus status 2>/dev/null || true)"
        if [ "$service_status" = "running" ]; then
            PODKOP_WAS_RUNNING=1
            return 0
        fi
    fi

    if [ -x /etc/init.d/podkop-plus ] && /etc/init.d/podkop-plus running >/dev/null 2>&1; then
        PODKOP_WAS_RUNNING=1
        return 0
    fi

    if [ -x /usr/bin/podkop-plus ] && /usr/bin/podkop-plus get_status 2>/dev/null | grep -q '"running":1'; then
        PODKOP_WAS_RUNNING=1
    fi
}

stop_conflicting_services() {
    [ -x /etc/init.d/podkop-plus ] && /etc/init.d/podkop-plus stop >/dev/null 2>&1 || true
    [ -x /etc/init.d/podkop-plus ] && /etc/init.d/podkop-plus disable >/dev/null 2>&1 || true
}

deactivate_original_podkop_if_present() {
    [ -x /etc/init.d/podkop ] || return 0

    if /etc/init.d/podkop running >/dev/null 2>&1; then
        warn "Detected a running original Podkop service. Stopping it before installing Podkop Plus."
        /etc/init.d/podkop stop >/dev/null 2>&1 || warn "Failed to stop the original Podkop service."
    fi

    if /etc/init.d/podkop enabled >/dev/null 2>&1; then
        warn "Detected an enabled original Podkop autostart. Disabling it before installing Podkop Plus."
        /etc/init.d/podkop disable >/dev/null 2>&1 || warn "Failed to disable original Podkop autostart."
    fi
}

cleanup_legacy_installation() {
    backend_package_installed=0
    config_backup_file=""

    pkg_is_installed "podkop-plus" && backend_package_installed=1
    if [ "$PODKOP_PLUS_RESET_CONFIG" -eq 1 ]; then
        rm -f /etc/config/podkop-plus || fail "Failed to remove unsupported /etc/config/podkop-plus"
        msg "Removed unsupported /etc/config/podkop-plus; a clean default config will be installed."
    elif [ -f /etc/config/podkop-plus ]; then
        config_backup_file="$TMP_DIR/podkop-plus.config.backup"
        cp /etc/config/podkop-plus "$config_backup_file" || fail "Failed to back up /etc/config/podkop-plus before upgrade"
    fi

    remember_service_state
    stop_conflicting_services

    pkg_remove_matching_prefix "luci-i18n-podkop-plus"
    pkg_remove_if_installed "luci-app-podkop-plus"

    if [ -n "$config_backup_file" ] && [ ! -f /etc/config/podkop-plus ]; then
        cp "$config_backup_file" /etc/config/podkop-plus || fail "Failed to restore /etc/config/podkop-plus after legacy package removal"
        chmod 0644 /etc/config/podkop-plus || true
    fi

    if [ "$backend_package_installed" -eq 0 ]; then
        rm -rf /usr/lib/podkop-plus
        rm -f /etc/init.d/podkop-plus
        rm -f /usr/bin/podkop-plus
    fi

    rm -rf /www/luci-static/resources/view/podkop_plus
    rm -f /usr/share/luci/menu.d/luci-app-podkop-plus.json
    rm -f /usr/share/rpcd/acl.d/luci-app-podkop-plus.json
    rm -f /etc/uci-defaults/50_luci-podkop-plus
    rm -f /usr/lib/lua/luci/i18n/podkop_plus.ru.lmo
    rm -f /usr/lib/lua/luci/i18n/podkop_plus.en.lmo
    rm -f /usr/lib/lua/luci/i18n/podkop_plus.ru.lua
    rm -f /usr/lib/lua/luci/i18n/podkop_plus.en.lua
}

append_arch_candidate() {
    candidate="$1"

    [ -n "$candidate" ] || return 0

    case "$candidate" in
        all|noarch)
            return 0
            ;;
    esac

    case " $ZAPRET_ARCH_CANDIDATES " in
        *" $candidate "*)
            return 0
            ;;
    esac

    if [ -n "$ZAPRET_ARCH_CANDIDATES" ]; then
        ZAPRET_ARCH_CANDIDATES="$ZAPRET_ARCH_CANDIDATES $candidate"
    else
        ZAPRET_ARCH_CANDIDATES="$candidate"
    fi
}

append_arch_candidate_variants() {
    candidate="$1"
    base_candidate=""

    [ -n "$candidate" ] || return 0

    append_arch_candidate "$candidate"

    case "$candidate" in
        *+*)
            append_arch_candidate "${candidate%%+*}"
            ;;
    esac

    for suffix in _musl _uclibc _glibc -musl -uclibc -glibc .musl .uclibc .glibc; do
        case "$candidate" in
            *"$suffix")
                base_candidate="${candidate%"$suffix"}"
                append_arch_candidate "$base_candidate"
                ;;
        esac
    done
}

add_arch_family_fallbacks() {
    arch="$1"

    append_arch_candidate_variants "$arch"

    case "$arch" in
        aarch64_*)
            append_arch_candidate_variants "aarch64_generic"
            ;;
        riscv64_*)
            append_arch_candidate_variants "riscv64_generic"
            ;;
        arm_cortex-a7_neon-vfpv4)
            append_arch_candidate_variants "arm_cortex-a7_vfpv4"
            append_arch_candidate_variants "arm_cortex-a7"
            ;;
        arm_cortex-a7_*)
            append_arch_candidate_variants "arm_cortex-a7"
            ;;
        arm_cortex-a9_*)
            append_arch_candidate_variants "arm_cortex-a9"
            ;;
        mipsel_24kc_24kf)
            append_arch_candidate_variants "mipsel_24kc"
            ;;
    esac
}

resolve_arch_candidates() {
    arch_list=""
    apk_arch_list=""
    release_arch=""

    if [ "$PKG_IS_APK" -eq 1 ]; then
        if [ -f /etc/apk/arch ]; then
            apk_arch_list="$(tr '\r\n' '  ' </etc/apk/arch)"
            [ -n "$apk_arch_list" ] && arch_list="$arch_list $apk_arch_list"
        fi

        apk_arch_list="$(apk --print-arch 2>/dev/null || true)"
        [ -n "$apk_arch_list" ] && arch_list="$arch_list $apk_arch_list"
    else
        arch_list="$(opkg print-architecture 2>/dev/null | awk '$1 == "arch" && $2 !~ /^(all|noarch)$/ {print $2 " " $3}' | sort -k2,2nr | awk '{print $1}')"
    fi

    release_arch="$(read_openwrt_release_value "DISTRIB_ARCH")"
    [ -n "$release_arch" ] && arch_list="$arch_list $release_arch"

    if [ -z "$(printf '%s' "$arch_list" | tr -d '[:space:]')" ]; then
        arch_list="$(uname -m 2>/dev/null || true)"
    fi

    for arch in $arch_list; do
        case "$arch" in
            all|noarch)
                continue
                ;;
        esac

        [ -n "$TARGET_ARCH" ] || TARGET_ARCH="$arch"
        add_arch_family_fallbacks "$arch"
    done

    [ -n "$TARGET_ARCH" ] || fail "Failed to detect the router package architecture"
    msg "Detected package architecture candidates: $ZAPRET_ARCH_CANDIDATES"
}

resolve_zapret_release() {
    candidate_name=""
    message=""
    url="https://api.github.com/repos/remittor/zapret-openwrt/releases/latest"

    clear_zapret_download_state

    [ "$ZAPRET_REQUESTED" -eq 1 ] || return 0

    ZAPRET_RELEASE_JSON="$(http_get "$url" 2>/dev/null || true)"
    if [ -z "$ZAPRET_RELEASE_JSON" ]; then
        warn_zapret_unavailable "Failed to query zapret release metadata."
        ZAPRET_SKIPPED_REASON="release metadata unavailable"
        return 0
    fi

    if ! printf '%s' "$ZAPRET_RELEASE_JSON" | jq -e . >/dev/null 2>&1; then
        warn_zapret_unavailable "GitHub returned an invalid zapret release response."
        ZAPRET_SKIPPED_REASON="invalid release metadata"
        clear_zapret_download_state
        return 0
    fi

    message="$(printf '%s' "$ZAPRET_RELEASE_JSON" | jq -r 'if type == "object" then (.message // empty) else empty end' 2>/dev/null)"
    case "$message" in
        *"API rate limit"*|*"rate limit exceeded"*)
            warn_zapret_unavailable "GitHub API rate limit reached while resolving zapret."
            ZAPRET_SKIPPED_REASON="GitHub API rate limit"
            clear_zapret_download_state
            return 0
            ;;
        "Not Found")
            warn_zapret_unavailable "No published releases found for remittor/zapret-openwrt."
            ZAPRET_SKIPPED_REASON="release not found"
            clear_zapret_download_state
            return 0
            ;;
    esac

    ZAPRET_RELEASE_TAG_RESOLVED="$(printf '%s' "$ZAPRET_RELEASE_JSON" | jq -r '.tag_name // empty')"
    if [ -z "$ZAPRET_RELEASE_TAG_RESOLVED" ]; then
        warn_zapret_unavailable "Failed to detect the zapret release tag."
        ZAPRET_SKIPPED_REASON="release tag unavailable"
        clear_zapret_download_state
        return 0
    fi

    for arch in $ZAPRET_ARCH_CANDIDATES; do
        candidate_name="$(printf '%s' "$ZAPRET_RELEASE_JSON" | jq -r --arg arch "$arch" '.assets[] | select(.name | endswith("_" + $arch + ".zip")) | .name' | sed -n '1p')"

        if [ -n "$candidate_name" ]; then
            ZAPRET_ARCH="$arch"
            ZAPRET_BUNDLE_NAME="$candidate_name"
            break
        fi
    done

    if [ -z "$ZAPRET_BUNDLE_NAME" ]; then
        warn_zapret_unavailable "No zapret package was found for architecture: $TARGET_ARCH. Tried: $ZAPRET_ARCH_CANDIDATES."
        ZAPRET_SKIPPED_REASON="package not found for architecture"
        clear_zapret_download_state
        return 0
    fi

    ZAPRET_BUNDLE_URL="$(printf '%s' "$ZAPRET_RELEASE_JSON" | jq -r --arg name "$ZAPRET_BUNDLE_NAME" '.assets[] | select(.name == $name) | .browser_download_url' | sed -n '1p')"
    if [ -z "$ZAPRET_BUNDLE_URL" ]; then
        warn_zapret_unavailable "Failed to resolve the zapret download URL for $ZAPRET_BUNDLE_NAME."
        ZAPRET_SKIPPED_REASON="download URL unavailable"
        clear_zapret_download_state
        return 0
    fi
}

get_openwrt_release_series() {
    release="$(read_openwrt_release_value "DISTRIB_RELEASE")"
    printf '%s\n' "$release" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

resolve_byedpi_release() {
    candidate_name=""
    message=""
    asset_ext="ipk"
    release_series=""
    response=""
    tag=""
    url="https://api.github.com/repos/DPITrickster/ByeDPI-OpenWrt/releases?per_page=30"

    clear_byedpi_download_state

    [ "$BYEDPI_REQUESTED" -eq 1 ] || return 0
    [ "$PKG_IS_APK" -eq 1 ] && asset_ext="apk"
    release_series="$(get_openwrt_release_series)"

    response="$(http_get "$url" 2>/dev/null || true)"
    if [ -z "$response" ]; then
        warn_byedpi_unavailable "Failed to query ByeDPI release metadata."
        BYEDPI_SKIPPED_REASON="release metadata unavailable"
        return 0
    fi

    if ! printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
        warn_byedpi_unavailable "GitHub returned an invalid ByeDPI release response."
        BYEDPI_SKIPPED_REASON="invalid release metadata"
        clear_byedpi_download_state
        return 0
    fi

    message="$(printf '%s' "$response" | jq -r 'if type == "object" then (.message // empty) else empty end' 2>/dev/null)"
    case "$message" in
        *"API rate limit"*|*"rate limit exceeded"*)
            warn_byedpi_unavailable "GitHub API rate limit reached while resolving ByeDPI."
            BYEDPI_SKIPPED_REASON="GitHub API rate limit"
            clear_byedpi_download_state
            return 0
            ;;
        "Not Found")
            warn_byedpi_unavailable "No published releases found for DPITrickster/ByeDPI-OpenWrt."
            BYEDPI_SKIPPED_REASON="release not found"
            clear_byedpi_download_state
            return 0
            ;;
    esac

    if [ -n "$release_series" ]; then
        tag="$(printf '%s' "$response" | jq -r --arg series "$release_series" '
            .[]
            | select(((.draft // false) | not) and ((.prerelease // false) | not))
            | select(((.tag_name // "") | contains($series)) or ((.name // "") | contains($series)))
            | .tag_name // empty
        ' | sed -n '1p')"
    fi

    if [ -z "$tag" ]; then
        tag="$(printf '%s' "$response" | jq -r '
            .[]
            | select(((.draft // false) | not) and ((.prerelease // false) | not))
            | .tag_name // empty
        ' | sed -n '1p')"
    fi

    if [ -z "$tag" ]; then
        warn_byedpi_unavailable "Failed to detect the ByeDPI release tag."
        BYEDPI_SKIPPED_REASON="release tag unavailable"
        clear_byedpi_download_state
        return 0
    fi

    BYEDPI_RELEASE_TAG_RESOLVED="$tag"
    BYEDPI_RELEASE_JSON="$(printf '%s' "$response" | jq -c --arg tag "$tag" '.[] | select(.tag_name == $tag)' | sed -n '1p')"

    for arch in $ZAPRET_ARCH_CANDIDATES; do
        candidate_name="$(printf '%s' "$BYEDPI_RELEASE_JSON" | jq -r --arg arch "$arch" --arg ext "$asset_ext" '
            .assets[]
            | select(((.name | startswith("byedpi_")) or (.name | startswith("byedpi-"))) and (.name | endswith("." + $ext)))
            | select((.name | contains("_" + $arch + "." + $ext)) or (.name | contains("-" + $arch + "." + $ext)))
            | .name
        ' | sed -n '1p')"

        if [ -n "$candidate_name" ]; then
            BYEDPI_ARCH="$arch"
            BYEDPI_PACKAGE_NAME="$candidate_name"
            break
        fi
    done

    if [ -z "$BYEDPI_PACKAGE_NAME" ]; then
        warn_byedpi_unavailable "No ByeDPI package was found for architecture: $TARGET_ARCH. Tried: $ZAPRET_ARCH_CANDIDATES."
        BYEDPI_SKIPPED_REASON="package not found for architecture"
        clear_byedpi_download_state
        return 0
    fi

    BYEDPI_PACKAGE_URL="$(printf '%s' "$BYEDPI_RELEASE_JSON" | jq -r --arg name "$BYEDPI_PACKAGE_NAME" '.assets[] | select(.name == $name) | .browser_download_url' | sed -n '1p')"
    if [ -z "$BYEDPI_PACKAGE_URL" ]; then
        warn_byedpi_unavailable "Failed to resolve the ByeDPI download URL for $BYEDPI_PACKAGE_NAME."
        BYEDPI_SKIPPED_REASON="download URL unavailable"
        clear_byedpi_download_state
        return 0
    fi

    BYEDPI_PACKAGE_VERSION="$(extract_arch_package_version "$BYEDPI_PACKAGE_NAME" "$BYEDPI_ARCH")"

    if [ "$BYEDPI_ALREADY_PRESENT" -eq 1 ]; then
        optional_package_update_needed "ByeDPI" "byedpi" "$BYEDPI_PACKAGE_VERSION"
        update_status=$?
        BYEDPI_INSTALLED_VERSION="$OPTIONAL_INSTALLED_VERSION"

        case "$update_status" in
            0)
                return 0
                ;;
            1)
                BYEDPI_UP_TO_DATE=1
                BYEDPI_PACKAGE_URL=""
                BYEDPI_PACKAGE_NAME=""
                BYEDPI_PACKAGE_VERSION=""
                return 0
                ;;
            *)
                BYEDPI_SKIPPED_REASON="installed version unavailable"
                clear_byedpi_download_state
                return 0
                ;;
        esac
    fi
}

detect_awg_release_context() {
    system_board_json=""
    release_target=""

    clear_awg_download_state

    if command_exists ubus && command_exists jsonfilter; then
        system_board_json="$(ubus call system board 2>/dev/null || true)"
        if [ -n "$system_board_json" ]; then
            AWG_OPENWRT_VERSION="$(printf '%s' "$system_board_json" | jsonfilter -e '@.release.version' 2>/dev/null | head -n 1)"
            release_target="$(printf '%s' "$system_board_json" | jsonfilter -e '@.release.target' 2>/dev/null | head -n 1)"
            AWG_ARCH="$(printf '%s' "$system_board_json" | jsonfilter -e '@.release.arch' 2>/dev/null | head -n 1)"
        fi
    fi

    [ -n "$AWG_OPENWRT_VERSION" ] || AWG_OPENWRT_VERSION="$(read_openwrt_release_value "DISTRIB_RELEASE")"
    [ -n "$release_target" ] || release_target="$(read_openwrt_release_value "DISTRIB_TARGET")"
    [ -n "$AWG_ARCH" ] || AWG_ARCH="$(read_openwrt_release_value "DISTRIB_ARCH")"
    [ -n "$AWG_ARCH" ] || AWG_ARCH="$TARGET_ARCH"

    if [ -z "$AWG_OPENWRT_VERSION" ] || [ -z "$release_target" ] || [ -z "$AWG_ARCH" ]; then
        warn_awg_unavailable "Failed to detect OpenWrt release, target or package architecture for AmneziaWG."
        AWG_SKIPPED_REASON="OpenWrt release context unavailable"
        clear_awg_download_state
        return 1
    fi

    case "$release_target" in
        */*)
            AWG_TARGET="${release_target%%/*}"
            AWG_SUBTARGET="${release_target#*/}"
            ;;
        *)
            warn_awg_unavailable "Unsupported OpenWrt target format for AmneziaWG: $release_target."
            AWG_SKIPPED_REASON="unsupported OpenWrt target format"
            clear_awg_download_state
            return 1
            ;;
    esac

    AWG_VERSION="1.0"
    AWG_LUCI_PACKAGE_NAME="luci-app-amneziawg"
    if version_ge "$AWG_OPENWRT_VERSION" "24.10.3"; then
        AWG_VERSION="2.0"
        AWG_LUCI_PACKAGE_NAME="luci-proto-amneziawg"
    fi

    if [ "$PKG_IS_APK" -eq 1 ]; then
        AWG_PACKAGE_EXT="apk"
    else
        AWG_PACKAGE_EXT="ipk"
    fi

    AWG_RELEASE_TAG_RESOLVED="v$AWG_OPENWRT_VERSION"
    AWG_BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/${AWG_RELEASE_TAG_RESOLVED}"
    return 0
}

append_awg_package_file() {
    package_file="$1"

    if [ -n "$AWG_PACKAGE_FILES" ]; then
        AWG_PACKAGE_FILES="$AWG_PACKAGE_FILES $package_file"
    else
        AWG_PACKAGE_FILES="$package_file"
    fi
}

download_awg_package() {
    package_name="$1"
    package_ext="$AWG_PACKAGE_EXT"
    fallback_ext="ipk"
    candidate_name=""
    candidate_file=""

    [ "$package_ext" = "ipk" ] && fallback_ext="apk"

    for ext in "$package_ext" "$fallback_ext"; do
        candidate_name="${package_name}_v${AWG_OPENWRT_VERSION}_${AWG_ARCH}_${AWG_TARGET}_${AWG_SUBTARGET}.${ext}"
        candidate_file="$TMP_DIR/$candidate_name"

        if download_with_retry "$AWG_BASE_URL/$candidate_name" "$candidate_file" "$candidate_name"; then
            append_awg_package_file "$candidate_file"
            return 0
        fi
    done

    return 1
}

extract_ipk_control_field() {
    package_file="$1"
    field_name="$2"
    control_dir="$TMP_DIR/control.$$"
    value=""

    [ -f "$package_file" ] || return 0

    rm -rf "$control_dir"
    mkdir -p "$control_dir" || return 0

    if tar -xzf "$package_file" -C "$control_dir" ./control.tar.gz >/dev/null 2>&1 &&
        tar -xzf "$control_dir/control.tar.gz" -C "$control_dir" ./control >/dev/null 2>&1; then
        value="$(awk -v field="$field_name" '
            index($0, field ":") == 1 {
                sub("^[^:]*:[[:space:]]*", "")
                print
                exit
            }
        ' "$control_dir/control" 2>/dev/null)"
    fi

    rm -rf "$control_dir"
    printf '%s\n' "$value"
}

extract_apk_control_field() {
    package_file="$1"
    field_name="$2"
    metadata_key=""

    case "$field_name" in
        Package)
            metadata_key="name"
            ;;
        Version)
            metadata_key="version"
            ;;
        *)
            return 0
            ;;
    esac

    command_exists apk || return 0
    apk adbdump "$package_file" 2>/dev/null | sed -n "s/^  ${metadata_key}:[[:space:]]*//p" | sed -n '1p'
}

extract_package_control_field() {
    package_file="$1"
    field_name="$2"

    case "$package_file" in
        *.ipk)
            extract_ipk_control_field "$package_file" "$field_name"
            ;;
        *.apk)
            extract_apk_control_field "$package_file" "$field_name"
            ;;
    esac
}

extract_downloaded_package_name() {
    package_file="$1"
    package_name=""

    package_name="$(extract_package_control_field "$package_file" "Package")"
    if [ -z "$package_name" ]; then
        package_name="$(basename "$package_file" | sed 's/[._-]v\?[0-9].*$//')"
    fi

    printf '%s\n' "$package_name"
}

extract_downloaded_package_version() {
    package_file="$1"
    package_version=""

    package_version="$(extract_package_control_field "$package_file" "Version")"
    if [ -z "$package_version" ]; then
        package_version="$(extract_package_version "$(basename "$package_file")")"
    fi

    printf '%s\n' "$package_version"
}

get_installed_kernel_package_version() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info -v kernel 2>/dev/null | sed 's/^kernel-//' | sed -n '1p'
    else
        opkg info kernel 2>/dev/null | sed -n 's/^Version:[[:space:]]*//p' | sed -n '1p'
    fi
}

validate_awg_kmod_package() {
    kmod_file=""
    depends=""
    required_kernel=""
    installed_kernel=""

    [ "$PKG_IS_APK" -eq 0 ] || return 0

    for package_file in $AWG_PACKAGE_FILES; do
        case "$(basename "$package_file")" in
            kmod-amneziawg_*.ipk)
                kmod_file="$package_file"
                break
                ;;
        esac
    done

    [ -n "$kmod_file" ] || return 0

    depends="$(extract_ipk_control_field "$kmod_file" "Depends")"
    required_kernel="$(printf '%s\n' "$depends" | sed -n 's/.*kernel *( *= *\([^),]*\).*/\1/p' | sed -n '1p')"
    installed_kernel="$(get_installed_kernel_package_version)"

    [ -n "$required_kernel" ] || return 0
    [ -n "$installed_kernel" ] || return 0

    if [ "$required_kernel" != "$installed_kernel" ]; then
        warn_awg_unavailable "Downloaded kmod-amneziawg requires kernel $required_kernel, but this router has $installed_kernel."
        AWG_SKIPPED_REASON="kernel ABI mismatch for kmod-amneziawg"
        clear_awg_download_state
        return 1
    fi

    return 0
}

validate_awg_update_needed() {
    update_needed=0
    comparable_packages=0
    package_name=""
    candidate_version=""
    installed_version=""

    [ "$AWG_ALREADY_PRESENT" -eq 1 ] || return 0

    for package_file in $AWG_PACKAGE_FILES; do
        package_name="$(extract_downloaded_package_name "$package_file")"
        candidate_version="$(extract_downloaded_package_version "$package_file")"

        if [ -z "$package_name" ] || [ -z "$candidate_version" ]; then
            warn_awg_unavailable "Failed to parse downloaded AmneziaWG package metadata."
            AWG_SKIPPED_REASON="package metadata unavailable"
            clear_awg_download_state
            return 2
        fi

        case "$package_name" in
            luci-i18n-amneziawg-*)
                [ "$PODKOP_PLUS_I18N_REQUESTED" -eq 1 ] || continue
                ;;
        esac

        comparable_packages=$((comparable_packages + 1))
        installed_version="$(get_installed_package_version "$package_name")"

        if [ -z "$installed_version" ]; then
            msg "AmneziaWG package $package_name is missing; installing $candidate_version."
            update_needed=1
            continue
        fi

        if package_version_newer "$candidate_version" "$installed_version"; then
            msg "Found AmneziaWG package update for $package_name: $installed_version -> $candidate_version"
            update_needed=1
        fi
    done

    if [ "$comparable_packages" -eq 0 ]; then
        warn_awg_unavailable "Failed to parse downloaded AmneziaWG package metadata."
        AWG_SKIPPED_REASON="package metadata unavailable"
        clear_awg_download_state
        return 2
    fi

    if [ "$update_needed" -eq 1 ]; then
        return 0
    fi

    msg "AmneziaWG packages are already up to date."
    AWG_UP_TO_DATE=1
    clear_awg_download_state
    AWG_UP_TO_DATE=1
    return 1
}

download_awg_packages() {
    [ "$AWG_REQUESTED" -eq 1 ] || return 0

    detect_awg_release_context || return 0

    msg "Resolving AmneziaWG $AWG_VERSION packages from Slava-Shchipunov/awg-openwrt@$AWG_RELEASE_TAG_RESOLVED"

    if ! download_awg_package "kmod-amneziawg"; then
        warn_awg_unavailable "Failed to download kmod-amneziawg for OpenWrt $AWG_OPENWRT_VERSION ($AWG_ARCH, $AWG_TARGET/$AWG_SUBTARGET)."
        AWG_SKIPPED_REASON="kmod-amneziawg package unavailable"
        clear_awg_download_state
        return 0
    fi

    if ! download_awg_package "amneziawg-tools"; then
        warn_awg_unavailable "Failed to download amneziawg-tools for OpenWrt $AWG_OPENWRT_VERSION ($AWG_ARCH, $AWG_TARGET/$AWG_SUBTARGET)."
        AWG_SKIPPED_REASON="amneziawg-tools package unavailable"
        clear_awg_download_state
        return 0
    fi

    if ! download_awg_package "$AWG_LUCI_PACKAGE_NAME"; then
        warn_awg_unavailable "Failed to download $AWG_LUCI_PACKAGE_NAME for OpenWrt $AWG_OPENWRT_VERSION ($AWG_ARCH, $AWG_TARGET/$AWG_SUBTARGET)."
        AWG_SKIPPED_REASON="$AWG_LUCI_PACKAGE_NAME package unavailable"
        clear_awg_download_state
        return 0
    fi

    if [ "$AWG_VERSION" = "2.0" ] && [ "$PODKOP_PLUS_I18N_REQUESTED" -eq 1 ]; then
        if ! download_awg_package "luci-i18n-amneziawg-ru"; then
            warn "Russian LuCI translation for AmneziaWG was not downloaded; continuing with core AmneziaWG packages."
        fi
    fi

    validate_awg_kmod_package || return 0
    validate_awg_update_needed || return 0
    AWG_PACKAGE_VERSION="$AWG_OPENWRT_VERSION"
}

decide_zapret_installation() {
    case "$ZAPRET_INSTALL_CHOICE" in
        0|no|NO|false|FALSE|n|N)
            if is_zapret_present; then
                ZAPRET_ALREADY_PRESENT=1
                ZAPRET_SKIPPED_REASON="provider update disabled by installer option"
                warn "Detected an existing zapret provider, but zapret update is disabled by installer option."
            else
                ZAPRET_SKIPPED_REASON="installation disabled by installer option"
                warn "Continuing without zapret provider."
            fi
            return 0
            ;;
    esac

    if is_zapret_present; then
        ZAPRET_ALREADY_PRESENT=1
        ZAPRET_REQUESTED=1
        msg "Detected an existing zapret provider. Checking for an updated package."
        return 0
    fi

    case "$ZAPRET_INSTALL_CHOICE" in
        1|yes|YES|true|TRUE|y|Y)
            ZAPRET_REQUESTED=1
            return 0
            ;;
    esac

    if [ ! -t 0 ]; then
        ZAPRET_SKIPPED_REASON="not requested; rerun with --with-zapret to install the optional provider"
        warn "Continuing without zapret provider."
        return 0
    fi

    if confirm_prompt "$(localized_prompt install_zapret)"; then
        ZAPRET_REQUESTED=1
        return 0
    fi

    ZAPRET_SKIPPED_REASON="installation declined by user"
    warn "Continuing without zapret provider."
}

decide_byedpi_installation() {
    case "$BYEDPI_INSTALL_CHOICE" in
        0|no|NO|false|FALSE|n|N)
            if is_byedpi_present; then
                BYEDPI_ALREADY_PRESENT=1
                BYEDPI_SKIPPED_REASON="provider update disabled by installer option"
                warn "Detected an existing ByeDPI provider, but ByeDPI update is disabled by installer option."
            else
                BYEDPI_SKIPPED_REASON="installation disabled by installer option"
                warn "Continuing without ByeDPI provider."
            fi
            return 0
            ;;
    esac

    if is_byedpi_present; then
        BYEDPI_ALREADY_PRESENT=1
        BYEDPI_REQUESTED=1
        msg "Detected an existing ByeDPI provider. Checking for an updated package."
        return 0
    fi

    case "$BYEDPI_INSTALL_CHOICE" in
        1|yes|YES|true|TRUE|y|Y)
            BYEDPI_REQUESTED=1
            return 0
            ;;
    esac

    if [ ! -t 0 ]; then
        BYEDPI_SKIPPED_REASON="not requested; rerun with --with-byedpi to install the optional provider"
        warn "Continuing without ByeDPI provider."
        return 0
    fi

    if confirm_prompt "$(localized_prompt install_byedpi)"; then
        BYEDPI_REQUESTED=1
        return 0
    fi

    BYEDPI_SKIPPED_REASON="installation declined by user"
    warn "Continuing without ByeDPI provider."
}

decide_awg_installation() {
    case "$AWG_INSTALL_CHOICE" in
        0|no|NO|false|FALSE|n|N)
            if is_awg_present; then
                AWG_ALREADY_PRESENT=1
                AWG_SKIPPED_REASON="package update disabled by installer option"
                warn "Detected an existing AmneziaWG installation, but AmneziaWG update is disabled by installer option."
            else
                AWG_SKIPPED_REASON="installation disabled by installer option"
                warn "Continuing without AmneziaWG packages."
            fi
            return 0
            ;;
    esac

    case "$AWG_INSTALL_CHOICE" in
        1|yes|YES|true|TRUE|y|Y)
            if is_awg_present; then
                AWG_ALREADY_PRESENT=1
                msg "Detected an existing AmneziaWG installation. Refreshing packages by installer option."
            fi
            AWG_REQUESTED=1
            return 0
            ;;
    esac

    if is_awg_present; then
        AWG_ALREADY_PRESENT=1
        AWG_REQUESTED=1
        msg "Detected an existing AmneziaWG installation. Checking for updated packages."
        return 0
    fi

    if [ ! -t 0 ]; then
        AWG_SKIPPED_REASON="not requested; rerun with --with-awg to install AmneziaWG OpenWrt packages"
        warn "Continuing without AmneziaWG packages."
        return 0
    fi

    if confirm_prompt "$(localized_prompt install_awg)"; then
        AWG_REQUESTED=1
        return 0
    fi

    AWG_SKIPPED_REASON="installation declined by user"
    warn "Continuing without AmneziaWG packages."
}

decide_i18n_installation() {
    luci_lang="$(get_luci_main_lang)"

    case "$luci_lang" in
        ru|ru_*|ru-*)
            INSTALLER_LANG="ru"
            PODKOP_PLUS_I18N_REQUESTED=1
            msg "Выбран русский язык LuCI. Пакет русского интерфейса будет установлен."
            return 0
            ;;
    esac

    INSTALLER_LANG="en"

    if confirm_prompt "Установить русский язык интерфейса? (Install the Russian interface language package?)"; then
        INSTALLER_LANG="ru"
        PODKOP_PLUS_I18N_REQUESTED=1
        return 0
    fi

    INSTALLER_LANG="en"
    warn "Continuing without the Russian interface language package."
}

download_podkop_plus_packages() {
    PODKOP_PLUS_BACKEND_FILE="$TMP_DIR/$PODKOP_PLUS_BACKEND_NAME"
    PODKOP_PLUS_APP_FILE="$TMP_DIR/$PODKOP_PLUS_APP_NAME"
    PODKOP_PLUS_I18N_FILE=""

    download_with_retry "$PODKOP_PLUS_BACKEND_URL" "$PODKOP_PLUS_BACKEND_FILE" "$PODKOP_PLUS_BACKEND_NAME" || fail "Failed to download $PODKOP_PLUS_BACKEND_NAME"
    download_with_retry "$PODKOP_PLUS_APP_URL" "$PODKOP_PLUS_APP_FILE" "$PODKOP_PLUS_APP_NAME" || fail "Failed to download $PODKOP_PLUS_APP_NAME"

    if [ -n "$PODKOP_PLUS_I18N_URL" ]; then
        PODKOP_PLUS_I18N_FILE="$TMP_DIR/$PODKOP_PLUS_I18N_NAME"
        download_with_retry "$PODKOP_PLUS_I18N_URL" "$PODKOP_PLUS_I18N_FILE" "$PODKOP_PLUS_I18N_NAME" || fail "Failed to download $PODKOP_PLUS_I18N_NAME"
    fi
}

download_and_extract_zapret_package() {
    bundle_file=""
    inner_package_path=""

    [ -n "$ZAPRET_BUNDLE_URL" ] || return 0

    bundle_file="$TMP_DIR/$ZAPRET_BUNDLE_NAME"
    if ! download_with_retry "$ZAPRET_BUNDLE_URL" "$bundle_file" "$ZAPRET_BUNDLE_NAME"; then
        warn_zapret_unavailable "Failed to download $ZAPRET_BUNDLE_NAME."
        ZAPRET_SKIPPED_REASON="download failed"
        clear_zapret_download_state
        return 0
    fi

    if [ "$PKG_IS_APK" -eq 1 ]; then
        inner_package_path="$(unzip -l "$bundle_file" | awk '{print $4}' | grep -E '^apk/zapret-.*\.apk$' | sed -n '1p')"
    else
        inner_package_path="$(unzip -l "$bundle_file" | awk '{print $4}' | grep -E "^zapret_.*_${ZAPRET_ARCH}\.ipk$" | sed -n '1p')"
        [ -n "$inner_package_path" ] || inner_package_path="$(unzip -l "$bundle_file" | awk '{print $4}' | grep -E '^zapret_.*\.ipk$' | sed -n '1p')"
    fi

    if [ -z "$inner_package_path" ]; then
        warn_zapret_unavailable "Failed to locate the zapret package inside $ZAPRET_BUNDLE_NAME."
        ZAPRET_SKIPPED_REASON="package archive layout is unsupported"
        clear_zapret_download_state
        return 0
    fi

    ZAPRET_PACKAGE_NAME="$(basename "$inner_package_path")"
    ZAPRET_PACKAGE_FILE="$TMP_DIR/$ZAPRET_PACKAGE_NAME"

    if ! unzip -p "$bundle_file" "$inner_package_path" > "$ZAPRET_PACKAGE_FILE"; then
        warn_zapret_unavailable "Failed to extract $ZAPRET_PACKAGE_NAME."
        ZAPRET_SKIPPED_REASON="package extraction failed"
        clear_zapret_download_state
        return 0
    fi

    if [ ! -s "$ZAPRET_PACKAGE_FILE" ]; then
        warn_zapret_unavailable "The extracted zapret package is empty."
        ZAPRET_SKIPPED_REASON="empty package archive"
        clear_zapret_download_state
        return 0
    fi

    ZAPRET_PACKAGE_VERSION="$(extract_package_control_field "$ZAPRET_PACKAGE_FILE" "Version")"
    [ -n "$ZAPRET_PACKAGE_VERSION" ] || ZAPRET_PACKAGE_VERSION="$(extract_arch_package_version "$ZAPRET_PACKAGE_NAME" "$ZAPRET_ARCH")"

    if [ "$ZAPRET_ALREADY_PRESENT" -eq 1 ]; then
        optional_package_update_needed "zapret" "zapret" "$ZAPRET_PACKAGE_VERSION"
        update_status=$?
        ZAPRET_INSTALLED_VERSION="$OPTIONAL_INSTALLED_VERSION"

        case "$update_status" in
            0)
                return 0
                ;;
            1)
                ZAPRET_UP_TO_DATE=1
                rm -f "$ZAPRET_PACKAGE_FILE"
                ZAPRET_PACKAGE_FILE=""
                ZAPRET_PACKAGE_NAME=""
                ZAPRET_PACKAGE_VERSION=""
                return 0
                ;;
            *)
                ZAPRET_SKIPPED_REASON="installed version unavailable"
                clear_zapret_download_state
                return 0
                ;;
        esac
    fi
}

download_byedpi_package() {
    [ -n "$BYEDPI_PACKAGE_URL" ] || return 0

    BYEDPI_PACKAGE_FILE="$TMP_DIR/$BYEDPI_PACKAGE_NAME"
    if ! download_with_retry "$BYEDPI_PACKAGE_URL" "$BYEDPI_PACKAGE_FILE" "$BYEDPI_PACKAGE_NAME"; then
        warn_byedpi_unavailable "Failed to download $BYEDPI_PACKAGE_NAME."
        BYEDPI_SKIPPED_REASON="download failed"
        clear_byedpi_download_state
        return 0
    fi

    if [ ! -s "$BYEDPI_PACKAGE_FILE" ]; then
        warn_byedpi_unavailable "The downloaded ByeDPI package is empty."
        BYEDPI_SKIPPED_REASON="empty package"
        clear_byedpi_download_state
        return 0
    fi
}

install_packages() {
    if [ -n "$ZAPRET_PACKAGE_FILE" ]; then
        if pkg_install_files "$ZAPRET_PACKAGE_FILE"; then
            ZAPRET_INSTALLED=1
            disable_installed_zapret_service
        else
            ZAPRET_SKIPPED_REASON="provider package installation failed"
            ZAPRET_PACKAGE_VERSION=""
            warn_zapret_unavailable "Failed to install the zapret provider package."
        fi
    fi

    if [ -n "$BYEDPI_PACKAGE_FILE" ]; then
        if pkg_install_files "$BYEDPI_PACKAGE_FILE"; then
            BYEDPI_INSTALLED=1
            disable_installed_byedpi_service
        else
            BYEDPI_SKIPPED_REASON="provider package installation failed"
            BYEDPI_PACKAGE_VERSION=""
            warn_byedpi_unavailable "Failed to install the ByeDPI provider package."
        fi
    fi

    if [ -n "$AWG_PACKAGE_FILES" ]; then
        if [ "$AWG_LUCI_PACKAGE_NAME" = "luci-proto-amneziawg" ]; then
            pkg_remove_if_installed "luci-app-amneziawg"
        else
            pkg_remove_if_installed "luci-proto-amneziawg"
        fi
        # shellcheck disable=SC2086
        if pkg_install_files $AWG_PACKAGE_FILES; then
            AWG_INSTALLED=1
        else
            AWG_SKIPPED_REASON="package installation failed"
            AWG_PACKAGE_VERSION=""
            warn_awg_unavailable "Failed to install AmneziaWG packages."
        fi
    fi

    pkg_install_files "$PODKOP_PLUS_BACKEND_FILE" || fail "podkop-plus installation failed"
    pkg_install_files "$PODKOP_PLUS_APP_FILE" || fail "luci-app-podkop-plus installation failed"

    if [ -n "$PODKOP_PLUS_I18N_FILE" ]; then
        pkg_install_files "$PODKOP_PLUS_I18N_FILE" || fail "luci-i18n-podkop-plus-ru installation failed"
    fi
}

disable_installed_zapret_service() {
    [ -n "$ZAPRET_PACKAGE_FILE" ] || return 0
    [ -x /etc/init.d/zapret ] || return 0

    /etc/init.d/zapret stop >/dev/null 2>&1 || true
    /etc/init.d/zapret disable >/dev/null 2>&1 || true

    if /etc/init.d/zapret status >/dev/null 2>&1; then
        warn "Standalone /etc/init.d/zapret is still running after installation. Stop it manually if you do not use standalone zapret."
    fi

    if /etc/init.d/zapret enabled >/dev/null 2>&1; then
        warn "Standalone /etc/init.d/zapret autostart is still enabled after installation. Disable it manually if you do not use standalone zapret."
    fi
}

disable_installed_byedpi_service() {
    [ -n "$BYEDPI_PACKAGE_FILE" ] || return 0
    [ -x /etc/init.d/byedpi ] || return 0

    /etc/init.d/byedpi stop >/dev/null 2>&1 || true
    /etc/init.d/byedpi disable >/dev/null 2>&1 || true

    if /etc/init.d/byedpi status >/dev/null 2>&1; then
        warn "Standalone /etc/init.d/byedpi is still running after installation. Stop it manually if you do not use standalone ByeDPI."
    fi

    if /etc/init.d/byedpi enabled >/dev/null 2>&1; then
        warn "Standalone /etc/init.d/byedpi autostart is still enabled after installation. Disable it manually if you do not use standalone ByeDPI."
    fi
}

post_install() {
    rm -f /var/luci-indexcache* /tmp/luci-indexcache*
    rm -f /tmp/podkop-plus.latest-version.cache
    rm -f /var/run/podkop-plus/system-info.json
    rm -f /var/run/podkop-plus/server-country-cache.json
    rm -f /tmp/podkop-plus/system-info.json
    [ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || true

    if [ "$PODKOP_WAS_ENABLED" -eq 1 ] && [ -x /etc/init.d/podkop-plus ]; then
        /etc/init.d/podkop-plus enable >/dev/null 2>&1 || true
    fi

    if [ "$PODKOP_WAS_RUNNING" -eq 1 ] && [ -x /etc/init.d/podkop-plus ]; then
        /etc/init.d/podkop-plus start >/dev/null 2>&1 || /etc/init.d/podkop-plus restart >/dev/null 2>&1 || warn "Failed to start Podkop Plus after upgrade."
    fi

    if [ "$ZAPRET_INSTALLED" -eq 1 ]; then
        disable_installed_zapret_service
        warn "The zapret provider was installed as an external upstream package."
        warn "Podkop Plus does not modify /etc/config/zapret or luci-app-zapret settings."
        msg "Standalone /etc/init.d/zapret service and autostart were disabled after provider installation."
    fi

    if [ "$BYEDPI_INSTALLED" -eq 1 ]; then
        disable_installed_byedpi_service
        warn "The ByeDPI provider was installed as an external upstream package."
        warn "Podkop Plus manages only its own ciadpi processes for action=byedpi."
        msg "Standalone /etc/init.d/byedpi service and autostart were disabled after provider installation."
    fi

    if [ "$AWG_INSTALLED" -eq 1 ]; then
        warn "AmneziaWG was installed as regular OpenWrt VPN interface support."
        warn "Import or create the AWG interface in LuCI, keep Route Allowed IPs disabled, then use it in Podkop Plus with action=vpn."
        warn "The installer does not rewrite /etc/config/network or /etc/config/podkop-plus."
    fi
}

main() {
    trap cleanup EXIT HUP INT TERM

    parse_args "$@"
    check_root
    init_tmp_dir
    detect_fetcher
    sync_time
    check_system

    decide_i18n_installation
    decide_zapret_installation
    decide_byedpi_installation
    decide_awg_installation
    decide_sing_box_installation
    decide_unsupported_config_migration

    deactivate_original_podkop_if_present

    pkg_list_update || fail "Failed to update package lists"
    ensure_bootstrap_tool "jq" "jq"

    if [ "$ZAPRET_REQUESTED" -eq 1 ]; then
        ensure_bootstrap_tool "unzip" "unzip"
    fi

    resolve_podkop_plus_release
    remove_conflicting_dns_proxy
    remove_old_sing_box_if_needed

    if [ "$ZAPRET_REQUESTED" -eq 1 ] || [ "$BYEDPI_REQUESTED" -eq 1 ] || [ "$AWG_REQUESTED" -eq 1 ]; then
        resolve_arch_candidates
    fi

    if [ "$ZAPRET_REQUESTED" -eq 1 ]; then
        resolve_zapret_release
    fi

    if [ "$BYEDPI_REQUESTED" -eq 1 ]; then
        resolve_byedpi_release
    fi

    if [ "$AWG_REQUESTED" -eq 1 ]; then
        download_awg_packages
    fi

    cleanup_legacy_installation
    prepare_sing_box_action_before_install
    download_podkop_plus_packages
    download_and_extract_zapret_package
    download_byedpi_package
    install_packages
    apply_sing_box_action_after_install
    post_install

    msg "Podkop Plus $PODKOP_PLUS_PACKAGE_VERSION has been installed successfully"
    msg "Source release: ${REPO_OWNER}/${REPO_NAME}@${PODKOP_PLUS_RELEASE_TAG}"

    if [ "$ZAPRET_INSTALLED" -eq 1 ]; then
        msg "zapret $ZAPRET_PACKAGE_VERSION installed for architecture $ZAPRET_ARCH"
        msg "zapret source: remittor/zapret-openwrt@${ZAPRET_RELEASE_TAG_RESOLVED}"
    elif [ "$ZAPRET_UP_TO_DATE" -eq 1 ]; then
        msg "zapret is already up to date ($ZAPRET_INSTALLED_VERSION)"
    elif [ -n "$ZAPRET_SKIPPED_REASON" ]; then
        warn "zapret was not installed or updated: $ZAPRET_SKIPPED_REASON"
    elif [ "$ZAPRET_ALREADY_PRESENT" -eq 1 ]; then
        msg "Using the existing zapret installation"
    fi

    if [ "$BYEDPI_INSTALLED" -eq 1 ]; then
        msg "ByeDPI $BYEDPI_PACKAGE_VERSION installed for architecture $BYEDPI_ARCH"
        msg "ByeDPI source: DPITrickster/ByeDPI-OpenWrt@${BYEDPI_RELEASE_TAG_RESOLVED}"
    elif [ "$BYEDPI_UP_TO_DATE" -eq 1 ]; then
        msg "ByeDPI is already up to date ($BYEDPI_INSTALLED_VERSION)"
    elif [ -n "$BYEDPI_SKIPPED_REASON" ]; then
        warn "ByeDPI was not installed or updated: $BYEDPI_SKIPPED_REASON"
    elif [ "$BYEDPI_ALREADY_PRESENT" -eq 1 ]; then
        msg "Using the existing ByeDPI installation"
    fi

    if [ "$AWG_INSTALLED" -eq 1 ]; then
        msg "AmneziaWG packages installed for OpenWrt $AWG_PACKAGE_VERSION ($AWG_ARCH, $AWG_TARGET/$AWG_SUBTARGET)"
        msg "AmneziaWG source: Slava-Shchipunov/awg-openwrt@${AWG_RELEASE_TAG_RESOLVED}"
    elif [ "$AWG_UP_TO_DATE" -eq 1 ]; then
        msg "AmneziaWG packages are already up to date"
    elif [ -n "$AWG_SKIPPED_REASON" ]; then
        warn "AmneziaWG was not installed or updated: $AWG_SKIPPED_REASON"
    elif [ "$AWG_ALREADY_PRESENT" -eq 1 ]; then
        msg "Using the existing AmneziaWG installation"
    fi

    warn "Open LuCI and review your rules before enabling Podkop Plus"
}

main "$@"
