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
INSTALLER_LANG="en"
SING_BOX_INSTALL_VARIANT=""

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
SING_BOX_VARIANT_STATE_FILE="/etc/podkop-plus/sing-box-variant"
SING_BOX_VERSION_STATE_FILE="/etc/podkop-plus/sing-box-version"
SING_BOX_MANAGED_SERVICE_MARKER="Podkop Plus managed sing-box service for binary variants"
SING_BOX_EXTENDED_RELEASE_JSON=""
SING_BOX_EXTENDED_RELEASE_TAG=""
SING_BOX_EXTENDED_ARCH_SUFFIX=""
SING_BOX_EXTENDED_ASSET_URL=""
SING_BOX_EXTENDED_ASSET_NAME=""
SING_BOX_EXTENDED_ARCHIVE_FILE=""
SING_BOX_EXTENDED_PACKAGE_FILE=""

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

Installs or updates Podkop Plus packages:
  - podkop-plus
  - luci-app-podkop-plus
  - luci-i18n-podkop-plus-ru when requested or when LuCI language is Russian

Can also install or switch sing-box variant:
  - stable/full sing-box from OpenWrt feeds
  - sing-box-tiny from OpenWrt feeds
  - sing-box-extended from GitHub OpenWrt packages
  - sing-box-extended compressed from GitHub binary archives
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

podkop_dont_touch_dhcp_enabled() {
    command_exists uci || return 1

    case "$(uci -q get 'podkop-plus.settings.dont_touch_dhcp' 2>/dev/null)" in
        1|true|yes|on)
            return 0
            ;;
    esac

    return 1
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

function contains(value, needle) {
    return index(as_string(value), as_string(needle)) >= 0;
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

function release_asset_url_by_suffix_from_release(release, suffix) {
    suffix = as_string(suffix);
    for (let asset in (type(release.assets) == "array" ? release.assets : [])) {
        if (type(asset) != "object")
            continue;
        let name = as_string(asset.name || "");
        if (ends_with(name, suffix))
            return as_string(asset.browser_download_url || "");
    }

    return "";
}

function release_asset_url_by_suffix(suffix) {
    let release = read_stdin_json();
    if (type(release) != "object")
        return;

    let url = release_asset_url_by_suffix_from_release(release, suffix);
    if (url != "")
        print(url, "\n");
}

function sing_box_extended_arch_suffix(host_arch, distrib_arch) {
    host_arch = as_string(host_arch);
    distrib_arch = as_string(distrib_arch);

    if (contains(distrib_arch, "mipsel") || contains(distrib_arch, "mipsle"))
        host_arch = "mipsel";
    else if (contains(distrib_arch, "mips64el") || contains(distrib_arch, "mips64le"))
        host_arch = "mips64el";

    if (host_arch == "aarch64")
        print("arm64\n");
    else if (substr(host_arch, 0, 5) == "armv7")
        print("armv7\n");
    else if (substr(host_arch, 0, 5) == "armv6")
        print("armv6\n");
    else if (host_arch == "x86_64")
        print("amd64\n");
    else if (host_arch == "i386" || host_arch == "i686")
        print("386\n");
    else if (host_arch == "mips")
        print("mips-softfloat\n");
    else if (host_arch == "mipsel" || host_arch == "mipsle")
        print("mipsle-softfloat\n");
    else if (host_arch == "mips64")
        print("mips64\n");
    else if (host_arch == "mips64el" || host_arch == "mips64le")
        print("mips64le\n");
    else if (host_arch == "riscv64")
        print("riscv64\n");
    else if (host_arch == "s390x")
        print("s390x\n");
    else
        exit(1);
}

function sing_box_extended_asset_url(arch_suffix, _unused, compressed) {
    let release = read_stdin_json();

    if (type(release) != "object")
        exit(1);

    if (as_string(compressed) != "1")
        exit(1);

    arch_suffix = as_string(arch_suffix);
    if (arch_suffix == "")
        exit(1);

    let url = release_asset_url_by_suffix_from_release(release, "linux-" + arch_suffix + "-compressed.tar.gz");
    if (url != "") {
        print(url, "\n");
        return;
    }

    exit(1);
}

function sing_box_extended_package_asset_url(distrib_arch, asset_ext) {
    let release = read_stdin_json();
    let suffix;

    if (type(release) != "object")
        exit(1);

    distrib_arch = as_string(distrib_arch);
    asset_ext = as_string(asset_ext);
    if (distrib_arch == "" || asset_ext == "")
        exit(1);

    suffix = "_openwrt_" + distrib_arch + "." + asset_ext;
    for (let asset in (type(release.assets) == "array" ? release.assets : [])) {
        if (type(asset) != "object")
            continue;

        let name = as_string(asset.name || "");
        let url = as_string(asset.browser_download_url || "");
        if (url != "" && starts_with(name, "sing-box-extended_") && ends_with(name, suffix)) {
            print(url, "\n");
            return;
        }
    }

    exit(1);
}

function archive_member_path(member_name) {
    member_name = as_string(member_name);
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (line == "")
            continue;
        let parts = split(line, "/");
        if (length(parts) > 0 && as_string(parts[length(parts) - 1]) == member_name) {
            print(line, "\n");
            return;
        }
    }
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
else if (mode == "sing-box-extended-arch-suffix")
    sing_box_extended_arch_suffix(ARGV[1], ARGV[2]);
else if (mode == "sing-box-extended-asset-url")
    sing_box_extended_asset_url(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "sing-box-extended-package-asset-url")
    sing_box_extended_package_asset_url(ARGV[1], ARGV[2]);
else if (mode == "archive-member-path")
    archive_member_path(ARGV[1]);
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
        opkg list-installed 2>/dev/null | awk -v pkg="$pkg_name" '$1 == pkg { found = 1 } END { exit(found ? 0 : 1) }'
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

pkg_install_name_downgrade() {
    pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        if pkg_is_installed "$pkg_name"; then
            apk fix --reinstall --upgrade "$pkg_name" </dev/null
        else
            apk add "$pkg_name" </dev/null
        fi
    else
        opkg install --force-overwrite --force-reinstall --force-downgrade "$pkg_name" </dev/null ||
            opkg install --force-downgrade "$pkg_name" </dev/null
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

pkg_remove_sing_box_conflict() {
    pkg_name="$1"

    if ! pkg_is_installed "$pkg_name"; then
        return 0
    fi

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk del --force-broken-world "$pkg_name" </dev/null
    else
        opkg remove --force-depends "$pkg_name" </dev/null
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

sing_box_managed_service_installed() {
    [ -r /etc/init.d/sing-box ] || return 1
    grep -q "$SING_BOX_MANAGED_SERVICE_MARKER" /etc/init.d/sing-box 2>/dev/null
}

install_managed_sing_box_service_script() {
    tmp_file="/etc/init.d/sing-box.podkop-plus.$$"
    cat >"$tmp_file" <<'EOF'
#!/bin/sh /etc/rc.common
# Podkop Plus managed sing-box service for binary variants

USE_PROCD=1
START=99
PROG="/usr/bin/sing-box"

start_service() {
    config_load "sing-box"
    local enabled config_file working_directory
    local log_stderr

    config_get_bool enabled "main" "enabled" "0"
    [ "$enabled" -eq "1" ] || return 0

    config_get config_file "main" "conffile" "/etc/sing-box/config.json"
    config_get working_directory "main" "workdir" "/usr/share/sing-box"
    config_get_bool log_stderr "main" "log_stderr" "1"

    procd_open_instance
    procd_set_param command "$PROG" run -c "$config_file" -D "$working_directory"
    procd_set_param file "$config_file"
    procd_set_param stderr "$log_stderr"
    procd_set_param limits core="unlimited"
    procd_set_param limits nofile="1000000 1000000"
    procd_set_param respawn
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "sing-box"
}
EOF

    chmod 0755 "$tmp_file" &&
        mv -f "$tmp_file" /etc/init.d/sing-box
}

remove_managed_sing_box_service_script() {
    sing_box_managed_service_installed || return 0

    /etc/init.d/sing-box stop >/dev/null 2>&1 || true
    /etc/init.d/sing-box disable >/dev/null 2>&1 || true
    rm -f /etc/init.d/sing-box
}

disable_sing_box_service_config() {
    command_exists uci || return 0

    uci -q get sing-box.main >/dev/null 2>&1 ||
        uci -q set sing-box.main=sing-box >/dev/null 2>&1 || true
    uci -q set sing-box.main.enabled='0' >/dev/null 2>&1 || true
    uci -q commit sing-box >/dev/null 2>&1 || true
}

prepare_sing_box_service_disabled() {
    disable_sing_box_service_config
    [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box stop >/dev/null 2>&1 || true
    [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box disable >/dev/null 2>&1 || true
}

prepare_sing_box_package_service_install() {
    prepare_sing_box_service_disabled
    remove_managed_sing_box_service_script
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

installer_is_ru() {
    [ "$INSTALLER_LANG" = "ru" ]
}

installer_text() {
    key="$1"

    if installer_is_ru; then
        case "$key" in
            yes) printf '%s\n' "Да" ;;
            no) printf '%s\n' "Нет" ;;
            select) printf '%s\n' "Выберите номер" ;;
            invalid_choice) printf '%s\n' "Введите номер из списка." ;;
            i18n_installed) printf '%s\n' "Русский пакет интерфейса уже установлен и будет обновлен." ;;
            i18n_prompt) printf '%s\n' "Установить русский пакет интерфейса?" ;;
            i18n_skip) printf '%s\n' "Продолжаю без русского пакета интерфейса." ;;
            luci_ru) printf '%s\n' "Язык LuCI - русский." ;;
            sing_box_prompt) printf '%s\n' "Какой вариант sing-box установить?" ;;
            sing_box_skip) printf '%s\n' "Не менять sing-box" ;;
            sing_box_stable) printf '%s\n' "Установить обычный sing-box" ;;
            sing_box_tiny) printf '%s\n' "Установить sing-box tiny" ;;
            sing_box_extended) printf '%s\n' "Установить sing-box extended" ;;
            sing_box_extended_compressed) printf '%s\n' "Установить sing-box extended compressed" ;;
            sing_box_skip_msg) printf '%s\n' "Пропускаю установку sing-box." ;;
            *) printf '%s\n' "$key" ;;
        esac
        return 0
    fi

    case "$key" in
        yes) printf '%s\n' "Yes" ;;
        no) printf '%s\n' "No" ;;
        select) printf '%s\n' "Select a number" ;;
        invalid_choice) printf '%s\n' "Enter a number from the list." ;;
        i18n_installed) printf '%s\n' "The Russian interface package is already installed and will be updated." ;;
        i18n_prompt) printf '%s\n' "Install the Russian interface language package?" ;;
        i18n_skip) printf '%s\n' "Continuing without the Russian interface language package." ;;
        luci_ru) printf '%s\n' "LuCI language is Russian." ;;
        sing_box_prompt) printf '%s\n' "Which sing-box variant should be installed?" ;;
        sing_box_skip) printf '%s\n' "Do not change sing-box" ;;
        sing_box_stable) printf '%s\n' "Install stable sing-box" ;;
        sing_box_tiny) printf '%s\n' "Install sing-box tiny" ;;
        sing_box_extended) printf '%s\n' "Install sing-box extended" ;;
        sing_box_extended_compressed) printf '%s\n' "Install sing-box extended compressed" ;;
        sing_box_skip_msg) printf '%s\n' "Skipping sing-box installation." ;;
        *) printf '%s\n' "$key" ;;
    esac
}

