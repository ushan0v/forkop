#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let rule_config = require("config.rule");
let connections = require("config.connections");
let zapret_validator = require("providers.zapret.validator");
let zapret2_validator = require("providers.zapret2.validator");
let byedpi_validator = require("providers.byedpi.validator");
const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const DEFAULT_PENDING_RELOAD_FILE = getenv("FORKOP_PENDING_RELOAD_FILE") || "/var/run/forkop/reload.pending";
const DEFAULT_SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || "/etc/init.d/forkop";
const ZAPRET_DEFAULT_NFQWS_OPT = getenv("ZAPRET_DEFAULT_NFQWS_OPT") || "";
const ZAPRET2_DEFAULT_NFQWS2_OPT = getenv("ZAPRET2_DEFAULT_NFQWS2_OPT") || "";
const BYEDPI_DEFAULT_CMD_OPTS = getenv("BYEDPI_DEFAULT_CMD_OPTS") || "";

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
    let data = read_stdin();
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function read_json_file(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_text_file(path, text) {
    let result = fs.writefile(path, as_string(text));
    if (result == null)
        return false;
    if (type(result) == "boolean" && !result)
        return false;
    return true;
}

function unlink_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
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

function command_output_from_args(args) {
    let pipe = fs.popen(command_from_args(args), "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return as_string(data);
}

function command_trimmed_output_from_args(args) {
    return replace(command_output_from_args(args), /[\r\n]+$/g, "");
}

function command_success_from_args(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function uci_get(path) {
    return uci_core.get(path);
}

function uci_exists(path) {
    return uci_core.exists(path);
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function file_first_line(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let newline = index(data, "\n");
    print(newline >= 0 ? substr(data, 0, newline) : data, "\n");
}

function read_state_value(path, needle) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    needle = as_string(needle);
    for (let line in split(data, "\n")) {
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key == needle) {
            print(equals >= 0 ? substr(line, equals + 1) : line, "\n");
            return;
        }
    }
}

function state_has_key(path, needle) {
    let data = fs.readfile(path);
    if (data == null)
        return false;

    needle = as_string(needle);
    for (let line in split(data, "\n")) {
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key == needle)
            return true;
    }

    return false;
}

const RELOAD_STATE_FIELDS = [
    "format",
    "service_trigger_signature",
    "dnsmasq_signature",
    "sing_box_signature",
    "nft_signature",
    "zapret_queue_signature",
    "zapret_runtime_signature",
    "zapret2_queue_signature",
    "zapret2_runtime_signature",
    "byedpi_runtime_signature",
    "list_signature",
    "cron_signature",
    "urltest_enabled_sections",
    "dont_touch_dhcp"
];

function reload_state_text(values) {
    let output = "";
    values = object_or_empty(values);

    for (let field in RELOAD_STATE_FIELDS)
        output += field + "=" + as_string(values[field]) + "\n";

    return output;
}

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    if (slash < 0)
        return "";
    return substr(path, 0, slash);
}

function ensure_parent_dir(path) {
    let dir = parent_dir(path);
    if (dir == "" || dir == ".")
        return true;
    return command_success_from_args([ "mkdir", "-p", dir ]);
}

function numeric_text(value) {
    return match(as_string(value), /^[0-9]+$/) != null;
}

function current_epoch() {
    let value = command_trimmed_output_from_args([ "date", "+%s" ]);
    return numeric_text(value) ? value : "0";
}

function config_file_hash(path) {
    let hash_line = trim(command_output_from_args([ "md5sum", as_string(path) ]));
    return length(hash_line) >= 32 ? substr(hash_line, 0, 32) : "";
}

function current_year() {
    let value = command_trimmed_output_from_args([ "date", "+%Y" ]);
    return numeric_text(value) ? int(value) : null;
}

function time_sync_needed(year) {
    if (year == null)
        return false;
    return int(year) < 2024;
}

function sync_time_if_needed() {
    if (!time_sync_needed(current_year()))
        return;

    command_success_from_args([
        "/usr/sbin/ntpd",
        "-q",
        "-p", "194.190.168.1",
        "-p", "216.239.35.0",
        "-p", "216.239.35.4",
        "-p", "162.159.200.1",
        "-p", "162.159.200.123"
    ]);
}

function mark_pending_reload(path, reason) {
    path = as_string(path || DEFAULT_PENDING_RELOAD_FILE);
    reason = as_string(reason || "pending");

    if (!ensure_parent_dir(path))
        exit(1);

    if (!write_text_file(path, "reason=" + reason + "\nupdated_at=" + current_epoch() + "\n"))
        exit(1);
}

function consume_pending_reload(path) {
    path = as_string(path || DEFAULT_PENDING_RELOAD_FILE);
    if (fs.stat(path) == null)
        return false;

    unlink_file(path);
    return true;
}

function run_pending_reload_if_requested(path, init_script) {
    path = as_string(path || DEFAULT_PENDING_RELOAD_FILE);
    init_script = as_string(init_script || DEFAULT_SERVICE_INIT);

    if (!consume_pending_reload(path))
        return;

    command_success_from_args([ "logger", "-t", "forkop", "[info] Applying pending Forkop reload" ]);
    system(shell_quote(init_script) + " reload pending >/dev/null 2>&1 1000>&- &");
}

function first_line_value(path) {
    let data = fs.readfile(path);
    if (data == null)
        return "";

    let newline = index(data, "\n");
    return newline >= 0 ? substr(data, 0, newline) : data;
}

function pid_alive(pid) {
    pid = as_string(pid);
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function lock_dir_write_owner(lock_dir, owner_pid) {
    return write_text_file(as_string(lock_dir) + "/pid", as_string(owner_pid) + "\n");
}

function acquire_runtime_dir_lock(lock_dir, owner_pid) {
    lock_dir = as_string(lock_dir);
    owner_pid = as_string(owner_pid);
    if (lock_dir == "" || owner_pid == "")
        return false;

    if (command_success_from_args([ "mkdir", lock_dir ])) {
        if (lock_dir_write_owner(lock_dir, owner_pid))
            return true;
        release_runtime_dir_lock(lock_dir);
        return false;
    }

    if (pid_alive(first_line_value(lock_dir + "/pid")))
        return false;

    command_success_from_args([ "rm", "-f", lock_dir + "/pid" ]);
    if (!command_success_from_args([ "rmdir", lock_dir ]))
        return false;
    if (!command_success_from_args([ "mkdir", lock_dir ]))
        return false;

    if (lock_dir_write_owner(lock_dir, owner_pid))
        return true;

    release_runtime_dir_lock(lock_dir);
    return false;
}

function acquire_runtime_dir_lock_wait(lock_dir, owner_pid, timeout) {
    let timeout_text = as_string(timeout == null ? "300" : timeout);
    timeout = numeric_text(timeout_text) ? int(timeout_text, 10) : 300;
    let start = int(current_epoch(), 10) || 0;

    while (!acquire_runtime_dir_lock(lock_dir, owner_pid)) {
        let now = int(current_epoch(), 10) || start;
        if (now - start >= timeout)
            return false;
        command_success_from_args([ "sleep", "2" ]);
    }

    return true;
}

function release_runtime_dir_lock(lock_dir) {
    lock_dir = as_string(lock_dir);
    if (lock_dir == "")
        return;

    command_success_from_args([ "rm", "-f", lock_dir + "/pid" ]);
    command_success_from_args([ "rmdir", lock_dir ]);
}

function write_reload_state(path, values) {
    if (!ensure_parent_dir(path))
        exit(1);

    if (!fs.writefile(path, reload_state_text(values)))
        exit(1);
}

function copy_file(source, target) {
    let data = fs.readfile(source);
    if (data == null)
        return false;
    if (!ensure_parent_dir(target))
        return false;
    return write_text_file(target, data);
}

function cleanup_rule_condition_cache(path) {
    path = as_string(path);
    if (path != "")
        command_success_from_args([ "rm", "-rf", path ]);
    system("rm -rf /tmp/forkop-rule-cache.* >/dev/null 2>&1");
}

function cleanup_reload_state_snapshots(path) {
    path = as_string(path);
    if (path == "")
        return;

    for (let snapshot_path in fs.glob(path + ".snapshot.*"))
        unlink_file(snapshot_path);
}

function clear_reload_state(path, snapshot_path) {
    unlink_file(path);
    if (as_string(snapshot_path) != "")
        unlink_file(snapshot_path);
    cleanup_reload_state_snapshots(path);
}

function remove_file(path) {
    unlink_file(path);
}

function reload_state_values_from_args(offset) {
    let values = {};
    offset = int(offset || 0);

    for (let i = 0; i < length(RELOAD_STATE_FIELDS); i++)
        values[RELOAD_STATE_FIELDS[i]] = ARGV[i + offset];

    return values;
}

function response_success() {
    let value = read_stdin_json();
    return type(value) == "object" && value.success === true;
}

function stdin_first_field() {
    let data = read_stdin();
    let newline = index(data, "\n");
    let line = newline >= 0 ? substr(data, 0, newline) : data;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);

    if (length(fields) > 0 && fields[0] != "")
        print(fields[0], "\n");
}

