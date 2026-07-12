#!/bin/sh
# shellcheck shell=dash

REPO_OWNER="ushan0v"
REPO_NAME="forkop"

REQUIRED_SPACE_KB=15360

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

installer_config_migration_path() {
    helper_path="$TMP_DIR/config-migration.uc"

    if [ ! -s "$helper_path" ]; then
        cat > "$helper_path" <<'FORKOP_CONFIG_MIGRATION_EOF'
#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let constants_module = require("core.constants");
let singbox_constants_module = require("singbox.constants");
let domain_config = require("config.domain");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json = common.write_json;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let object_or_empty = common.object_or_empty;

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || "/tmp/sing-box/subscriptions";
const FORKOP_RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const FORKOP_SUBSCRIPTION_LINKS_DIR = getenv("FORKOP_SUBSCRIPTION_LINKS_DIR") || FORKOP_RUNTIME_STATE_DIR + "/subscription-links";
const FORKOP_SUBSCRIPTION_METADATA_DIR = getenv("FORKOP_SUBSCRIPTION_METADATA_DIR") || FORKOP_RUNTIME_STATE_DIR + "/subscription-metadata";
const FORKOP_OUTBOUND_METADATA_DIR = getenv("FORKOP_OUTBOUND_METADATA_DIR") || FORKOP_RUNTIME_STATE_DIR + "/outbound-metadata";
const FORKOP_SECTION_CACHE_DIR = getenv("FORKOP_SECTION_CACHE_DIR") || FORKOP_RUNTIME_STATE_DIR + "/section-cache";
const FORKOP_RUNTIME_CACHE_FORMAT_FILE = getenv("FORKOP_RUNTIME_CACHE_FORMAT_FILE") || FORKOP_RUNTIME_STATE_DIR + "/cache-format";
const FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/forkop/subscription-cache";
const FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD = getenv("FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD") || "/var/run/forkop.internal-config-change";
const FORKOP_RUNTIME_CACHE_FORMAT = getenv("FORKOP_RUNTIME_CACHE_FORMAT") || "7";
const SERVER_COUNTRY_METHOD_FLAG_EMOJI = "flag_emoji";
const SERVER_COUNTRY_METHOD_COUNTRY_IS = "country_is";
const CHILD_ITEM_TYPES = [
    "subscription_url",
    "urltest"
];

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return replace(as_string(data), /[\r\n]+$/g, "");
}

function run(command) {
    return system(command) == 0;
}

function constants_context() {
    let constants = object_or_empty(constants_module);
    return {
        zapret_legacy_default_nfqws_opt: as_string(constants.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT),
        zapret_default_nfqws_opt: as_string(constants.ZAPRET_DEFAULT_NFQWS_OPT),
        urltest_default_idle_timeout: as_string(object_or_empty(singbox_constants_module).URLTEST_DEFAULT_IDLE_TIMEOUT || "30m")
    };
}

function section_name(section) {
    return option(section, ".name", "");
}

function clone_section(section) {
    let result = {};
    for (let key in keys(object_or_empty(section)))
        result[key] = section[key];
    return result;
}