detect_installer_language() {
    luci_lang="$(get_luci_main_lang)"

    INSTALLER_LANG="en"
    if pkg_is_installed "luci-i18n-podkop-plus-ru"; then
        INSTALLER_LANG="ru"
        return 0
    fi

    case "$luci_lang" in
        ru|ru_*|ru-*) INSTALLER_LANG="ru" ;;
    esac
}

numbered_yes_no_prompt() {
    prompt_text="$1"
    answer=""

    if [ ! -t 0 ]; then
        msg "$prompt_text: 1 ($(installer_text yes), non-interactive)"
        return 0
    fi

    while :; do
        printf '\n%s\n' "$prompt_text"
        printf '  1) %s\n' "$(installer_text yes)"
        printf '  2) %s\n' "$(installer_text no)"
        printf '%s [2]: ' "$(installer_text select)"
        read -r answer || return 1

        case "$answer" in
            1)
                return 0
                ;;
            2|"")
                return 1
                ;;
            *)
                warn "$(installer_text invalid_choice)"
                ;;
        esac
    done
}

confirm_prompt() {
    prompt_text="$1"
    numbered_yes_no_prompt "$prompt_text"
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

    PODKOP_PLUS_BACKEND_URL="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | install_json_ucode release-asset-url backend "$asset_ext" 2>/dev/null)"
    [ -n "$PODKOP_PLUS_BACKEND_URL" ] || fail "The Podkop Plus release does not contain a podkop-plus .$asset_ext package"

    PODKOP_PLUS_APP_URL="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | install_json_ucode release-asset-url app "$asset_ext" 2>/dev/null)"
    [ -n "$PODKOP_PLUS_APP_URL" ] || fail "The Podkop Plus release does not contain a luci-app-podkop-plus .$asset_ext package"

    PODKOP_PLUS_BACKEND_NAME="$(basename "$PODKOP_PLUS_BACKEND_URL")"
    PODKOP_PLUS_APP_NAME="$(basename "$PODKOP_PLUS_APP_URL")"
    PODKOP_PLUS_PACKAGE_VERSION="$(extract_package_version "$PODKOP_PLUS_BACKEND_NAME")"

    PODKOP_PLUS_I18N_URL=""
    PODKOP_PLUS_I18N_NAME=""

    if [ "$PODKOP_PLUS_I18N_REQUESTED" -eq 1 ]; then
        PODKOP_PLUS_I18N_URL="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | install_json_ucode release-asset-url i18n "$asset_ext" 2>/dev/null)"
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

    command_exists sing-box || return 0

    installed_version="$(sing_box_version_value)"
    [ -n "$installed_version" ] || return 0

    if version_ge "$installed_version" "$REQUIRED_SING_BOX_VERSION"; then
        return 0
    fi

    warn "sing-box $installed_version is older than the required version $REQUIRED_SING_BOX_VERSION. Removing the old package first."
    [ -x /etc/init.d/podkop-plus ] && /etc/init.d/podkop-plus stop >/dev/null 2>&1 || true
    [ -x /etc/init.d/podkop ] && /etc/init.d/podkop stop >/dev/null 2>&1 || true
    restore_podkop_dnsmasq_failsafe
    pkg_remove_if_installed "sing-box-tiny"
    pkg_remove_if_installed "sing-box"
}

