#!/bin/sh
# shellcheck shell=dash

REPO_OWNER="ushan0v"
REPO_NAME="forkop"

REQUIRED_SPACE_KB=15360
CONNECT_TIMEOUT_SECONDS=15
METADATA_TIMEOUT_SECONDS=60
DOWNLOAD_TIMEOUT_SECONDS=600

PKG_IS_APK=0
FETCHER=""
TMP_DIR=""
FORKOP_WAS_ENABLED=0
FORKOP_WAS_RUNNING=0
FORKOP_LEGACY_DETECTED=0
FORKOP_I18N_REQUESTED=0
INSTALLER_LANG="en"
SING_BOX_INSTALL_VARIANT=""

FORKOP_RELEASE_JSON=""
FORKOP_RELEASE_TAG=""
FORKOP_BACKEND_URL=""
FORKOP_BACKEND_NAME=""
FORKOP_BACKEND_FILE=""
FORKOP_APP_URL=""
FORKOP_APP_NAME=""
FORKOP_APP_FILE=""
FORKOP_I18N_URL=""
FORKOP_I18N_NAME=""
FORKOP_I18N_FILE=""
FORKOP_PACKAGE_VERSION=""
LEGACY_BRAND="$(printf '\160\157\144\153\157\160')"
LEGACY_BACKEND_PACKAGE="${LEGACY_BRAND}-plus"
LEGACY_CONFIG_PACKAGE_ALT="${LEGACY_BRAND}_plus"
LEGACY_CONFIG_BACKUP=""

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

Installs or updates Forkop packages:
  - forkop
  - luci-app-forkop
  - luci-i18n-forkop-ru when requested or when LuCI language is Russian

Can also install or switch sing-box variant:
  - stable sing-box from OpenWrt feeds
  - sing-box-extended from GitHub OpenWrt packages (for xHTTP support)
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
    TMP_DIR="$(mktemp -d /tmp/forkop.XXXXXX 2>/dev/null || true)"

    if [ -z "$TMP_DIR" ]; then
        TMP_DIR="/tmp/forkop.$$"
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

    fail "wget or curl is required to download Forkop"
}

run_with_deadline() {
    forkop_deadline_seconds="$1"
    shift

    "$@" &
    forkop_deadline_command_pid=$!
    (
        trap 'kill "$forkop_deadline_sleep_pid" 2>/dev/null || true; exit 0' TERM INT
        sleep "$forkop_deadline_seconds" &
        forkop_deadline_sleep_pid=$!
        wait "$forkop_deadline_sleep_pid"
        kill "$forkop_deadline_command_pid" 2>/dev/null || true
    ) &
    forkop_deadline_watchdog_pid=$!

    wait "$forkop_deadline_command_pid"
    forkop_deadline_status=$?
    kill "$forkop_deadline_watchdog_pid" 2>/dev/null || true
    wait "$forkop_deadline_watchdog_pid" 2>/dev/null || true
    return "$forkop_deadline_status"
}

http_get() {
    case "$FETCHER" in
        wget)
            run_with_deadline "$METADATA_TIMEOUT_SECONDS" wget -T "$CONNECT_TIMEOUT_SECONDS" -qO- "$1"
            ;;
        curl)
            curl --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --max-time "$METADATA_TIMEOUT_SECONDS" -fsSL "$1"
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

