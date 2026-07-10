#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");
let migration = require("config.migration");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function constant_value(name, fallback) {
    let value = constants[name];
    return value == null ? as_string(fallback) : as_string(value);
}

const CONFIG_NAME = getenv("PODKOP_CONFIG_NAME") || constant_value("PODKOP_CONFIG_NAME", "podkop-plus");
const CONFIG_FILE = getenv("PODKOP_CONFIG_FILE") || "/etc/config/" + CONFIG_NAME;
const LIB_DIR = getenv("PODKOP_LIB") || "/usr/lib/podkop-plus";
const BIN_PATH = getenv("PODKOP_BIN") || constant_value("PODKOP_BIN", "/usr/bin/podkop-plus");
const SERVICE_INIT = getenv("PODKOP_SERVICE_INIT") || constant_value("PODKOP_SERVICE_INIT", "/etc/init.d/podkop-plus");
const SERVICE_NAME = getenv("PODKOP_SERVICE_NAME") || constant_value("PODKOP_SERVICE_NAME", "podkop-plus");
const LUCI_VIEW_DIR = getenv("PODKOP_LUCI_VIEW_DIR") || constant_value("PODKOP_LUCI_VIEW_DIR", "/www/luci-static/resources/view/podkop_plus");
const LUCI_I18N_DOMAIN = getenv("PODKOP_LUCI_I18N_DOMAIN") || constant_value("PODKOP_LUCI_I18N_DOMAIN", "podkop_plus");