sing_box_version_value() {
    command_exists sing-box || return 0

    if sing_box_compressed_marker_set; then
        read_sing_box_version_state 2>/dev/null || true
        return 0
    fi

    if sing_box_extended_marker_set; then
        read_sing_box_version_state 2>/dev/null && return 0
    fi

    read_sing_box_binary_version /usr/bin/sing-box
}

sing_box_is_extended() {
    version="${1:-}"

    if [ -z "$version" ] && command_exists sing-box &&
        { sing_box_compressed_marker_set || sing_box_extended_marker_set; }; then
        return 0
    fi

    [ -n "$version" ] || version="$(sing_box_version_value)"
    case "$version" in
        *extended*) return 0 ;;
    esac
    return 1
}

sing_box_compressed_marker_set() {
    [ -r "$SING_BOX_VARIANT_STATE_FILE" ] || return 1
    [ "$(cat "$SING_BOX_VARIANT_STATE_FILE" 2>/dev/null)" = "extended-compressed" ]
}

sing_box_extended_marker_set() {
    [ -r "$SING_BOX_VARIANT_STATE_FILE" ] || return 1
    [ "$(cat "$SING_BOX_VARIANT_STATE_FILE" 2>/dev/null)" = "extended" ]
}

sing_box_tiny_marker_set() {
    [ -r "$SING_BOX_VARIANT_STATE_FILE" ] || return 1
    [ "$(cat "$SING_BOX_VARIANT_STATE_FILE" 2>/dev/null)" = "tiny" ]
}

read_sing_box_version_state() {
    [ -r "$SING_BOX_VERSION_STATE_FILE" ] || return 1
    sed -n '1p' "$SING_BOX_VERSION_STATE_FILE" 2>/dev/null
}

read_sing_box_variant_marker() {
    [ -r "$SING_BOX_VARIANT_STATE_FILE" ] || return 1
    sed -n '1p' "$SING_BOX_VARIANT_STATE_FILE" 2>/dev/null
}

read_sing_box_binary_version() {
    binary_path="$1"
    library_dir="${2:-}"

    [ -x "$binary_path" ] || return 1

    if [ -n "$library_dir" ]; then
        LD_LIBRARY_PATH="$library_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$binary_path" version 2>/dev/null | head -n 1 | awk '{print $3}'
    else
        "$binary_path" version 2>/dev/null | head -n 1 | awk '{print $3}'
    fi
}

sing_box_supports_tailscale() {
    sing_box_is_extended && return 0
    command_exists sing-box || return 1
    sing-box version 2>/dev/null | grep -Eq '(^|[,:[:space:]])with_tailscale([,[:space:]]|$)'
}

sing_box_active_variant() {
    if ! command_exists sing-box; then
        printf '%s\n' "none"
        return 0
    fi

    if sing_box_compressed_marker_set; then
        printf '%s\n' "extended-compressed"
        return 0
    fi

    if sing_box_extended_marker_set || sing_box_is_extended; then
        printf '%s\n' "extended"
        return 0
    fi

    if pkg_is_installed "sing-box-tiny" || { sing_box_tiny_marker_set && ! sing_box_supports_tailscale; }; then
        printf '%s\n' "tiny"
        return 0
    fi

    printf '%s\n' "stable"
}

select_sing_box_installation() {
    active_variant="$(sing_box_active_variant)"
    answer=""
    skip_choice=""
    default_choice=1
    next_choice=1
    stable_choice=""
    tiny_choice=""
    extended_choice=""
    extended_compressed_choice=""

    if [ "$active_variant" != "none" ]; then
        skip_choice="$next_choice"
        next_choice=$((next_choice + 1))
    fi
    if [ "$active_variant" != "stable" ]; then
        stable_choice="$next_choice"
        next_choice=$((next_choice + 1))
    fi
    if [ "$active_variant" != "tiny" ]; then
        tiny_choice="$next_choice"
        next_choice=$((next_choice + 1))
    fi
    if [ "$active_variant" != "extended" ]; then
        extended_choice="$next_choice"
        next_choice=$((next_choice + 1))
    fi
    if [ "$active_variant" != "extended-compressed" ]; then
        extended_compressed_choice="$next_choice"
        next_choice=$((next_choice + 1))
    fi

    if [ ! -t 0 ]; then
        if [ "$active_variant" = "none" ]; then
            SING_BOX_INSTALL_VARIANT="stable"
            msg "$(installer_text sing_box_prompt): $default_choice ($(installer_text sing_box_stable), non-interactive)"
        else
            SING_BOX_INSTALL_VARIANT=""
            msg "$(installer_text sing_box_prompt): $default_choice ($(installer_text sing_box_skip), non-interactive)"
        fi
        return 0
    fi

    while :; do
        printf '\n%s\n' "$(installer_text sing_box_prompt)"
        [ -n "$skip_choice" ] && printf '  %s) %s\n' "$skip_choice" "$(installer_text sing_box_skip)"
        [ -n "$stable_choice" ] && printf '  %s) %s\n' "$stable_choice" "$(installer_text sing_box_stable)"
        [ -n "$tiny_choice" ] && printf '  %s) %s\n' "$tiny_choice" "$(installer_text sing_box_tiny)"
        [ -n "$extended_choice" ] && printf '  %s) %s\n' "$extended_choice" "$(installer_text sing_box_extended)"
        [ -n "$extended_compressed_choice" ] && printf '  %s) %s\n' "$extended_compressed_choice" "$(installer_text sing_box_extended_compressed)"
        printf '%s [%s]: ' "$(installer_text select)" "$default_choice"
        read -r answer || return 1
        [ -n "$answer" ] || answer="$default_choice"

        if [ -n "$skip_choice" ] && [ "$answer" = "$skip_choice" ]; then
            SING_BOX_INSTALL_VARIANT=""
            return 0
        fi
        if [ -n "$stable_choice" ] && [ "$answer" = "$stable_choice" ]; then
            SING_BOX_INSTALL_VARIANT="stable"
            return 0
        fi
        if [ -n "$tiny_choice" ] && [ "$answer" = "$tiny_choice" ]; then
            SING_BOX_INSTALL_VARIANT="tiny"
            return 0
        fi
        if [ -n "$extended_choice" ] && [ "$answer" = "$extended_choice" ]; then
            SING_BOX_INSTALL_VARIANT="extended"
            return 0
        fi
        if [ -n "$extended_compressed_choice" ] && [ "$answer" = "$extended_compressed_choice" ]; then
            SING_BOX_INSTALL_VARIANT="extended-compressed"
            return 0
        fi

        warn "$(installer_text invalid_choice)"
    done
}