let uci_cursor_state = false;

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function truthy(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function path_parts(path) {
    path = as_string(path);
    let first = index(path, ".");
    if (first < 0)
        return null;

    let package_name = substr(path, 0, first);
    let rest = substr(path, first + 1);
    let second = index(rest, ".");
    if (second < 0)
        return { package: package_name, section: rest, option: "" };

    return {
        package: package_name,
        section: substr(rest, 0, second),
        option: substr(rest, second + 1)
    };
}

function uci_cursor() {
    if (uci_cursor_state !== false)
        return uci_cursor_state;

    try {
        uci_cursor_state = require("uci").cursor();
    }
    catch (e) {
        uci_cursor_state = null;
    }

    return uci_cursor_state;
}

function uci_available() {
    return uci_cursor() != null;
}

function uci_load(package_name) {
    let c = uci_cursor();
    if (c == null)
        return false;

    try {
        c.load(as_string(package_name));
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_value_to_string(value) {
    if (value == null)
        return "";
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function uci_value_to_list(value) {
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    return words(value);
}

function uci_get(path) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return "";
    if (!uci_load(parts.package))
        return "";

    return uci_value_to_string(c.get(parts.package, parts.section, parts.option));
}

function uci_exists(path) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null)
        return false;
    if (!uci_load(parts.package))
        return false;

    if (parts.option == "")
        return c.get_all(parts.package, parts.section) != null;
    return c.get(parts.package, parts.section, parts.option) != null;
}

function uci_delete(path) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null)
        return false;

    try {
        if (parts.option == "")
            c.delete(parts.package, parts.section);
        else
            c.delete(parts.package, parts.section, parts.option);
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_set(path, value) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    try {
        c.set(parts.package, parts.section, parts.option, type(value) == "array" ? value : as_string(value));
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_add_list(path, value) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    try {
        let values = uci_value_to_list(c.get(parts.package, parts.section, parts.option));
        push(values, as_string(value));
        c.set(parts.package, parts.section, parts.option, values);
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_del_list(path, value) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    let values = [];
    let removed = false;
    for (let item in uci_value_to_list(c.get(parts.package, parts.section, parts.option))) {
        if (item == value) {
            removed = true;
            continue;
        }
        push(values, item);
    }

    if (!removed)
        return false;

    try {
        if (length(values) == 0)
            c.delete(parts.package, parts.section, parts.option);
        else
            c.set(parts.package, parts.section, parts.option, values);
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_commit(package_name) {
    let c = uci_cursor();
    if (c == null)
        return false;

    try {
        return c.commit(package_name) != false;
    }
    catch (e) {
        return false;
    }
}

function run(command) {
    return system(command) == 0;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function run_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

function command_output(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    pipe.close();
    return data == null ? "" : data;
}

function env(name, fallback) {
    let value = getenv(name);
    if (value == null || value == "")
        return as_string(fallback);
    return as_string(value);
}

const INSTALLER_FORKOP_INIT = env("FORKOP_INSTALLER_INIT", "/etc/init.d/forkop");
const INSTALLER_FORKOP_BIN = env("FORKOP_INSTALLER_BIN", "/usr/bin/forkop");
const INSTALLER_FORKOP_LIB = env("FORKOP_INSTALLER_LIB", "/usr/lib/forkop");
const INSTALLER_FORKOP_PERSISTENT_DIR = env("FORKOP_INSTALLER_PERSISTENT_DIR", "/etc/forkop");
const INSTALLER_FORKOP_UCI_DEFAULTS = env("FORKOP_INSTALLER_UCI_DEFAULTS", "/etc/uci-defaults/50_luci-forkop");
const INSTALLER_FORKOP_LUCI_VIEW = env("FORKOP_INSTALLER_LUCI_VIEW", "/www/luci-static/resources/view/forkop");
const INSTALLER_MENU_JSON = env("FORKOP_INSTALLER_MENU_JSON", "/usr/share/luci/menu.d/luci-app-forkop.json");
const INSTALLER_ACL_JSON = env("FORKOP_INSTALLER_ACL_JSON", "/usr/share/rpcd/acl.d/luci-app-forkop.json");
const INSTALLER_RU_LMO = env("FORKOP_INSTALLER_RU_LMO", "/usr/lib/lua/luci/i18n/forkop.ru.lmo");
const INSTALLER_EN_LMO = env("FORKOP_INSTALLER_EN_LMO", "/usr/lib/lua/luci/i18n/forkop.en.lmo");
const INSTALLER_RU_LUA = env("FORKOP_INSTALLER_RU_LUA", "/usr/lib/lua/luci/i18n/forkop.ru.lua");
const INSTALLER_EN_LUA = env("FORKOP_INSTALLER_EN_LUA", "/usr/lib/lua/luci/i18n/forkop.en.lua");
const INSTALLER_RPCD_INIT = env("FORKOP_INSTALLER_RPCD_INIT", "/etc/init.d/rpcd");
const LEGACY_BRAND = env("FORKOP_INSTALLER_LEGACY_BRAND", "");
const LEGACY_BACKEND_PACKAGE = env("FORKOP_INSTALLER_LEGACY_BACKEND", LEGACY_BRAND + "-plus");
const LEGACY_CONFIG_PACKAGE_ALT = env("FORKOP_INSTALLER_LEGACY_CONFIG_ALT", LEGACY_BRAND + "_plus");
const INSTALLER_LEGACY_INIT = env("FORKOP_INSTALLER_LEGACY_INIT", "/etc/init.d/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_BASE_INIT = env("FORKOP_INSTALLER_LEGACY_BASE_INIT", "/etc/init.d/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_BIN = env("FORKOP_INSTALLER_LEGACY_BASE_BIN", "/usr/bin/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_LIB = env("FORKOP_INSTALLER_LEGACY_BASE_LIB", "/usr/lib/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_UCI_DEFAULTS = env("FORKOP_INSTALLER_LEGACY_BASE_UCI_DEFAULTS", "/etc/uci-defaults/50_luci-" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_LUCI_VIEW = env("FORKOP_INSTALLER_LEGACY_BASE_LUCI_VIEW", "/www/luci-static/resources/view/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_MENU_JSON = env("FORKOP_INSTALLER_LEGACY_BASE_MENU_JSON", "/usr/share/luci/menu.d/luci-app-" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_ACL_JSON = env("FORKOP_INSTALLER_LEGACY_BASE_ACL_JSON", "/usr/share/rpcd/acl.d/luci-app-" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_I18N = env("FORKOP_INSTALLER_LEGACY_BASE_I18N", "/usr/lib/lua/luci/i18n/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_CONFIG = env("FORKOP_INSTALLER_LEGACY_BASE_CONFIG", "/etc/config/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_PERSISTENT_DIR = env("FORKOP_INSTALLER_LEGACY_BASE_PERSISTENT_DIR", "/etc/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_RUNTIME_DIR = env("FORKOP_INSTALLER_LEGACY_BASE_RUNTIME_DIR", "/var/run/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_TMP_DIR = env("FORKOP_INSTALLER_LEGACY_BASE_TMP_DIR", "/tmp/" + LEGACY_BRAND);
const INSTALLER_LEGACY_TMP_PACKAGE_GLOB = env("FORKOP_INSTALLER_LEGACY_TMP_PACKAGE_GLOB", "/tmp/*" + LEGACY_BRAND + "*");
const INSTALLER_LEGACY_SCAN_ROOTS = env("FORKOP_INSTALLER_LEGACY_SCAN_ROOTS", "/tmp /var/run /etc /usr/lib /usr/share/luci /usr/share/rpcd /www/luci-static/resources/view");
const INSTALLER_LEGACY_BIN = env("FORKOP_INSTALLER_LEGACY_BIN", "/usr/bin/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_LIB = env("FORKOP_INSTALLER_LEGACY_LIB", "/usr/lib/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_UCI_DEFAULTS = env("FORKOP_INSTALLER_LEGACY_UCI_DEFAULTS", "/etc/uci-defaults/50_luci-" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_LUCI_VIEW = env("FORKOP_INSTALLER_LEGACY_LUCI_VIEW", "/www/luci-static/resources/view/" + LEGACY_CONFIG_PACKAGE_ALT);
const INSTALLER_LEGACY_MENU_JSON = env("FORKOP_INSTALLER_LEGACY_MENU_JSON", "/usr/share/luci/menu.d/luci-app-" + LEGACY_BACKEND_PACKAGE + ".json");
const INSTALLER_LEGACY_ACL_JSON = env("FORKOP_INSTALLER_LEGACY_ACL_JSON", "/usr/share/rpcd/acl.d/luci-app-" + LEGACY_BACKEND_PACKAGE + ".json");
const INSTALLER_LEGACY_CONFIG = env("FORKOP_INSTALLER_LEGACY_CONFIG", "/etc/config/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_CONFIG_ALT = env("FORKOP_INSTALLER_LEGACY_CONFIG_FILE_ALT", "/etc/config/" + LEGACY_CONFIG_PACKAGE_ALT);
const INSTALLER_LEGACY_PERSISTENT_DIR = env("FORKOP_INSTALLER_LEGACY_PERSISTENT_DIR", "/etc/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_RUNTIME_DIR = env("FORKOP_INSTALLER_LEGACY_RUNTIME_DIR", "/var/run/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_TMP_DIR = env("FORKOP_INSTALLER_LEGACY_TMP_DIR", "/tmp/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_TMP_ALT_DIR = env("FORKOP_INSTALLER_LEGACY_TMP_ALT_DIR", "/tmp/" + LEGACY_CONFIG_PACKAGE_ALT);

let dns_owner_config = "forkop";
let dns_owner_section = "forkop";
let dns_owner_option_prefix = "forkop_";

function path_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function path_executable(path) {
    return run_args([ "test", "-x", path ]);
}

function remove_path(path) {
    if (as_string(path) == "" || !path_exists(path))
        return true;
    return run_args([ "rm", "-rf", path ]);
}

function remove_glob(pattern) {
    pattern = as_string(pattern);
    if (pattern == "")
        return true;
    let removed = true;
    for (let path in fs.glob(pattern))
        if (!remove_path(path))
            removed = false;
    return removed;
}

function remove_globs(patterns) {
    let removed = true;
    for (let pattern in words(patterns))
        if (!remove_glob(pattern))
            removed = false;
    return removed;
}

function remove_legacy_named_children(root) {
    root = as_string(root);
    if (root == "" || LEGACY_BRAND == "")
        return true;

    let entries = fs.lsdir(root);
    if (type(entries) != "array")
        return true;

    let removed = true;
    let brand = lc(LEGACY_BRAND);
    for (let entry in entries) {
        entry = as_string(entry);
        let path = root + "/" + entry;
        if (index(lc(entry), brand) >= 0) {
            if (!remove_path(path))
                removed = false;
            continue;
        }

        let stat = fs.stat(path);
        if (stat != null && stat.type == "directory" && !remove_legacy_named_children(path))
            removed = false;
    }
    return removed;
}

function restart_dnsmasq() {
    return run("[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart");
}

function installer_package_manager() {
    return run_args([ "apk", "--version" ]) ? "apk" : "opkg";
}

function installer_installed_package_names() {
    let manager = installer_package_manager();
    let output = manager == "apk" ?
        command_output([ "apk", "info" ]) :
        command_output([ "opkg", "list-installed" ]);
    let names = [];

    for (let line in split(output, "\n")) {
        line = trim(as_string(line));
        if (line == "")
            continue;
        if (manager == "opkg") {
            let parts = split(line, /[ \t]+/);
            line = parts[0] || "";
        }
        if (line != "")
            push(names, line);
    }

    return names;
}

function installer_package_installed(name) {
    name = as_string(name);
    if (name == "")
        return false;

    if (installer_package_manager() == "apk")
        return run_args([ "apk", "info", "-e", name ]);

    for (let installed in installer_installed_package_names())
        if (installed == name)
            return true;
    return false;
}

function installer_remove_package(name) {
    name = as_string(name);
    if (name == "" || !installer_package_installed(name))
        return true;

    if (installer_package_manager() == "apk")
        return run_args([ "apk", "del", name ]);
    return run_args([ "opkg", "remove", "--force-depends", name ]);
}

function installer_remove_package_prefix(prefix) {
    prefix = as_string(prefix);
    if (prefix == "")
        return true;

    let removed = true;
    for (let name in installer_installed_package_names())
        if (starts_with(name, prefix) && !installer_remove_package(name))
            removed = false;
    return removed;
}

function installer_confirm_remove_https_dns_proxy() {
    if (!installer_package_installed("https-dns-proxy"))
        return true;

    warn("Detected conflicting package: https-dns-proxy\n");

    if (run("[ ! -t 0 ]")) {
        warn("Remove the conflicting https-dns-proxy package and continue?: 1 (yes, non-interactive)\n");
        return true;
    }

    while (true) {
        warn("\nRemove the conflicting https-dns-proxy package and continue?\n");
        warn("  1) yes\n");
        warn("  2) no\n");
        warn("Select [2]: ");

        let input = fs.open("/dev/stdin", "r");
        let answer = input ? trim(as_string(input.read("line"))) : "";
        if (input)
            input.close();

        if (answer == "1")
            return true;
        if (answer == "" || answer == "2")
            return false;
        warn("Invalid choice\n");
    }
}

function installer_service_enabled(init_script) {
    return path_executable(init_script) && run_args([ init_script, "enabled" ]);
}

function installer_service_running(init_script) {
    if (!path_executable(init_script))
        return false;

    if (trim(command_output([ init_script, "status" ])) == "running")
        return true;
    return run_args([ init_script, "running" ]);
}

function installer_backend_status_running(bin_path) {
    if (!path_executable(bin_path))
        return false;
    return index(command_output([ bin_path, "get_status" ]), "\"running\":1") >= 0;
}

function select_dns_owner(legacy) {
    if (legacy) {
        dns_owner_config = LEGACY_BACKEND_PACKAGE;
        dns_owner_section = LEGACY_CONFIG_PACKAGE_ALT;
        dns_owner_option_prefix = LEGACY_BRAND + "_";
    }
    else {
        dns_owner_config = "forkop";
        dns_owner_section = "forkop";
        dns_owner_option_prefix = "forkop_";
    }
}

function installer_restore_dnsmasq(bin_path, legacy) {
    if (path_executable(bin_path) && run_args([ bin_path, "restore_dnsmasq" ]))
        return true;

    select_dns_owner(legacy);
    return dnsmasq_failsafe_restore();
}

function installer_deactivate_legacy_base() {
    if (!path_executable(INSTALLER_LEGACY_BASE_INIT))
        return;

    if (installer_service_running(INSTALLER_LEGACY_BASE_INIT)) {
        warn("Detected a running legacy service. Stopping it before installing Forkop.\n");
        run_args([ INSTALLER_LEGACY_BASE_INIT, "stop" ]);
    }

    if (installer_service_enabled(INSTALLER_LEGACY_BASE_INIT)) {
        warn("Detected an enabled legacy autostart. Disabling it before installing Forkop.\n");
        run_args([ INSTALLER_LEGACY_BASE_INIT, "disable" ]);
    }
}

function installer_cleanup_legacy() {
    let forkop_installed = installer_package_installed("forkop");
    let legacy_installed = LEGACY_BRAND != "" && installer_package_installed(LEGACY_BACKEND_PACKAGE);
    let active_init = legacy_installed ? INSTALLER_LEGACY_INIT : INSTALLER_FORKOP_INIT;
    let active_bin = legacy_installed ? INSTALLER_LEGACY_BIN : INSTALLER_FORKOP_BIN;
    let was_enabled = installer_service_enabled(active_init);
    let was_running = installer_service_running(active_init) || installer_backend_status_running(active_bin);

    if (!installer_confirm_remove_https_dns_proxy())
        return false;

    if (legacy_installed)
        installer_deactivate_legacy_base();

    if (path_executable(active_init)) {
        run_args([ active_init, "stop" ]);
        installer_restore_dnsmasq(active_bin, legacy_installed);
        run_args([ active_init, "disable" ]);
    }

    let packages_removed = true;
    for (let package_name in [ "luci-app-https-dns-proxy", "https-dns-proxy" ])
        if (!installer_remove_package(package_name))
            packages_removed = false;
    if (!installer_remove_package_prefix("luci-i18n-https-dns-proxy"))
        packages_removed = false;

    if (legacy_installed) {
        if (!installer_remove_package_prefix("luci-i18n-" + LEGACY_BACKEND_PACKAGE))
            packages_removed = false;
        if (!installer_remove_package("luci-app-" + LEGACY_BACKEND_PACKAGE))
            packages_removed = false;
        if (!installer_remove_package(LEGACY_BACKEND_PACKAGE))
            packages_removed = false;
    }

    if (!installer_remove_package_prefix("luci-i18n-forkop"))
        packages_removed = false;
    if (!installer_remove_package("luci-app-forkop"))
        packages_removed = false;

    if (!packages_removed) {
        warn("Failed to remove one or more conflicting or legacy packages.\n");
        return false;
    }

    if (legacy_installed) {
        remove_path(INSTALLER_LEGACY_LIB);
        remove_path(INSTALLER_LEGACY_INIT);
        remove_path(INSTALLER_LEGACY_BIN);
        for (let path in [
            INSTALLER_LEGACY_LUCI_VIEW,
            INSTALLER_LEGACY_MENU_JSON,
            INSTALLER_LEGACY_ACL_JSON,
            INSTALLER_LEGACY_UCI_DEFAULTS
        ])
            remove_path(path);
    }

    if (!forkop_installed) {
        remove_path(INSTALLER_FORKOP_LIB);
        remove_path(INSTALLER_FORKOP_INIT);
        remove_path(INSTALLER_FORKOP_BIN);
    }

    for (let path in [
        INSTALLER_FORKOP_LUCI_VIEW,
        INSTALLER_MENU_JSON,
        INSTALLER_ACL_JSON,
        INSTALLER_FORKOP_UCI_DEFAULTS,
        INSTALLER_RU_LMO,
        INSTALLER_EN_LMO,
        INSTALLER_RU_LUA,
        INSTALLER_EN_LUA
    ])
        remove_path(path);

    print("FORKOP_WAS_ENABLED=", was_enabled ? "1" : "0", "\n");
    print("FORKOP_WAS_RUNNING=", was_running ? "1" : "0", "\n");
    print("FORKOP_LEGACY_DETECTED=", legacy_installed ? "1" : "0", "\n");
    return true;
}

function installer_finalize_legacy() {
    if (LEGACY_BRAND == "")
        return false;

    let legacy_tailscale_dir = INSTALLER_LEGACY_PERSISTENT_DIR + "/tailscale";
    if (path_exists(legacy_tailscale_dir)) {
        let entries = fs.lsdir(legacy_tailscale_dir);
        let forkop_tailscale_dir = INSTALLER_FORKOP_PERSISTENT_DIR + "/tailscale";
        if (type(entries) != "array" || !run_args([ "mkdir", "-p", forkop_tailscale_dir ])) {
            warn("Failed to prepare legacy Tailscale state migration; the legacy directory was preserved.\n");
            return false;
        }

        for (let entry in entries) {
            entry = as_string(entry);
            let source = legacy_tailscale_dir + "/" + entry;
            let target = forkop_tailscale_dir + "/" + entry;
            if (path_exists(target))
                continue;

            let temporary = forkop_tailscale_dir + "/." + entry + ".forkop-migrate";
            if (!remove_path(temporary) ||
                !run_args([ "cp", "-a", source, temporary ]) ||
                !run_args([ "mv", temporary, target ])) {
                remove_path(temporary);
                warn("Failed to migrate legacy Tailscale state; the legacy directory was preserved.\n");
                return false;
            }
        }
    }

    let cleaned = true;
    for (let path in [
        INSTALLER_LEGACY_CONFIG,
        INSTALLER_LEGACY_CONFIG_ALT,
        INSTALLER_LEGACY_PERSISTENT_DIR,
        INSTALLER_LEGACY_RUNTIME_DIR,
        INSTALLER_LEGACY_TMP_DIR,
        INSTALLER_LEGACY_TMP_ALT_DIR
    ])
        if (!remove_path(path))
            cleaned = false;

    for (let prefix in [
        INSTALLER_LEGACY_CONFIG,
        INSTALLER_LEGACY_CONFIG_ALT,
        INSTALLER_LEGACY_PERSISTENT_DIR,
        INSTALLER_LEGACY_RUNTIME_DIR,
        INSTALLER_LEGACY_TMP_DIR,
        INSTALLER_LEGACY_TMP_ALT_DIR,
        INSTALLER_LEGACY_INIT,
        INSTALLER_LEGACY_BIN,
        INSTALLER_LEGACY_LIB,
        INSTALLER_LEGACY_UCI_DEFAULTS,
        INSTALLER_LEGACY_LUCI_VIEW,
        INSTALLER_LEGACY_MENU_JSON,
        INSTALLER_LEGACY_ACL_JSON,
        INSTALLER_LEGACY_BASE_CONFIG,
        INSTALLER_LEGACY_BASE_PERSISTENT_DIR,
        INSTALLER_LEGACY_BASE_RUNTIME_DIR,
        INSTALLER_LEGACY_BASE_TMP_DIR,
        INSTALLER_LEGACY_BASE_INIT,
        INSTALLER_LEGACY_BASE_BIN,
        INSTALLER_LEGACY_BASE_LIB,
        INSTALLER_LEGACY_BASE_UCI_DEFAULTS,
        INSTALLER_LEGACY_BASE_LUCI_VIEW,
        INSTALLER_LEGACY_BASE_MENU_JSON,
        INSTALLER_LEGACY_BASE_ACL_JSON,
        INSTALLER_LEGACY_BASE_I18N
    ])
        if (!remove_glob(prefix + "*"))
            cleaned = false;

    if (!remove_glob(INSTALLER_LEGACY_TMP_PACKAGE_GLOB))
        cleaned = false;

    for (let root in words(INSTALLER_LEGACY_SCAN_ROOTS))
        if (!remove_legacy_named_children(root))
            cleaned = false;

    return cleaned;
}

function installer_post_install() {
    remove_globs(env("FORKOP_INSTALLER_LUCI_CACHE_GLOBS", "/var/luci-indexcache* /tmp/luci-indexcache*"));
    for (let path in [
        env("FORKOP_INSTALLER_LATEST_VERSION_CACHE", "/tmp/forkop.latest-version.cache"),
        env("FORKOP_INSTALLER_SYSTEM_INFO_CACHE", "/var/run/forkop/system-info.json"),
        env("FORKOP_INSTALLER_SERVER_COUNTRY_CACHE", "/var/run/forkop/server-country-cache.json"),
        env("FORKOP_INSTALLER_SING_BOX_VERSION_CACHE", "/var/run/forkop/ui-state/sing-box-version"),
        env("FORKOP_INSTALLER_TMP_SYSTEM_INFO_CACHE", "/tmp/forkop/system-info.json")
    ])
        remove_path(path);

    if (path_executable(INSTALLER_RPCD_INIT))
        run_args([ INSTALLER_RPCD_INIT, "reload" ]);

    if (env("FORKOP_WAS_ENABLED", "0") == "1" && path_executable(INSTALLER_FORKOP_INIT))
        run_args([ INSTALLER_FORKOP_INIT, "enable" ]);

    if (env("FORKOP_WAS_RUNNING", "0") == "1" && path_executable(INSTALLER_FORKOP_INIT)) {
        if (!run_args([ INSTALLER_FORKOP_INIT, "start" ]) &&
            !run_args([ INSTALLER_FORKOP_INIT, "restart" ]))
            warn("Failed to start Forkop after upgrade.\n");
    }

    return true;
}

function list_has(values, needle) {
    for (let value in words(values))
        if (value == needle)
            return true;
    return false;
}

function dnsmasq_managed_instance_exists() {
    return uci_exists("dhcp." + dns_owner_section);
}

function dnsmasq_default_servers() {
    return uci_get("dhcp.@dnsmasq[0].server");
}

function dnsmasq_default_has_managed_dns() {
    return list_has(dnsmasq_default_servers(), "127.0.0.42");
}

function dnsmasq_has_managed_dns() {
    return dnsmasq_default_has_managed_dns() || dnsmasq_managed_instance_exists();
}

function dnsmasq_has_managed_state() {
    return uci_get("dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "server") != "" ||
        uci_get("dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "noresolv") != "" ||
        uci_get("dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "cachesize") != "" ||
        uci_get("dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "notinterface") != "" ||
        dnsmasq_managed_instance_exists();
}

function dnsmasq_management_disabled() {
    return truthy(uci_get(dns_owner_config + ".settings.dont_touch_dhcp"));
}

function dnsmasq_managed_interfaces() {
    let interfaces = uci_get("dhcp." + dns_owner_section + ".interface");
    if (interfaces == "")
        interfaces = uci_get(dns_owner_config + ".settings.source_network_interfaces");
    if (interfaces == "")
        interfaces = "br-lan";

    return interfaces;
}

function dnsmasq_cleanup_managed_instance() {
    let managed_instance_present = dnsmasq_managed_instance_exists();
    let managed_interfaces = managed_instance_present ? dnsmasq_managed_interfaces() : "";

    uci_delete("dhcp." + dns_owner_section);

    let backup_option = "dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "notinterface";
    let backup_notinterfaces = uci_get(backup_option);
    if (backup_notinterfaces != "") {
        uci_delete("dhcp.@dnsmasq[0].notinterface");
        for (let value in words(backup_notinterfaces))
            uci_add_list("dhcp.@dnsmasq[0].notinterface", value);
        uci_delete(backup_option);
        return;
    }

    if (managed_instance_present) {
        for (let value in words(managed_interfaces))
            uci_del_list("dhcp.@dnsmasq[0].notinterface", value);
    }

    uci_delete(backup_option);
}

function dnsmasq_restore_default_instance() {
    let server_list = dnsmasq_default_servers();
    let server_backup_option = "dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "server";
    let backup_servers = uci_get(server_backup_option);
    let managed_global_dns = list_has(server_list, "127.0.0.42");

    uci_delete("dhcp.@dnsmasq[0].server");
    if (backup_servers != "") {
        for (let value in words(backup_servers))
            uci_add_list("dhcp.@dnsmasq[0].server", value);
        uci_delete(server_backup_option);
    }
    else {
        for (let value in words(server_list)) {
            if (value != "127.0.0.42")
                uci_add_list("dhcp.@dnsmasq[0].server", value);
        }
    }
    uci_delete(server_backup_option);

    let noresolv_backup_option = "dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "noresolv";
    let noresolv = uci_get(noresolv_backup_option);
    if (noresolv != "") {
        uci_set("dhcp.@dnsmasq[0].noresolv", noresolv);
        uci_delete(noresolv_backup_option);
    }
    else if (managed_global_dns) {
        uci_set("dhcp.@dnsmasq[0].noresolv", "0");
    }

    let cachesize_backup_option = "dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "cachesize";
    let cachesize = uci_get(cachesize_backup_option);
    if (cachesize != "") {
        uci_set("dhcp.@dnsmasq[0].cachesize", cachesize);
        uci_delete(cachesize_backup_option);
    }
    else if (managed_global_dns) {
        uci_set("dhcp.@dnsmasq[0].cachesize", "150");
    }
}

function dnsmasq_failsafe_restore() {
    if (!uci_available())
        return true;

    if (dnsmasq_management_disabled() && !dnsmasq_has_managed_state())
        return true;

    if (!dnsmasq_has_managed_dns() && !dnsmasq_has_managed_state())
        return true;

    dnsmasq_cleanup_managed_instance();
    dnsmasq_restore_default_instance();
    uci_commit("dhcp");
    restart_dnsmasq();
    return true;
}

function release_version_valid(value) {
    return match(as_string(value), /^[0-9]+[.][0-9]+[.][0-9]+$/) != null;
}

function asset_matches(name, kind, ext, version) {
    if (!release_version_valid(version))
        return false;

    if (kind == "backend")
        return name == "forkop_" + version + "." + ext;
    if (kind == "app")
        return name == "luci-app-forkop_" + version + "." + ext;
    if (kind == "i18n")
        return name == "luci-i18n-forkop-ru_" + version + "." + ext;
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
    let version = as_string(release.tag_name || "");
    if (!release_version_valid(version))
        return;
    for (let asset in release.assets) {
        if (type(asset) == "object" && asset_matches(asset.name, kind, ext, version)) {
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
else if (mode == "uci-get") {
    let value = uci_get(ARGV[1]);
    if (value != "")
        print(value, "\n");
}
else if (mode == "dnsmasq-failsafe-restore")
    exit(dnsmasq_failsafe_restore() ? 0 : 1);
else if (mode == "installer-cleanup-legacy")
    exit(installer_cleanup_legacy() ? 0 : 1);
else if (mode == "installer-finalize-legacy")
    exit(installer_finalize_legacy() ? 0 : 1);
else if (mode == "installer-post-install")
    exit(installer_post_install() ? 0 : 1);
else
    exit(1);
EOF
    fi

    printf '%s\n' "$helper_path"
}


install_json_ucode() {
    FORKOP_INSTALLER_LEGACY_BRAND="$LEGACY_BRAND" \
    FORKOP_INSTALLER_LEGACY_BACKEND="$LEGACY_BACKEND_PACKAGE" \
    FORKOP_INSTALLER_LEGACY_CONFIG_ALT="$LEGACY_CONFIG_PACKAGE_ALT" \
        ucode "$(install_json_helper_path)" "$@"
}

download_file_once() {
    case "$FETCHER" in
        wget)
            run_with_deadline "$DOWNLOAD_TIMEOUT_SECONDS" wget -T "$CONNECT_TIMEOUT_SECONDS" -q -O "$2" "$1"
            ;;
        curl)
            curl --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --max-time "$DOWNLOAD_TIMEOUT_SECONDS" -fsSL "$1" -o "$2"
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

ensure_bootstrap_package() {
    package_name="$1"

    if pkg_is_installed "$package_name"; then
        return 0
    fi

    msg "Installing bootstrap dependency: $package_name"
    pkg_install_name "$package_name" || fail "Failed to install $package_name"
}

ensure_bootstrap_ucode_runtime() {
    ensure_bootstrap_tool "ucode" "ucode"
    ensure_bootstrap_package "ucode-mod-fs"
    ensure_bootstrap_package "ucode-mod-uci"
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
        fail "Forkop requires OpenWrt 24.10 or newer"
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
            luci_ru) printf '%s\n' "Русский пакет интерфейса будет установлен автоматически." ;;
            sing_box_prompt) printf '%s\n' "Какую сборку singbox ставить?" ;;
            sing_box_stable) printf '%s\n' "singbox stable" ;;
            sing_box_extended) printf '%s\n' "singbox extended (если нужен xhttp)" ;;
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
        luci_ru) printf '%s\n' "The Russian interface package will be installed automatically." ;;
        sing_box_prompt) printf '%s\n' "Which singbox build should be installed?" ;;
        sing_box_stable) printf '%s\n' "singbox stable" ;;
        sing_box_extended) printf '%s\n' "singbox extended (if xhttp is needed)" ;;
        sing_box_skip_msg) printf '%s\n' "Skipping sing-box installation." ;;
        *) printf '%s\n' "$key" ;;
    esac
}

detect_installer_language() {
    luci_lang="$(get_luci_main_lang)"

    INSTALLER_LANG="en"
    if pkg_is_installed "luci-i18n-forkop-ru"; then
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
    command_exists ucode || return 0
    ucode -e 'require("fs"); require("uci");' >/dev/null 2>&1 || return 0
    install_json_ucode uci-get luci.main.lang 2>/dev/null || true
}

extract_package_version() {
    package_name="$1"

    case "$package_name" in
        forkop_*.ipk|forkop_*.apk)
            printf '%s\n' "$package_name" | sed 's/^forkop_//;s/\.ipk$//;s/\.apk$//'
            ;;
        luci-app-forkop_*.ipk|luci-app-forkop_*.apk)
            printf '%s\n' "$package_name" | sed 's/^luci-app-forkop_//;s/\.ipk$//;s/\.apk$//'
            ;;
        luci-i18n-forkop-ru_*.ipk|luci-i18n-forkop-ru_*.apk)
            printf '%s\n' "$package_name" | sed 's/^luci-i18n-forkop-ru_//;s/\.ipk$//;s/\.apk$//'
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

resolve_forkop_release() {
    asset_ext="ipk"

    [ "$PKG_IS_APK" -eq 1 ] && asset_ext="apk"

    FORKOP_RELEASE_JSON="$(fetch_github_latest_release_json "$REPO_OWNER" "$REPO_NAME")"
    FORKOP_RELEASE_TAG="$(printf '%s' "$FORKOP_RELEASE_JSON" | install_json_ucode release-tag 2>/dev/null)"
    [ -n "$FORKOP_RELEASE_TAG" ] || fail "Failed to detect the Forkop release tag"

    FORKOP_BACKEND_URL="$(printf '%s' "$FORKOP_RELEASE_JSON" | install_json_ucode release-asset-url backend "$asset_ext" 2>/dev/null)"
    [ -n "$FORKOP_BACKEND_URL" ] || fail "The Forkop release does not contain a forkop .$asset_ext package"

    FORKOP_APP_URL="$(printf '%s' "$FORKOP_RELEASE_JSON" | install_json_ucode release-asset-url app "$asset_ext" 2>/dev/null)"
    [ -n "$FORKOP_APP_URL" ] || fail "The Forkop release does not contain a luci-app-forkop .$asset_ext package"

    FORKOP_BACKEND_NAME="$(basename "$FORKOP_BACKEND_URL")"
    FORKOP_APP_NAME="$(basename "$FORKOP_APP_URL")"
    FORKOP_PACKAGE_VERSION="$(extract_package_version "$FORKOP_BACKEND_NAME")"

    FORKOP_I18N_URL=""
    FORKOP_I18N_NAME=""

    if [ "$FORKOP_I18N_REQUESTED" -eq 1 ]; then
        FORKOP_I18N_URL="$(printf '%s' "$FORKOP_RELEASE_JSON" | install_json_ucode release-asset-url i18n "$asset_ext" 2>/dev/null)"
        [ -n "$FORKOP_I18N_URL" ] || fail "The Forkop release does not contain a luci-i18n-forkop-ru .$asset_ext package"
        FORKOP_I18N_NAME="$(basename "$FORKOP_I18N_URL")"
    fi
}

sing_box_is_present() {
    command_exists sing-box ||
        pkg_is_installed "sing-box" ||
        pkg_is_installed "sing-box-tiny" ||
        pkg_is_installed "sing-box-extended"
}

select_sing_box_installation() {
    answer=""
    default_choice=1

    if [ "$FORKOP_LEGACY_DETECTED" -eq 1 ] &&
        [ -r /etc/init.d/sing-box ] &&
        grep -Fq 'managed sing-box service for binary variants' /etc/init.d/sing-box; then
        SING_BOX_INSTALL_VARIANT="extended-compressed"
        msg "The legacy binary-managed sing-box variant will be reinstalled for Forkop"
        return 0
    fi

    if sing_box_is_present; then
        SING_BOX_INSTALL_VARIANT=""
        return 0
    fi

    if [ ! -t 0 ]; then
        SING_BOX_INSTALL_VARIANT="stable"
        msg "$(installer_text sing_box_prompt): $default_choice ($(installer_text sing_box_stable), non-interactive)"
        return 0
    fi

    while :; do
        printf '\n%s\n' "$(installer_text sing_box_prompt)"
        printf '  1) %s\n' "$(installer_text sing_box_stable)"
        printf '  2) %s\n' "$(installer_text sing_box_extended)"
        printf '%s [%s]: ' "$(installer_text select)" "$default_choice"
        read -r answer || return 1
        [ -n "$answer" ] || answer="$default_choice"

        if [ "$answer" = "1" ]; then
            SING_BOX_INSTALL_VARIANT="stable"
            return 0
        fi
        if [ "$answer" = "2" ]; then
            SING_BOX_INSTALL_VARIANT="extended"
            return 0
        fi

        warn "$(installer_text invalid_choice)"
    done
}

install_selected_sing_box() {
    action=""
    output_file="$TMP_DIR/sing-box-component-action.json"

    case "$SING_BOX_INSTALL_VARIANT" in
        "")
            msg "$(installer_text sing_box_skip_msg)"
            return 0
            ;;
        stable)
            action="install_stable"
            ;;
        extended)
            action="install_extended"
            ;;
        extended-compressed)
            action="install_extended_compressed"
            ;;
        *)
            fail "Unknown sing-box installation variant: $SING_BOX_INSTALL_VARIANT"
            ;;
    esac

    [ -x /usr/bin/forkop ] || fail "forkop backend must be installed before sing-box component action"
    msg "Installing selected sing-box variant through Forkop ucode backend"
    if ! /usr/bin/forkop component_action sing_box "$action" >"$output_file" 2>&1; then
        cat "$output_file" >&2 2>/dev/null || true
        fail "Failed to install selected sing-box variant"
    fi
}

cleanup_legacy_installation() {
    state_file="$TMP_DIR/install-state.env"

    install_json_ucode installer-cleanup-legacy >"$state_file" ||
        fail "Failed to prepare the system before Forkop package installation"

    # shellcheck disable=SC1090
    . "$state_file"
}

detect_legacy_installation() {
    FORKOP_LEGACY_DETECTED=0
    LEGACY_CONFIG_BACKUP=""

    pkg_is_installed "$LEGACY_BACKEND_PACKAGE" || return 0

    FORKOP_LEGACY_DETECTED=1
    for legacy_config_path in \
        "/etc/config/$LEGACY_BACKEND_PACKAGE" \
        "/etc/config/$LEGACY_CONFIG_PACKAGE_ALT"; do
        if [ -r "$legacy_config_path" ]; then
            LEGACY_CONFIG_BACKUP="$TMP_DIR/legacy-config.backup"
            cp "$legacy_config_path" "$LEGACY_CONFIG_BACKUP" ||
                fail "Failed to back up the legacy configuration"
            break
        fi
    done

    msg "Legacy installation detected; its packages will be removed and its configuration will be upgraded"
}

decide_i18n_installation() {
    luci_lang="$(get_luci_main_lang)"

    detect_installer_language

    if pkg_is_installed "luci-i18n-forkop-ru"; then
        FORKOP_I18N_REQUESTED=1
        msg "$(installer_text i18n_installed)"
        return 0
    fi

    if [ "$FORKOP_LEGACY_DETECTED" -eq 1 ] &&
        pkg_is_installed "luci-i18n-${LEGACY_BACKEND_PACKAGE}-ru"; then
        FORKOP_I18N_REQUESTED=1
        msg "$(installer_text i18n_installed)"
        return 0
    fi

    case "$luci_lang" in
        ru|ru_*|ru-*)
            FORKOP_I18N_REQUESTED=1
            INSTALLER_LANG="ru"
            msg "$(installer_text luci_ru)"
            return 0
            ;;
    esac

    if confirm_prompt "$(installer_text i18n_prompt)"; then
        FORKOP_I18N_REQUESTED=1
        INSTALLER_LANG="ru"
        return 0
    fi

    warn "$(installer_text i18n_skip)"
}

download_forkop_packages() {
    FORKOP_BACKEND_FILE="$TMP_DIR/$FORKOP_BACKEND_NAME"
    FORKOP_APP_FILE="$TMP_DIR/$FORKOP_APP_NAME"
    FORKOP_I18N_FILE=""

    download_with_retry "$FORKOP_BACKEND_URL" "$FORKOP_BACKEND_FILE" "$FORKOP_BACKEND_NAME" || fail "Failed to download $FORKOP_BACKEND_NAME"
    download_with_retry "$FORKOP_APP_URL" "$FORKOP_APP_FILE" "$FORKOP_APP_NAME" || fail "Failed to download $FORKOP_APP_NAME"

    if [ -n "$FORKOP_I18N_URL" ]; then
        FORKOP_I18N_FILE="$TMP_DIR/$FORKOP_I18N_NAME"
        download_with_retry "$FORKOP_I18N_URL" "$FORKOP_I18N_FILE" "$FORKOP_I18N_NAME" || fail "Failed to download $FORKOP_I18N_NAME"
    fi
}

install_backend_package() {
    pkg_install_files "$FORKOP_BACKEND_FILE" || fail "forkop installation failed"
}

migrate_legacy_configuration() {
    [ "$FORKOP_LEGACY_DETECTED" -eq 1 ] || return 0

    if [ -n "$LEGACY_CONFIG_BACKUP" ]; then
        cp "$LEGACY_CONFIG_BACKUP" /etc/config/forkop ||
            fail "Failed to restore the legacy configuration for migration"
        chmod 0644 /etc/config/forkop ||
            fail "Failed to set permissions on the Forkop configuration"

        msg "Migrating the legacy configuration to Forkop"
        if ! FORKOP_CONFIG_NAME="forkop" \
            FORKOP_LIB="/usr/lib/forkop" \
            ucode -L /usr/lib/forkop /usr/lib/forkop/config/migration.uc migrate-podkop; then
            cp "$LEGACY_CONFIG_BACKUP" /etc/config/forkop 2>/dev/null || true
            fail "Legacy configuration migration failed; the original configuration was restored"
        fi
    else
        warn "The legacy package had no readable configuration; Forkop defaults will be used"
    fi

    install_json_ucode installer-finalize-legacy ||
        fail "Failed to remove legacy configuration and cache files after migration"
}

install_ui_packages() {
    pkg_install_files "$FORKOP_APP_FILE" || fail "luci-app-forkop installation failed"

    if [ -n "$FORKOP_I18N_FILE" ]; then
        pkg_install_files "$FORKOP_I18N_FILE" || fail "luci-i18n-forkop-ru installation failed"
    fi
}

post_install() {
    FORKOP_WAS_ENABLED="$FORKOP_WAS_ENABLED" FORKOP_WAS_RUNNING="$FORKOP_WAS_RUNNING" \
        install_json_ucode installer-post-install ||
        fail "Failed to complete Forkop post-install actions"
}

main() {
    trap cleanup EXIT HUP INT TERM

    parse_args "$@"
    check_root
    init_tmp_dir
    detect_fetcher
    sync_time
    check_system

    detect_legacy_installation
    decide_i18n_installation
    select_sing_box_installation

    pkg_list_update || fail "Failed to update package lists"
    ensure_bootstrap_ucode_runtime

    resolve_forkop_release
    download_forkop_packages

    cleanup_legacy_installation
    install_backend_package
    migrate_legacy_configuration
    install_ui_packages
    install_selected_sing_box
    post_install

    msg "Forkop $FORKOP_PACKAGE_VERSION has been installed successfully"
    msg "Source release: ${REPO_OWNER}/${REPO_NAME}@${FORKOP_RELEASE_TAG}"
    warn "Open LuCI and review your rules before enabling Forkop"
}

main "$@"