function sing_box_service_pid_from_value(value) {
    let service = type(value) == "object" ? value["sing-box"] : null;
    let instances = service && type(service.instances) == "object" ? service.instances : {};

    for (let _, instance in instances) {
        if (type(instance) == "object" && instance.running === true && int(instance.pid || 0) > 0)
            return int(instance.pid);
    }

    return 0;
}

function sing_box_service_pid() {
    let pid = sing_box_service_pid_from_value(read_stdin_json());
    if (pid > 0)
        print(pid, "\n");
}

function sing_box_service_pid_runtime() {
    let data = command_output_from_args([ "ubus", "call", "service", "list", "{\"name\":\"sing-box\"}" ]);
    try {
        return sing_box_service_pid_from_value(json(data));
    }
    catch (e) {
        return 0;
    }
}

function path_basename(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, slash + 1) : path;
}

function pid_is_sing_box(pid) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null)
        return false;

    return path_basename(command_trimmed_output_from_args([ "readlink", "/proc/" + pid + "/exe" ])) == "sing-box";
}

function hup_sing_box_runtime() {
    let pid = sing_box_service_pid_runtime();
    if (pid <= 0 || !pid_is_sing_box(pid))
        exit(1);

    command_success_from_args([ "logger", "-t", "forkop", "[info] Applying DNS failover with sing-box SIGHUP reload" ]);
    if (!command_success_from_args([ "kill", "-HUP", as_string(pid) ]))
        exit(1);
}

function process_age_seconds(pid) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null)
        return null;

    let stat = fs.readfile("/proc/" + pid + "/stat");
    if (stat == null)
        return null;

    let marker = index(stat, ") ");
    if (marker < 0)
        return null;

    let fields = split(trim(substr(stat, marker + 2)), /[ \t\r\n]+/);
    if (length(fields) < 20)
        return null;

    let start_ticks = fields[19];
    if (match(start_ticks, /^[0-9]+$/) == null)
        return null;

    let uptime = fs.readfile("/proc/uptime");
    if (uptime == null)
        return null;

    let uptime_seconds = split(trim(as_string(uptime)), /[ \t\r\n.]+/)[0];
    if (match(uptime_seconds, /^[0-9]+$/) == null)
        return null;

    return int(uptime_seconds) - int(int(start_ticks) / 100);
}

function sing_box_pid_replaced(previous_pid, current_pid, current_is_sing_box) {
    previous_pid = int(previous_pid || 0);
    current_pid = int(current_pid || 0);
    current_is_sing_box = lc(as_string(current_is_sing_box));
    let executable_matches = current_is_sing_box == "1" || current_is_sing_box == "true" ||
        current_is_sing_box == "yes" || current_is_sing_box == "on";
    return current_pid > 0 && executable_matches &&
        (previous_pid <= 0 || current_pid != previous_pid);
}

function wait_sing_box_pid_replacement(previous_pid, timeout) {
    timeout = int(timeout || 15);
    while (timeout > 0) {
        let current_pid = sing_box_service_pid_runtime();
        if (sing_box_pid_replaced(previous_pid, current_pid, pid_is_sing_box(current_pid)))
            return true;

        command_success_from_args([ "sleep", "1" ]);
        timeout--;
    }
    return false;
}

function sing_box_reload_previous_pid(previous_pid, config_hash_before, config_hash_after) {
    previous_pid = as_string(previous_pid);
    if (as_string(config_hash_before) == as_string(config_hash_after) ||
        match(previous_pid, /^[0-9]+$/) == null || int(previous_pid) <= 0)
        return 0;
    return int(previous_pid);
}