pkg_install_sing_box_variant() {
    target_pkg="$1"
    conflict_pkg="$2"

    prepare_sing_box_package_service_install

    if { [ -z "$conflict_pkg" ] || ! pkg_is_installed "$conflict_pkg"; } &&
        { [ "$target_pkg" = "sing-box-extended" ] || ! pkg_is_installed "sing-box-extended"; }; then
        pkg_install_name_downgrade "$target_pkg" && return 0
    fi

    if [ "$target_pkg" != "sing-box-extended" ]; then
        pkg_remove_sing_box_conflict "sing-box-extended" || return 1
    fi
    if [ -n "$conflict_pkg" ]; then
        pkg_remove_sing_box_conflict "$conflict_pkg" || return 1
    fi

    pkg_install_name_downgrade "$target_pkg"
}

write_sing_box_variant_marker() {
    variant="$1"
    marker_dir="$(dirname "$SING_BOX_VARIANT_STATE_FILE")"

    mkdir -p "$marker_dir" || return 1
    printf '%s\n' "$variant" >"$SING_BOX_VARIANT_STATE_FILE"
}

write_sing_box_version_state() {
    version="$1"
    state_dir="$(dirname "$SING_BOX_VERSION_STATE_FILE")"

    [ -n "$version" ] || return 1
    mkdir -p "$state_dir" || return 1
    printf '%s\n' "$version" >"$SING_BOX_VERSION_STATE_FILE"
}

restore_sing_box_variant_marker() {
    previous_marker="$1"

    if [ -n "$previous_marker" ]; then
        write_sing_box_variant_marker "$previous_marker"
    else
        rm -f "$SING_BOX_VARIANT_STATE_FILE" 2>/dev/null || true
    fi
}

restore_sing_box_version_state() {
    previous_version="$1"

    if [ -n "$previous_version" ]; then
        write_sing_box_version_state "$previous_version"
    else
        rm -f "$SING_BOX_VERSION_STATE_FILE" 2>/dev/null || true
    fi
}

resolve_sing_box_extended_release() {
    compressed="$1"
    host_arch="$(uname -m 2>/dev/null || true)"
    distrib_arch="$(read_openwrt_release_value "DISTRIB_ARCH")"
    asset_ext="ipk"

    SING_BOX_EXTENDED_RELEASE_JSON="$(fetch_github_latest_release_json "shtorm-7" "sing-box-extended")"
    SING_BOX_EXTENDED_RELEASE_TAG="$(printf '%s' "$SING_BOX_EXTENDED_RELEASE_JSON" | install_json_ucode release-tag 2>/dev/null)"
    [ -n "$SING_BOX_EXTENDED_RELEASE_TAG" ] || fail "Failed to detect the sing-box-extended release tag"

    if [ "$compressed" -eq 0 ]; then
        [ "$PKG_IS_APK" -eq 1 ] && asset_ext="apk"
        [ -n "$distrib_arch" ] || fail "Failed to detect OpenWrt package architecture for sing-box-extended"

        SING_BOX_EXTENDED_ASSET_URL="$(printf '%s' "$SING_BOX_EXTENDED_RELEASE_JSON" | install_json_ucode sing-box-extended-package-asset-url "$distrib_arch" "$asset_ext" 2>/dev/null)"
        [ -n "$SING_BOX_EXTENDED_ASSET_URL" ] || fail "The sing-box-extended release does not contain an OpenWrt .$asset_ext package for $distrib_arch"
        SING_BOX_EXTENDED_ASSET_NAME="$(basename "$SING_BOX_EXTENDED_ASSET_URL")"
        return 0
    fi

    SING_BOX_EXTENDED_ARCH_SUFFIX="$(install_json_ucode sing-box-extended-arch-suffix "$host_arch" "$distrib_arch" 2>/dev/null)" ||
        fail "Failed to resolve sing-box-extended architecture for $host_arch/$distrib_arch"
    [ -n "$SING_BOX_EXTENDED_ARCH_SUFFIX" ] || fail "Failed to resolve sing-box-extended architecture for $host_arch/$distrib_arch"

    SING_BOX_EXTENDED_ASSET_URL="$(printf '%s' "$SING_BOX_EXTENDED_RELEASE_JSON" | install_json_ucode sing-box-extended-asset-url "$SING_BOX_EXTENDED_ARCH_SUFFIX" 0 "$compressed" 2>/dev/null)"
    [ -n "$SING_BOX_EXTENDED_ASSET_URL" ] || fail "The sing-box-extended release does not contain a matching asset for $SING_BOX_EXTENDED_ARCH_SUFFIX"
    SING_BOX_EXTENDED_ASSET_NAME="$(basename "$SING_BOX_EXTENDED_ASSET_URL")"
}

validate_extended_sing_box_binary() {
    binary_path="$1"
    library_dir="${2:-}"
    version=""

    [ -x "$binary_path" ] || return 1

    version="$(read_sing_box_binary_version "$binary_path" "$library_dir")"

    case "$version" in
        *extended*) printf '%s\n' "$version"; return 0 ;;
    esac

    return 1
}

move_file_to_backup() {
    target_path="$1"
    backup_path="$2"

    [ -e "$target_path" ] || return 0
    rm -f "$backup_path"
    mv -f "$target_path" "$backup_path"
}

