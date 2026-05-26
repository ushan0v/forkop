#!/bin/sh
# shellcheck shell=dash

REPO_OWNER="ushan0v"
REPO_NAME="podkop-plus"

REQUIRED_SPACE_KB=15360
REQUIRED_SING_BOX_VERSION="1.12.4"

PKG_IS_APK=0
FETCHER=""
TMP_DIR=""
PODKOP_WAS_ENABLED=0
PODKOP_WAS_RUNNING=0
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
Usage: $0

Installs or updates Podkop Plus packages only:
  - podkop-plus
  - luci-app-podkop-plus
  - luci-i18n-podkop-plus-ru when requested or when LuCI language is Russian

External components are managed from the Podkop Plus Updates tab after installation.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
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

install_json_helper_path() {
    helper_path="$TMP_DIR/install-json.uc"

    if [ ! -s "$helper_path" ]; then
        cat > "$helper_path" <<'EOF'
#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_stdin_json() {
    try {
        return json(read_stdin());
    }
    catch (e) {
        return null;
    }
}

function starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function ends_with(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

function asset_matches(name, kind, ext) {
    let suffix = "." + ext;
    if (!ends_with(name, suffix))
        return false;

    if (kind == "backend")
        return starts_with(name, "podkop-plus_") || starts_with(name, "podkop-plus-");
    if (kind == "app")
        return starts_with(name, "luci-app-podkop-plus_") || starts_with(name, "luci-app-podkop-plus-");
    if (kind == "i18n")
        return starts_with(name, "luci-i18n-podkop-plus-ru_") || starts_with(name, "luci-i18n-podkop-plus-ru-");
    return false;
}

function github_message() {
    let value = read_stdin_json();
    if (value == null)
        exit(2);
    if (type(value) == "object" && value.message != null)
        print(as_string(value.message), "\n");
}

function release_tag() {
    let release = read_stdin_json();
    if (type(release) == "object" && release.tag_name != null)
        print(as_string(release.tag_name), "\n");
}

function release_asset_url(kind, ext) {
    let release = read_stdin_json();
    if (type(release) != "object" || type(release.assets) != "array")
        return;
    for (let asset in release.assets) {
        if (type(asset) == "object" && asset_matches(asset.name, kind, ext)) {
            print(as_string(asset.browser_download_url || ""), "\n");
            return;
        }
    }
}

let mode = ARGV[0] || "";

if (mode == "github-message")
    github_message();
else if (mode == "release-tag")
    release_tag();
else if (mode == "release-asset-url")
    release_asset_url(ARGV[1], ARGV[2]);
else
    exit(1);
EOF
    fi

    printf '%s\n' "$helper_path"
}

install_json_ucode() {
    ucode "$(install_json_helper_path)" "$@"
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
        luci-i18n-podkop-plus-ru_*.ipk)
            printf '%s\n' "$package_name" | sed 's/^luci-i18n-podkop-plus-ru_//;s/_[^_]*\.ipk$//'
            ;;
        luci-i18n-podkop-plus-ru_*.apk)
            printf '%s\n' "$package_name" | sed 's/^luci-i18n-podkop-plus-ru_//;s/\.apk$//'
            ;;
        luci-i18n-podkop-plus-ru-*.ipk)
            printf '%s\n' "$package_name" | sed 's/^luci-i18n-podkop-plus-ru-//;s/-[^-]*\.ipk$//'
            ;;
        luci-i18n-podkop-plus-ru-*.apk)
            printf '%s\n' "$package_name" | sed 's/^luci-i18n-podkop-plus-ru-//;s/\.apk$//'
            ;;
        *)
            printf '%s\n' "$package_name"
            ;;
    esac
}

fetch_github_latest_release_json() {
    owner="$1"
    repo="$2"
    response=""
    message=""
    url="https://api.github.com/repos/${owner}/${repo}/releases/latest"

    response="$(http_get "$url" 2>/dev/null || true)"
    [ -n "$response" ] || fail "Failed to query GitHub latest release metadata for ${owner}/${repo}"

    message="$(printf '%s' "$response" | install_json_ucode github-message 2>/dev/null)" ||
        fail "GitHub returned an invalid latest release response for ${owner}/${repo}"
    case "$message" in
        *"API rate limit"*|*"rate limit exceeded"*)
            fail "GitHub API rate limit reached. Try again later."
            ;;
        "Not Found")
            fail "No published latest release found for ${owner}/${repo}"
            ;;
    esac

    printf '%s' "$response"
}