const RUNTIME_STATE_DIR = getenv("PODKOP_RUNTIME_STATE_DIR") || "/var/run/podkop-plus";
const SYSTEM_INFO_CACHE_FILE = getenv("PODKOP_SYSTEM_INFO_CACHE_FILE") || RUNTIME_STATE_DIR + "/system-info.json";
const RELOAD_STATE_FILE = getenv("PODKOP_RELOAD_STATE_FILE") || RUNTIME_STATE_DIR + "/reload-state";
const RELOAD_STATE_SNAPSHOT_FILE = getenv("PODKOP_RELOAD_STATE_SNAPSHOT_FILE") || RUNTIME_STATE_DIR + "/reload-state.snapshot." + clock()[0] + "." + clock()[1];
const PENDING_RELOAD_FILE = getenv("PODKOP_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const SERVICE_TRIGGER_SYNC_FILE = getenv("PODKOP_SERVICE_TRIGGER_SYNC_FILE") || RUNTIME_STATE_DIR + "/service-triggers.sync";
const SUBSCRIPTION_UPDATE_STATE_DIR = getenv("PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR") || RUNTIME_STATE_DIR + "/subscription-update";
const SUBSCRIPTION_UPDATE_JOB_DIR = getenv("PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR") || RUNTIME_STATE_DIR + "/subscription-update-jobs";
const SUBSCRIPTION_LINKS_DIR = getenv("PODKOP_SUBSCRIPTION_LINKS_DIR") || RUNTIME_STATE_DIR + "/subscription-links";
const SUBSCRIPTION_METADATA_DIR = getenv("PODKOP_SUBSCRIPTION_METADATA_DIR") || RUNTIME_STATE_DIR + "/subscription-metadata";
const OUTBOUND_METADATA_DIR = getenv("PODKOP_OUTBOUND_METADATA_DIR") || RUNTIME_STATE_DIR + "/outbound-metadata";
const SECTION_CACHE_DIR = getenv("PODKOP_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const RULE_CONDITION_CACHE_DIR = getenv("PODKOP_RULE_CONDITION_CACHE_DIR") || RUNTIME_STATE_DIR + "/rule-condition-cache";
const RUNTIME_CACHE_FORMAT_FILE = getenv("PODKOP_RUNTIME_CACHE_FORMAT_FILE") || RUNTIME_STATE_DIR + "/cache-format";
const PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/podkop-plus/subscription-cache";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE = getenv("PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE") || RUNTIME_STATE_DIR + "/subscription-bootstrap-retry.pid";
const DNS_FAILOVER_STATE_FILE = getenv("PODKOP_DNS_FAILOVER_STATE_FILE") || RUNTIME_STATE_DIR + "/dns-failover.json";
const DNS_FAILOVER_PID_FILE = getenv("PODKOP_DNS_FAILOVER_PID_FILE") || RUNTIME_STATE_DIR + "/dns-failover.pid";
const SUBSCRIPTION_UPDATE_LOCK_DIR = getenv("PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR") || RUNTIME_STATE_DIR + "/subscription-update.lock";
const RELOAD_LOCK_DIR = getenv("PODKOP_RELOAD_LOCK_DIR") || "/var/run/podkop-plus.reload.lock";

const LIST_UPDATE_CRON_MARKER = getenv("PODKOP_LIST_UPDATE_CRON_MARKER") || "# podkop-plus-list-update";
const SUBSCRIPTION_UPDATE_CRON_MARKER = getenv("PODKOP_SUBSCRIPTION_UPDATE_CRON_MARKER") || "# podkop-plus-subscription-update";
const COMPONENT_UPDATE_CHECK_CRON_MARKER = getenv("PODKOP_COMPONENT_UPDATE_CHECK_CRON_MARKER") || "# podkop-plus-component-update-check";
const RELOAD_STATE_FORMAT = int(getenv("PODKOP_RELOAD_STATE_FORMAT") || "1");
const RUNTIME_CACHE_FORMAT = int(getenv("PODKOP_RUNTIME_CACHE_FORMAT") || "7");
const RUNTIME_STABLE_MIN_AGE = int(getenv("PODKOP_RUNTIME_STABLE_MIN_AGE") || "2");
const SING_BOX_START_STABLE_MIN_AGE = int(getenv("PODKOP_SING_BOX_START_STABLE_MIN_AGE") || "8");
const SING_BOX_START_VERIFY_TIMEOUT = int(getenv("PODKOP_SING_BOX_START_VERIFY_TIMEOUT") || "10");
const NFT_POPULATE_ENABLED_DEFAULT = int(getenv("PODKOP_NFT_POPULATE_ENABLED") || "1");

const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || constant_value("TMP_SING_BOX_FOLDER", "/tmp/sing-box");
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || constant_value("TMP_RULESET_FOLDER", TMP_SING_BOX_FOLDER + "/rulesets");
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || constant_value("TMP_SUBSCRIPTION_FOLDER", TMP_SING_BOX_FOLDER + "/subscriptions");

const RT_TABLE_NAME = constant_value("RT_TABLE_NAME", "podkop");
const NFT_TABLE_NAME = constant_value("NFT_TABLE_NAME", "PodkopPlusTable");
const NFT_LOCALV4_SET_NAME = constant_value("NFT_LOCALV4_SET_NAME", "localv4");
const NFT_LOCALV6_SET_NAME = constant_value("NFT_LOCALV6_SET_NAME", "localv6");
const NFT_COMMON_SET_NAME = constant_value("NFT_COMMON_SET_NAME", "podkop_plus_subnets");
const NFT_COMMON6_SET_NAME = constant_value("NFT_COMMON6_SET_NAME", "podkop_plus_subnets6");
const NFT_PORT_SET_NAME = constant_value("NFT_PORT_SET_NAME", "podkop_plus_ports");
const NFT_IP_PORT_SET_NAME = constant_value("NFT_IP_PORT_SET_NAME", "podkop_plus_ip_ports");
const NFT_IP_PORT6_SET_NAME = constant_value("NFT_IP_PORT6_SET_NAME", "podkop_plus_ip6_ports");
const NFT_INTERFACE_SET_NAME = constant_value("NFT_INTERFACE_SET_NAME", "podkop_plus_interfaces");
const NFT_FAKEIP_MARK = constant_value("NFT_FAKEIP_MARK", "0x00100000");
const NFT_OUTBOUND_MARK = constant_value("NFT_OUTBOUND_MARK", "0x00200000");

const SB_FAKEIP_INET4_RANGE = constant_value("SB_FAKEIP_INET4_RANGE", "198.18.0.0/15");
const SB_FAKEIP_INET6_RANGE = constant_value("SB_FAKEIP_INET6_RANGE", "fc00::/18");
const SB_TPROXY_INBOUND6_ADDRESS = constant_value("SB_TPROXY_INBOUND6_ADDRESS", "::1");
const SB_TPROXY_INBOUND_PORT = constant_value("SB_TPROXY_INBOUND_PORT", "1602");
const SB_SERVICE_MIXED_INBOUND_ADDRESS = constant_value("SB_SERVICE_MIXED_INBOUND_ADDRESS", "127.0.0.1");
const SB_SERVICE_MIXED_INBOUND_PORT = constant_value("SB_SERVICE_MIXED_INBOUND_PORT", "4534");
const SB_VARIANT_STATE_FILE = constant_value("SB_VARIANT_STATE_FILE", "/etc/podkop-plus/sing-box-variant");
const SB_VERSION_STATE_FILE = constant_value("SB_VERSION_STATE_FILE", "/etc/podkop-plus/sing-box-version");

const ZAPRET_PROVIDER_NFQWS_BIN = constant_value("ZAPRET_PROVIDER_NFQWS_BIN", "/opt/zapret/nfq/nfqws");
const ZAPRET_ROUTE_MARK_BASE = constant_value("ZAPRET_ROUTE_MARK_BASE", "0x01000000");
const ZAPRET_QUEUE_BASE = constant_value("ZAPRET_QUEUE_BASE", "4000");
const ZAPRET_DESYNC_MARK = constant_value("ZAPRET_DESYNC_MARK", "0x40000000");
const ZAPRET_DESYNC_MARK_POSTNAT = constant_value("ZAPRET_DESYNC_MARK_POSTNAT", "0x20000000");
const ZAPRET2_PROVIDER_NFQWS2_BIN = constant_value("ZAPRET2_PROVIDER_NFQWS2_BIN", "/opt/zapret2/nfq2/nfqws2");
const ZAPRET2_ROUTE_MARK_BASE = constant_value("ZAPRET2_ROUTE_MARK_BASE", "0x01010000");
const ZAPRET2_QUEUE_BASE = constant_value("ZAPRET2_QUEUE_BASE", "4300");
const ZAPRET2_DESYNC_MARK = constant_value("ZAPRET2_DESYNC_MARK", "0x40000000");
const ZAPRET2_DESYNC_MARK_POSTNAT = constant_value("ZAPRET2_DESYNC_MARK_POSTNAT", "0x20000000");
const BYEDPI_BIN = constant_value("BYEDPI_BIN", "/usr/bin/ciadpi");

const DNS_APPLY_UC = LIB_DIR + "/dns/apply.uc";
const MIGRATION_UC = LIB_DIR + "/config/migration.uc";
const VALIDATOR_UC = LIB_DIR + "/config/validator.uc";
const SERVER_UC = LIB_DIR + "/server/service.uc";
const NFT_UC = LIB_DIR + "/nft/apply.uc";
const SINGBOX_UC = LIB_DIR + "/singbox/runtime.uc";
const PRIORITY_UC = LIB_DIR + "/singbox/priority.uc";
const DNS_FAILOVER_UC = LIB_DIR + "/singbox/dns_failover.uc";
const SUBSCRIPTION_CACHE_UC = LIB_DIR + "/subscription/cache.uc";
const UPDATES_UC = LIB_DIR + "/components/updates.uc";
const STATE_UC = LIB_DIR + "/service/state.uc";
const RELOAD_UC = LIB_DIR + "/service/reload.uc";
const UI_UC = LIB_DIR + "/service/ui.uc";
const DIAGNOSTICS_UC = LIB_DIR + "/diagnostics/runtime.uc";
const ZAPRET_UC = LIB_DIR + "/providers/zapret/runtime.uc";
const ZAPRET2_UC = LIB_DIR + "/providers/zapret2/runtime.uc";
const BYEDPI_UC = LIB_DIR + "/providers/byedpi/runtime.uc";
const PACKAGES_UC = LIB_DIR + "/core/packages.uc";

let start_subscription_update_lock_held = false;
let subscription_caches_prepared = getenv("PODKOP_SUBSCRIPTION_CACHES_PREPARED") || "0";
let subscription_runtime_no_refresh = getenv("PODKOP_SUBSCRIPTION_RUNTIME_NO_REFRESH") || "0";
let subscription_deferred_sections = "";
let nft_populate_enabled = NFT_POPULATE_ENABLED_DEFAULT;
let rule_condition_cache_enabled = 0;
let startup_config_fingerprint = "";

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

function command_status(command) {
    return normalize_status(system(command));
}

function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };

    let data = pipe.read("all");
    let status = normalize_status(pipe.close());
    return { status, output: data == null ? "" : as_string(data) };
}

function command_output(command) {
    let result = command_capture(command);
    return result.status == 0 ? result.output : "";
}