restore_file_backup() {
    target_path="$1"
    backup_path="$2"

    if [ -n "$backup_path" ] && [ -s "$backup_path" ]; then
        mv -f "$backup_path" "$target_path"
        return $?
    fi

    rm -f "$target_path"
}

restore_sing_box_service_from_marker() {
    previous_marker="$1"

    if [ "$previous_marker" = "extended-compressed" ]; then
        install_managed_sing_box_service_script >/dev/null 2>&1 || return 1
        return 0
    fi

    remove_managed_sing_box_service_script >/dev/null 2>&1 || true
}

restore_sing_box_extended_package_variant() {
    package_file=""
    new_version=""

    resolve_sing_box_extended_release 0
    package_file="$TMP_DIR/$SING_BOX_EXTENDED_ASSET_NAME"
    download_with_retry "$SING_BOX_EXTENDED_ASSET_URL" "$package_file" "$SING_BOX_EXTENDED_ASSET_NAME" || return 1
    prepare_sing_box_package_service_install
    pkg_remove_sing_box_conflict "sing-box-tiny" >/dev/null 2>&1 || true
    pkg_remove_sing_box_conflict "sing-box" >/dev/null 2>&1 || true
    pkg_install_files "$package_file" || {
        rm -f "$package_file"
        return 1
    }
    rm -f "$package_file"

    new_version="$(validate_extended_sing_box_binary /usr/bin/sing-box /usr/lib)" || return 1
    write_sing_box_variant_marker "extended" >/dev/null 2>&1 || true
    write_sing_box_version_state "$new_version" >/dev/null 2>&1 || true
}

restore_sing_box_package_variant() {
    previous_variant="$1"

    case "$previous_variant" in
        tiny)
            pkg_install_sing_box_variant "sing-box-tiny" "sing-box"
            ;;
        stable)
            pkg_install_sing_box_variant "sing-box" "sing-box-tiny"
            ;;
        extended)
            restore_sing_box_extended_package_variant
            ;;
        none)
            pkg_remove_sing_box_conflict "sing-box-extended"
            pkg_remove_if_installed "sing-box"
            pkg_remove_if_installed "sing-box-tiny"
            remove_managed_sing_box_service_script >/dev/null 2>&1 || true
            rm -f /usr/bin/sing-box
            ;;
        *)
            return 1
            ;;
    esac
}

sing_box_variant_is_package_managed() {
    case "$1" in
        stable | tiny | extended)
            return 0
            ;;
    esac

    return 1
}

restore_sing_box_install_backup() {
    previous_variant="$1"
    backup_binary="$2"

    if sing_box_variant_is_package_managed "$previous_variant"; then
        if restore_sing_box_package_variant "$previous_variant"; then
            return 0
        fi

        [ -n "$backup_binary" ] && restore_file_backup /usr/bin/sing-box "$backup_binary" >/dev/null 2>&1 || true
        [ -x /usr/bin/sing-box ] && chmod 0755 /usr/bin/sing-box >/dev/null 2>&1 || true
        return 1
    fi

    if [ -n "$backup_binary" ]; then
        restore_file_backup /usr/bin/sing-box "$backup_binary" >/dev/null 2>&1 || return 1
        [ -x /usr/bin/sing-box ] && chmod 0755 /usr/bin/sing-box >/dev/null 2>&1 || true
        return 0
    fi

    restore_sing_box_package_variant "$previous_variant"
}

restore_sing_box_after_failed_extended_install() {
    previous_variant="$1"
    backup_binary="$2"
    backup_cronet="$3"
    previous_marker="$4"
    previous_version_state="$5"
    archive_file="${6:-}"
    cronet_touched="${7:-0}"
    restore_status=0

    [ -n "$archive_file" ] && rm -f "$archive_file"

    if [ "$cronet_touched" -eq 1 ]; then
        restore_file_backup /usr/lib/libcronet.so "$backup_cronet" >/dev/null 2>&1 || true
    fi

    restore_sing_box_install_backup "$previous_variant" "$backup_binary" >/dev/null 2>&1 || restore_status=1

    restore_sing_box_variant_marker "$previous_marker" >/dev/null 2>&1 || true
    restore_sing_box_version_state "$previous_version_state" >/dev/null 2>&1 || true
    restore_sing_box_service_from_marker "$previous_marker" >/dev/null 2>&1 || true
    rm -f /var/run/podkop-plus/ui-state/sing-box-version 2>/dev/null || true
    return "$restore_status"
}

restore_sing_box_after_failed_extended_package_install() {
    previous_variant="$1"
    backup_binary="$2"
    backup_cronet="$3"
    previous_marker="$4"
    previous_version_state="$5"
    package_file="${6:-}"
    cronet_touched="${7:-0}"
    restore_status=0

    [ -n "$package_file" ] && rm -f "$package_file"
    pkg_remove_sing_box_conflict "sing-box-extended" >/dev/null 2>&1 || true

    restore_sing_box_install_backup "$previous_variant" "$backup_binary" >/dev/null 2>&1 || restore_status=1

    if [ "$cronet_touched" -eq 1 ]; then
        restore_file_backup /usr/lib/libcronet.so "$backup_cronet" >/dev/null 2>&1 || true
        [ -s /usr/lib/libcronet.so ] && chmod 0644 /usr/lib/libcronet.so >/dev/null 2>&1 || true
    fi

    restore_sing_box_variant_marker "$previous_marker" >/dev/null 2>&1 || true
    restore_sing_box_version_state "$previous_version_state" >/dev/null 2>&1 || true
    restore_sing_box_service_from_marker "$previous_marker" >/dev/null 2>&1 || true
    rm -f /var/run/podkop-plus/ui-state/sing-box-version 2>/dev/null || true
    return "$restore_status"
}

