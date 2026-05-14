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
ZAPRET_REQUESTED=0
ZAPRET_SKIPPED_REASON=""
ZAPRET_INSTALL_CHOICE="${PODKOP_PLUS_INSTALL_ZAPRET:-${INSTALL_ZAPRET:-}}"
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

ZAPRET_RELEASE_JSON=""
ZAPRET_RELEASE_TAG_RESOLVED=""
ZAPRET_BUNDLE_URL=""
ZAPRET_BUNDLE_NAME=""
ZAPRET_PACKAGE_NAME=""
ZAPRET_PACKAGE_FILE=""
ZAPRET_PACKAGE_VERSION=""

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
Usage: $0 [--with-zapret|--without-zapret]

Options:
  --with-zapret       Install the optional external zapret provider package.
  --without-zapret    Install Podkop Plus without the zapret provider.
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

is_zapret_present() {
    pkg_is_installed "zapret" || [ -x /opt/zapret/nfq/nfqws ]
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

    printf '%s [y/N]: ' "$prompt_text"
    read -r answer || return 1

    case "$answer" in
        y|Y|yes|YES|Yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
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
        *)
            printf '%s\n' "$package_name"
            ;;
    esac
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

    message="$(printf '%s' "$response" | jq -r '.message // empty')"
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

resolve_podkop_plus_release() {
    asset_ext="ipk"

    [ "$PKG_IS_APK" -eq 1 ] && asset_ext="apk"

    PODKOP_PLUS_RELEASE_JSON="$(fetch_github_release_json "$REPO_OWNER" "$REPO_NAME")"
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

is_original_podkop_present() {
    pkg_is_installed "podkop" ||
        pkg_is_installed "luci-app-podkop" ||
        [ -x /etc/init.d/podkop ] ||
        [ -x /usr/bin/podkop ] ||
        [ -d /usr/lib/podkop ] ||
        [ -f /usr/share/luci/menu.d/luci-app-podkop.json ] ||
        [ -f /usr/share/rpcd/acl.d/luci-app-podkop.json ]
}

migrate_podkop_plus_config_if_needed() {
    [ -f /etc/config/podkop-plus ] && return 0

    if [ -f /etc/config/podkop_plus ]; then
        cp /etc/config/podkop_plus /etc/config/podkop-plus || fail "Failed to migrate the Podkop Plus config to /etc/config/podkop-plus"
        chmod 0644 /etc/config/podkop-plus || true
        msg "Migrated the Podkop Plus config to /etc/config/podkop-plus"
        return 0
    fi

    [ -f /etc/config/podkop ] || return 0

    if ! pkg_is_installed "luci-app-podkop-plus" &&
        [ ! -x /etc/init.d/podkop-plus ] &&
        [ ! -x /usr/bin/podkop-plus ] &&
        [ ! -d /usr/lib/podkop-plus ]; then
        return 0
    fi

    if is_original_podkop_present; then
        warn "Detected the original Podkop installation together with a shared legacy config at /etc/config/podkop."
        warn "Podkop Plus will not import this shared config automatically. The new version will use /etc/config/podkop-plus."
        return 0
    fi

    cp /etc/config/podkop /etc/config/podkop-plus || fail "Failed to migrate the Podkop Plus config to /etc/config/podkop-plus"
    chmod 0644 /etc/config/podkop-plus || true

    msg "Migrated the Podkop Plus config to /etc/config/podkop-plus"
}

remove_conflicting_dns_proxy() {
    if ! pkg_is_installed "https-dns-proxy"; then
        return 0
    fi

    warn "Detected conflicting package: https-dns-proxy"
    confirm_prompt "Remove https-dns-proxy and continue?" || fail "Please remove https-dns-proxy manually and run the installer again"

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
    if [ -f /etc/config/podkop-plus ]; then
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
    msg "Detected zapret architecture candidates: $ZAPRET_ARCH_CANDIDATES"
}

resolve_zapret_release() {
    candidate_name=""
    message=""
    url="https://api.github.com/repos/remittor/zapret-openwrt/releases/latest"

    clear_zapret_download_state

    [ "$ZAPRET_REQUESTED" -eq 1 ] || return 0

    ZAPRET_RELEASE_JSON="$(http_get "$url" 2>/dev/null || true)"
    if [ -z "$ZAPRET_RELEASE_JSON" ]; then
        warn "Failed to query zapret release metadata. Continuing without zapret provider."
        ZAPRET_SKIPPED_REASON="release metadata unavailable"
        return 0
    fi

    if ! printf '%s' "$ZAPRET_RELEASE_JSON" | jq -e . >/dev/null 2>&1; then
        warn "GitHub returned an invalid zapret release response. Continuing without zapret provider."
        ZAPRET_SKIPPED_REASON="invalid release metadata"
        clear_zapret_download_state
        return 0
    fi

    message="$(printf '%s' "$ZAPRET_RELEASE_JSON" | jq -r '.message // empty')"
    case "$message" in
        *"API rate limit"*|*"rate limit exceeded"*)
            warn "GitHub API rate limit reached while resolving zapret. Continuing without zapret provider."
            ZAPRET_SKIPPED_REASON="GitHub API rate limit"
            clear_zapret_download_state
            return 0
            ;;
        "Not Found")
            warn "No published releases found for remittor/zapret-openwrt. Continuing without zapret provider."
            ZAPRET_SKIPPED_REASON="release not found"
            clear_zapret_download_state
            return 0
            ;;
    esac

    ZAPRET_RELEASE_TAG_RESOLVED="$(printf '%s' "$ZAPRET_RELEASE_JSON" | jq -r '.tag_name // empty')"
    if [ -z "$ZAPRET_RELEASE_TAG_RESOLVED" ]; then
        warn "Failed to detect the zapret release tag. Continuing without zapret provider."
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
        warn "No zapret package was found for architecture: $TARGET_ARCH. Tried: $ZAPRET_ARCH_CANDIDATES. Continuing without zapret provider."
        ZAPRET_SKIPPED_REASON="package not found for architecture"
        clear_zapret_download_state
        return 0
    fi

    ZAPRET_BUNDLE_URL="$(printf '%s' "$ZAPRET_RELEASE_JSON" | jq -r --arg name "$ZAPRET_BUNDLE_NAME" '.assets[] | select(.name == $name) | .browser_download_url' | sed -n '1p')"
    if [ -z "$ZAPRET_BUNDLE_URL" ]; then
        warn "Failed to resolve the zapret download URL for $ZAPRET_BUNDLE_NAME. Continuing without zapret provider."
        ZAPRET_SKIPPED_REASON="download URL unavailable"
        clear_zapret_download_state
        return 0
    fi
}