function read_json_file(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function command_success(command) {
    return command_status(command + " >/dev/null 2>&1") == 0;
}

function command_status_from_args(args) {
    return command_status(command_from_args(args));
}

function command_output_from_args(args) {
    return command_output(command_from_args(args) + " 2>/dev/null");
}

function command_success_from_args(args) {
    return command_status(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function external_config_fingerprint() {
    let data = fs.readfile(CONFIG_FILE);
    if (data == null)
        return "";

    let lines = [];
    for (let line in split(as_string(data), "\n"))
        if (match(as_string(line), /^[ \t]*option[ \t]+shutdown_correctly([ \t]|$)/) == null)
            push(lines, line);

    return join("\n", lines);
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function owner_pid() {
    let pid = trim(command_output_from_args([ "sh", "-c", "echo $PPID" ]));
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function now_seconds() {
    return int(clock()[0]);
}

function bool_text(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function string_array_contains(values, needle) {
    needle = as_string(needle);
    if (needle == "")
        return false;

    for (let item in array_or_empty(values))
        if (as_string(item) == needle)
            return true;

    return false;
}

function write_file(path, value) {
    return fs.writefile(as_string(path), as_string(value));
}

function remove_file(path) {
    return fs.unlink(as_string(path)) || true;
}

function ensure_dir(path) {
    path = as_string(path);
    return path == "" || fs.mkdir(path, 0755) || fs.stat(path) != null;
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", SERVICE_NAME, "[" + level + "] " + as_string(message) ]);
}

function lifecycle_env() {
    return {
        PODKOP_CONFIG_NAME: CONFIG_NAME,
        PODKOP_LIB: LIB_DIR,
        PODKOP_BIN: BIN_PATH,
        PODKOP_SERVICE_INIT: SERVICE_INIT,
        PODKOP_RUNTIME_STATE_DIR: RUNTIME_STATE_DIR,
        PODKOP_SYSTEM_INFO_CACHE_FILE: SYSTEM_INFO_CACHE_FILE,
        PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR: SUBSCRIPTION_UPDATE_STATE_DIR,
        PODKOP_SUBSCRIPTION_LINKS_DIR: SUBSCRIPTION_LINKS_DIR,
        PODKOP_SUBSCRIPTION_METADATA_DIR: SUBSCRIPTION_METADATA_DIR,
        PODKOP_OUTBOUND_METADATA_DIR: OUTBOUND_METADATA_DIR,
        PODKOP_SECTION_CACHE_DIR: SECTION_CACHE_DIR,
        PODKOP_RULE_CONDITION_CACHE_DIR: RULE_CONDITION_CACHE_DIR,
        PODKOP_RUNTIME_CACHE_FORMAT_FILE: RUNTIME_CACHE_FORMAT_FILE,
        PODKOP_RUNTIME_CACHE_FORMAT: as_string(RUNTIME_CACHE_FORMAT),
        PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR: PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE: SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE,
        PODKOP_DNS_FAILOVER_STATE_FILE: DNS_FAILOVER_STATE_FILE,
        PODKOP_DNS_FAILOVER_PID_FILE: DNS_FAILOVER_PID_FILE,
        PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR: SUBSCRIPTION_UPDATE_LOCK_DIR,
        PODKOP_PENDING_RELOAD_FILE: PENDING_RELOAD_FILE,
        PODKOP_RELOAD_LOCK_DIR: RELOAD_LOCK_DIR,
        TMP_SING_BOX_FOLDER: TMP_SING_BOX_FOLDER,
        TMP_RULESET_FOLDER: TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER: TMP_SUBSCRIPTION_FOLDER,
        SB_SERVICE_MIXED_INBOUND_ADDRESS: SB_SERVICE_MIXED_INBOUND_ADDRESS,
        SB_SERVICE_MIXED_INBOUND_PORT: SB_SERVICE_MIXED_INBOUND_PORT,
        SB_VARIANT_STATE_FILE: SB_VARIANT_STATE_FILE,
        SB_VERSION_STATE_FILE: SB_VERSION_STATE_FILE,
        ZAPRET_PROVIDER_NFQWS_BIN: ZAPRET_PROVIDER_NFQWS_BIN,
        ZAPRET2_PROVIDER_NFQWS2_BIN: ZAPRET2_PROVIDER_NFQWS2_BIN,
        BYEDPI_BIN: BYEDPI_BIN,
        PODKOP_RULE_CONDITION_CACHE_ENABLED: as_string(rule_condition_cache_enabled)
    };
}

function command_env(assignments) {
    let parts = [];
    for (let name, value in assignments)
        push(parts, as_string(name) + "=" + shell_quote(value));
    return join(" ", parts);
}

function module_args(module_path, args) {
    let result = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let arg in (type(args) == "array" ? args : []))
        push(result, arg);
    return result;
}

function module_command(module_path, args) {
    return command_env(lifecycle_env()) + " " + command_from_args(module_args(module_path, args));
}

function module_capture(module_path, args) {
    return command_capture(module_command(module_path, args));
}

function module_status(module_path, args) {
    return command_status(module_command(module_path, args));
}

function module_success(module_path, args) {
    return module_status(module_path, args) == 0;
}

function mark_pending_reload(reason) {
    return module_success(STATE_UC, [ "mark-pending-reload", PENDING_RELOAD_FILE, reason ]);
}

function pending_reload_log_context(reason) {
    reason = as_string(reason);
    if (reason == "config_changed_during_reload")
        return "current reload";
    return "startup";
}

function mark_pending_reload_if_config_changed(initial_fingerprint, reason) {
    initial_fingerprint = as_string(initial_fingerprint);
    if (initial_fingerprint == "")
        return false;

    let current_fingerprint = external_config_fingerprint();
    if (current_fingerprint == "" || current_fingerprint == initial_fingerprint)
        return false;

    let context = pending_reload_log_context(reason);
    if (mark_pending_reload(reason)) {
        log_message("Configuration changed during " + context + "; queued reload after " + context + " completes", "info");
        return true;
    }

    log_message("Configuration changed during " + context + ", but pending reload could not be queued", "warn");
    return false;
}

function finish_reload_status(status, initial_fingerprint) {
    status = int(status || 0);
    if (status == 0)
        mark_pending_reload_if_config_changed(initial_fingerprint, "config_changed_during_reload");
    return status;
}

function module_output(module_path, args) {
    let result = module_capture(module_path, args);
    return result.status == 0 ? result.output : "";
}

function selector_state_from_proxies_payload(payload) {
    let result = {};
    let proxies = object_or_empty(object_or_empty(payload).proxies);

    for (let tag, proxy in proxies) {
        proxy = object_or_empty(proxy);
        let proxy_type = lc(as_string(proxy.type || ""));
        let selected = as_string(proxy.now || "");

        if (proxy_type == "selector" && string_array_contains(proxy.all, selected))
            result[as_string(tag)] = selected;
    }

    return result;
}

function selector_restore_pairs(snapshot, payload) {
    let result = [];
    snapshot = object_or_empty(snapshot);
    let proxies = object_or_empty(object_or_empty(payload).proxies);

    for (let group, selected in snapshot) {
        group = as_string(group);
        selected = as_string(selected);

        if (group == "" || selected == "")
            continue;

        let proxy = object_or_empty(proxies[group]);
        if (lc(as_string(proxy.type || "")) != "selector")
            continue;
        if (!string_array_contains(proxy.all, selected))
            continue;
        if (as_string(proxy.now || "") == selected)
            continue;

        push(result, { group, proxy: selected });
    }

    return result;
}

function clash_api_json(action, arg1, arg2, arg3) {
    let result = module_capture(DIAGNOSTICS_UC, [
        "clash-api",
        action,
        as_string(arg1 || ""),
        as_string(arg2 || ""),
        as_string(arg3 || "")
    ]);
    if (result.status != 0)
        return null;

    try {
        return json(result.output);
    }
    catch (e) {
        return null;
    }
}

function capture_selector_state() {
    return selector_state_from_proxies_payload(clash_api_json("get_proxies"));
}

function restore_selector_state(snapshot) {
    let pairs = selector_restore_pairs(snapshot, clash_api_json("get_proxies"));

    for (let pair in pairs)
        module_success(DIAGNOSTICS_UC, [ "clash-api", "set_group_proxy", pair.group, pair.proxy, "" ]);
}

function module_background(module_path, args) {
    return command_status(module_command(module_path, args) + " >/dev/null 2>&1 1000>&- &") == 0;
}

function config_get(path, fallback) {
    path = as_string(path);
    if (!uci_core.exists(path))
        return as_string(fallback);
    return trim(uci_core.get(path));
}

function config_set(path, value) {
    return uci_core.set(path, value);
}

function config_commit() {
    if (!uci_core.commit(CONFIG_NAME))
        return 1;
    migration.mark_internal_config_guard();
    return 0;
}

function mark_runtime_stopped_clean() {
    let status = 0;
    if (!config_set(CONFIG_NAME + ".settings.shutdown_correctly", "1"))
        status = 1;
    else {
        let commit_status = config_commit();
        if (commit_status != 0)
            status = commit_status;
    }

    module_success(STATE_UC, [ "clear-reload-state", RELOAD_STATE_FILE, RELOAD_STATE_SNAPSHOT_FILE ]);
    return status;
}

function setting_bool(name, fallback) {
    let value = config_get(CONFIG_NAME + ".settings." + as_string(name), fallback ? "1" : "0");
    return bool_text(value);
}

function dns_apply_status(args) {
    return module_status(DNS_APPLY_UC, args);
}

function dns_apply_success(args) {
    return dns_apply_status(args) == 0;
}

function dnsmasq_configure(force) {
    let args = [ "configure" ];
    if (force)
        push(args, "force");
    return dns_apply_status(args);
}

function dnsmasq_restore(force) {
    let args = [ "restore" ];
    if (force)
        push(args, "force");
    return dns_apply_status(args);
}

function dnsmasq_restore_fail_safe() {
    return dns_apply_status([ "failsafe-restore" ]);
}

function dnsmasq_has_podkop_managed_state() {
    return dns_apply_success([ "has-managed-state" ]);
}

function validate_start_config() {
    let status = module_status(MIGRATION_UC, [ "migrate" ]);
    if (status != 0) {
        log_message("Config migration failed. Aborted.", "fatal");
        return status;
    }

    status = module_status(VALIDATOR_UC, [ "check-requirements" ]);
    if (status != 0)
        return status;

    status = module_status(SERVER_UC, [ "prepare-all-defaults" ]);
    if (status != 0)
        return status;

    status = module_status(VALIDATOR_UC, [ "validate-runtime" ]);
    if (status != 0) {
        log_message("Runtime config validation failed. Aborted.", "fatal");
        return status;
    }

    return 0;
}

function acquire_start_subscription_update_lock() {
    if (module_success(STATE_UC, [ "acquire-runtime-dir-lock-wait", SUBSCRIPTION_UPDATE_LOCK_DIR, owner_pid(), "300" ])) {
        start_subscription_update_lock_held = true;
        return true;
    }

    log_message("Subscription update is already running during startup. Aborted.", "fatal");
    return false;
}

function release_start_subscription_update_lock() {
    if (!start_subscription_update_lock_held)
        return;

    module_success(STATE_UC, [ "release-runtime-dir-lock", SUBSCRIPTION_UPDATE_LOCK_DIR ]);
    start_subscription_update_lock_held = false;
}

function nft_rebuild_runtime() {
    return module_status(NFT_UC, [
        "nft-rebuild-runtime-from-uci",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_LOCALV4_SET_NAME,
        NFT_COMMON_SET_NAME,
        NFT_PORT_SET_NAME,
        NFT_IP_PORT_SET_NAME,
        NFT_INTERFACE_SET_NAME,
        NFT_FAKEIP_MARK,
        NFT_OUTBOUND_MARK,
        SB_FAKEIP_INET4_RANGE,
        SB_TPROXY_INBOUND_PORT,
        ZAPRET_PROVIDER_NFQWS_BIN,
        ZAPRET_ROUTE_MARK_BASE,
        ZAPRET_QUEUE_BASE,
        ZAPRET_DESYNC_MARK,
        ZAPRET_DESYNC_MARK_POSTNAT,
        ZAPRET2_PROVIDER_NFQWS2_BIN,
        ZAPRET2_ROUTE_MARK_BASE,
        ZAPRET2_QUEUE_BASE,
        ZAPRET2_DESYNC_MARK,
        ZAPRET2_DESYNC_MARK_POSTNAT,
        NFT_LOCALV6_SET_NAME,
        NFT_COMMON6_SET_NAME,
        NFT_IP_PORT6_SET_NAME,
        SB_FAKEIP_INET6_RANGE,
        SB_TPROXY_INBOUND6_ADDRESS
    ]);
}

function nft_populate_runtime_sets() {
    return module_status(NFT_UC, [
        "nft-populate-runtime-sets-from-uci",
        as_string(nft_populate_enabled),
        subscription_deferred_sections,
        NFT_TABLE_NAME,
        NFT_COMMON_SET_NAME,
        NFT_PORT_SET_NAME,
        NFT_IP_PORT_SET_NAME,
        NFT_INTERFACE_SET_NAME,
        NFT_LOCALV4_SET_NAME,
        NFT_FAKEIP_MARK,
        NFT_COMMON6_SET_NAME,
        NFT_IP_PORT6_SET_NAME,
        NFT_LOCALV6_SET_NAME
    ]);
}

function singbox_init_config() {
    let result = module_capture(SINGBOX_UC, [
        "init-config",
        as_string(nft_populate_enabled),
        subscription_caches_prepared,
        subscription_runtime_no_refresh
    ]);
    if (result.status == 0) {
        subscription_deferred_sections = trim(result.output);
        subscription_caches_prepared = "1";
    }
    return result.status;
}

function refresh_cron() {
    return module_status(UPDATES_UC, [
        "refresh-cron-from-uci",
        BIN_PATH,
        LIST_UPDATE_CRON_MARKER,
        SUBSCRIPTION_UPDATE_CRON_MARKER,
        COMPONENT_UPDATE_CHECK_CRON_MARKER
    ]);
}

function remove_cron_jobs() {
    return module_status(UPDATES_UC, [
        "remove-cron-jobs",
        LIST_UPDATE_CRON_MARKER,
        SUBSCRIPTION_UPDATE_CRON_MARKER,
        COMPONENT_UPDATE_CHECK_CRON_MARKER
    ]);
}

function prepare_subscription_caches(mode) {
    let result = module_capture(SUBSCRIPTION_CACHE_UC, [
        "prepare-caches",
        mode,
        subscription_caches_prepared,
        subscription_runtime_no_refresh
    ]);
    if (result.status == 0) {
        subscription_deferred_sections = trim(result.output);
        subscription_caches_prepared = "1";
    }
    return result.status;
}

function start_main() {
    let status;

    log_message("Starting Podkop Plus", "info");

    status = validate_start_config();
    if (status != 0)
        return status;

    startup_config_fingerprint = external_config_fingerprint();

    status = module_status(NFT_UC, [ "ensure-bridge-netfilter-disabled" ]);
    if (status != 0)
        return status;

    module_success(STATE_UC, [ "sync-time-if-needed" ]);

    status = module_status(SUBSCRIPTION_CACHE_UC, [ "ensure-runtime-dirs" ]);
    if (status != 0)
        return status;

    if (!acquire_start_subscription_update_lock())
        return 1;

    status = prepare_subscription_caches("startup");
    if (status != 0) {
        log_message("Subscription caches are not ready. Aborted.", "fatal");
        return status;
    }

    status = nft_rebuild_runtime();
    if (status != 0)
        return status;

    status = module_status(SINGBOX_UC, [ "configure-service" ]);
    if (status != 0)
        return status;

    status = singbox_init_config();
    if (status != 0)
        return status;

    status = refresh_cron();
    if (status != 0)
        return status;

    module_success(BYEDPI_UC, [ "start-runtime" ]);

    if (!command_success_from_args([ "/etc/init.d/sing-box", "start" ])) {
        log_message("Failed to start sing-box. Aborted.", "fatal");
        return 1;
    }

    status = module_status(STATE_UC, [
        "wait-podkop-stable-start",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(SING_BOX_START_STABLE_MIN_AGE),
        as_string(SING_BOX_START_VERIFY_TIMEOUT)
    ]);
    if (status != 0) {
        log_message("sing-box did not reach a stable running state after start. Aborted.", "fatal");
        return status;
    }

    status = module_status(PRIORITY_UC, [ "start-runtime" ]);
    if (status != 0) {
        log_message("Failed to start Priority runtime. Aborted.", "fatal");
        return status;
    }

    status = module_status(SUBSCRIPTION_CACHE_UC, [ "run-deferred-bootstrap", subscription_deferred_sections ]);
    if (status != 0)
        return status;

    release_start_subscription_update_lock();
    module_success(ZAPRET_UC, [ "start-runtime" ]);
    module_success(ZAPRET2_UC, [ "start-runtime" ]);

    module_background(UPDATES_UC, [ "list-update" ]);
    return 0;
}

function start_impl() {
    let status = start_main();
    if (status != 0)
        return status;

    if (!setting_bool("dont_touch_dhcp", false)) {
        status = dnsmasq_configure(false);
        if (status != 0)
            return status;
    }
    else if (dnsmasq_has_podkop_managed_state()) {
        status = dnsmasq_restore(true);
        if (status != 0)
            return status;
    }

    if (!config_set(CONFIG_NAME + ".settings.shutdown_correctly", "0"))
        return 1;

    status = config_commit();
    if (status != 0)
        return status;

    status = module_status(STATE_UC, [
        "write-current-reload-state-clean",
        RELOAD_STATE_FILE,
        as_string(RELOAD_STATE_FORMAT),
        RULE_CONDITION_CACHE_DIR
    ]);
    if (status != 0)
        return status;

    status = module_status(DNS_FAILOVER_UC, [ "start-runtime" ]);
    if (status != 0) {
        log_message("Failed to start DNS failover runtime", "fatal");
        return status;
    }

    module_background(DIAGNOSTICS_UC, [ "get-system-info" ]);
    return 0;
}

function stop_main() {
    let status = 0;

    log_message("Stopping Podkop Plus", "info");
    module_success(DNS_FAILOVER_UC, [ "stop-runtime" ]);
    module_success(PRIORITY_UC, [ "stop-runtime" ]);
    module_success(SUBSCRIPTION_CACHE_UC, [ "stop-deferred-bootstrap-worker" ]);
    module_success(UPDATES_UC, [ "stop-list-update" ]);
    remove_cron_jobs();
    command_success_from_args([ "find", TMP_RULESET_FOLDER, "-mindepth", "1", "-maxdepth", "1", "-type", "f", "-delete" ]);

    module_success(ZAPRET_UC, [ "stop-runtime" ]);
    module_success(ZAPRET2_UC, [ "stop-runtime" ]);
    module_success(BYEDPI_UC, [ "stop-runtime" ]);

    if (command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ]))
        command_success_from_args([ "nft", "delete", "table", "inet", NFT_TABLE_NAME ]);

    if (module_success(NFT_UC, [ "tproxy-marking-rule4-present", RT_TABLE_NAME, NFT_FAKEIP_MARK ]))
        command_success_from_args([ "ip", "-4", "rule", "del", "fwmark", NFT_FAKEIP_MARK + "/" + NFT_FAKEIP_MARK, "table", RT_TABLE_NAME, "priority", "105" ]);
    if (module_success(NFT_UC, [ "tproxy-marking-rule6-present", RT_TABLE_NAME, NFT_FAKEIP_MARK ]))
        command_success_from_args([ "ip", "-6", "rule", "del", "fwmark", NFT_FAKEIP_MARK + "/" + NFT_FAKEIP_MARK, "table", RT_TABLE_NAME, "priority", "105" ]);

    if (module_success(NFT_UC, [ "tproxy-route4-present", RT_TABLE_NAME ]))
        command_success_from_args([ "ip", "route", "flush", "table", RT_TABLE_NAME ]);
    if (module_success(NFT_UC, [ "tproxy-route6-present", RT_TABLE_NAME ]))
        command_success_from_args([ "ip", "-6", "route", "flush", "table", RT_TABLE_NAME ]);

    let sing_box_status = command_status_from_args([ "/etc/init.d/sing-box", "stop" ]);
    if (sing_box_status != 0)
        status = sing_box_status;

    return status;
}

function cleanup_failed_runtime() {
    let status = 0;

    log_message("Cleaning up Podkop Plus runtime after failed start/reload", "info");

    let stop_status = stop_main();
    if (stop_status != 0)
        status = stop_status;

    let dns_status = dnsmasq_restore_fail_safe();
    if (dns_status != 0 && status == 0)
        status = dns_status;

    let mark_status = mark_runtime_stopped_clean();
    if (mark_status != 0 && status == 0)
        status = mark_status;

    if (status != 0)
        log_message("Failed to fully clean up Podkop Plus runtime after start/reload failure", "warn");

    return status;
}

function start() {
    let status = start_impl();
    release_start_subscription_update_lock();

    if (status != 0) {
        cleanup_failed_runtime();
        return status;
    }

    mark_pending_reload_if_config_changed(startup_config_fingerprint, "config_changed_during_start");

    status = module_status(STATE_UC, [
        "wait-podkop-stable-start",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(RUNTIME_STABLE_MIN_AGE),
        "8"
    ]);
    if (status != 0) {
        log_message("Startup verification failed after Podkop Plus was started; rolling back DNS changes", "warn");
        cleanup_failed_runtime();
        return status;
    }

    return 0;
}

function stop_impl() {
    let status = 0;

    if (!setting_bool("dont_touch_dhcp", false)) {
        let dns_status = dnsmasq_restore(false);
        if (dns_status != 0)
            status = dns_status;
    }
    else if (dnsmasq_has_podkop_managed_state()) {
        let dns_status = dnsmasq_restore(true);
        if (dns_status != 0)
            status = dns_status;
    }

    let runtime_status = stop_main();
    if (runtime_status != 0)
        status = runtime_status;

    if (!config_set(CONFIG_NAME + ".settings.shutdown_correctly", "1"))
        status = 1;
    else {
        let commit_status = config_commit();
        if (commit_status != 0)
            status = commit_status;
    }

    module_success(STATE_UC, [ "clear-reload-state", RELOAD_STATE_FILE, RELOAD_STATE_SNAPSHOT_FILE ]);

    if (status != 0)
        dnsmasq_restore_fail_safe();

    return status;
}

function stop() {
    return stop_impl();
}

function restart_runtime_for_reload() {
    let status;
    let selector_state = capture_selector_state();

    log_message("Reload requires a full Podkop Plus runtime restart", "info");

    status = stop_main();
    if (status != 0)
        return status;

    status = start_main();
    if (status != 0) {
        cleanup_failed_runtime();
        return status;
    }

    status = module_status(STATE_UC, [
        "wait-podkop-stable-start",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(RUNTIME_STABLE_MIN_AGE),
        "8"
    ]);
    if (status != 0) {
        log_message("Reload runtime restart verification failed after Podkop Plus was started; rolling back DNS changes", "fatal");
        cleanup_failed_runtime();
        return status;
    }

    restore_selector_state(selector_state);

    if (!setting_bool("dont_touch_dhcp", false))
        dnsmasq_configure(true);
    else if (dnsmasq_has_podkop_managed_state()) {
        dnsmasq_restore(true);
    }

    config_set(CONFIG_NAME + ".settings.shutdown_correctly", "0");
    if (config_commit() != 0)
        return 1;

    status = module_status(STATE_UC, [
        "write-current-reload-state-clean",
        RELOAD_STATE_FILE,
        as_string(RELOAD_STATE_FORMAT),
        RULE_CONDITION_CACHE_DIR
    ]);
    if (status != 0)
        return status;

    status = module_status(DNS_FAILOVER_UC, [ "start-runtime" ]);
    if (status != 0)
        log_message("Failed to start DNS failover runtime after runtime restart", "error");
    return status;
}

function write_service_trigger_sync_state(changed) {
    ensure_dir(RUNTIME_STATE_DIR);
    write_file(SERVICE_TRIGGER_SYNC_FILE, as_string(changed) + "\n");
}

function parse_reload_plan(output) {
    let result = {
        changed_service_triggers: 0,
        changed_dnsmasq: 0,
        changed_sing_box: 0,
        changed_nft: 0,
        changed_zapret_queue: 0,
        changed_zapret_runtime: 0,
        changed_zapret2_queue: 0,
        changed_zapret2_runtime: 0,
        changed_byedpi_runtime: 0,
        changed_cron: 0,
        changed_list: 0,
        needs_sing_box_reload: 0,
        needs_nft_rebuild: 0,
        needs_zapret_restart: 0,
        needs_zapret2_restart: 0,
        needs_byedpi_restart: 0,
        needs_dnsmasq_configure: 0,
        needs_dnsmasq_restore: 0,
        needs_cron_refresh: 0,
        needs_list_update: 0,
        has_work: 0
    };

    for (let line in split(as_string(output), "\n")) {
        line = as_string(line);
        if (line == "")
            continue;
        let fields = split(line, "\t");
        if (length(fields) < 2)
            continue;
        let key = fields[0];
        if (result[key] != null)
            result[key] = int(fields[1] || 0);
    }

    return result;
}

function append_reload_action(actions, enabled, label) {
    if (!(enabled === true || int(enabled || 0) == 1))
        return actions;
    return actions + (actions != "" ? ", " : "") + label;
}

function reload_actions_summary(plan) {
    let actions = "";
    actions = append_reload_action(actions, plan.needs_sing_box_reload, "sing-box");
    actions = append_reload_action(actions, plan.needs_nft_rebuild, "nftables");
    actions = append_reload_action(actions, plan.needs_zapret_restart, "Zapret");
    actions = append_reload_action(actions, plan.needs_zapret2_restart, "Zapret2");
    actions = append_reload_action(actions, plan.needs_byedpi_restart, "ByeDPI");
    actions = append_reload_action(actions, plan.needs_dnsmasq_configure || plan.needs_dnsmasq_restore, "dnsmasq");
    actions = append_reload_action(actions, plan.needs_cron_refresh, "scheduled jobs");
    actions = append_reload_action(actions, plan.needs_list_update, "remote lists");
    return actions;
}

function release_reload_lock() {
    module_success(STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR ]);
}

function wait_dns_failover_state(candidate_state_path, attempts) {
    attempts = int(attempts || 1);
    for (let i = 0; i < attempts; i++) {
        let status = module_status(DNS_FAILOVER_UC, [ "verify-state", candidate_state_path ]);
        if (status == 0)
            return 0;
        if (i + 1 < attempts)
            command_success_from_args([ "sleep", "1" ]);
    }
    return 1;
}

function dns_failover_apply(candidate_state_path) {
    candidate_state_path = as_string(candidate_state_path);
    if (candidate_state_path == "" || fs.stat(candidate_state_path) == null)
        return 1;

    if (!module_success(STATE_UC, [ "acquire-runtime-dir-lock-wait", RELOAD_LOCK_DIR, owner_pid(), "2" ]))
        return 2;

    let patch_result = module_capture(SINGBOX_UC, [ "patch-dns-config", candidate_state_path ]);
    if (patch_result.status != 0) {
        release_reload_lock();
        return patch_result.status;
    }

    let fields = split(trim(patch_result.output), "\t");
    let changed = as_string(fields[0]) == "1";
    let backup_path = length(fields) > 1 ? as_string(fields[1]) : "";
    let status = 0;

    if (changed) {
        status = module_status(STATE_UC, [ "hup-sing-box-runtime" ]);
        if (status == 0)
            status = wait_dns_failover_state(candidate_state_path, 5);

        if (status != 0) {
            log_message("sing-box SIGHUP DNS reload did not become ready; trying service reload", "warn");
            status = module_status(STATE_UC, [ "reload-sing-box-runtime" ]);
            if (status == 0)
                status = wait_dns_failover_state(candidate_state_path, 8);
        }
    }

    if (status == 0 && !module_success(DNS_FAILOVER_UC, [ "commit-state", candidate_state_path ]))
        status = 1;

    if (status != 0 && backup_path != "") {
        log_message("DNS failover apply failed; restoring the previous sing-box configuration", "error");
        if (module_success(SINGBOX_UC, [ "restore-dns-config", backup_path ]))
            module_success(STATE_UC, [ "reload-sing-box-runtime" ]);
    }

    if (backup_path != "")
        remove_file(backup_path);
    release_reload_lock();
    return status;
}

function reload(reason) {
    let status;
    let force_runtime_reload = as_string(reason || "") == "on_config_change" ? 0 : 1;
    let reload_config_fingerprint = external_config_fingerprint();
    rule_condition_cache_enabled = force_runtime_reload;

    log_message("Reloading Podkop Plus", "info");

    status = validate_start_config();
    if (status != 0)
        return status;

    status = module_status(SUBSCRIPTION_CACHE_UC, [ "ensure-runtime-dirs" ]);
    if (status != 0)
        return status;

    if (!module_success(STATE_UC, [ "podkop-running", RT_TABLE_NAME, NFT_TABLE_NAME, NFT_FAKEIP_MARK ])) {
        log_message("Runtime state is incomplete; restarting Podkop Plus runtime", "info");
        return finish_reload_status(restart_runtime_for_reload(), reload_config_fingerprint);
    }

    remove_file(RELOAD_STATE_SNAPSHOT_FILE);
    status = module_status(STATE_UC, [
        "capture-reload-state",
        RELOAD_STATE_SNAPSHOT_FILE,
        as_string(RELOAD_STATE_FORMAT)
    ]);
    if (status != 0)
        return status;

    let current_reload_state_file = trim(command_output_from_args([ "mktemp" ]));
    if (current_reload_state_file == "")
        return 1;

    status = module_status(STATE_UC, [
        "write-captured-reload-state",
        current_reload_state_file,
        RELOAD_STATE_SNAPSHOT_FILE,
        as_string(RELOAD_STATE_FORMAT),
        "",
        "0",
        "0"
    ]);
    if (status != 0) {
        remove_file(current_reload_state_file);
        return status;
    }

    let dnsmasq_managed_state = dnsmasq_has_podkop_managed_state() ? 1 : 0;
    let list_update_sources = module_success(STATE_UC, [ "has-list-update-sources" ]) ? 1 : 0;
    let nft_list_update_sources = module_success(STATE_UC, [ "has-nft-list-update-sources" ]) ? 1 : 0;
    let runtime_cache_needs_rebuild = 0;
    if (as_string(getenv("PODKOP_RUNTIME_CACHE_INVALIDATED") || "0") == "1" ||
        module_success(SUBSCRIPTION_CACHE_UC, [ "runtime-cache-needs-rebuild", SECTION_CACHE_DIR ]))
        runtime_cache_needs_rebuild = 1;

    let plan_result = module_capture(RELOAD_UC, [
        "plan-state-files",
        RELOAD_STATE_FILE,
        current_reload_state_file,
        as_string(force_runtime_reload),
        as_string(dnsmasq_managed_state),
        as_string(list_update_sources),
        as_string(nft_list_update_sources),
        as_string(runtime_cache_needs_rebuild)
    ]);
    remove_file(current_reload_state_file);

    if (plan_result.status != 0) {
        if (plan_result.status == 2) {
            log_message("Reload state is unavailable; restarting Podkop Plus runtime", "info");
            return finish_reload_status(restart_runtime_for_reload(), reload_config_fingerprint);
        }
        return plan_result.status;
    }

    let plan = parse_reload_plan(plan_result.output);
    write_service_trigger_sync_state(plan.changed_service_triggers);

    if (plan.has_work == 0) {
        status = module_status(STATE_UC, [
            "write-captured-reload-state",
            RELOAD_STATE_FILE,
            RELOAD_STATE_SNAPSHOT_FILE,
            as_string(RELOAD_STATE_FORMAT),
            RULE_CONDITION_CACHE_DIR,
            "1",
            "1"
        ]);
        if (status == 0)
            log_message("Reload skipped: runtime-relevant configuration is unchanged", "info");
        return finish_reload_status(status, reload_config_fingerprint);
    }

    let actions = reload_actions_summary(plan);
    if (actions != "")
        log_message("Applying reload changes: " + actions, "info");

    if (plan.needs_zapret_restart == 1)
        module_success(ZAPRET_UC, [ "stop-runtime" ]);
    if (plan.needs_zapret2_restart == 1)
        module_success(ZAPRET2_UC, [ "stop-runtime" ]);
    if (plan.needs_byedpi_restart == 1)
        module_success(BYEDPI_UC, [ "stop-runtime" ]);

    if (plan.needs_nft_rebuild == 1) {
        log_message("Rebuilding nftables rules", "info");
        status = nft_rebuild_runtime();
        if (status != 0)
            return status;
    }

    if (plan.needs_sing_box_reload == 1) {
        module_success(DNS_FAILOVER_UC, [ "stop-runtime" ]);
        module_success(PRIORITY_UC, [ "stop-runtime" ]);
        status = module_status(SINGBOX_UC, [ "configure-service" ]);
        if (status != 0)
            return status;
        nft_populate_enabled = plan.needs_nft_rebuild == 1 ? 1 : 0;
        status = singbox_init_config();
        if (status != 0)
            return status;
        nft_populate_enabled = NFT_POPULATE_ENABLED_DEFAULT;
        status = module_status(STATE_UC, [ "reload-sing-box-runtime" ]);
        if (status != 0)
            return status;
        status = module_status(STATE_UC, [
            "wait-podkop-stable-start",
            RT_TABLE_NAME,
            NFT_TABLE_NAME,
            NFT_FAKEIP_MARK,
            as_string(SING_BOX_START_STABLE_MIN_AGE),
            as_string(SING_BOX_START_VERIFY_TIMEOUT)
        ]);
        if (status != 0) {
            log_message("Reload verification failed after sing-box was reloaded; stopping Podkop Plus runtime", "fatal");
            cleanup_failed_runtime();
            return status;
        }
        status = module_status(PRIORITY_UC, [ "start-runtime" ]);
        if (status != 0) {
            log_message("Failed to start Priority runtime after sing-box reload", "fatal");
            cleanup_failed_runtime();
            return status;
        }
        status = module_status(DNS_FAILOVER_UC, [ "start-runtime" ]);
        if (status != 0) {
            log_message("Failed to restart DNS failover runtime after sing-box reload", "fatal");
            cleanup_failed_runtime();
            return status;
        }
    }
    else if (plan.needs_nft_rebuild == 1 && nft_populate_enabled == 1) {
        status = nft_populate_runtime_sets();
        if (status != 0)
            return status;
    }

    if (plan.needs_zapret_restart == 1)
        module_success(ZAPRET_UC, [ "start-runtime" ]);
    if (plan.needs_zapret2_restart == 1)
        module_success(ZAPRET2_UC, [ "start-runtime" ]);
    if (plan.needs_byedpi_restart == 1)
        module_success(BYEDPI_UC, [ "start-runtime" ]);

    if (plan.needs_dnsmasq_configure == 1) {
        status = dnsmasq_configure(true);
        if (status != 0)
            return status;
        module_success(STATE_UC, [ "capture-reload-state", RELOAD_STATE_SNAPSHOT_FILE, as_string(RELOAD_STATE_FORMAT) ]);
    }
    else if (plan.needs_dnsmasq_restore == 1) {
        status = dnsmasq_restore(true);
        if (status != 0)
            return status;
        module_success(STATE_UC, [ "capture-reload-state", RELOAD_STATE_SNAPSHOT_FILE, as_string(RELOAD_STATE_FORMAT) ]);
    }

    if (plan.needs_cron_refresh == 1) {
        status = refresh_cron();
        if (status != 0)
            return status;
    }

    if (plan.needs_list_update == 1)
        module_background(UPDATES_UC, [ "list-update" ]);

    return finish_reload_status(module_status(STATE_UC, [
        "write-captured-reload-state",
        RELOAD_STATE_FILE,
        RELOAD_STATE_SNAPSHOT_FILE,
        as_string(RELOAD_STATE_FORMAT),
        RULE_CONDITION_CACHE_DIR,
        "1",
        "1"
    ]), reload_config_fingerprint);
}

function reload_tracked(reason) {
    if (as_string(getenv("PODKOP_UI_ACTION_TRACKED") || "0") == "1")
        return reload(reason);

    let job_id = trim(module_output(UI_UC, [ "service-action-begin-if-idle", "reload", "runtime_reload" ]));
    if (job_id != "")
        module_success(UI_UC, [ "service-action-update-pid", job_id, owner_pid() ]);

    let status = reload(reason);
    if (job_id != "")
        module_success(UI_UC, [ "service-action-finish-after-command", "reload", job_id, as_string(status) ]);

    return status;
}

function restart() {
    log_message("Restarting Podkop Plus", "info");

    let selector_state = capture_selector_state();
    let status = stop_impl();
    if (status != 0)
        return status;

    status = start_impl();
    if (status != 0) {
        cleanup_failed_runtime();
        return status;
    }

    if (module_success(STATE_UC, [
        "podkop-stably-running",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(RUNTIME_STABLE_MIN_AGE)
    ])) {
        restore_selector_state(selector_state);
        return 0;
    }

    log_message("Restart verification failed after Podkop Plus was started; stopping Podkop Plus runtime", "fatal");
    cleanup_failed_runtime();
    return 1;
}

function package_manager_remove_if_installed(package_name) {
    package_name = as_string(package_name);
    if (command_success_from_args([ "sh", "-c", "command -v apk" ])) {
        if (command_success_from_args([ "apk", "info", "-e", package_name ]))
            command_success_from_args([ "apk", "del", package_name ]);
        return;
    }

    if (module_success(PACKAGES_UC, [ "opkg-installed", package_name ]))
        command_success_from_args([ "opkg", "remove", "--force-depends", package_name ]);
}

function uninstall() {
    log_message("Uninstalling Podkop Plus", "info");

    if (fs.stat(SERVICE_INIT) != null) {
        stop();
        command_success_from_args([ SERVICE_INIT, "disable" ]);
    }

    dnsmasq_restore_fail_safe();

    if (fs.stat("/etc/init.d/podkop") != null) {
        command_success_from_args([ "/etc/init.d/podkop", "stop" ]);
        command_success_from_args([ "/etc/init.d/podkop", "disable" ]);
    }

    package_manager_remove_if_installed("luci-i18n-podkop-plus-ru");
    package_manager_remove_if_installed("luci-app-podkop-plus");

    if (module_success(SINGBOX_UC, [ "managed-service-installed" ])) {
        module_success(SINGBOX_UC, [ "remove-managed-service-script" ]);
        remove_file("/usr/bin/sing-box");
        remove_file("/usr/lib/libcronet.so");
    }

    command_success_from_args([ "rm", "-rf", "/usr/lib/podkop-plus" ]);
    command_success_from_args([ "rm", "-rf", LUCI_VIEW_DIR ]);
    remove_file(SERVICE_INIT);
    remove_file(BIN_PATH);
    remove_file("/usr/share/luci/menu.d/luci-app-podkop-plus.json");
    remove_file("/usr/share/rpcd/acl.d/luci-app-podkop-plus.json");
    remove_file("/etc/uci-defaults/50_luci-podkop-plus");
    command_success_from_args([ "find", "/usr/lib/lua/luci/i18n", "-maxdepth", "1", "-type", "f", "-name", LUCI_I18N_DOMAIN + ".*.lmo", "-delete" ]);
    remove_file("/usr/lib/lua/luci/i18n/" + LUCI_I18N_DOMAIN + ".ru.lua");
    remove_file("/usr/lib/lua/luci/i18n/" + LUCI_I18N_DOMAIN + ".en.lua");
    command_success("rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null");
    if (fs.stat("/etc/init.d/rpcd") != null)
        command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);

    print("{\"removed\":true}\n");
    return 0;
}

function enable_service() {
    return command_status_from_args([ SERVICE_INIT, "enable" ]);
}

function disable_service() {
    return command_status_from_args([ SERVICE_INIT, "disable" ]);
}

let mode = ARGV[0] || "";
let status = 1;

if (mode == "main")
    status = start_main();
else if (mode == "start")
    status = start();
else if (mode == "stop")
    status = stop();
else if (mode == "reload")
    status = reload_tracked(ARGV[1] || "");
else if (mode == "dns-failover-apply")
    status = dns_failover_apply(ARGV[1] || "");
else if (mode == "restart")
    status = restart();
else if (mode == "enable")
    status = enable_service();
else if (mode == "disable")
    status = disable_service();
else if (mode == "selector-state-from-proxies-fixture") {
    write_json(selector_state_from_proxies_payload(read_json_file(ARGV[1])));
    status = 0;
}
else if (mode == "selector-restore-pairs-fixture") {
    write_json(selector_restore_pairs(read_json_file(ARGV[1]), read_json_file(ARGV[2])));
    status = 0;
}
else if (mode == "dnsmasq-restore" || mode == "restore-dnsmasq")
    status = dnsmasq_restore_fail_safe();
else if (mode == "uninstall")
    status = uninstall();
else {
    warn("Usage: service/lifecycle.uc <start|stop|reload|restart|main|enable|disable|dnsmasq-restore|uninstall> ...\n");
    status = 1;
}

release_start_subscription_update_lock();
exit(status);