install_sing_box_extended_package() {
    label="sing-box-extended"
    marker_variant="extended"
    current_variant="$(sing_box_active_variant)"
    previous_marker="$(read_sing_box_variant_marker 2>/dev/null || true)"
    previous_version_state="$(read_sing_box_version_state 2>/dev/null || true)"
    backup_binary=""
    backup_cronet=""
    cronet_touched=0

    resolve_sing_box_extended_release 0
    SING_BOX_EXTENDED_PACKAGE_FILE="$TMP_DIR/$SING_BOX_EXTENDED_ASSET_NAME"
    download_with_retry "$SING_BOX_EXTENDED_ASSET_URL" "$SING_BOX_EXTENDED_PACKAGE_FILE" "$SING_BOX_EXTENDED_ASSET_NAME" ||
        fail "Failed to download $SING_BOX_EXTENDED_ASSET_NAME"

    prepare_sing_box_package_service_install

    case "$current_variant" in
        extended|extended-compressed)
            if [ -e /usr/bin/sing-box ]; then
                backup_binary="/usr/bin/sing-box.podkop-backup.$$"
                move_file_to_backup /usr/bin/sing-box "$backup_binary" || {
                    rm -f "$backup_binary"
                    fail "Failed to backup current sing-box binary"
                }
            fi
            if [ -e /usr/lib/libcronet.so ]; then
                cronet_touched=1
                backup_cronet="/usr/lib/libcronet.so.podkop-backup.$$"
                move_file_to_backup /usr/lib/libcronet.so "$backup_cronet" || {
                    rm -f "$backup_cronet"
                    backup_cronet=""
                    cronet_touched=0
                    restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_PACKAGE_FILE" "$cronet_touched"
                    fail "Failed to backup current libcronet.so"
                }
            fi
            ;;
    esac

    pkg_remove_sing_box_conflict "sing-box-tiny" || {
        restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_PACKAGE_FILE" "$cronet_touched"
        fail "Failed to remove sing-box-tiny before $label package installation"
    }
    pkg_remove_sing_box_conflict "sing-box" || {
        restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_PACKAGE_FILE" "$cronet_touched"
        fail "Failed to remove sing-box before $label package installation"
    }

    if [ -z "$backup_binary" ] && [ -e /usr/bin/sing-box ]; then
        backup_binary="/usr/bin/sing-box.podkop-backup.$$"
        move_file_to_backup /usr/bin/sing-box "$backup_binary" || {
            rm -f "$backup_binary"
            backup_binary=""
            restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_PACKAGE_FILE" "$cronet_touched"
            fail "Failed to backup existing sing-box binary"
        }
    fi

    if [ "$cronet_touched" -eq 0 ] && [ -e /usr/lib/libcronet.so ]; then
        cronet_touched=1
        backup_cronet="/usr/lib/libcronet.so.podkop-backup.$$"
        move_file_to_backup /usr/lib/libcronet.so "$backup_cronet" || {
            rm -f "$backup_cronet"
            backup_cronet=""
            cronet_touched=0
            restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_PACKAGE_FILE" "$cronet_touched"
            fail "Failed to backup current libcronet.so"
        }
    fi

    pkg_install_files "$SING_BOX_EXTENDED_PACKAGE_FILE" || {
        restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_PACKAGE_FILE" "$cronet_touched"
        fail "Failed to install $SING_BOX_EXTENDED_ASSET_NAME"
    }

    new_version="$(validate_extended_sing_box_binary /usr/bin/sing-box /usr/lib)" || {
        restore_sing_box_after_failed_extended_package_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_PACKAGE_FILE" "$cronet_touched"
        fail "Installed $label package failed validation"
    }

    rm -f "$SING_BOX_EXTENDED_PACKAGE_FILE" "$backup_binary" "$backup_cronet"
    write_sing_box_variant_marker "$marker_variant" || warn "Failed to write sing-box variant marker"
    write_sing_box_version_state "$new_version" || warn "Failed to write sing-box version state"
    rm -f /var/run/podkop-plus/ui-state/sing-box-version 2>/dev/null || true
    msg "Installed $label $new_version"
}