function fixture_section_list(data, type_name) {
    let value = object_or_empty(data)[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = object_or_empty(data)[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function model_from_fixture(path) {
    let data = object_or_empty(read_json_file(path));
    let model = {
        settings: clone_section(object_or_empty(data.settings)),
        rules: [],
        sections: []
    };
    for (let type_name in CHILD_ITEM_TYPES)
        model[type_name] = [];

    if (model.settings[".name"] == null)
        model.settings[".name"] = "settings";
    if (model.settings[".type"] == null)
        model.settings[".type"] = "settings";

    for (let section in fixture_section_list(data, "rule"))
        push(model.rules, clone_section(section));
    for (let section in fixture_section_list(data, "section"))
        push(model.sections, clone_section(section));
    for (let type_name in CHILD_ITEM_TYPES)
        for (let section in fixture_section_list(data, type_name))
            push(model[type_name], clone_section(section));

    return model;
}

function model_from_uci(cursor) {
    let model = {
        settings: clone_section(object_or_empty(cursor.get_all(CONFIG_NAME, "settings"))),
        rules: [],
        sections: []
    };
    for (let type_name in CHILD_ITEM_TYPES)
        model[type_name] = [];

    cursor.foreach(CONFIG_NAME, "rule", function(section) {
        push(model.rules, clone_section(section));
    });
    cursor.foreach(CONFIG_NAME, "section", function(section) {
        push(model.sections, clone_section(section));
    });
    for (let type_name in CHILD_ITEM_TYPES) {
        cursor.foreach(CONFIG_NAME, type_name, function(section) {
            push(model[type_name], clone_section(section));
        });
    }

    return model;
}

function export_model(model) {
    let result = {
        settings: model.settings,
        section: model.sections
    };
    if (length(model.rules) > 0)
        result.rule = model.rules;
    for (let type_name in CHILD_ITEM_TYPES)
        if (length(model[type_name] || []) > 0)
            result[type_name] = model[type_name];
    return result;
}

function migration_context(model) {
    return {
        model,
        operations: [],
        removed_caches: [],
        added_lists: {},
        changed: false
    };
}

function record_operation(ctx, op) {
    push(ctx.operations, op);
    ctx.changed = true;
}

function option_exists(section, key) {
    return object_or_empty(section)[key] != null;
}

function set_option(ctx, section, key, value) {
    value = as_string(value);
    if (option(section, key, "") == value && option_exists(section, key))
        return;

    section[key] = value;
    record_operation(ctx, { op: "set", section: section_name(section), option: key, value });
}

function set_option_if_missing(ctx, section, key, value) {
    if (option_exists(section, key))
        return;
    set_option(ctx, section, key, value);
}

function list_values_equal(left, right) {
    if (length(left) != length(right))
        return false;

    for (let i = 0; i < length(left); i++)
        if (as_string(left[i]) != as_string(right[i]))
            return false;

    return true;
}

function set_list_option(ctx, section, key, values) {
    let normalized = [];
    for (let value in values) {
        value = as_string(value);
        if (value != "")
            push(normalized, value);
    }

    let current = object_or_empty(section)[key];
    let current_values = [];
    if (type(current) == "array")
        current_values = current;
    else if (current != null && as_string(current) != "")
        current_values = [ as_string(current) ];

    if (option_exists(section, key) && list_values_equal(current_values, normalized))
        return;

    section[key] = normalized;
    record_operation(ctx, { op: "set_list", section: section_name(section), option: key, values: normalized });
}

function set_list_option_if_not_empty(ctx, section, key, values) {
    if (length(values || []) > 0)
        set_list_option(ctx, section, key, values);
}

function set_option_json(ctx, section, key, value) {
    set_option(ctx, section, key, sprintf("%J", value));
}

function delete_option(ctx, section, key) {
    if (!option_exists(section, key))
        return;

    delete section[key];
    record_operation(ctx, { op: "delete", section: section_name(section), option: key });
}

function list_contains(section, key, value) {
    value = as_string(value);
    for (let item in list_option(section, key))
        if (as_string(item) == value)
            return true;
    return false;
}

function add_list_unique(ctx, section, key, value) {
    value = as_string(value);
    if (value == "")
        return;

    let list_key = section_name(section) + "." + key + "=" + value;
    if (ctx.added_lists[list_key] || list_contains(section, key, value))
        return;

    let current = section[key];
    if (type(current) != "array")
        current = list_option(section, key);
    push(current, value);
    section[key] = current;
    ctx.added_lists[list_key] = true;
    record_operation(ctx, { op: "add_list", section: section_name(section), option: key, values: current });
}

function create_child_section(ctx, type_name) {
    ctx.child_index = int(ctx.child_index || 0) + 1;
    let item_id = "__" + type_name + "_" + ctx.child_index;
    let section = {
        ".name": item_id,
        ".type": type_name
    };
    if (ctx.model[type_name] == null)
        ctx.model[type_name] = [];
    push(ctx.model[type_name], section);
    record_operation(ctx, { op: "create", section: item_id, type: type_name, anonymous: true });
    return section;
}

function create_child_for_section(ctx, parent, type_name) {
    let child = create_child_section(ctx, type_name);
    set_option(ctx, child, "section", section_name(parent));
    return child;
}

function option_list_values(section, key) {
    let value = object_or_empty(section)[key];
    if (type(value) == "array")
        return value;
    if (value == null)
        return [];
    value = as_string(value);
    return value == "" ? [] : [ value ];
}

function whitespace_list_values(section, key) {
    let value = object_or_empty(section)[key];
    if (type(value) == "array")
        return value;
    return list_option(section, key);
}

function parse_json_object(value) {
    value = as_string(value);
    if (value == "")
        return {};

    try {
        value = json(value);
    }
    catch (e) {
        return {};
    }

    return object_or_empty(value);
}

function str_last_index(value, needle) {
    value = as_string(value);
    needle = as_string(needle);
    if (needle == "")
        return length(value);

    for (let i = length(value) - length(needle); i >= 0; i--)
        if (substr(value, i, length(needle)) == needle)
            return i;

    return -1;
}

function settings_entry(map, item) {
    item = as_string(item);
    let entry = object_or_empty(map[item]);
    map[item] = entry;
    return entry;
}

function settings_entry_set_if_missing(map, item, key, value) {
    let entry = settings_entry(map, item);
    if (entry[key] == null)
        entry[key] = as_string(value);
}

function settings_entry_set_value_if_missing(map, item, key, value) {
    let entry = settings_entry(map, item);
    if (entry[key] == null)
        entry[key] = value;
}

function settings_entry_set_bool_if_missing(map, item, key, value) {
    settings_entry_set_if_missing(map, item, key, value ? "1" : "0");
}

function settings_entry_set_list_if_not_empty(map, item, key, value) {
    value = option_list_values({ value }, "value");
    if (length(value) > 0)
        settings_entry_set_value_if_missing(map, item, key, value);
}

function settings_entry_move_if_needed(map, from_item, to_item) {
    from_item = as_string(from_item);
    to_item = as_string(to_item);
    if (from_item == "" || to_item == "" || from_item == to_item || map[from_item] == null)
        return;

    let from_entry = object_or_empty(map[from_item]);
    let to_entry = settings_entry(map, to_item);
    for (let key in keys(from_entry))
        if (to_entry[key] == null)
            to_entry[key] = from_entry[key];

    delete map[from_item];
}

function subscription_url_entry_profile(value) {
    let entry = trim(as_string(value));
    let result = {
        raw: entry,
        value: entry,
        user_agent: "",
        changed: false
    };
    let delimiter = " | ";
    let delimiter_index = str_last_index(entry, delimiter);

    if (delimiter_index < 0)
        return result;

    let url = trim(substr(entry, 0, delimiter_index));
    let user_agent = trim(substr(entry, delimiter_index + length(delimiter)));
    if (url == "" || user_agent == "")
        return result;

    result.value = url;
    result.user_agent = user_agent;
    result.changed = true;
    return result;
}

function normalize_connections_list(ctx, section, old_key, new_key) {
    let old_values = option_list_values(section, old_key);

    for (let value in old_values)
        add_list_unique(ctx, section, new_key, value);

    if (length(old_values) > 0)
        delete_option(ctx, section, old_key);
}

function set_section_type(ctx, section, type_name) {
    if (option(section, ".type", "") == type_name)
        return;

    section[".type"] = type_name;
    record_operation(ctx, { op: "set_type", section: section_name(section), type: type_name });
}

function normalize_detect_server_country_method(value) {
    value = as_string(value);
    if (value == SERVER_COUNTRY_METHOD_COUNTRY_IS)
        return SERVER_COUNTRY_METHOD_COUNTRY_IS;
    return SERVER_COUNTRY_METHOD_FLAG_EMOJI;
}

function urltest_filter_mode_filters_enabled(value) {
    return value == "exclude" || value == "include" || value == "mixed";
}

function duration_to_seconds_value(value) {
    let rest = as_string(value);
    if (rest == "")
        return null;

    let total = 0.0;
    let multipliers = {
        ns: 0.000000001,
        us: 0.000001,
        ms: 0.001,
        s: 1,
        m: 60,
        h: 3600,
        d: 86400
    };

    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return null;

        let token = as_string(matched[0]);
        let amount = matched[1] * 1;
        let unit = matched[3];
        total += amount * multipliers[unit];
        rest = substr(rest, length(token));
    }

    return total <= 0 ? null : int(total + 0.5);
}

function legacy_urltest_idle_timeout(section, constants) {
    let interval = option(section, "urltest_check_interval", "3m") || "3m";
    let interval_seconds = duration_to_seconds_value(interval);
    let default_idle_seconds = duration_to_seconds_value(object_or_empty(constants).urltest_default_idle_timeout || "30m");
    return interval_seconds != null && default_idle_seconds != null && interval_seconds > default_idle_seconds
        ? interval
        : "";
}

const LEGACY_URLTEST_OPTIONS = [
    "urltest_enabled",
    "urltest_check_interval",
    "urltest_tolerance",
    "urltest_testing_url",
    "urltest_filter_mode",
    "urltest_hide_filtered_outbounds",
    "detect_server_country",
    "urltest_include_countries",
    "urltest_include_outbounds",
    "urltest_include_regex",
    "urltest_exclude_countries",
    "urltest_exclude_outbounds",
    "urltest_exclude_regex"
];

function delete_legacy_urltest_options(ctx, section) {
    for (let key in LEGACY_URLTEST_OPTIONS)
        delete_option(ctx, section, key);
}

function migrate_urltest_filter_mode(ctx, section) {
    if (option_exists(section, "urltest_filter_mode"))
        return;

    if (option_exists(section, "urltest_exclude_countries") ||
        option_exists(section, "urltest_include_countries") ||
        option_exists(section, "urltest_exclude_outbounds") ||
        option_exists(section, "urltest_exclude_regex")) {
        set_option(ctx, section, "urltest_filter_mode", "exclude");
    }
}

function migrate_detect_server_country(ctx, section) {
    if (!option_exists(section, "detect_server_country"))
        return;

    let value = option(section, "detect_server_country", "");
    if (value != "0" && value != "1")
        return;

    if (bool_option(section, "urltest_enabled", false) &&
        urltest_filter_mode_filters_enabled(option(section, "urltest_filter_mode", "disabled"))) {
        set_option(ctx, section, "detect_server_country", normalize_detect_server_country_method(value));
    }
    else {
        delete_option(ctx, section, "detect_server_country");
    }
}

function trim_lines(value) {
    let result = [];
    for (let line in split(as_string(value), "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        if (line != "")
            push(result, line);
    }
    return result;
}

function migrate_urltest_link(ctx, section, link) {
    add_list_unique(ctx, section, "selector_proxy_links", link);
}

function migrate_proxy_string(ctx, section) {
    let proxy_string = option(section, "proxy_string", "");
    if (proxy_string == "")
        return;

    let migrated = false;
    for (let link in trim_lines(proxy_string)) {
        if (substr(link, 0, 2) == "//")
            continue;
        add_list_unique(ctx, section, "selector_proxy_links", link);
        migrated = true;
    }

    if (migrated)
        delete_option(ctx, section, "proxy_string");
}

function cache_section_safe(section) {
    section = as_string(section);
    return section != "" && index(section, "/") < 0 && index(section, "..") < 0;
}

function subscription_cache_paths(section) {
    return [
        TMP_SUBSCRIPTION_FOLDER + "/" + section + ".json",
        TMP_SUBSCRIPTION_FOLDER + "/" + section + ".url",
        TMP_SUBSCRIPTION_FOLDER + "/" + section + ".user_agent",
        FORKOP_SUBSCRIPTION_METADATA_DIR + "/" + section + ".json",
        FORKOP_SUBSCRIPTION_LINKS_DIR + "/" + section + ".json",
        FORKOP_OUTBOUND_METADATA_DIR + "/" + section + ".json",
        FORKOP_SECTION_CACHE_DIR + "/" + section + ".json",
        TMP_SUBSCRIPTION_FOLDER + "/" + section + "-subscription-*.json",
        TMP_SUBSCRIPTION_FOLDER + "/" + section + "-subscription-*.url",
        TMP_SUBSCRIPTION_FOLDER + "/" + section + "-subscription-*.user_agent"
    ];
}

function delete_subscription_cache(ctx, section) {
    section = as_string(section);
    if (!cache_section_safe(section))
        return;

    for (let path in subscription_cache_paths(section))
        push(ctx.removed_caches, path);
}

function migrate_subscription_url(ctx, section) {
    let subscription_url = option(section, "subscription_url", "");
    if (subscription_url == "")
        return;

    let subscription_user_agent = option(section, "subscription_user_agent", "");
    let entry = subscription_user_agent != ""
        ? subscription_url + " | " + subscription_user_agent
        : subscription_url;
    add_list_unique(ctx, section, "subscription_urls", entry);
    delete_option(ctx, section, "subscription_url");
    delete_option(ctx, section, "subscription_user_agent");
    delete_subscription_cache(ctx, section_name(section));
}

function migrate_interval_flags(ctx, section, proxy_config_type) {
    if (proxy_config_type == "urltest" || proxy_config_type == "subscription") {
        if (option(section, "urltest_check_interval_disabled", "") == "1")
            set_option(ctx, section, "urltest_enabled", "0");
        else
            set_option_if_missing(ctx, section, "urltest_enabled", "1");
    }
    else if (proxy_config_type == "url" || proxy_config_type == "selector") {
        set_option_if_missing(ctx, section, "urltest_enabled", "0");
    }

    if (proxy_config_type == "subscription") {
        if (option(section, "subscription_update_interval_disabled", "") == "1")
            set_option(ctx, section, "subscription_update_enabled", "0");
        else
            set_option_if_missing(ctx, section, "subscription_update_enabled", "1");
    }

    delete_option(ctx, section, "urltest_check_interval_disabled");
    delete_option(ctx, section, "subscription_update_interval_disabled");
}

function migrate_proxy_rule(ctx, section, proxy_config_type) {
    if (proxy_config_type == "url")
        migrate_proxy_string(ctx, section);
    else if (proxy_config_type == "urltest") {
        for (let link in list_option(section, "urltest_proxy_links"))
            migrate_urltest_link(ctx, section, link);
        delete_option(ctx, section, "urltest_proxy_links");
    }
    else if (proxy_config_type == "subscription") {
        migrate_subscription_url(ctx, section);
        delete_subscription_cache(ctx, section_name(section));
    }

    migrate_interval_flags(ctx, section, proxy_config_type);
    delete_option(ctx, section, "proxy_config_type");
}

function migrated_rule_action(section) {
    let action = option(section, "action", "");
    let proxy_config_type = option(section, "proxy_config_type", "");
    let connection_type = option(section, "connection_type", "");
    let iface = option(section, "interface", "");
    let outbound_json = option(section, "outbound_json", "");
    let selector_proxy_links = option(section, "selector_proxy_links", "");
    let subscription_urls = option(section, "subscription_urls", "");

    if (action == "proxy" || action == "vpn" || action == "outbound")
        return "connection";

    if (action == "direct")
        return "bypass";

    if (action != "")
        return action;

    if (connection_type == "proxy")
        return "connection";
    if (connection_type == "vpn")
        return "connection";
    if (connection_type == "block")
        return "block";
    if (connection_type == "exclusion")
        return "bypass";

    if (proxy_config_type == "interface")
        return "connection";
    if (proxy_config_type == "outbound")
        return "connection";
    if (proxy_config_type == "url" || proxy_config_type == "selector" ||
        proxy_config_type == "urltest" || proxy_config_type == "subscription")
        return "connection";

    if (outbound_json != "")
        return "connection";
    if (iface != "")
        return "connection";
    if (selector_proxy_links != "" || subscription_urls != "")
        return "connection";

    return "";
}

function legacy_rule_connection_kind(section) {
    let action = option(section, "action", "");
    let proxy_config_type = option(section, "proxy_config_type", "");
    let connection_type = option(section, "connection_type", "");

    if (action == "vpn" || connection_type == "vpn" || proxy_config_type == "interface")
        return "interface";
    if (action == "outbound" || proxy_config_type == "outbound")
        return "outbound";
    if (action == "proxy" || connection_type == "proxy" ||
        proxy_config_type == "url" || proxy_config_type == "selector" ||
        proxy_config_type == "urltest" || proxy_config_type == "subscription")
        return "proxy";
    if (option(section, "interface", "") != "")
        return "interface";
    if (option(section, "outbound_json", "") != "")
        return "outbound";
    return "proxy";
}

function migrate_byedpi_cmd_opts(ctx, section) {
    let cmd_opts = option(section, "cmd_opts", "");
    if (cmd_opts == "")
        return;

    if (option(section, "byedpi_cmd_opts", "") == "")
        set_option(ctx, section, "byedpi_cmd_opts", cmd_opts);
    delete_option(ctx, section, "cmd_opts");
}

function migrate_zapret_nfqws_default(ctx, section, constants) {
    if (migrated_rule_action(section) != "zapret")
        return;

    let nfqws_opt = option(section, "nfqws_opt", "");
    if (nfqws_opt == "" || nfqws_opt != constants.zapret_legacy_default_nfqws_opt)
        return;

    set_option(ctx, section, "nfqws_opt", constants.zapret_default_nfqws_opt);
}

function migrate_subscription_url_item_settings(ctx, section) {
    let values = whitespace_list_values(section, "subscription_urls");
    let seen_values = {};
    let update_enabled = bool_option(section, "subscription_update_enabled", true);
    let update_interval = option(section, "subscription_update_interval", "");
    if (update_interval == "")
        update_interval = "1h";
    let index = 1;

    for (let value in values) {
        let profile = subscription_url_entry_profile(value);
        if (profile.value == "")
            continue;
        if (seen_values[profile.value])
            continue;
        seen_values[profile.value] = true;

        let child = create_child_for_section(ctx, section, "subscription_url");
        set_option(ctx, child, "url", profile.value);
        set_option(ctx, child, "subscription_update_enabled", update_enabled ? "1" : "0");
        set_option(ctx, child, "subscription_update_interval", update_enabled ? update_interval : "");
        set_option(ctx, child, "auto_user_agent", profile.user_agent != "" ? "0" : "1");
        if (profile.user_agent != "")
            set_option(ctx, child, "user_agent", profile.user_agent);
        set_option(ctx, child, "auto_hwid", "1");
        set_option(ctx, child, "show_dashboard_metadata", "1");
        set_option(ctx, child, "prefix_nodes", "0");
        set_option(ctx, child, "include_urltest_groups", "1");
        set_option(ctx, child, "hide_urltest_group_outbounds", "1");
        set_option(ctx, child, "hide_detour_outbounds", "1");
        index++;
    }

    delete_option(ctx, section, "subscription_urls");
    delete_option(ctx, section, "subscription_url_settings");
}

function migrate_urltest_item_settings(ctx, section, constants) {
    let legacy_enabled = bool_option(section, "urltest_enabled", false);

    if (legacy_enabled) {
        let child = create_child_for_section(ctx, section, "urltest");
        set_option(ctx, child, "name", "Fastest");
        set_option(ctx, child, "check_interval", option(section, "urltest_check_interval", "3m") || "3m");
        set_option(ctx, child, "tolerance", option(section, "urltest_tolerance", "50") || "50");
        set_option(ctx, child, "testing_url", option(section, "urltest_testing_url", "https://www.gstatic.com/generate_204") || "https://www.gstatic.com/generate_204");
        set_option(ctx, child, "filter_mode", option(section, "urltest_filter_mode", "disabled") || "disabled");
        set_option(ctx, child, "detect_server_country", normalize_detect_server_country_method(option(section, "detect_server_country", SERVER_COUNTRY_METHOD_FLAG_EMOJI)));
        set_option(ctx, child, "interrupt_exist_connections", "1");
        set_option(ctx, child, "pin_dashboard", "1");

        let idle_timeout = legacy_urltest_idle_timeout(section, constants);
        if (idle_timeout != "")
            set_option(ctx, child, "idle_timeout", idle_timeout);

        set_list_option_if_not_empty(ctx, child, "include_countries", option_list_values(section, "urltest_include_countries"));
        set_list_option_if_not_empty(ctx, child, "include_outbounds", option_list_values(section, "urltest_include_outbounds"));
        set_list_option_if_not_empty(ctx, child, "include_regex", option_list_values(section, "urltest_include_regex"));
        set_list_option_if_not_empty(ctx, child, "exclude_countries", option_list_values(section, "urltest_exclude_countries"));
        set_list_option_if_not_empty(ctx, child, "exclude_outbounds", option_list_values(section, "urltest_exclude_outbounds"));
        set_list_option_if_not_empty(ctx, child, "exclude_regex", option_list_values(section, "urltest_exclude_regex"));
    }

    delete_legacy_urltest_options(ctx, section);
    delete_option(ctx, section, "urltest_settings");
}

function migrate_interface_list(ctx, section) {
    normalize_connections_list(ctx, section, "interface", "interfaces");
}

function migrate_legacy_outbound_json_detour(ctx, section, legacy_connection_kind) {
    if (legacy_connection_kind != "outbound" ||
        !bool_option(section, "outbound_detour_enabled", false))
        return;

    let detour_section = option(section, "outbound_detour_section", "");
    let outbound_json = option(section, "outbound_json", "");
    if (detour_section == "" || outbound_json == "")
        return;

    let outbound;
    try {
        outbound = json(outbound_json);
    }
    catch (e) {
        return;
    }
    if (type(outbound) != "object")
        return;

    if (as_string(outbound.detour || "") == "")
        outbound.detour = singbox_constants_module.outbound_tag(detour_section);
    set_option(ctx, section, "outbound_json", sprintf("%J", outbound));
    delete_option(ctx, section, "outbound_detour_enabled");
    delete_option(ctx, section, "outbound_detour_section");
}

function migrate_outbound_json_list(ctx, section, legacy_connection_kind) {
    migrate_legacy_outbound_json_detour(ctx, section, legacy_connection_kind);
    normalize_connections_list(ctx, section, "outbound_json", "outbound_jsons");
}

function migrate_connection_section(ctx, section, constants, legacy_connection_kind) {
    migrate_subscription_url_item_settings(ctx, section);
    migrate_urltest_item_settings(ctx, section, constants);
    migrate_interface_list(ctx, section);
    migrate_outbound_json_list(ctx, section, legacy_connection_kind);

    delete_option(ctx, section, "subscription_update_enabled");
    delete_option(ctx, section, "subscription_update_interval");
    delete_option(ctx, section, "enable_udp_over_tcp");
    delete_option(ctx, section, "domain_resolver_enabled");
    delete_option(ctx, section, "domain_resolver_dns_type");
    delete_option(ctx, section, "domain_resolver_dns_server");
}

function strip_list_comment(line) {
    line = replace(as_string(line), /[[:space:]]*\/\/.*$/, "");
    return replace(line, /[[:space:]]*#.*$/, "");
}

function text_list_values(value, separator_mode) {
    let result = [];
    separator_mode = as_string(separator_mode);

    for (let line in split(as_string(value), "\n")) {
        line = strip_list_comment(line);
        line = separator_mode == "comma-space"
            ? replace(line, /[ ,]/g, "\n")
            : replace(line, /,/g, "\n");

        for (let item in split(line, "\n")) {
            item = trim(replace(item, /\r/g, ""));
            if (item != "")
                push(result, item);
        }
    }

    return result;
}

function filter_domain_values(values) {
    let result = [];
    for (let value in values) {
        let normalized = domain_config.suffix_to_ascii(value);
        if (normalized != null)
            push(result, normalized);
    }
    return result;
}

function generic_values_from_text(value) {
    return text_list_values(value, "comma");
}

function legacy_condition_values(kind, text_mode, conditions_text_mode, text_value, list_value) {
    if (int(text_mode || 0) == 1 || int(conditions_text_mode || 0) == 1)
        return kind == "domains"
            ? filter_domain_values(text_list_values(text_value, "comma-space"))
            : generic_values_from_text(text_value);

    let result = [];
    for (let item in list_option({ value: list_value }, "value"))
        push(result, item);
    if (length(result) > 0)
        return result;

    if (as_string(text_value) != "")
        return kind == "domains"
            ? filter_domain_values(text_list_values(text_value, "comma-space"))
            : generic_values_from_text(text_value);

    return [];
}

function add_unique_value(result, seen, value) {
    value = as_string(value);
    if (value == "" || seen[value])
        return;

    seen[value] = true;
    push(result, value);
}

function has_domain_condition_prefix(value) {
    let colon = index(value, ":");
    if (colon <= 0)
        return false;

    let prefix = domain_config.ascii_lower(substr(value, 0, colon));
    return prefix == "full" || prefix == "keyword" || prefix == "regex";
}

function add_values_with_prefix(result, seen, values, prefix) {
    for (let value in values) {
        value = trim(as_string(value));
        add_unique_value(result, seen, has_domain_condition_prefix(value) ? value : prefix + value);
    }
}

function legacy_values_for_option(section, option_name, kind) {
    return legacy_condition_values(
        kind,
        option(section, option_name + "_text_mode", "0"),
        option(section, "conditions_text_mode", "0"),
        option(section, option_name + "_text", ""),
        section[option_name]
    );
}

function raw_text_condition_values(section, option_name) {
    return text_list_values(option(section, option_name, ""), "comma-space");
}

function add_domain_values_with_prefix(result, seen, section, option_name, prefix, kind) {
    let values = legacy_condition_values(
        kind,
        option(section, option_name + "_text_mode", "0"),
        option(section, "conditions_text_mode", "0"),
        option(section, option_name + "_text", ""),
        section[option_name]
    );

    add_values_with_prefix(result, seen, values, prefix);
}

function migrate_combined_domain_conditions(ctx, section) {
    let values = [];
    let seen = {};

    for (let value in list_option(section, "domain_suffix"))
        add_unique_value(values, seen, value);
    for (let value in raw_text_condition_values(section, "domain_suffix_text"))
        add_unique_value(values, seen, value);

    add_domain_values_with_prefix(values, seen, section, "domain", "full:", "domains");
    add_domain_values_with_prefix(values, seen, section, "domain_keyword", "keyword:", "generic");
    add_domain_values_with_prefix(values, seen, section, "domain_regex", "regex:", "generic");

    if (length(values) > 0)
        set_option(ctx, section, "domain", join("\n", values));
    else
        delete_option(ctx, section, "domain");

    delete_option(ctx, section, "domain_suffix");
    delete_option(ctx, section, "domain_suffix_text");
    delete_option(ctx, section, "domain_suffix_text_mode");
    delete_option(ctx, section, "domain_keyword");
    delete_option(ctx, section, "domain_regex");
    delete_option(ctx, section, "domain_text");
    delete_option(ctx, section, "domain_keyword_text");
    delete_option(ctx, section, "domain_regex_text");
    delete_option(ctx, section, "domain_text_mode");
    delete_option(ctx, section, "domain_keyword_text_mode");
    delete_option(ctx, section, "domain_regex_text_mode");
}

function migrate_text_condition(ctx, section, option_name, kind) {
    let values = legacy_values_for_option(section, option_name, kind);
    if (length(values) > 0)
        set_option(ctx, section, option_name, join("\n", values));
    else if (option_exists(section, option_name) && type(section[option_name]) == "array")
        delete_option(ctx, section, option_name);

    delete_option(ctx, section, option_name + "_text");
    delete_option(ctx, section, option_name + "_text_mode");
}

function migrate_rule(ctx, section, converted_from_rule, constants) {
    let action = migrated_rule_action(section);
    let legacy_connection_kind = legacy_rule_connection_kind(section);
    let proxy_config_type = option(section, "proxy_config_type", "");
    let subscription_urls = option(section, "subscription_urls", "");

    if (action != "")
        set_option(ctx, section, "action", action);

    delete_option(ctx, section, "connection_type");
    delete_option(ctx, section, "subscription_group_by_countries");
    delete_option(ctx, section, "group_by_countries");
    delete_option(ctx, section, "subscription_detect_server_countries");

    if (action == "connection") {
        migrate_urltest_filter_mode(ctx, section);
        migrate_detect_server_country(ctx, section);
        if (legacy_connection_kind == "proxy")
            migrate_proxy_rule(ctx, section, proxy_config_type);
        else {
            delete_option(ctx, section, "proxy_config_type");
            delete_option(ctx, section, "proxy_string");
            delete_option(ctx, section, "urltest_proxy_links");
            delete_option(ctx, section, "subscription_url");
            delete_option(ctx, section, "subscription_user_agent");
            delete_option(ctx, section, "urltest_check_interval_disabled");
            delete_option(ctx, section, "subscription_update_interval_disabled");
        }
        migrate_connection_section(ctx, section, constants, legacy_connection_kind);
        if (converted_from_rule && subscription_urls != "")
            delete_subscription_cache(ctx, section_name(section));
    }
    else if (action == "block" ||
        action == "bypass" || action == "zapret" || action == "zapret2" || action == "byedpi") {
        delete_option(ctx, section, "proxy_config_type");
        delete_option(ctx, section, "proxy_string");
        delete_option(ctx, section, "urltest_proxy_links");
        delete_option(ctx, section, "subscription_url");
        delete_option(ctx, section, "subscription_user_agent");
        delete_option(ctx, section, "urltest_check_interval_disabled");
        delete_option(ctx, section, "subscription_update_interval_disabled");
    }

    if (action != "connection")
        delete_legacy_urltest_options(ctx, section);

    migrate_byedpi_cmd_opts(ctx, section);
    migrate_zapret_nfqws_default(ctx, section, constants);
}

function migrate_rule_section(ctx, section, constants) {
    set_section_type(ctx, section, "section");
    migrate_rule(ctx, section, true, constants);
    migrate_combined_domain_conditions(ctx, section);
    migrate_text_condition(ctx, section, "ip_cidr", "subnets");
}

function migrate_list_update_enabled(ctx) {
    let settings = ctx.model.settings;
    if (option_exists(settings, "list_update_enabled")) {
        if (bool_option(settings, "list_update_enabled", true) &&
            option(settings, "update_interval", "") == "") {
            set_option(ctx, settings, "update_interval", "1d");
        }
        return;
    }

    if (option(settings, "update_interval", "") != "") {
        set_option(ctx, settings, "list_update_enabled", "1");
    }
    else {
        set_option(ctx, settings, "list_update_enabled", "0");
        set_option(ctx, settings, "update_interval", "1d");
    }
}

function normalize_existing_list_option(ctx, section, key) {
    let current = object_or_empty(section)[key];
    if (current == null || type(current) == "array")
        return;

    let value = trim(as_string(current));
    let values = value == "" ? [] : [ value ];
    section[key] = values;
    record_operation(ctx, { op: "set_list", section: section_name(section), option: key, values });
}

function migrate_dns_server_lists(ctx) {
    normalize_existing_list_option(ctx, ctx.model.settings, "dns_server");
    normalize_existing_list_option(ctx, ctx.model.settings, "bootstrap_dns_server");
}

function migrate_download_via_proxy_flags(ctx) {
    let settings = ctx.model.settings;
    let legacy_section = option(settings, "download_lists_via_proxy_section", "");
    let lists_enabled = bool_option(settings, "download_lists_via_proxy", false);
    let components_enabled = option_exists(settings, "download_components_via_proxy")
        ? bool_option(settings, "download_components_via_proxy", false)
        : lists_enabled;

    set_option(ctx, settings, "download_lists_via_proxy", lists_enabled ? "1" : "0");
    if (!lists_enabled)
        delete_option(ctx, settings, "download_lists_via_proxy_section");

    set_option(ctx, settings, "download_components_via_proxy", components_enabled ? "1" : "0");
    if (components_enabled) {
        if (option(settings, "download_components_via_proxy_section", "") == "" && legacy_section != "")
            set_option(ctx, settings, "download_components_via_proxy_section", legacy_section);
    }
    else {
        delete_option(ctx, settings, "download_components_via_proxy_section");
    }
}

function migrate_subscription_download_via_proxy_settings(ctx) {
    let settings_section = ctx.model.settings;
    let enabled = bool_option(settings_section, "download_subscriptions_via_proxy", false);
    let target_section = option(settings_section, "download_lists_via_proxy_section", "");

    if (enabled && target_section != "") {
        for (let child in ctx.model.subscription_url || []) {
            let name = option(child, "section", "");
            if (name == "" || name == target_section)
                continue;
            set_option(ctx, child, "download_via_proxy_enabled", "1");
            set_option(ctx, child, "download_via_proxy_section", target_section);
        }
    }

    delete_option(ctx, settings_section, "download_subscriptions_via_proxy");
}

function migrate_rule_set_settings(ctx, section) {
    let normalize_list = function(key) {
        let seen = {};
        let result = [];
        for (let reference in option_list_values(section, key)) {
            reference = as_string(reference);
            if (reference == "" || seen[reference])
                continue;
            seen[reference] = true;
            push(result, reference);
        }
        if (length(result) > 0)
            set_list_option(ctx, section, key, result);
        else
            delete_option(ctx, section, key);
    };

    normalize_list("community_lists");
    normalize_list("rule_set");
    normalize_list("rule_set_with_subnets");
    delete_option(ctx, section, "rule_set_settings");
}

function migrate_model(model, constants) {
    let ctx = migration_context(model);
    constants = object_or_empty(constants);

    delete_option(ctx, model.settings, "routing_excluded_ips");
    migrate_dns_server_lists(ctx);
    migrate_list_update_enabled(ctx);

    let converted_sections = [];
    for (let section in model.rules) {
        migrate_rule_section(ctx, section, constants);
        push(converted_sections, section);
    }
    model.rules = [];

    for (let section in model.sections) {
        migrate_rule(ctx, section, false, constants);
        migrate_combined_domain_conditions(ctx, section);
        migrate_text_condition(ctx, section, "ip_cidr", "subnets");
        migrate_rule_set_settings(ctx, section);
    }
    for (let section in converted_sections) {
        migrate_rule_set_settings(ctx, section);
        push(model.sections, section);
    }
    migrate_subscription_download_via_proxy_settings(ctx);
    migrate_download_via_proxy_flags(ctx);

    return ctx;
}

function first_line(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return "";
    let newline = index(data, "\n");
    return newline >= 0 ? substr(data, 0, newline) : data;
}

function ensure_dir(path) {
    run("mkdir -p " + shell_quote(path) + " >/dev/null 2>&1");
}

function clear_subscription_runtime_cache() {
    run("rm -rf " +
        shell_quote(TMP_SUBSCRIPTION_FOLDER) + " " +
        shell_quote(FORKOP_SUBSCRIPTION_LINKS_DIR) + " " +
        shell_quote(FORKOP_SUBSCRIPTION_METADATA_DIR) + " " +
        shell_quote(FORKOP_OUTBOUND_METADATA_DIR) + " " +
        shell_quote(FORKOP_SECTION_CACHE_DIR));
}

function ensure_runtime_dirs() {
    ensure_dir(TMP_SUBSCRIPTION_FOLDER);
    ensure_dir(FORKOP_RUNTIME_STATE_DIR);
    ensure_dir(FORKOP_SUBSCRIPTION_LINKS_DIR);
    ensure_dir(FORKOP_SUBSCRIPTION_METADATA_DIR);
    ensure_dir(FORKOP_OUTBOUND_METADATA_DIR);
    ensure_dir(FORKOP_SECTION_CACHE_DIR);
}

function ensure_runtime_cache_format() {
    ensure_dir(FORKOP_RUNTIME_STATE_DIR);

    if (first_line(FORKOP_RUNTIME_CACHE_FORMAT_FILE) != FORKOP_RUNTIME_CACHE_FORMAT) {
        clear_subscription_runtime_cache();
        ensure_runtime_dirs();
        fs.writefile(FORKOP_RUNTIME_CACHE_FORMAT_FILE, FORKOP_RUNTIME_CACHE_FORMAT + "\n");
    }

    if (first_line(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) != FORKOP_RUNTIME_CACHE_FORMAT) {
        run("rm -rf " + shell_quote(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR));
        ensure_dir(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        run("chmod 700 " + shell_quote(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR) + " >/dev/null 2>&1");
        fs.writefile(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE, FORKOP_RUNTIME_CACHE_FORMAT + "\n");
        run("chmod 600 " + shell_quote(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) + " >/dev/null 2>&1");
    }
}

function remove_legacy_server_country_cache() {
    fs.unlink(FORKOP_RUNTIME_STATE_DIR + "/server-country-cache.json");
}

function remove_cache_path(path) {
    path = as_string(path);
    if (index(path, "*") >= 0)
        run("rm -f " + path);
    else
        fs.unlink(path);
}

function apply_operations(cursor, operations) {
    let created = {};
    let section_ref = function(name) {
        name = as_string(name);
        return as_string(created[name] || name);
    };

    for (let op in operations) {
        if (op.op == "create") {
            if (op.anonymous && type(cursor.add) == "function")
                created[as_string(op.section)] = cursor.add(CONFIG_NAME, op.type);
            else
                cursor.set(CONFIG_NAME, op.section, op.type);
        }
        else if (op.op == "set")
            cursor.set(CONFIG_NAME, section_ref(op.section), op.option, op.value);
        else if (op.op == "delete")
            cursor.delete(CONFIG_NAME, section_ref(op.section), op.option);
        else if (op.op == "add_list")
            cursor.set(CONFIG_NAME, section_ref(op.section), op.option, op.values);
        else if (op.op == "set_list")
            cursor.set(CONFIG_NAME, section_ref(op.section), op.option, op.values);
        else if (op.op == "set_type")
            cursor.set(CONFIG_NAME, section_ref(op.section), op.type);
    }
}

function runtime_cursor() {
    return {
        load: function(package_name) {
            return uci_core.load(package_name);
        },
        get_all: function(package_name, section_name) {
            return uci_core.get_all(package_name, section_name);
        },
        foreach: function(package_name, type_name, callback) {
            for (let section in uci_core.section_objects(package_name, type_name))
                callback(section);
        },
        add: function(package_name, type_name) {
            return uci_core.add(package_name, type_name);
        },
        set: function(package_name, section_name, option_name, value) {
            if (value == null)
                return uci_core.set_section(package_name + "." + section_name, option_name);
            return uci_core.set(package_name + "." + section_name + "." + option_name, value);
        },
        delete: function(package_name, section_name, option_name) {
            return uci_core.delete(package_name + "." + section_name + "." + option_name);
        },
        commit: function(package_name) {
            return uci_core.commit(package_name);
        }
    };
}

function current_config_hash() {
    let config_path = "/etc/config/" + CONFIG_NAME;
    if (fs.stat(config_path) == null)
        return "";

    let output = command_output("md5sum " + shell_quote(config_path) + " 2>/dev/null");
    let fields = split(trim(output), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function mark_internal_config_guard() {
    let hash = current_config_hash();
    if (hash == "") {
        fs.unlink(FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD);
        return;
    }

    let stamp = clock();
    let tmp_path = FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD + "." + stamp[0] + "." + stamp[1];
    fs.writefile(tmp_path, as_string(stamp[0]) + "\n" + hash + "\n");
    if (!fs.rename(tmp_path, FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD))
        fs.unlink(tmp_path);
}

function commit_cursor(cursor) {
    if (!cursor.commit(CONFIG_NAME))
        return false;
    mark_internal_config_guard();
    return true;
}

function migrate_runtime() {
    ensure_runtime_cache_format();
    remove_legacy_server_country_cache();

    let cursor = runtime_cursor();
    cursor.load(CONFIG_NAME);
    let ctx = migrate_model(model_from_uci(cursor), constants_context());
    if (!ctx.changed)
        return true;

    apply_operations(cursor, ctx.operations);
    for (let path in ctx.removed_caches)
        remove_cache_path(path);

    return commit_cursor(cursor);
}

function commit_runtime() {
    let cursor = runtime_cursor();
    cursor.load(CONFIG_NAME);
    return commit_cursor(cursor);
}

function migrate_fixture(path) {
    let ctx = migrate_model(model_from_fixture(path), constants_context());
    write_json({
        changed: ctx.changed,
        config: export_model(ctx.model),
        operations: ctx.operations,
        removed_caches: ctx.removed_caches
    });
}

function module_exports() {
    return {
        migrate_model,
        mark_internal_config_guard
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

let mode = ARGV[0] || "";

if (mode == "migrate")
    exit(migrate_runtime() ? 0 : 1);
else if (mode == "commit")
    exit(commit_runtime() ? 0 : 1);
else if (mode == "migrate-fixture")
    migrate_fixture(ARGV[1]);
else {
    warn("Usage: config/migration.uc migrate\n");
    warn("       config/migration.uc commit\n");
    warn("       config/migration.uc migrate-fixture <fixture.json>\n");
    exit(1);
}
FORKOP_CONFIG_MIGRATION_EOF
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
            ucode -L /usr/lib/forkop "$(installer_config_migration_path)" migrate; then
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