function reload_sing_box_runtime(previous_pid, config_hash_before, config_hash_after) {
    previous_pid = sing_box_reload_previous_pid(previous_pid, config_hash_before, config_hash_after);
    command_success_from_args([ "logger", "-t", "forkop", "[info] Reloading sing-box runtime" ]);
    if (!command_success_from_args([ "/etc/init.d/sing-box", "reload" ])) {
        command_success_from_args([ "logger", "-t", "forkop", "[fatal] Failed to reload sing-box. Aborted." ]);
        exit(1);
    }

    let timeout = getenv("FORKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15";
    if (previous_pid > 0 && !wait_sing_box_pid_replacement(previous_pid, timeout)) {
        command_success_from_args([ "logger", "-t", "forkop", "[fatal] sing-box reload did not replace the running process. Aborted." ]);
        exit(1);
    }
}

function sing_box_service_running() {
    let pid = sing_box_service_pid_runtime();
    return pid > 0 && pid_is_sing_box(pid);
}

function sing_box_service_stable(min_age) {
    min_age = int(min_age || 2);

    let pid = sing_box_service_pid_runtime();
    if (pid <= 0 || !pid_is_sing_box(pid))
        return false;

    let age = process_age_seconds(pid);
    return age != null && age >= min_age;
}

function forkop_runtime_network_configured(rt_table, nft_table, mark) {
    return command_success_from_args([ "nft", "list", "table", "inet", nft_table ]) &&
        command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/nft/apply.uc", "tproxy-route-rule-present", rt_table, mark ]);
}

function forkop_running(rt_table, nft_table, mark) {
    return sing_box_service_running() && forkop_runtime_network_configured(rt_table, nft_table, mark);
}

function forkop_stably_running(rt_table, nft_table, mark, min_age) {
    return sing_box_service_stable(min_age) && forkop_runtime_network_configured(rt_table, nft_table, mark);
}

function wait_forkop_stable_start(rt_table, nft_table, mark, min_age, timeout) {
    timeout = int(timeout || 8);
    while (timeout > 0) {
        if (forkop_stably_running(rt_table, nft_table, mark, min_age))
            return true;

        command_success_from_args([ "sleep", "1" ]);
        timeout--;
    }

    return forkop_stably_running(rt_table, nft_table, mark, min_age);
}

function whitespace_fields(value) {
    value = as_string(value);
    let result = [];
    for (let item in split(trim(value), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";

    let value = object_or_empty(section)[key];
    if (value == null)
        return fallback;
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function list_option(section, key, fallback) {
    let value = object_or_empty(section)[key];
    if (type(value) == "array")
        return value;

    value = trim(as_string(value));
    if (value != "")
        return split(value, /[ \t\r\n]+/);

    fallback = as_string(fallback);
    return fallback == "" ? [] : [ fallback ];
}

function bool_option(section, key, fallback) {
    return arg_bool(option(section, key, fallback ? "1" : "0"));
}

function bool_value(value) {
    return arg_bool(value) ? "1" : "0";
}

function bool_option_value(section, key, fallback) {
    return bool_option(section, key, fallback) ? "1" : "0";
}

function section_name(section) {
    return as_string(object_or_empty(section)[".name"]);
}

function str_startswith(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function reference_is_remote(value) {
    return str_startswith(value, "http://") || str_startswith(value, "https://");
}

function list_has_remote_references(value) {
    for (let item in whitespace_fields(value))
        if (reference_is_remote(item))
            return true;
    return false;
}

function community_service_has_subnet_list(value) {
    return rule_config.community_service_has_subnet_list(value);
}

function filter_community_subnet_lists(value) {
    print(rule_config.filter_community_subnet_lists_value(value), "\n");
}

function has_community_subnet_list(value) {
    return rule_config.has_community_subnet_list(value);
}

function rule_has_list_update_source(enabled, action, community_lists, remote_domain_lists, remote_subnet_lists, rule_set_with_subnets, domain_ip_lists) {
    if (!arg_bool(enabled))
        return false;
    if (as_string(action) == "dns")
        return list_has_remote_references(domain_ip_lists);

    return (
        has_community_subnet_list(community_lists) ||
        as_string(remote_domain_lists) != "" ||
        as_string(remote_subnet_lists) != "" ||
        as_string(rule_set_with_subnets) != "" ||
        list_has_remote_references(domain_ip_lists)
    );
}

function rule_has_nft_list_update_source(enabled, action, community_lists, remote_subnet_lists, rule_set_with_subnets, domain_ip_lists) {
    if (!arg_bool(enabled) || as_string(action) == "dns")
        return false;

    return (
        has_community_subnet_list(community_lists) ||
        as_string(remote_subnet_lists) != "" ||
        as_string(rule_set_with_subnets) != "" ||
        list_has_remote_references(domain_ip_lists)
    );
}

function rule_has_subscription_update_source(is_subscription_proxy, subscription_update_interval) {
    return arg_bool(is_subscription_proxy) && as_string(subscription_update_interval) != "";
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

function download_via_proxy_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy";
    if (purpose == "components")
        return "download_components_via_proxy";
    return "";
}

function download_via_proxy_section_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy_section";
    if (purpose == "components")
        return "download_components_via_proxy_section";
    return "";
}

function download_via_proxy_enabled(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    return enabled_option != "" && bool_option(settings, enabled_option, false);
}

function download_via_proxy_any_enabled(settings) {
    return download_via_proxy_enabled(settings, "lists") ||
        download_via_proxy_enabled(settings, "components");
}

function signature_add_value(body, key, value) {
    return body + "[" + as_string(key) + "]\n" + as_string(value) + "\n";
}

function signature_hash(body) {
    let path = trim(command_output_from_args([ "mktemp" ]));
    if (path == "")
        return "";

    if (!write_text_file(path, body)) {
        unlink_file(path);
        return "";
    }

    let hash_line = command_output_from_args([ "md5sum", path ]);
    unlink_file(path);
    hash_line = trim(hash_line);

    return length(hash_line) >= 32 ? substr(hash_line, 0, 32) : "";
}

function print_signature_hash(body) {
    let hash = signature_hash(body);
    if (hash == "")
        return false;

    print(hash, "\n");
    return true;
}

function dont_touch_dhcp_value(settings) {
    return bool_option(settings, "dont_touch_dhcp", false) ? "1" : "0";
}

function service_trigger_signature_body(settings) {
    let enabled = bool_option(settings, "enable_badwan_interface_monitoring", false);
    let body = signature_add_value("", "settings.enable_badwan_interface_monitoring", enabled ? "1" : "0");

    if (enabled) {
        body = signature_add_value(body, "settings.badwan_monitored_interfaces", option(settings, "badwan_monitored_interfaces", ""));
        body = signature_add_value(body, "settings.badwan_reload_delay", option(settings, "badwan_reload_delay", "2000"));
    }

    return body;
}

function normalize_detect_server_country_method(value) {
    value = as_string(value);
    if (value == "country_is")
        return "country_is";
    return "flag_emoji";
}

function dnsmasq_signature_body(settings, dnsmasq, legacy_dnsmasq_present) {
    let body = "";

    body = signature_add_value(body, "settings.dont_touch_dhcp", dont_touch_dhcp_value(settings));
    body = signature_add_value(body, "dhcp.@dnsmasq[0].server", option(dnsmasq, "server", ""));
    body = signature_add_value(body, "dhcp.@dnsmasq[0].noresolv", option(dnsmasq, "noresolv", ""));
    body = signature_add_value(body, "dhcp.@dnsmasq[0].cachesize", option(dnsmasq, "cachesize", ""));
    body = signature_add_value(body, "dhcp.@dnsmasq[0].forkop_server", option(dnsmasq, "forkop_server", ""));
    body = signature_add_value(body, "dhcp.@dnsmasq[0].forkop_noresolv", option(dnsmasq, "forkop_noresolv", ""));
    body = signature_add_value(body, "dhcp.@dnsmasq[0].forkop_cachesize", option(dnsmasq, "forkop_cachesize", ""));
    body = signature_add_value(body, "dhcp.forkop.present", arg_bool(legacy_dnsmasq_present) ? "1" : "0");

    return body;
}

function settings_update_interval(settings) {
    settings = object_or_empty(settings);

    if (!bool_option(settings, "list_update_enabled", true))
        return "";

    let value = option(settings, "update_interval", "1d");
    return value != "" ? value : "1d";
}

function settings_component_update_check_interval(settings) {
    settings = object_or_empty(settings);

    if (!bool_option(settings, "component_update_check_enabled", false))
        return "";

    let value = option(settings, "component_update_check_interval", "1d");
    return value != "" ? value : "1d";
}

function section_rule_ports_csv(section) {
    return rule_config.rule_ports_csv_value(option(section, "ports", ""), option(section, "ports_text", ""));
}

function combined_domain_condition_text(section) {
    if (type(object_or_empty(section)["domain"]) != "array") {
        let value = option(section, "domain", "");
        if (value != "")
            return value;
    }

    return option(section, "domain_suffix_text", "");
}

function section_rule_condition_csv(section, key, kind) {
    return rule_config.rule_condition_csv_value(
        key,
        kind,
        option(section, key + "_text_mode", "0"),
        option(section, "conditions_text_mode", "0"),
        option(section, key + "_text", ""),
        option(section, key, ""),
        combined_domain_condition_text(section),
        option(section, "domain_suffix", "")
    );
}

function nft_runtime_signature_body(settings, sections) {
    let body = "";

    body = signature_add_value(body, "settings.source_network_interfaces", option(settings, "source_network_interfaces", "br-lan"));
    body = signature_add_value(body, "settings.exclude_ntp", bool_option(settings, "exclude_ntp", false) ? "1" : "0");

    for (let section in sections) {
        section = object_or_empty(section);
        let name = section_name(section);
        if (name == "" || !bool_option(section, "enabled", true))
            continue;

        let action = option(section, "action", "");
        body = signature_add_value(body, "rule." + name + ".action", action);
        if (action == "dns")
            continue;
        body = signature_add_value(body, "rule." + name + ".ip_cidr", section_rule_condition_csv(section, "ip_cidr", "subnets"));
        body = signature_add_value(body, "rule." + name + ".source_ip_cidr", section_rule_condition_csv(section, "source_ip_cidr", "subnets"));
        body = signature_add_value(body, "rule." + name + ".ports", section_rule_ports_csv(section));
        body = signature_add_value(body, "rule." + name + ".fully_routed_ips", option(section, "fully_routed_ips", ""));
        body = signature_add_value(body, "rule." + name + ".community_subnet_lists", rule_config.filter_community_subnet_lists_value(connections.community_lists_value(section)));
        body = signature_add_value(body, "rule." + name + ".remote_subnet_lists", option(section, "remote_subnet_lists", ""));
        body = signature_add_value(body, "rule." + name + ".rule_set_with_subnets", connections.rule_sets_with_subnets_value(section));
        body = signature_add_value(body, "rule." + name + ".domain_ip_lists", option(section, "domain_ip_lists", ""));
    }

    return body;
}

function section_subscription_update_interval(section) {
    let result = "";
    let result_seconds = 0;

    for (let entry in connections.subscription_urls(section)) {
        if (!connections.subscription_update_enabled(section, entry))
            continue;

        let value = connections.subscription_update_interval(section, entry);
        if (value == "")
            value = "1h";
        let seconds = duration_to_seconds_value(value);
        if (result == "" || (seconds != null && (result_seconds == 0 || seconds < result_seconds))) {
            result = value;
            result_seconds = seconds == null ? 0 : seconds;
        }
    }

    return result;
}

function connection_urls_signature(section) {
    return sprintf("%J", connections.connection_urls(section));
}

function subscription_urls_signature(section) {
    let result = [];
    for (let entry in connections.subscription_urls(section)) {
        push(result, {
            url: entry,
            subscription_update_enabled: connections.subscription_update_enabled(section, entry) ? "1" : "0",
            subscription_update_interval: connections.subscription_update_interval(section, entry),
            download_via_proxy_section: connections.subscription_download_section(section, entry),
            auto_user_agent: connections.subscription_auto_user_agent(section, entry) ? "1" : "0",
            user_agent: connections.subscription_user_agent(section, entry),
            auto_hwid: connections.subscription_auto_hwid(section, entry) ? "1" : "0",
            hwid: connections.subscription_hwid(section, entry),
            show_dashboard_metadata: connections.subscription_dashboard_metadata_enabled(section, entry) ? "1" : "0",
            prefix_nodes: connections.subscription_prefix_nodes(section, entry) ? "1" : "0",
            node_prefix: connections.subscription_node_prefix(section, entry),
            include_urltest_groups: connections.subscription_include_urltest_groups(section, entry) ? "1" : "0",
            hide_urltest_group_outbounds: connections.subscription_hide_urltest_group_outbounds(section, entry) ? "1" : "0",
            hide_detour_outbounds: connections.subscription_hide_detour_outbounds(section, entry) ? "1" : "0"
        });
    }
    return sprintf("%J", result);
}

function interfaces_signature(section) {
    let result = [];
    for (let entry in connections.interfaces(section)) {
        push(result, {
            name: entry,
            domain_resolver_enabled: connections.interface_domain_resolver_enabled(section, entry) ? "1" : "0",
            domain_resolver_dns_type: connections.interface_domain_resolver_dns_type(section, entry),
            domain_resolver_dns_server: connections.interface_domain_resolver_dns_server(section, entry)
        });
    }
    return sprintf("%J", result);
}

function urltests_signature(section) {
    let result = [];
    for (let entry in connections.urltests(section)) {
        push(result, {
            id: entry,
            display_name: connections.urltest_display_name(section, entry),
            check_interval: connections.urltest_check_interval(section, entry),
            tolerance: connections.urltest_tolerance(section, entry),
            testing_url: connections.urltest_testing_url(section, entry),
            idle_timeout: connections.urltest_idle_timeout(section, entry),
            interrupt_exist_connections: connections.urltest_interrupt_exist_connections(section, entry) ? "1" : "0",
            pin_dashboard: connections.urltest_pin_dashboard(section, entry) ? "1" : "0",
            hide_added_outbounds: connections.urltest_hide_added_outbounds(section, entry) ? "1" : "0",
            filter_mode: connections.urltest_filter_mode(section, entry),
            detect_server_country: connections.urltest_detect_server_country(section, entry),
            include_countries: connections.urltest_include_countries(section, entry),
            include_outbounds: connections.urltest_include_outbounds(section, entry),
            include_regex: connections.urltest_include_regex(section, entry),
            exclude_countries: connections.urltest_exclude_countries(section, entry),
            exclude_outbounds: connections.urltest_exclude_outbounds(section, entry),
            exclude_regex: connections.urltest_exclude_regex(section, entry)
        });
    }
    return sprintf("%J", result);
}

function priority_groups_signature(section) {
    let result = [];
    for (let group_id in connections.priority_groups(section)) {
        let levels = [];
        for (let level_id in connections.priority_levels(group_id)) {
            push(levels, {
                id: level_id,
                display_name: connections.priority_level_display_name(group_id, level_id),
                order: connections.priority_level_order(group_id, level_id),
                direct: connections.priority_level_direct(group_id, level_id) ? "1" : "0",
                filter_mode: connections.priority_level_filter_mode(group_id, level_id),
                detect_server_country: connections.priority_level_detect_server_country(group_id, level_id),
                include_countries: connections.priority_level_include_countries(group_id, level_id),
                include_outbounds: connections.priority_level_include_outbounds(group_id, level_id),
                include_regex: connections.priority_level_include_regex(group_id, level_id),
                exclude_countries: connections.priority_level_exclude_countries(group_id, level_id),
                exclude_outbounds: connections.priority_level_exclude_outbounds(group_id, level_id),
                exclude_regex: connections.priority_level_exclude_regex(group_id, level_id)
            });
        }

        push(result, {
            id: group_id,
            display_name: connections.priority_group_display_name(section, group_id),
            health_url: connections.priority_group_health_url(section, group_id),
            active_check_interval: connections.priority_group_active_check_interval(section, group_id),
            check_timeout: connections.priority_group_check_timeout(section, group_id),
            recovery_check_interval: connections.priority_group_recovery_check_interval(section, group_id),
            pick_fastest: connections.priority_group_pick_fastest(section, group_id) ? "1" : "0",
            switch_to_faster_same_priority: connections.priority_group_switch_to_faster_same_priority(section, group_id) ? "1" : "0",
            fastest_check_interval: connections.priority_group_fastest_check_interval(section, group_id),
            interrupt_exist_connections: connections.priority_group_interrupt_exist_connections(section, group_id) ? "1" : "0",
            pin_dashboard: connections.priority_group_pin_dashboard(section, group_id) ? "1" : "0",
            hide_added_outbounds: connections.priority_group_hide_added_outbounds(section, group_id) ? "1" : "0",
            levels
        });
    }
    return sprintf("%J", result);
}

function section_is_subscription_proxy(section) {
    return bool_option(section, "enabled", true) &&
        connections.is_connections_action(option(section, "action", "")) &&
        length(connections.subscription_urls(section)) > 0;
}

function section_urltest_check_interval(section) {
    let urltests = connections.urltests(section);
    if (length(urltests) == 0)
        return "";

    let result = "";
    let result_seconds = 0;
    for (let urltest_id in urltests) {
        let value = connections.urltest_check_interval(section, urltest_id);
        if (value == "")
            value = "3m";
        let seconds = duration_to_seconds_value(value);
        if (result == "" || (seconds != null && (result_seconds == 0 || seconds < result_seconds))) {
            result = value;
            result_seconds = seconds == null ? 0 : seconds;
        }
    }

    return result;
}

function append_list_update_signature_body(body, section) {
    let name = section_name(section);
    if (name == "" || !bool_option(section, "enabled", true))
        return body;

    let action = option(section, "action", "");
    body = signature_add_value(body, "lists." + name + ".action", action);
    if (action == "dns") {
        body = signature_add_value(body, "lists." + name + ".domain_ip_lists", option(section, "domain_ip_lists", ""));
        return body;
    }

    body = signature_add_value(body, "lists." + name + ".ports", section_rule_ports_csv(section));
    body = signature_add_value(body, "lists." + name + ".community_subnet_lists", rule_config.filter_community_subnet_lists_value(connections.community_lists_value(section)));
    body = signature_add_value(body, "lists." + name + ".remote_domain_lists", option(section, "remote_domain_lists", ""));
    body = signature_add_value(body, "lists." + name + ".remote_subnet_lists", option(section, "remote_subnet_lists", ""));
    body = signature_add_value(body, "lists." + name + ".rule_set_with_subnets", connections.rule_sets_with_subnets_value(section));
    body = signature_add_value(body, "lists." + name + ".domain_ip_lists", option(section, "domain_ip_lists", ""));

    return body;
}

function list_update_signature_body(sections) {
    let body = "";

    for (let section in sections)
        body = append_list_update_signature_body(body, object_or_empty(section));

    return body;
}

function cron_signature_body(settings, sections) {
    let body = signature_add_value("", "settings.update_interval", settings_update_interval(settings));
    body = signature_add_value(body, "settings.component_update_check_interval", settings_component_update_check_interval(settings));

    for (let section in sections)
        body = append_list_update_signature_body(body, object_or_empty(section));

    for (let section in sections) {
        section = object_or_empty(section);
        if (!section_is_subscription_proxy(section))
            continue;

        let name = section_name(section);
        body = signature_add_value(body, "subscription." + name + ".subscription_urls", subscription_urls_signature(section));
        body = signature_add_value(body, "subscription." + name + ".subscription_update_interval", section_subscription_update_interval(section));
    }

    return body;
}

function urltest_enabled_sections_value(sections) {
    let result = [];

    for (let section in sections) {
        section = object_or_empty(section);
        if (bool_option(section, "enabled", true) &&
            connections.is_connections_action(option(section, "action", "")) &&
            length(connections.urltests(section)) > 0)
            push(result, section_name(section));
    }

    return join(" ", result);
}

function print_urltest_enabled_sections(sections) {
    print(urltest_enabled_sections_value(sections), "\n");
}

function sing_box_signature_has_remote_ruleset_sources(sections) {
    for (let section in sections) {
        section = object_or_empty(section);
        if (!bool_option(section, "enabled", true))
            continue;

        if (length(connections.community_lists(section)) > 0 ||
            list_has_remote_references(connections.rule_sets_value(section)) ||
            list_has_remote_references(connections.rule_sets_with_subnets_value(section)))
            return true;
    }

    return false;
}

function sing_box_signature_enabled_action_index(sections, target_section, action) {
    let result = 0;
    target_section = as_string(target_section);
    action = as_string(action);

    for (let section in sections) {
        section = object_or_empty(section);
        if (section_name(section) == "" ||
            !bool_option(section, "enabled", true) ||
            option(section, "action", "") != action)
            continue;

        result++;
        if (section_name(section) == target_section)
            return result;
    }

    return 0;
}

function signature_add_mixed_proxy_body(body, section, prefix) {
    let mixed_proxy_enabled = bool_option_value(section, "mixed_proxy_enabled", false);
    body = signature_add_value(body, prefix + ".mixed_proxy_enabled", mixed_proxy_enabled);

    if (mixed_proxy_enabled == "1") {
        body = signature_add_value(body, prefix + ".mixed_proxy_port", option(section, "mixed_proxy_port", ""));
        let auth_enabled = bool_option_value(section, "mixed_proxy_auth_enabled", false);
        body = signature_add_value(body, prefix + ".mixed_proxy_auth_enabled", auth_enabled);
        if (auth_enabled == "1") {
            body = signature_add_value(body, prefix + ".mixed_proxy_username", option(section, "mixed_proxy_username", ""));
            body = signature_add_value(body, prefix + ".mixed_proxy_password", option(section, "mixed_proxy_password", ""));
        }
    }

    return body;
}

function signature_add_outbound_detour_body(body, section, prefix) {
    let outbound_detour_enabled = bool_option_value(section, "outbound_detour_enabled", false);
    body = signature_add_value(body, prefix + ".outbound_detour_enabled", outbound_detour_enabled);

    if (outbound_detour_enabled == "1")
        body = signature_add_value(body, prefix + ".outbound_detour_section", option(section, "outbound_detour_section", ""));

    return body;
}

function append_sing_box_rule_signature_body(body, section, sections) {
    section = object_or_empty(section);
    let name = section_name(section);
    if (name == "" || !bool_option(section, "enabled", true))
        return body;

    let action = option(section, "action", "");
    if (action == "")
        return body;

    let prefix = "rule." + name;
    body = signature_add_value(body, prefix + ".action", action);

    if (connections.is_connections_action(action)) {
        body = signature_add_value(body, prefix + ".connection_urls", connection_urls_signature(section));
        body = signature_add_value(body, prefix + ".subscription_urls", subscription_urls_signature(section));
        body = signature_add_value(body, prefix + ".interfaces", interfaces_signature(section));
        body = signature_add_value(body, prefix + ".outbound_jsons", option(section, "outbound_jsons", ""));
        body = signature_add_value(body, prefix + ".legacy_interface", option(section, "interface", ""));
        body = signature_add_value(body, prefix + ".legacy_outbound_json", option(section, "outbound_json", ""));
        body = signature_add_value(body, prefix + ".urltests", urltests_signature(section));
        body = signature_add_value(body, prefix + ".priority_groups", priority_groups_signature(section));
        body = signature_add_value(body, prefix + ".urltest_enabled", bool_option_value(section, "urltest_enabled", false));
        body = signature_add_value(body, prefix + ".detect_server_country", normalize_detect_server_country_method(option(section, "detect_server_country", "flag_emoji")));
        body = signature_add_value(body, prefix + ".urltest_check_interval", section_urltest_check_interval(section));
        body = signature_add_value(body, prefix + ".urltest_tolerance", option(section, "urltest_tolerance", "50"));
        body = signature_add_value(body, prefix + ".urltest_testing_url", option(section, "urltest_testing_url", "https://www.gstatic.com/generate_204"));
        body = signature_add_value(body, prefix + ".urltest_filter_mode", option(section, "urltest_filter_mode", "disabled"));
        body = signature_add_value(body, prefix + ".urltest_exclude_countries", option(section, "urltest_exclude_countries", ""));
        body = signature_add_value(body, prefix + ".urltest_include_countries", option(section, "urltest_include_countries", ""));
        body = signature_add_value(body, prefix + ".urltest_exclude_outbounds", option(section, "urltest_exclude_outbounds", ""));
        body = signature_add_value(body, prefix + ".urltest_exclude_regex", option(section, "urltest_exclude_regex", ""));
        body = signature_add_value(body, prefix + ".urltest_include_outbounds", option(section, "urltest_include_outbounds", ""));
        body = signature_add_value(body, prefix + ".urltest_include_regex", option(section, "urltest_include_regex", ""));
        body = signature_add_value(body, prefix + ".subscription_update_interval", section_subscription_update_interval(section));
        body = signature_add_outbound_detour_body(body, section, prefix);
        body = signature_add_mixed_proxy_body(body, section, prefix);
        body = signature_add_value(body, prefix + ".resolve_real_ip_for_routing", bool_option_value(section, "resolve_real_ip_for_routing", false));
    }
    else if (action == "byedpi") {
        body = signature_add_value(body, prefix + ".byedpi_index", sing_box_signature_enabled_action_index(sections, name, "byedpi"));
        body = signature_add_mixed_proxy_body(body, section, prefix);
        body = signature_add_value(body, prefix + ".resolve_real_ip_for_routing", "1");
    }
    else if (action == "zapret" || action == "zapret2") {
        body = signature_add_mixed_proxy_body(body, section, prefix);
    }
    else if (action == "dns") {
        body = signature_add_value(body, prefix + ".dns_type", option(section, "dns_type", "udp"));
        body = signature_add_value(body, prefix + ".dns_server", option(section, "dns_server", ""));
        body = signature_add_value(body, prefix + ".dns_detour_enabled", bool_option_value(section, "dns_detour_enabled", false));
        if (bool_option(section, "dns_detour_enabled", false))
            body = signature_add_value(body, prefix + ".dns_detour_section", option(section, "dns_detour_section", ""));
    }

    body = signature_add_value(body, prefix + ".domain", section_rule_condition_csv(section, "domain", "domains"));
    body = signature_add_value(body, prefix + ".domain_suffix", section_rule_condition_csv(section, "domain_suffix", "domains"));
    body = signature_add_value(body, prefix + ".domain_keyword", section_rule_condition_csv(section, "domain_keyword", "generic"));
    body = signature_add_value(body, prefix + ".domain_regex", section_rule_condition_csv(section, "domain_regex", "generic"));
    if (action != "dns") {
        body = signature_add_value(body, prefix + ".ip_cidr", section_rule_condition_csv(section, "ip_cidr", "subnets"));
        body = signature_add_value(body, prefix + ".source_ip_cidr", section_rule_condition_csv(section, "source_ip_cidr", "subnets"));
        body = signature_add_value(body, prefix + ".ports", section_rule_ports_csv(section));
        body = signature_add_value(body, prefix + ".fully_routed_ips", option(section, "fully_routed_ips", ""));
    }
    body = signature_add_value(body, prefix + ".community_lists", connections.community_lists_value(section));
    body = signature_add_value(body, prefix + ".rule_set", connections.rule_sets_value(section));
    if (action != "dns")
        body = signature_add_value(body, prefix + ".rule_set_with_subnets", connections.rule_sets_with_subnets_value(section));
    body = signature_add_value(body, prefix + ".domain_ip_lists", option(section, "domain_ip_lists", ""));

    return body;
}

function append_sing_box_server_signature_body(body, server) {
    server = object_or_empty(server);
    let name = section_name(server);
    if (name == "")
        return body;

    let prefix = "server." + name;
    let enabled = bool_option_value(server, "enabled", false);
    body = signature_add_value(body, prefix + ".enabled", enabled);
    if (enabled != "1")
        return body;

    if (option(server, "protocol", "vless") == "socks")
        body = signature_add_value(body, prefix + ".socks_auth_enabled", bool_option_value(server, "socks_auth_enabled", true));

    let fields = [
        [ "label", name ],
        [ "protocol", "vless" ],
        [ "listen", "0.0.0.0" ],
        [ "listen_port", "" ],
        [ "public_host", "" ],
        [ "inbound_json", "" ],
        [ "routing_mode", "rules" ],
        [ "routing_section", "" ],
        [ "security", "reality" ],
        [ "server_users", "" ],
        [ "tls_server_name", "" ],
        [ "tls_alpn", "" ],
        [ "tls_certificate_path", "" ],
        [ "tls_key_path", "" ],
        [ "reality_handshake_server", "" ],
        [ "reality_handshake_server_port", "" ],
        [ "reality_private_key", "" ],
        [ "reality_public_key", "" ],
        [ "reality_short_id", "" ],
        [ "reality_max_time_difference", "" ],
        [ "transport", "tcp" ],
        [ "transport_path", "" ],
        [ "transport_host", "" ],
        [ "transport_service_name", "" ],
        [ "transport_hosts", "" ],
        [ "transport_xhttp_mode", "" ],
        [ "client_fingerprint", "" ],
        [ "server_uuid", "" ],
        [ "server_username", "" ],
        [ "server_password", "" ],
        [ "vless_flow", "" ],
        [ "vmess_alter_id", "" ],
        [ "shadowsocks_method", "" ],
        [ "hysteria2_up_mbps", "" ],
        [ "hysteria2_down_mbps", "" ],
        [ "hysteria2_obfs_type", "" ],
        [ "hysteria2_obfs_password", "" ],
        [ "mtproto_secret", "" ],
        [ "mtproto_faketls", "" ],
        [ "mtproto_padding", "" ],
        [ "mtproto_concurrency", "" ],
        [ "mtproto_domain_fronting_port", "" ],
        [ "mtproto_domain_fronting_ip", "" ],
        [ "mtproto_domain_fronting_proxy_protocol", "" ],
        [ "mtproto_prefer_ip", "" ],
        [ "mtproto_auto_update", "" ],
        [ "mtproto_allow_fallback_on_unknown_dc", "" ],
        [ "mtproto_tolerate_time_skewness", "" ],
        [ "mtproto_idle_timeout", "" ],
        [ "mtproto_handshake_timeout", "" ],
        [ "tailscale_auth_key", "" ],
        [ "tailscale_control_url", "" ],
        [ "tailscale_hostname", "" ],
        [ "tailscale_accept_routes", "" ],
        [ "tailscale_advertise_routes", "" ],
        [ "tailscale_advertise_exit_node", "" ]
    ];

    for (let field in fields)
        body = signature_add_value(body, prefix + "." + field[0], option(server, field[0], field[1]));

    return body;
}

function sing_box_signature_body(settings, sections, servers, mwan3_active) {
    settings = object_or_empty(settings);
    let body = "";

    body = signature_add_value(body, "settings.dns_type", option(settings, "dns_type", "doh"));
    body = signature_add_value(body, "settings.dns_strategy", option(settings, "dns_strategy", "prefer_ipv4"));
    for (let value in list_option(settings, "dns_server", "77.88.8.8"))
        body = signature_add_value(body, "settings.dns_server", value);
    for (let value in list_option(settings, "bootstrap_dns_server", "77.88.8.8"))
        body = signature_add_value(body, "settings.bootstrap_dns_server", value);
    body = signature_add_value(body, "settings.dns_check_interval", option(settings, "dns_check_interval", "10s"));
    body = signature_add_value(body, "settings.dns_recovery_check_interval", option(settings, "dns_recovery_check_interval", "60s"));
    body = signature_add_value(body, "settings.dns_check_timeout", option(settings, "dns_check_timeout", "2s"));
    let dns_detour_enabled = bool_option_value(settings, "dns_detour_enabled", false);
    body = signature_add_value(body, "settings.dns_detour_enabled", dns_detour_enabled);
    if (dns_detour_enabled == "1")
        body = signature_add_value(body, "settings.dns_detour_section", option(settings, "dns_detour_section", ""));
    body = signature_add_value(body, "settings.dns_rewrite_ttl", option(settings, "dns_rewrite_ttl", "60"));
    body = signature_add_value(body, "settings.output_network_interface", option(settings, "output_network_interface", ""));
    body = signature_add_value(body, "settings.disable_quic", bool_option_value(settings, "disable_quic", false));
    if (sing_box_signature_has_remote_ruleset_sources(sections))
        body = signature_add_value(body, "settings.update_interval", settings_update_interval(settings));
    body = signature_add_value(body, "settings.cache_path", option(settings, "cache_path", "/tmp/sing-box/cache.db"));
    body = signature_add_value(body, "settings.config_path", option(settings, "config_path", ""));
    body = signature_add_value(body, "settings.log_level", option(settings, "log_level", "warn"));
    body = signature_add_value(body, "settings.service_listen_address", option(settings, "service_listen_address", ""));
    body = signature_add_value(body, "runtime.mwan3_active", bool_value(mwan3_active));

    let enable_yacd = bool_option_value(settings, "enable_yacd", false);
    body = signature_add_value(body, "settings.enable_yacd", enable_yacd);
    if (enable_yacd == "1") {
        body = signature_add_value(body, "settings.enable_yacd_wan_access", bool_option_value(settings, "enable_yacd_wan_access", false));
        body = signature_add_value(body, "settings.yacd_secret_key", option(settings, "yacd_secret_key", ""));
    }

    body = signature_add_value(body, "settings.download_lists_via_proxy", bool_option_value(settings, "download_lists_via_proxy", false));
    body = signature_add_value(body, "settings.download_components_via_proxy", bool_option_value(settings, "download_components_via_proxy", false));
    if (download_via_proxy_enabled(settings, "lists"))
        body = signature_add_value(body, "settings.download_lists_via_proxy_section", option(settings, "download_lists_via_proxy_section", ""));
    if (download_via_proxy_enabled(settings, "components"))
        body = signature_add_value(body, "settings.download_components_via_proxy_section", option(settings, "download_components_via_proxy_section", ""));

    for (let section in sections)
        body = append_sing_box_rule_signature_body(body, object_or_empty(section), sections);

    for (let server in servers)
        body = append_sing_box_server_signature_body(body, object_or_empty(server));

    return body;
}

function section_action_is_enabled(section, action) {
    return section_name(section) != "" &&
        bool_option(section, "enabled", true) &&
        option(section, "action", "") == as_string(action);
}

function action_queue_signature_body(sections, action, signature_key) {
    let body = "";

    for (let section in sections) {
        section = object_or_empty(section);
        if (section_action_is_enabled(section, action))
            body = signature_add_value(body, signature_key, section_name(section));
    }

    return body;
}

function section_user_domains_for_list_type(section) {
    let list_type = option(section, "user_domain_list_type", "disabled");

    if (list_type == "dynamic")
        return option(section, "user_domains", "");
    if (list_type == "text")
        return option(section, "user_domains_text", "");
    return "";
}

function append_zapret_runtime_signature_body(body, section, signature_prefix, opt_key, normalized_opt) {
    let name = section_name(section);
    let user_domain_list_type = option(section, "user_domain_list_type", "disabled");

    body = signature_add_value(body, signature_prefix + "." + name + "." + opt_key, normalized_opt);
    body = signature_add_value(body, signature_prefix + "." + name + ".domain", section_rule_condition_csv(section, "domain", "domains"));
    body = signature_add_value(body, signature_prefix + "." + name + ".domain_suffix", section_rule_condition_csv(section, "domain_suffix", "domains"));
    body = signature_add_value(body, signature_prefix + "." + name + ".community_lists", connections.community_lists_value(section));
    body = signature_add_value(body, signature_prefix + "." + name + ".rule_set", connections.rule_sets_value(section));
    body = signature_add_value(body, signature_prefix + "." + name + ".rule_set_with_subnets", connections.rule_sets_with_subnets_value(section));
    body = signature_add_value(body, signature_prefix + "." + name + ".domain_ip_lists", option(section, "domain_ip_lists", ""));
    body = signature_add_value(body, signature_prefix + "." + name + ".user_domain_list_type", user_domain_list_type);
    body = signature_add_value(body, signature_prefix + "." + name + ".local_domain_lists", option(section, "local_domain_lists", ""));
    body = signature_add_value(body, signature_prefix + "." + name + ".remote_domain_lists", option(section, "remote_domain_lists", ""));
    body = signature_add_value(body, signature_prefix + "." + name + ".user_domains", section_user_domains_for_list_type(section));

    return body;
}

function zapret_runtime_signature_body(sections) {
    let body = "";

    for (let section in sections) {
        section = object_or_empty(section);
        if (!section_action_is_enabled(section, "zapret"))
            continue;

        body = append_zapret_runtime_signature_body(
        body,
        section,
        "zapret",
        "nfqws_opt",
            zapret_validator.strategy_or_default(option(section, "nfqws_opt", ""), ZAPRET_DEFAULT_NFQWS_OPT)
        );
    }

    return body;
}

function zapret2_runtime_signature_body(sections) {
    let body = "";

    for (let section in sections) {
        section = object_or_empty(section);
        if (!section_action_is_enabled(section, "zapret2"))
            continue;

        body = append_zapret_runtime_signature_body(
        body,
        section,
        "zapret2",
        "nfqws2_opt",
            zapret2_validator.strategy_or_default(option(section, "nfqws2_opt", ""), ZAPRET2_DEFAULT_NFQWS2_OPT)
        );
    }

    return body;
}

function enabled_action_index(sections, target_section, action) {
    let result = 0;
    target_section = as_string(target_section);
    action = as_string(action);

    for (let section in sections) {
        section = object_or_empty(section);
        if (!section_action_is_enabled(section, action))
            continue;

        result++;
        if (section_name(section) == target_section)
            return result;
    }

    return 0;
}

function byedpi_runtime_signature_body(sections) {
    let body = "";

    for (let section in sections) {
        section = object_or_empty(section);
        if (!section_action_is_enabled(section, "byedpi"))
            continue;

        let name = section_name(section);
        body = signature_add_value(body, "byedpi." + name + ".index", enabled_action_index(sections, name, "byedpi"));
        body = signature_add_value(body, "byedpi." + name + ".byedpi_cmd_opts", byedpi_validator.strategy_or_default(option(section, "byedpi_cmd_opts", ""), BYEDPI_DEFAULT_CMD_OPTS));
    }

    return body;
}

function reload_state_values_from_sources(format, settings, sections, servers, dnsmasq, legacy_dnsmasq_present, mwan3_active_value) {
    return {
        format: as_string(format),
        service_trigger_signature: signature_hash(service_trigger_signature_body(settings)),
        dnsmasq_signature: signature_hash(dnsmasq_signature_body(settings, dnsmasq, legacy_dnsmasq_present)),
        sing_box_signature: signature_hash(sing_box_signature_body(settings, sections, servers, mwan3_active_value)),
        nft_signature: signature_hash(nft_runtime_signature_body(settings, sections)),
        zapret_queue_signature: signature_hash(action_queue_signature_body(sections, "zapret", "zapret_queue.section")),
        zapret_runtime_signature: signature_hash(zapret_runtime_signature_body(sections)),
        zapret2_queue_signature: signature_hash(action_queue_signature_body(sections, "zapret2", "zapret2_queue.section")),
        zapret2_runtime_signature: signature_hash(zapret2_runtime_signature_body(sections)),
        byedpi_runtime_signature: signature_hash(byedpi_runtime_signature_body(sections)),
        list_signature: signature_hash(list_update_signature_body(sections)),
        cron_signature: signature_hash(cron_signature_body(settings, sections)),
        urltest_enabled_sections: urltest_enabled_sections_value(sections),
        dont_touch_dhcp: dont_touch_dhcp_value(settings)
    };
}

function fixture_section_list(data, type_name) {
    type_name = as_string(type_name || "section");
    let value = object_or_empty(data)[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = object_or_empty(data)[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function uci_sections(type_name) {
    return uci_core.section_objects(CONFIG_NAME, type_name);
}

function uci_servers() {
    return uci_sections("server");
}

function mwan3_has_enabled_interface() {
    for (let section in uci_core.section_objects("mwan3", "interface"))
        if (option(section, "enabled", "0") == "1")
            return true;

    return false;
}

function mwan3_active() {
    if (!command_success_from_args([ "test", "-x", "/etc/init.d/mwan3" ]))
        return false;
    if (!command_success_from_args([ "test", "-s", "/etc/config/mwan3" ]))
        return false;
    if (!mwan3_has_enabled_interface())
        return false;

    return command_success_from_args([ "/etc/init.d/mwan3", "status" ]) ||
        command_success_from_args([ "/etc/init.d/mwan3", "enabled" ]);
}

function has_remote_sing_box_ruleset_sources_from_sections(sections) {
    for (let section in sections) {
        if (!bool_option(section, "enabled", true))
            continue;

        if (length(connections.community_lists(section)) > 0 ||
            list_has_remote_references(connections.rule_sets_value(section)) ||
            list_has_remote_references(connections.rule_sets_with_subnets_value(section)))
            return true;
    }

    return false;
}

function has_list_update_sources_from_sections(sections) {
    for (let section in sections)
        if (rule_has_list_update_source(
            bool_option(section, "enabled", true),
            option(section, "action", ""),
            connections.community_lists_value(section),
            option(section, "remote_domain_lists", ""),
            option(section, "remote_subnet_lists", ""),
            connections.rule_sets_with_subnets_value(section),
            option(section, "domain_ip_lists", "")
        ))
            return true;

    return false;
}

function has_nft_list_update_sources_from_sections(sections) {
    for (let section in sections)
        if (rule_has_nft_list_update_source(
            bool_option(section, "enabled", true),
            option(section, "action", ""),
            connections.community_lists_value(section),
            option(section, "remote_subnet_lists", ""),
            connections.rule_sets_with_subnets_value(section),
            option(section, "domain_ip_lists", "")
        ))
            return true;

    return false;
}

function has_subscription_update_sources_from_sections(sections) {
    for (let section in sections) {
        section = object_or_empty(section);
        if (section_is_subscription_proxy(section) && section_subscription_update_interval(section) != "")
            return true;
    }

    return false;
}

function fixture_sections(path) {
    let data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(data);
    return fixture_section_list(data);
}

function fixture_servers(data) {
    return fixture_section_list(data, "server");
}

function fixture_data(path) {
    let data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(data);
    return data;
}

function fixture_settings(data) {
    return object_or_empty(object_or_empty(data).settings);
}

function fixture_dnsmasq(data) {
    return object_or_empty(object_or_empty(data).dhcp_dnsmasq);
}

function fixture_legacy_dnsmasq_present(data) {
    return object_or_empty(data).legacy_dnsmasq_present;
}

function fixture_mwan3_active(data) {
    return arg_bool(object_or_empty(object_or_empty(data).runtime).mwan3_active);
}

function uci_settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function uci_section(section_name) {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, section_name));
}

function uci_dnsmasq() {
    return {
        server: uci_get("dhcp.@dnsmasq[0].server"),
        noresolv: uci_get("dhcp.@dnsmasq[0].noresolv"),
        cachesize: uci_get("dhcp.@dnsmasq[0].cachesize"),
        forkop_server: uci_get("dhcp.@dnsmasq[0].forkop_server"),
        forkop_noresolv: uci_get("dhcp.@dnsmasq[0].forkop_noresolv"),
        forkop_cachesize: uci_get("dhcp.@dnsmasq[0].forkop_cachesize")
    };
}

function current_reload_state_values(format) {
    let settings = uci_settings();
    let sections = uci_sections("section");

    return reload_state_values_from_sources(
        format,
        settings,
        sections,
        uci_servers(),
        uci_dnsmasq(),
        uci_exists("dhcp.forkop"),
        mwan3_active()
    );
}

function capture_reload_state(path, format) {
    write_reload_state(path, current_reload_state_values(format || "1"));
}

function write_current_reload_state_clean(path, format, cache_dir) {
    write_reload_state(path, current_reload_state_values(format || "1"));
    cleanup_rule_condition_cache(cache_dir);
    cleanup_reload_state_snapshots(path);
}

function write_captured_reload_state(path, snapshot_path, format, cache_dir, cleanup_cache, clear_snapshot) {
    snapshot_path = as_string(snapshot_path);
    if (snapshot_path == "") {
        if (as_string(cleanup_cache) == "1")
            write_current_reload_state_clean(path, format, cache_dir);
        else
            write_reload_state(path, current_reload_state_values(format || "1"));
        return;
    }

    if (fs.stat(snapshot_path) == null)
        capture_reload_state(snapshot_path, format || "1");

    if (!copy_file(snapshot_path, path))
        exit(1);

    if (as_string(cleanup_cache) == "1")
        cleanup_rule_condition_cache(cache_dir);
    if (as_string(clear_snapshot) == "1")
        unlink_file(snapshot_path);
}

function fixture_reload_state_values(data, format) {
    data = object_or_empty(data);
    let settings = fixture_settings(data);
    let sections = fixture_section_list(data);

    return reload_state_values_from_sources(
        format,
        settings,
        sections,
        fixture_servers(data),
        fixture_dnsmasq(data),
        fixture_legacy_dnsmasq_present(data),
        fixture_mwan3_active(data)
    );
}

let mode = ARGV[0];

if (mode == "file-first-line")
    file_first_line(ARGV[1]);
else if (mode == "get")
    read_state_value(ARGV[1], ARGV[2]);
else if (mode == "has-key")
    exit(state_has_key(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "time-sync-needed")
    exit(time_sync_needed(ARGV[1]) ? 0 : 1);
else if (mode == "sync-time-if-needed")
    sync_time_if_needed();
else if (mode == "mark-pending-reload")
    mark_pending_reload(ARGV[1], ARGV[2]);
else if (mode == "consume-pending-reload")
    exit(consume_pending_reload(ARGV[1]) ? 0 : 1);
else if (mode == "run-pending-reload-if-requested")
    run_pending_reload_if_requested(ARGV[1], ARGV[2]);
else if (mode == "acquire-runtime-dir-lock")
    exit(acquire_runtime_dir_lock(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "acquire-runtime-dir-lock-wait")
    exit(acquire_runtime_dir_lock_wait(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "release-runtime-dir-lock")
    release_runtime_dir_lock(ARGV[1]);
else if (mode == "reload-sing-box-runtime")
    reload_sing_box_runtime(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "hup-sing-box-runtime")
    hup_sing_box_runtime();
else if (mode == "clear-reload-state")
    clear_reload_state(ARGV[1], ARGV[2]);
else if (mode == "remove-file")
    remove_file(ARGV[1]);
else if (mode == "capture-reload-state")
    capture_reload_state(ARGV[1], ARGV[2] || "1");
else if (mode == "write-current-reload-state-clean")
    write_current_reload_state_clean(ARGV[1], ARGV[2] || "1", ARGV[3]);
else if (mode == "write-captured-reload-state")
    write_captured_reload_state(ARGV[1], ARGV[2], ARGV[3] || "1", ARGV[4], ARGV[5], ARGV[6]);
else if (mode == "write-reload-state")
    write_reload_state(ARGV[1], reload_state_values_from_args(2));
else if (mode == "write-current-reload-state")
    write_reload_state(ARGV[1], current_reload_state_values(ARGV[2] || "1"));
else if (mode == "reload-state-text-fixture") {
    let data = fixture_data(ARGV[1]);
    print(reload_state_text(fixture_reload_state_values(data, ARGV[2] || "1")));
}
else if (mode == "response-success")
    exit(response_success() ? 0 : 1);
else if (mode == "stdin-first-field")
    stdin_first_field();
else if (mode == "sing-box-service-pid")
    sing_box_service_pid();
else if (mode == "sing-box-service-runtime-pid") {
    let pid = sing_box_service_pid_runtime();
    if (pid <= 0)
        exit(1);
    print(pid, "\n");
}
else if (mode == "sing-box-service-running")
    exit(sing_box_service_running() ? 0 : 1);
else if (mode == "sing-box-service-stable")
    exit(sing_box_service_stable(ARGV[1]) ? 0 : 1);
else if (mode == "sing-box-pid-replaced-fixture")
    exit(sing_box_pid_replaced(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "sing-box-reload-previous-pid-fixture")
    print(sing_box_reload_previous_pid(ARGV[1], ARGV[2], ARGV[3]), "\n");
else if (mode == "forkop-running")
    exit(forkop_running(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "forkop-stably-running")
    exit(forkop_stably_running(ARGV[1], ARGV[2], ARGV[3], ARGV[4]) ? 0 : 1);
else if (mode == "wait-forkop-stable-start")
    exit(wait_forkop_stable_start(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]) ? 0 : 1);
else if (mode == "list-has-remote-references" || mode == "list-has-remote-sing-box-rulesets")
    exit(list_has_remote_references(ARGV[1]) ? 0 : 1);
else if (mode == "community-service-has-subnet-list")
    exit(community_service_has_subnet_list(ARGV[1]) ? 0 : 1);
else if (mode == "filter-community-subnet-lists")
    filter_community_subnet_lists(ARGV[1]);
else if (mode == "rule-has-list-update-source")
    exit(rule_has_list_update_source(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]) ? 0 : 1);
else if (mode == "rule-has-nft-list-update-source")
    exit(rule_has_nft_list_update_source(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]) ? 0 : 1);
else if (mode == "rule-has-subscription-update-source")
    exit(rule_has_subscription_update_source(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "service-trigger-signature")
    exit(print_signature_hash(service_trigger_signature_body(uci_settings())) ? 0 : 1);
else if (mode == "service-trigger-signature-fixture") {
    let data = fixture_data(ARGV[1]);
    exit(print_signature_hash(service_trigger_signature_body(fixture_settings(data))) ? 0 : 1);
}
else if (mode == "dnsmasq-signature")
    exit(print_signature_hash(dnsmasq_signature_body(uci_settings(), uci_dnsmasq(), uci_exists("dhcp.forkop"))) ? 0 : 1);
else if (mode == "dnsmasq-signature-fixture") {
    let data = fixture_data(ARGV[1]);
    exit(print_signature_hash(dnsmasq_signature_body(fixture_settings(data), fixture_dnsmasq(data), fixture_legacy_dnsmasq_present(data))) ? 0 : 1);
}
else if (mode == "sing-box-signature")
    exit(print_signature_hash(sing_box_signature_body(uci_settings(), uci_sections("section"), uci_servers(), mwan3_active())) ? 0 : 1);
else if (mode == "sing-box-signature-fixture") {
    let data = fixture_data(ARGV[1]);
    exit(print_signature_hash(sing_box_signature_body(fixture_settings(data), fixture_section_list(data), fixture_servers(data), fixture_mwan3_active(data))) ? 0 : 1);
}
else if (mode == "sing-box-signature-body-fixture") {
    let data = fixture_data(ARGV[1]);
    print(sing_box_signature_body(fixture_settings(data), fixture_section_list(data), fixture_servers(data), fixture_mwan3_active(data)));
}
else if (mode == "nft-signature")
    exit(print_signature_hash(nft_runtime_signature_body(uci_settings(), uci_sections("section"))) ? 0 : 1);
else if (mode == "nft-signature-fixture") {
    let data = fixture_data(ARGV[1]);
    exit(print_signature_hash(nft_runtime_signature_body(fixture_settings(data), fixture_section_list(data))) ? 0 : 1);
}
else if (mode == "zapret-queue-signature")
    exit(print_signature_hash(action_queue_signature_body(uci_sections("section"), "zapret", "zapret_queue.section")) ? 0 : 1);
else if (mode == "zapret-queue-signature-fixture") {
    let data = fixture_data(ARGV[1]);
    exit(print_signature_hash(action_queue_signature_body(fixture_section_list(data), "zapret", "zapret_queue.section")) ? 0 : 1);
}
else if (mode == "zapret-runtime-signature")
    exit(print_signature_hash(zapret_runtime_signature_body(uci_sections("section"))) ? 0 : 1);
else if (mode == "zapret-runtime-signature-fixture") {
    let data = fixture_data(ARGV[1]);
    exit(print_signature_hash(zapret_runtime_signature_body(fixture_section_list(data))) ? 0 : 1);
}
else if (mode == "zapret2-queue-signature")
    exit(print_signature_hash(action_queue_signature_body(uci_sections("section"), "zapret2", "zapret2_queue.section")) ? 0 : 1);
else if (mode == "zapret2-queue-signature-fixture") {
    let data = fixture_data(ARGV[1]);
    exit(print_signature_hash(action_queue_signature_body(fixture_section_list(data), "zapret2", "zapret2_queue.section")) ? 0 : 1);
}
else if (mode == "zapret2-runtime-signature")
    exit(print_signature_hash(zapret2_runtime_signature_body(uci_sections("section"))) ? 0 : 1);
else if (mode == "zapret2-runtime-signature-fixture") {
    let data = fixture_data(ARGV[1]);
    exit(print_signature_hash(zapret2_runtime_signature_body(fixture_section_list(data))) ? 0 : 1);
}
else if (mode == "byedpi-runtime-signature")
    exit(print_signature_hash(byedpi_runtime_signature_body(uci_sections("section"))) ? 0 : 1);
else if (mode == "byedpi-runtime-signature-fixture") {
    let data = fixture_data(ARGV[1]);
    exit(print_signature_hash(byedpi_runtime_signature_body(fixture_section_list(data))) ? 0 : 1);
}
else if (mode == "dont-touch-dhcp")
    print(dont_touch_dhcp_value(uci_settings()), "\n");
else if (mode == "dont-touch-dhcp-fixture") {
    let data = fixture_data(ARGV[1]);
    print(dont_touch_dhcp_value(fixture_settings(data)), "\n");
}
else if (mode == "settings-update-interval")
    print(settings_update_interval(uci_settings()), "\n");
else if (mode == "settings-update-interval-fixture") {
    let data = fixture_data(ARGV[1]);
    print(settings_update_interval(fixture_settings(data)), "\n");
}
else if (mode == "remote-ruleset-update-interval") {
    let update_interval = settings_update_interval(uci_settings());
    print(update_interval != "" ? update_interval : as_string(ARGV[1]), "\n");
}
else if (mode == "subscription-update-interval")
    print(section_subscription_update_interval(uci_section(ARGV[1])), "\n");
else if (mode == "subscription-update-interval-fixture") {
    let data = fixture_data(ARGV[1]);
    let sections = fixture_section_list(data);
    let name = as_string(ARGV[2]);
    for (let section in sections) {
        section = object_or_empty(section);
        if (section_name(section) == name) {
            print(section_subscription_update_interval(section), "\n");
            exit(0);
        }
    }
    print("\n");
}
else if (mode == "urltest-check-interval")
    print(section_urltest_check_interval(uci_section(ARGV[1])), "\n");
else if (mode == "urltest-check-interval-fixture") {
    let data = fixture_data(ARGV[1]);
    let sections = fixture_section_list(data);
    let name = as_string(ARGV[2]);
    for (let section in sections) {
        section = object_or_empty(section);
        if (section_name(section) == name) {
            print(section_urltest_check_interval(section), "\n");
            exit(0);
        }
    }
    print("\n");
}
else if (mode == "list-update-signature")
    exit(print_signature_hash(list_update_signature_body(uci_sections("section"))) ? 0 : 1);
else if (mode == "list-update-signature-fixture") {
    let data = fixture_data(ARGV[1]);
    exit(print_signature_hash(list_update_signature_body(fixture_section_list(data))) ? 0 : 1);
}
else if (mode == "cron-signature")
    exit(print_signature_hash(cron_signature_body(uci_settings(), uci_sections("section"))) ? 0 : 1);
else if (mode == "cron-signature-fixture") {
    let data = fixture_data(ARGV[1]);
    exit(print_signature_hash(cron_signature_body(fixture_settings(data), fixture_section_list(data))) ? 0 : 1);
}
else if (mode == "cron-signature-body-fixture") {
    let data = fixture_data(ARGV[1]);
    print(cron_signature_body(fixture_settings(data), fixture_section_list(data)));
}
else if (mode == "urltest-enabled-sections")
    print_urltest_enabled_sections(uci_sections("section"));
else if (mode == "urltest-enabled-sections-fixture") {
    let data = fixture_data(ARGV[1]);
    print_urltest_enabled_sections(fixture_section_list(data));
}
else if (mode == "has-remote-sing-box-ruleset-sources")
    exit(has_remote_sing_box_ruleset_sources_from_sections(uci_sections("section")) ? 0 : 1);
else if (mode == "has-remote-sing-box-ruleset-sources-fixture")
    exit(has_remote_sing_box_ruleset_sources_from_sections(fixture_sections(ARGV[1])) ? 0 : 1);
else if (mode == "has-list-update-sources")
    exit(has_list_update_sources_from_sections(uci_sections("section")) ? 0 : 1);
else if (mode == "has-list-update-sources-fixture")
    exit(has_list_update_sources_from_sections(fixture_sections(ARGV[1])) ? 0 : 1);
else if (mode == "has-subscription-update-sources")
    exit(has_subscription_update_sources_from_sections(uci_sections("section")) ? 0 : 1);
else if (mode == "has-subscription-update-sources-fixture")
    exit(has_subscription_update_sources_from_sections(fixture_sections(ARGV[1])) ? 0 : 1);
else if (mode == "has-nft-list-update-sources")
    exit(has_nft_list_update_sources_from_sections(uci_sections("section")) ? 0 : 1);
else if (mode == "has-nft-list-update-sources-fixture")
    exit(has_nft_list_update_sources_from_sections(fixture_sections(ARGV[1])) ? 0 : 1);
else {
    warn("Usage: service/state.uc <operation> ...\n");
    exit(1);
}