install_sing_box_extended_binary() {
    compressed="$1"
    if [ "$compressed" -ne 1 ]; then
        install_sing_box_extended_package
        return 0
    fi

    label="sing-box-extended compressed"
    marker_variant="extended-compressed"
    current_variant="$(sing_box_active_variant)"
    previous_marker="$(read_sing_box_variant_marker 2>/dev/null || true)"
    previous_version_state="$(read_sing_box_version_state 2>/dev/null || true)"
    binary_path=""
    cronet_path=""
    backup_binary=""
    backup_cronet=""
    cronet_touched=0
    tmp_binary="$TMP_DIR/sing-box.compressed.$$"
    tmp_cronet=""
    extract_error="$TMP_DIR/sing-box-extract.err"

    resolve_sing_box_extended_release "$compressed"
    SING_BOX_EXTENDED_ARCHIVE_FILE="$TMP_DIR/$SING_BOX_EXTENDED_ASSET_NAME"
    download_with_retry "$SING_BOX_EXTENDED_ASSET_URL" "$SING_BOX_EXTENDED_ARCHIVE_FILE" "$SING_BOX_EXTENDED_ASSET_NAME" ||
        fail "Failed to download $SING_BOX_EXTENDED_ASSET_NAME"

    binary_path="$(tar -tzf "$SING_BOX_EXTENDED_ARCHIVE_FILE" 2>/dev/null | install_json_ucode archive-member-path sing-box 2>/dev/null)"
    [ -n "$binary_path" ] || fail "sing-box binary was not found in $SING_BOX_EXTENDED_ASSET_NAME"
    cronet_path="$(tar -tzf "$SING_BOX_EXTENDED_ARCHIVE_FILE" 2>/dev/null | install_json_ucode archive-member-path libcronet.so 2>/dev/null)"

    if ! tar -xzf "$SING_BOX_EXTENDED_ARCHIVE_FILE" -O "$binary_path" >"$tmp_binary" 2>"$extract_error"; then
        [ -s "$extract_error" ] && cat "$extract_error" >&2
        rm -f "$tmp_binary"
        fail "Failed to extract $label"
    fi
    if [ ! -s "$tmp_binary" ]; then
        rm -f "$tmp_binary"
        fail "Extracted $label binary is empty"
    fi
    if ! chmod 0755 "$tmp_binary"; then
        rm -f "$tmp_binary"
        fail "Failed to prepare $label binary"
    fi

    if [ -n "$cronet_path" ]; then
        tmp_cronet="$TMP_DIR/libcronet.so"
        if ! tar -xzf "$SING_BOX_EXTENDED_ARCHIVE_FILE" -O "$cronet_path" >"$tmp_cronet" 2>"$extract_error"; then
            [ -s "$extract_error" ] && cat "$extract_error" >&2
            rm -f "$tmp_binary" "$tmp_cronet"
            fail "Failed to extract libcronet.so from $label"
        fi
        if [ ! -s "$tmp_cronet" ]; then
            rm -f "$tmp_binary" "$tmp_cronet"
            fail "Extracted libcronet.so is empty"
        fi
        if ! chmod 0644 "$tmp_cronet"; then
            rm -f "$tmp_binary" "$tmp_cronet"
            fail "Failed to prepare libcronet.so"
        fi
    fi

    new_version="$(validate_extended_sing_box_binary "$tmp_binary" "$TMP_DIR")" || {
        rm -f "$tmp_binary" "$tmp_cronet"
        fail "Downloaded $label failed validation"
    }

    if [ -e /usr/bin/sing-box ]; then
        backup_binary="/usr/bin/sing-box.podkop-backup.$$"
        move_file_to_backup /usr/bin/sing-box "$backup_binary" || {
            rm -f "$backup_binary" "$tmp_binary" "$tmp_cronet"
            fail "Failed to backup current sing-box binary"
        }
    fi

    if [ -n "$cronet_path" ]; then
        cronet_touched=1
        if [ -e /usr/lib/libcronet.so ]; then
            backup_cronet="/usr/lib/libcronet.so.podkop-backup.$$"
            move_file_to_backup /usr/lib/libcronet.so "$backup_cronet" || {
                rm -f "$backup_cronet" "$tmp_binary" "$tmp_cronet"
                backup_cronet=""
                cronet_touched=0
                restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_ARCHIVE_FILE" "$cronet_touched"
                fail "Failed to backup current libcronet.so"
            }
        fi
    fi

    pkg_remove_sing_box_conflict "sing-box-extended" || {
        restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_ARCHIVE_FILE" "$cronet_touched"
        rm -f "$tmp_binary" "$tmp_cronet"
        fail "Failed to remove sing-box-extended before $label installation"
    }
    pkg_remove_sing_box_conflict "sing-box-tiny" || {
        restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_ARCHIVE_FILE" "$cronet_touched"
        rm -f "$tmp_binary" "$tmp_cronet"
        fail "Failed to remove sing-box-tiny before $label installation"
    }
    pkg_remove_sing_box_conflict "sing-box" || {
        restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_ARCHIVE_FILE" "$cronet_touched"
        rm -f "$tmp_binary" "$tmp_cronet"
        fail "Failed to remove sing-box before $label installation"
    }

    remove_managed_sing_box_service_script >/dev/null 2>&1 || true
    install_managed_sing_box_service_script || {
        restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_ARCHIVE_FILE" "$cronet_touched"
        rm -f "$tmp_binary" "$tmp_cronet"
        fail "Failed to install managed sing-box service for $label"
    }

    rm -f /usr/bin/sing-box
    if ! mv -f "$tmp_binary" /usr/bin/sing-box || ! chmod 0755 /usr/bin/sing-box; then
        rm -f /usr/bin/sing-box "$tmp_binary"
        restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_ARCHIVE_FILE" "$cronet_touched"
        fail "Failed to install $label binary"
    fi

    if [ -n "$tmp_cronet" ]; then
        rm -f /usr/lib/libcronet.so
        if ! mv -f "$tmp_cronet" /usr/lib/libcronet.so || ! chmod 0644 /usr/lib/libcronet.so; then
            rm -f /usr/lib/libcronet.so "$tmp_cronet"
            restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_ARCHIVE_FILE" "$cronet_touched"
            fail "Failed to install libcronet.so for $label"
        fi
    fi

    rm -f "$SING_BOX_EXTENDED_ARCHIVE_FILE"

    new_version="$(validate_extended_sing_box_binary /usr/bin/sing-box /usr/lib)" || {
        restore_sing_box_after_failed_extended_install "$current_variant" "$backup_binary" "$backup_cronet" "$previous_marker" "$previous_version_state" "$SING_BOX_EXTENDED_ARCHIVE_FILE" "$cronet_touched"
        fail "Installed $label failed validation"
    }

    rm -f "$backup_binary" "$backup_cronet"
    write_sing_box_variant_marker "$marker_variant" || warn "Failed to write sing-box variant marker"
    write_sing_box_version_state "$new_version" || warn "Failed to write sing-box version state"
    rm -f /var/run/podkop-plus/ui-state/sing-box-version 2>/dev/null || true
    msg "Installed $label $new_version"
}

stop_podkop_for_sing_box_install() {
    remember_service_state
    [ -x /etc/init.d/podkop-plus ] && [ "$PODKOP_WAS_RUNNING" -eq 1 ] &&
        /etc/init.d/podkop-plus stop >/dev/null 2>&1 || true
    [ "$PODKOP_WAS_RUNNING" -eq 1 ] && restore_podkop_dnsmasq_failsafe
    prepare_sing_box_service_disabled
}

install_selected_sing_box() {
    case "$SING_BOX_INSTALL_VARIANT" in
        "")
            msg "$(installer_text sing_box_skip_msg)"
            ;;
        stable)
            stop_podkop_for_sing_box_install
            pkg_install_sing_box_variant "sing-box" "sing-box-tiny" || fail "Failed to install stable sing-box"
            new_version="$(read_sing_box_binary_version /usr/bin/sing-box)"
            [ -n "$new_version" ] || fail "Stable sing-box package was installed, but sing-box binary is not available"
            sing_box_is_extended "$new_version" && fail "Stable sing-box package was installed, but the active binary is still sing-box-extended"
            write_sing_box_variant_marker "stable" || warn "Failed to write sing-box variant marker"
            write_sing_box_version_state "$new_version" || warn "Failed to write sing-box version state"
            rm -f /var/run/podkop-plus/ui-state/sing-box-version 2>/dev/null || true
            ;;
        tiny)
            stop_podkop_for_sing_box_install
            pkg_install_sing_box_variant "sing-box-tiny" "sing-box" || fail "Failed to install sing-box-tiny"
            new_version="$(read_sing_box_binary_version /usr/bin/sing-box)"
            [ -n "$new_version" ] || fail "sing-box-tiny package was installed, but sing-box binary is not available"
            sing_box_is_extended "$new_version" && fail "sing-box-tiny package was installed, but the active binary is still sing-box-extended"
            write_sing_box_variant_marker "tiny" || warn "Failed to write sing-box variant marker"
            write_sing_box_version_state "$new_version" || warn "Failed to write sing-box version state"
            rm -f /var/run/podkop-plus/ui-state/sing-box-version 2>/dev/null || true
            ;;
        extended)
            stop_podkop_for_sing_box_install
            install_sing_box_extended_package
            ;;
        extended-compressed)
            stop_podkop_for_sing_box_install
            install_sing_box_extended_binary 1
            ;;
        *)
            fail "Unknown sing-box installation variant: $SING_BOX_INSTALL_VARIANT"
            ;;
    esac
}