decide_zapret_installation() {
    if is_zapret_present; then
        ZAPRET_ALREADY_PRESENT=1
        msg "Detected an existing zapret provider. Skipping zapret installation."
        return 0
    fi

    case "$ZAPRET_INSTALL_CHOICE" in
        1|yes|YES|true|TRUE|y|Y)
            ZAPRET_REQUESTED=1
            return 0
            ;;
        0|no|NO|false|FALSE|n|N)
            ZAPRET_SKIPPED_REASON="installation disabled by installer option"
            warn "Continuing without zapret provider."
            return 0
            ;;
    esac

    if [ ! -t 0 ]; then
        ZAPRET_SKIPPED_REASON="not requested; rerun with --with-zapret to install the optional provider"
        warn "Continuing without zapret provider."
        return 0
    fi

    if confirm_prompt "Install optional zapret external provider for action=zapret?"; then
        ZAPRET_REQUESTED=1
        return 0
    fi

    ZAPRET_SKIPPED_REASON="installation declined by user"
    warn "Continuing without zapret provider."
}

decide_i18n_installation() {
    if pkg_is_installed "luci-i18n-podkop-plus-ru"; then
        PODKOP_PLUS_I18N_REQUESTED=1
        msg "Detected the installed Russian interface language package. It will be reinstalled."
        return 0
    fi

    if confirm_prompt "Установить русский язык интерфейса? (Install the Russian interface language package?)"; then
        PODKOP_PLUS_I18N_REQUESTED=1
        return 0
    fi

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
        warn "Failed to download $ZAPRET_BUNDLE_NAME. Continuing without zapret provider."
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
        warn "Failed to locate the zapret package inside $ZAPRET_BUNDLE_NAME. Continuing without zapret provider."
        ZAPRET_SKIPPED_REASON="package archive layout is unsupported"
        clear_zapret_download_state
        return 0
    fi

    ZAPRET_PACKAGE_NAME="$(basename "$inner_package_path")"
    ZAPRET_PACKAGE_FILE="$TMP_DIR/$ZAPRET_PACKAGE_NAME"
    ZAPRET_PACKAGE_VERSION="$(extract_package_version "$ZAPRET_PACKAGE_NAME")"

    if ! unzip -p "$bundle_file" "$inner_package_path" > "$ZAPRET_PACKAGE_FILE"; then
        warn "Failed to extract $ZAPRET_PACKAGE_NAME. Continuing without zapret provider."
        ZAPRET_SKIPPED_REASON="package extraction failed"
        clear_zapret_download_state
        return 0
    fi

    if [ ! -s "$ZAPRET_PACKAGE_FILE" ]; then
        warn "The extracted zapret package is empty. Continuing without zapret provider."
        ZAPRET_SKIPPED_REASON="empty package archive"
        clear_zapret_download_state
        return 0
    fi
}