resolve_podkop_plus_release() {
    asset_ext="ipk"

    [ "$PKG_IS_APK" -eq 1 ] && asset_ext="apk"

    PODKOP_PLUS_RELEASE_JSON="$(fetch_github_latest_release_json "$REPO_OWNER" "$REPO_NAME")"
    PODKOP_PLUS_RELEASE_TAG="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | install_json_ucode release-tag 2>/dev/null)"
    [ -n "$PODKOP_PLUS_RELEASE_TAG" ] || fail "Failed to detect the Podkop Plus release tag"

    PODKOP_PLUS_BACKEND_URL="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | install_json_ucode release-asset-url backend "$asset_ext" 2>/dev/null | sed -n '1p')"
    [ -n "$PODKOP_PLUS_BACKEND_URL" ] || fail "The Podkop Plus release does not contain a podkop-plus .$asset_ext package"

    PODKOP_PLUS_APP_URL="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | install_json_ucode release-asset-url app "$asset_ext" 2>/dev/null | sed -n '1p')"
    [ -n "$PODKOP_PLUS_APP_URL" ] || fail "The Podkop Plus release does not contain a luci-app-podkop-plus .$asset_ext package"

    PODKOP_PLUS_BACKEND_NAME="$(basename "$PODKOP_PLUS_BACKEND_URL")"
    PODKOP_PLUS_APP_NAME="$(basename "$PODKOP_PLUS_APP_URL")"
    PODKOP_PLUS_PACKAGE_VERSION="$(extract_package_version "$PODKOP_PLUS_BACKEND_NAME")"

    PODKOP_PLUS_I18N_URL=""
    PODKOP_PLUS_I18N_NAME=""

    if [ "$PODKOP_PLUS_I18N_REQUESTED" -eq 1 ]; then
        PODKOP_PLUS_I18N_URL="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | install_json_ucode release-asset-url i18n "$asset_ext" 2>/dev/null | sed -n '1p')"
        [ -n "$PODKOP_PLUS_I18N_URL" ] || fail "The Podkop Plus release does not contain a luci-i18n-podkop-plus-ru .$asset_ext package"
        PODKOP_PLUS_I18N_NAME="$(basename "$PODKOP_PLUS_I18N_URL")"
    fi
}

remove_conflicting_dns_proxy() {
    if ! pkg_is_installed "https-dns-proxy"; then
        return 0
    fi

    warn "Detected conflicting package: https-dns-proxy"
    confirm_prompt "Remove the conflicting https-dns-proxy package and continue?" || fail "Please remove https-dns-proxy manually and run the installer again"

    pkg_remove_if_installed "luci-app-https-dns-proxy"
    pkg_remove_if_installed "https-dns-proxy"
    pkg_remove_matching_prefix "luci-i18n-https-dns-proxy"
}

remove_old_sing_box_if_needed() {
    installed_version=""

    pkg_is_installed "sing-box" || return 0
    command_exists sing-box || return 0

    installed_version="$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')"
    [ -n "$installed_version" ] || return 0

    if version_ge "$installed_version" "$REQUIRED_SING_BOX_VERSION"; then
        return 0
    fi

    warn "sing-box $installed_version is older than the required version $REQUIRED_SING_BOX_VERSION. Removing the old package first."
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

    pkg_is_installed "podkop-plus" && backend_package_installed=1
    remember_service_state
    stop_conflicting_services

    pkg_remove_matching_prefix "luci-i18n-podkop-plus"
    pkg_remove_if_installed "luci-app-podkop-plus"

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

decide_i18n_installation() {
    luci_lang="$(get_luci_main_lang)"

    if pkg_is_installed "luci-i18n-podkop-plus-ru"; then
        PODKOP_PLUS_I18N_REQUESTED=1
        msg "The Russian interface package is already installed and will be updated."
        return 0
    fi

    case "$luci_lang" in
        ru|ru_*|ru-*)
            msg "LuCI language is Russian."
            ;;
    esac

    if confirm_prompt "Install the Russian interface language package?"; then
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

install_packages() {
    pkg_install_files "$PODKOP_PLUS_BACKEND_FILE" || fail "podkop-plus installation failed"
    pkg_install_files "$PODKOP_PLUS_APP_FILE" || fail "luci-app-podkop-plus installation failed"

    if [ -n "$PODKOP_PLUS_I18N_FILE" ]; then
        pkg_install_files "$PODKOP_PLUS_I18N_FILE" || fail "luci-i18n-podkop-plus-ru installation failed"
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
    deactivate_original_podkop_if_present

    pkg_list_update || fail "Failed to update package lists"
    ensure_bootstrap_tool "ucode" "ucode"

    resolve_podkop_plus_release
    remove_conflicting_dns_proxy
    remove_old_sing_box_if_needed

    cleanup_legacy_installation
    download_podkop_plus_packages
    install_packages
    post_install

    msg "Podkop Plus $PODKOP_PLUS_PACKAGE_VERSION has been installed successfully"
    msg "Source release: ${REPO_OWNER}/${REPO_NAME}@${PODKOP_PLUS_RELEASE_TAG}"
    warn "Open LuCI and review your rules before enabling Podkop Plus"
}

main "$@"