restore_podkop_dnsmasq_failsafe_raw() {
    podkop_legacy_dnsmasq_section="podkop_plus"
    podkop_dns_address="127.0.0.42"
    podkop_config_name="podkop-plus"
    podkop_dnsmasq_changed=0
    podkop_default_has_dns=0
    podkop_legacy_instance_present=0

    command_exists uci || return 0
    podkop_dont_touch_dhcp_enabled && return 0

    podkop_legacy_interfaces="$(uci -q get "dhcp.$podkop_legacy_dnsmasq_section.interface" 2>/dev/null)"
    [ -n "$podkop_legacy_interfaces" ] ||
        podkop_legacy_interfaces="$(uci -q get "$podkop_config_name.settings.source_network_interfaces" 2>/dev/null)"
    [ -n "$podkop_legacy_interfaces" ] || podkop_legacy_interfaces="br-lan"

    podkop_default_servers="$(uci -q get 'dhcp.@dnsmasq[0].server' 2>/dev/null)"
    for podkop_value in $podkop_default_servers; do
        [ "$podkop_value" = "$podkop_dns_address" ] && podkop_default_has_dns=1
    done

    if uci -q show "dhcp.$podkop_legacy_dnsmasq_section" >/dev/null 2>&1; then
        podkop_legacy_instance_present=1
        podkop_dnsmasq_changed=1
    fi
    uci -q delete "dhcp.$podkop_legacy_dnsmasq_section" >/dev/null 2>&1 || true

    podkop_backup_notinterfaces="$(uci -q get 'dhcp.@dnsmasq[0].podkop_notinterface' 2>/dev/null)"
    if [ -n "$podkop_backup_notinterfaces" ]; then
        uci -q delete 'dhcp.@dnsmasq[0].notinterface' >/dev/null 2>&1 || true
        for podkop_value in $podkop_backup_notinterfaces; do
            uci -q add_list "dhcp.@dnsmasq[0].notinterface=$podkop_value" >/dev/null 2>&1 || true
        done
        uci -q delete 'dhcp.@dnsmasq[0].podkop_notinterface' >/dev/null 2>&1 || true
        podkop_dnsmasq_changed=1
    else
        if [ "$podkop_legacy_instance_present" -eq 1 ]; then
            for podkop_value in $podkop_legacy_interfaces; do
                uci -q del_list "dhcp.@dnsmasq[0].notinterface=$podkop_value" >/dev/null 2>&1 && podkop_dnsmasq_changed=1
            done
        fi
        uci -q delete 'dhcp.@dnsmasq[0].podkop_notinterface' >/dev/null 2>&1 || true
    fi

    podkop_backup_servers="$(uci -q get 'dhcp.@dnsmasq[0].podkop_server' 2>/dev/null)"
    if [ -n "$podkop_backup_servers" ]; then
        uci -q delete 'dhcp.@dnsmasq[0].server' >/dev/null 2>&1 || true
        for podkop_value in $podkop_backup_servers; do
            uci -q add_list "dhcp.@dnsmasq[0].server=$podkop_value" >/dev/null 2>&1 || true
        done
        uci -q delete 'dhcp.@dnsmasq[0].podkop_server' >/dev/null 2>&1 || true
        podkop_dnsmasq_changed=1
    else
        uci -q del_list "dhcp.@dnsmasq[0].server=$podkop_dns_address" >/dev/null 2>&1 && podkop_dnsmasq_changed=1
        uci -q delete 'dhcp.@dnsmasq[0].podkop_server' >/dev/null 2>&1 || true
    fi

    podkop_noresolv="$(uci -q get 'dhcp.@dnsmasq[0].podkop_noresolv' 2>/dev/null)"
    if [ -n "$podkop_noresolv" ]; then
        uci -q set "dhcp.@dnsmasq[0].noresolv=$podkop_noresolv" >/dev/null 2>&1 || true
        uci -q delete 'dhcp.@dnsmasq[0].podkop_noresolv' >/dev/null 2>&1 || true
        podkop_dnsmasq_changed=1
    elif [ "$podkop_default_has_dns" -eq 1 ]; then
        uci -q set 'dhcp.@dnsmasq[0].noresolv=0' >/dev/null 2>&1 || true
        podkop_dnsmasq_changed=1
    fi

    podkop_cachesize="$(uci -q get 'dhcp.@dnsmasq[0].podkop_cachesize' 2>/dev/null)"
    if [ -n "$podkop_cachesize" ]; then
        uci -q set "dhcp.@dnsmasq[0].cachesize=$podkop_cachesize" >/dev/null 2>&1 || true
        uci -q delete 'dhcp.@dnsmasq[0].podkop_cachesize' >/dev/null 2>&1 || true
        podkop_dnsmasq_changed=1
    elif [ "$podkop_default_has_dns" -eq 1 ]; then
        uci -q set 'dhcp.@dnsmasq[0].cachesize=150' >/dev/null 2>&1 || true
        podkop_dnsmasq_changed=1
    fi

    [ "$podkop_dnsmasq_changed" -eq 1 ] || return 0

    uci -q commit dhcp >/dev/null 2>&1 || true
    [ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
}

restore_podkop_dnsmasq_failsafe() {
    podkop_dont_touch_dhcp_enabled && return 0

    [ -x /usr/bin/podkop-plus ] && /usr/bin/podkop-plus restore_dnsmasq >/dev/null 2>&1 || true

    if [ -r /usr/lib/podkop-plus/dnsmasq_failsafe_restore.sh ]; then
        sh /usr/lib/podkop-plus/dnsmasq_failsafe_restore.sh >/dev/null 2>&1 || true
    else
        restore_podkop_dnsmasq_failsafe_raw
    fi
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
    restore_podkop_dnsmasq_failsafe
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

    detect_installer_language

    if pkg_is_installed "luci-i18n-podkop-plus-ru"; then
        PODKOP_PLUS_I18N_REQUESTED=1
        msg "$(installer_text i18n_installed)"
        return 0
    fi

    case "$luci_lang" in
        ru|ru_*|ru-*)
            msg "$(installer_text luci_ru)"
            ;;
    esac

    if confirm_prompt "$(installer_text i18n_prompt)"; then
        PODKOP_PLUS_I18N_REQUESTED=1
        INSTALLER_LANG="ru"
        return 0
    fi

    warn "$(installer_text i18n_skip)"
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
    rm -f /var/run/podkop-plus/ui-state/sing-box-version
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
    select_sing_box_installation
    deactivate_original_podkop_if_present

    pkg_list_update || fail "Failed to update package lists"
    ensure_bootstrap_tool "ucode" "ucode"

    resolve_podkop_plus_release
    remove_conflicting_dns_proxy
    remove_old_sing_box_if_needed
    install_selected_sing_box

    cleanup_legacy_installation
    download_podkop_plus_packages
    install_packages
    post_install

    msg "Podkop Plus $PODKOP_PLUS_PACKAGE_VERSION has been installed successfully"
    msg "Source release: ${REPO_OWNER}/${REPO_NAME}@${PODKOP_PLUS_RELEASE_TAG}"
    warn "Open LuCI and review your rules before enabling Podkop Plus"
}

main "$@"