install_packages() {
    if [ -n "$ZAPRET_PACKAGE_FILE" ]; then
        pkg_remove_if_installed "zapret"
        pkg_install_files "$ZAPRET_PACKAGE_FILE" || fail "zapret provider installation failed"
        disable_installed_zapret_service
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

post_install() {
    rm -f /var/luci-indexcache* /tmp/luci-indexcache*
    rm -f /tmp/podkop-plus.latest-version.cache
    rm -f /var/run/podkop-plus/system-info.json
    rm -f /tmp/podkop-plus/system-info.json
    [ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || true

    if [ "$PODKOP_WAS_ENABLED" -eq 1 ] && [ -x /etc/init.d/podkop-plus ]; then
        /etc/init.d/podkop-plus enable >/dev/null 2>&1 || true
    fi

    if [ "$PODKOP_WAS_RUNNING" -eq 1 ] && [ -x /etc/init.d/podkop-plus ]; then
        /etc/init.d/podkop-plus start >/dev/null 2>&1 || /etc/init.d/podkop-plus restart >/dev/null 2>&1 || warn "Failed to start Podkop Plus after upgrade."
    fi

    if [ -n "$ZAPRET_PACKAGE_FILE" ]; then
        disable_installed_zapret_service
        warn "The zapret provider was installed as an external upstream package."
        warn "Podkop Plus does not modify /etc/config/zapret or luci-app-zapret settings."
        msg "Standalone /etc/init.d/zapret service and autostart were disabled after provider installation."
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

    decide_zapret_installation
    decide_i18n_installation

    deactivate_original_podkop_if_present

    pkg_list_update || fail "Failed to update package lists"
    ensure_bootstrap_tool "jq" "jq"

    if [ "$ZAPRET_REQUESTED" -eq 1 ]; then
        ensure_bootstrap_tool "unzip" "unzip"
    fi

    resolve_podkop_plus_release
    migrate_podkop_plus_config_if_needed
    remove_conflicting_dns_proxy
    remove_old_sing_box_if_needed

    if [ "$ZAPRET_REQUESTED" -eq 1 ]; then
        resolve_arch_candidates
        resolve_zapret_release
    fi

    cleanup_legacy_installation
    download_podkop_plus_packages
    download_and_extract_zapret_package
    install_packages
    post_install

    msg "Podkop Plus $PODKOP_PLUS_PACKAGE_VERSION has been installed successfully"
    msg "Source release: ${REPO_OWNER}/${REPO_NAME}@${PODKOP_PLUS_RELEASE_TAG}"

    if [ -n "$ZAPRET_PACKAGE_VERSION" ]; then
        msg "zapret $ZAPRET_PACKAGE_VERSION installed for architecture $ZAPRET_ARCH"
        msg "zapret source: remittor/zapret-openwrt@${ZAPRET_RELEASE_TAG_RESOLVED}"
    elif [ "$ZAPRET_ALREADY_PRESENT" -eq 1 ]; then
        msg "Using the existing zapret installation"
    elif [ -n "$ZAPRET_SKIPPED_REASON" ]; then
        warn "zapret was not installed: $ZAPRET_SKIPPED_REASON"
    fi

    warn "Open LuCI and review your rules before enabling Podkop Plus"
}

main "$@"
