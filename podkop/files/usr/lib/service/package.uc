#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

const CONFIG_NAME = env("PODKOP_CONFIG_NAME", "podkop-plus");
const CONFIG_PATH = env("PODKOP_CONFIG", "/etc/config/" + CONFIG_NAME);
const LEGACY_CONFIG_PATH = env("PODKOP_LEGACY_CONFIG", "/etc/config/podkop_plus");
const RT_TABLES_PATH = env("PODKOP_RT_TABLES", "/etc/iproute2/rt_tables");
const BIN_PATH = env("PODKOP_BIN", "/usr/bin/podkop-plus");
const DNS_APPLY_UC = env("PODKOP_DNS_APPLY_UC", "/usr/lib/podkop-plus/dns/apply.uc");
const SING_BOX_INIT = env("PODKOP_SING_BOX_INIT", "/etc/init.d/sing-box");
const SING_BOX_BIN = env("PODKOP_SING_BOX_BIN", "/usr/bin/sing-box");
const SING_BOX_CRONET = env("PODKOP_SING_BOX_CRONET", "/usr/lib/libcronet.so");
const SING_BOX_MANAGED_MARKER = env("SB_MANAGED_SERVICE_MARKER", "Podkop Plus managed sing-box service for binary variants");
const PACKAGE_TEST_MODE = env("PODKOP_PACKAGE_TEST_MODE", "") != "";

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

function command_success_from_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

function path_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function unlink_if_exists(path) {
    if (path_exists(path))
        fs.unlink(as_string(path));
}

function copy_legacy_config_if_needed() {
    if (env("IPKG_INSTROOT", "") != "")
        return true;
    if (path_exists(CONFIG_PATH) || !path_exists(LEGACY_CONFIG_PATH))
        return true;

    let data = fs.readfile(LEGACY_CONFIG_PATH);
    if (data == null || fs.writefile(CONFIG_PATH, data) == null)
        return false;

    command_success_from_args([ "chmod", "0644", CONFIG_PATH ]);
    return true;
}

function remove_rt_tables_entry() {
    let data = fs.readfile(RT_TABLES_PATH);
    if (data == null)
        return true;

    let changed = false;
    let lines = [];
    for (let line in split(data, "\n")) {
        if (index(line, "105 podkopplus") >= 0) {
            changed = true;
            continue;
        }
        push(lines, line);
    }

    return !changed || fs.writefile(RT_TABLES_PATH, join("\n", lines)) != null;
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function truthy(value) {
    value = ascii_lower(trim(as_string(value)));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function dont_touch_dhcp_enabled() {
    return truthy(uci_core.get(CONFIG_NAME + ".settings.dont_touch_dhcp"));
}

function restore_dnsmasq_if_needed() {
    if (dont_touch_dhcp_enabled())
        return;

    command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);
    if (path_exists(DNS_APPLY_UC))
        command_success_from_args([ "ucode", DNS_APPLY_UC, "failsafe-restore" ]);
}

function remove_managed_sing_box() {
    let data = fs.readfile(SING_BOX_INIT);
    if (data == null || index(data, SING_BOX_MANAGED_MARKER) < 0)
        return;

    command_success_from_args([ SING_BOX_INIT, "stop" ]);
    command_success_from_args([ SING_BOX_INIT, "disable" ]);
    unlink_if_exists(SING_BOX_INIT);
    unlink_if_exists(SING_BOX_BIN);
    unlink_if_exists(SING_BOX_CRONET);
}

function prerm_cleanup() {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    remove_rt_tables_entry();
    if (!PACKAGE_TEST_MODE) {
        command_success_from_args([ "/etc/init.d/podkop-plus", "stop" ]);
        restore_dnsmasq_if_needed();
        remove_managed_sing_box();
    }
    return true;
}

function luci_cache_globs() {
    let configured = env("PODKOP_LUCI_CACHE_GLOBS", "");
    if (configured != "")
        return split(configured, /[ \t\r\n]+/);

    return [ "/var/luci-indexcache*", "/tmp/luci-indexcache*" ];
}

function remove_luci_index_cache() {
    for (let pattern in luci_cache_globs()) {
        pattern = as_string(pattern);
        if (pattern == "")
            continue;

        for (let path in fs.glob(pattern))
            unlink_if_exists(path);
    }
}

function luci_postinst() {
    remove_luci_index_cache();
    if (!PACKAGE_TEST_MODE) {
        if (path_exists("/etc/init.d/rpcd"))
            command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);
        command_success_from_args([ "logger", "-t", "podkop-plus", "[info] Package defaults applied" ]);
    }
    return true;
}

let mode = ARGV[0] || "";

if (mode == "preinst")
    exit(copy_legacy_config_if_needed() ? 0 : 1);
else if (mode == "prerm")
    exit(prerm_cleanup() ? 0 : 1);
else if (mode == "remove-rt-tables-entry")
    exit(remove_rt_tables_entry() ? 0 : 1);
else if (mode == "luci-postinst")
    exit(luci_postinst() ? 0 : 1);
else {
    warn("Usage: service/package.uc <preinst|prerm|remove-rt-tables-entry|luci-postinst>\n");
    exit(1);
}
