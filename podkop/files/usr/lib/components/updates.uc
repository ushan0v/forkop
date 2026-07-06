#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let connections = require("config.connections");
const CONFIG_NAME = getenv("PODKOP_CONFIG_NAME") || "podkop-plus";
const LIB_DIR = getenv("PODKOP_LIB") || "/usr/lib/podkop-plus";
const BIN_PATH = getenv("PODKOP_BIN") || "/usr/bin/podkop-plus";
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || "/tmp/sing-box";
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || TMP_SING_BOX_FOLDER + "/rulesets";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || TMP_SING_BOX_FOLDER + "/subscriptions";
const RUNTIME_STATE_DIR = getenv("PODKOP_RUNTIME_STATE_DIR") || "/var/run/podkop-plus";
const LIST_UPDATE_STATE_FILE = getenv("PODKOP_LIST_UPDATE_STATE_FILE") || RUNTIME_STATE_DIR + "/list-update.timestamp";
const LIST_UPDATE_PID_FILE = getenv("PODKOP_LIST_UPDATE_PID_FILE") || "/var/run/podkop_list_update.pid";
const SUBSCRIPTION_UPDATE_STATE_DIR = getenv("PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR") || RUNTIME_STATE_DIR + "/subscription-update";
const SUBSCRIPTION_JOB_DIR = getenv("PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR") || "/var/run/podkop-plus/subscription-update-jobs";
const SUBSCRIPTION_UPDATE_LOCK_DIR = getenv("PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR") || RUNTIME_STATE_DIR + "/subscription-update.lock";
const SUBSCRIPTION_LINKS_DIR = getenv("PODKOP_SUBSCRIPTION_LINKS_DIR") || RUNTIME_STATE_DIR + "/subscription-links";
const SUBSCRIPTION_METADATA_DIR = getenv("PODKOP_SUBSCRIPTION_METADATA_DIR") || RUNTIME_STATE_DIR + "/subscription-metadata";
const OUTBOUND_METADATA_DIR = getenv("PODKOP_OUTBOUND_METADATA_DIR") || RUNTIME_STATE_DIR + "/outbound-metadata";
const SECTION_CACHE_DIR = getenv("PODKOP_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const RUNTIME_CACHE_FORMAT_FILE = getenv("PODKOP_RUNTIME_CACHE_FORMAT_FILE") || RUNTIME_STATE_DIR + "/cache-format";
const RUNTIME_CACHE_FORMAT = getenv("PODKOP_RUNTIME_CACHE_FORMAT") || "7";
const PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/podkop-plus/subscription-cache";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const PENDING_RELOAD_FILE = getenv("PODKOP_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const RELOAD_STATE_FILE = getenv("PODKOP_RELOAD_STATE_FILE") || RUNTIME_STATE_DIR + "/reload-state";
const RELOAD_STATE_FORMAT = getenv("PODKOP_RELOAD_STATE_FORMAT") || "1";
const RULE_CONDITION_CACHE_DIR = getenv("PODKOP_RULE_CONDITION_CACHE_DIR") || RUNTIME_STATE_DIR + "/rule-condition-cache";
const RELOAD_LOCK_DIR = getenv("PODKOP_RELOAD_LOCK_DIR") || "/var/run/podkop-plus.reload.lock";
const SERVICE_INIT = getenv("PODKOP_SERVICE_INIT") || "/etc/init.d/podkop-plus";
const COMPONENT_JOB_DIR = getenv("UPDATES_JOB_DIR") || getenv("PODKOP_UI_COMPONENT_ACTION_DIR") || "/var/run/podkop-plus/component-actions";
const COMPONENT_JOB_FINISHED_TTL_MINUTES = getenv("UPDATES_JOB_FINISHED_TTL_MINUTES") || "60";
const COMPONENT_JOB_ORPHAN_OUTPUT_TTL_MINUTES = getenv("UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES") || "60";
const COMPONENT_JOB_STALE_GRACE_SECONDS = getenv("UPDATES_JOB_STALE_GRACE_SECONDS") || getenv("PODKOP_UI_ACTION_STALE_GRACE_SECONDS") || "15";
const SUBSCRIPTION_JOB_FINISHED_TTL_MINUTES = getenv("PODKOP_SUBSCRIPTION_UPDATE_JOB_FINISHED_TTL_MINUTES") || "60";
const SUBSCRIPTION_JOB_ORPHAN_OUTPUT_TTL_MINUTES = getenv("PODKOP_SUBSCRIPTION_UPDATE_JOB_ORPHAN_OUTPUT_TTL_MINUTES") || "60";
const SUBSCRIPTION_JOB_STALE_GRACE_SECONDS = getenv("PODKOP_UI_ACTION_STALE_GRACE_SECONDS") || "15";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || "PodkopPlusTable";
const NFT_COMMON_SET_NAME = getenv("NFT_COMMON_SET_NAME") || "podkop_plus_subnets";
const NFT_COMMON6_SET_NAME = getenv("NFT_COMMON6_SET_NAME") || "podkop_plus_subnets6";
const NFT_IP_PORT_SET_NAME = getenv("NFT_IP_PORT_SET_NAME") || "podkop_plus_ip_ports";
const NFT_IP_PORT6_SET_NAME = getenv("NFT_IP_PORT6_SET_NAME") || "podkop_plus_ip6_ports";
const NFT_DISCORD_SET_NAME = getenv("NFT_DISCORD_SET_NAME") || "podkop_plus_discord_subnets";
const NFT_DISCORD6_SET_NAME = getenv("NFT_DISCORD6_SET_NAME") || "podkop_plus_discord_subnets6";
const NFT_INTERFACE_SET_NAME = getenv("NFT_INTERFACE_SET_NAME") || "podkop_plus_interfaces";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || "0x00100000";
const SB_SERVICE_MIXED_INBOUND_ADDRESS = getenv("SB_SERVICE_MIXED_INBOUND_ADDRESS") || "127.0.0.1";
const SB_SERVICE_MIXED_INBOUND_PORT = getenv("SB_SERVICE_MIXED_INBOUND_PORT") || "4534";
const SB_VARIANT_STATE_FILE = getenv("SB_VARIANT_STATE_FILE") || "/etc/podkop-plus/sing-box-variant";
const GITHUB_RAW_URL = getenv("GITHUB_RAW_URL") || "https://raw.githubusercontent.com/itdoginfo/allow-domains/main";
const BUILTIN_SUBNET_URLS = {
    twitter: getenv("SUBNETS_TWITTER") || GITHUB_RAW_URL + "/Subnets/IPv4/twitter.lst",
    meta: getenv("SUBNETS_META") || GITHUB_RAW_URL + "/Subnets/IPv4/meta.lst",
    discord: getenv("SUBNETS_DISCORD") || GITHUB_RAW_URL + "/Subnets/IPv4/discord.lst",
    roblox: getenv("SUBNETS_ROBLOX") || GITHUB_RAW_URL + "/Subnets/IPv4/roblox.lst",
    telegram: getenv("SUBNETS_TELERAM") || GITHUB_RAW_URL + "/Subnets/IPv4/telegram.lst",
    cloudflare: getenv("SUBNETS_CLOUDFLARE") || GITHUB_RAW_URL + "/Subnets/IPv4/cloudflare.lst",
    hetzner: getenv("SUBNETS_HETZNER") || GITHUB_RAW_URL + "/Subnets/IPv4/hetzner.lst",
    ovh: getenv("SUBNETS_OVH") || GITHUB_RAW_URL + "/Subnets/IPv4/ovh.lst",
    digitalocean: getenv("SUBNETS_DIGITALOCEAN") || GITHUB_RAW_URL + "/Subnets/IPv4/digitalocean.lst",
    cloudfront: getenv("SUBNETS_CLOUDFRONT") || GITHUB_RAW_URL + "/Subnets/IPv4/cloudfront.lst"
};
let rule_config = null;
let routing_rulesets_module_value = null;
let singbox_rulesets_module_value = null;

function routing_rulesets_module() {
    if (routing_rulesets_module_value == null)
        routing_rulesets_module_value = require("routing.rulesets");
    return routing_rulesets_module_value;
}

function singbox_rulesets_module() {
    if (singbox_rulesets_module_value == null)
        singbox_rulesets_module_value = require("singbox.rulesets");
    return singbox_rulesets_module_value;
}

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let data = fs.readfile("/dev/stdin");
    return data == null ? "" : data;
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

function command_env(assignments) {
    let parts = [];

    for (let name, value in assignments)
        push(parts, name + "=" + shell_quote(value));

    return join(" ", parts);
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return as_string(data);
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success(command) {
    return command_status(command + " >/dev/null 2>&1") == 0;
}

function command_success_from_args(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function now_seconds() {
    return int(clock()[0]);
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", path ]);
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "podkop-plus", "[" + level + "] " + as_string(message) ]);
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

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function json_text(value) {
    return sprintf("%J", value) + "\n";
}

function write_file(path, value) {
    return fs.writefile(as_string(path), as_string(value)) != null;
}

function write_state_file(path, value) {
    path = as_string(path);
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);

    if (!write_file(tmp_path, json_text(value))) {
        fs.unlink(tmp_path);
        return false;
    }
    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        return false;
    }
    return true;
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function file_first_line(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let newline = index(data, "\n");
    print(newline >= 0 ? substr(data, 0, newline) : data, "\n");
}

function file_first_line_value(path) {
    let data = fs.readfile(path);
    if (data == null)
        return "";

    let newline = index(data, "\n");
    return newline >= 0 ? substr(data, 0, newline) : data;
}

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "true" || value == "1" || value == "yes" || value == "on";
}

function arg_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9-]/))
        return 0;
    return int(value);
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function text_first_chars(value, max_chars) {
    value = as_string(value);
    max_chars = int(max_chars || "0", 10) || 0;
    return max_chars > 0 && length(value) > max_chars ? substr(value, 0, max_chars) : value;
}

function file_last_nonblank_line_value(path, fallback, max_chars) {
    let data = fs.readfile(path);
    let result = "";

    if (data != null) {
        for (let line in split(as_string(data), "\n"))
            if (match(line, /^[[:space:]]*$/) == null)
                result = line;
    }

    if (result == "")
        result = as_string(fallback);

    return text_first_chars(result, max_chars);
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
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

function bool_option(section, key, fallback) {
    let value = object_or_empty(section)[key];
    return value == null ? !!fallback : arg_bool(value);
}

function section_name(section) {
    return as_string(object_or_empty(section)[".name"]);
}

function file_exists_value(path) {
    return fs.stat(as_string(path)) != null;
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && int(stat.size || 0) > 0;
}

function copy_file(source, target) {
    let data = fs.readfile(as_string(source));
    if (data == null)
        return false;
    return write_file(target, data);
}

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, 0, slash) : "";
}

function ensure_parent_dir(path) {
    let dir = parent_dir(path);
    return dir == "" || dir == "." || ensure_dir(dir);
}

function temp_path() {
    return trim(command_output_from_args([ "mktemp" ]));
}

function remove_files(paths) {
    for (let path in paths)
        if (as_string(path) != "")
            remove_file(path);
}

function owner_pid() {
    let pid = trim(command_output_from_args([ "sh", "-c", "echo $PPID" ]));
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function runtime_pid_running(pid) {
    pid = as_string(pid);
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function whitespace_items(value) {
    let result = [];
    if (type(value) == "array") {
        for (let item in value) {
            item = as_string(item);
            if (item != "")
                push(result, item);
        }
        return result;
    }

    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function list_option_values(section, key) {
    return whitespace_items(object_or_empty(section)[key]);
}

function uci_sections(type_name) {
    return uci_core.section_objects(CONFIG_NAME, as_string(type_name));
}

function uci_settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function module_command(args) {
    let command_args = [ "ucode", "-L", LIB_DIR ];
    for (let arg in args)
        push(command_args, arg);
    return command_from_args(command_args);
}

function module_status(args) {
    return command_status(module_command(args));
}

function module_success(args) {
    return module_status(args) == 0;
}

function module_output(args) {
    return command_output(module_command(args));
}

function module_env_status(env, args) {
    return command_status(command_env(env) + " " + module_command(args));
}

function nft_module_success(args) {
    let command_args = [ LIB_DIR + "/nft/apply.uc" ];
    for (let arg in args)
        push(command_args, arg);
    return module_success(command_args);
}

function service_state_success(args) {
    let command_args = [ LIB_DIR + "/service/state.uc" ];
    for (let arg in args)
        push(command_args, arg);
    return module_success(command_args);
}

function acquire_runtime_lock(lock_dir, wait) {
    return service_state_success([
        wait ? "acquire-runtime-dir-lock-wait" : "acquire-runtime-dir-lock",
        lock_dir,
        owner_pid(),
        "300"
    ]);
}

function release_runtime_lock(lock_dir) {
    service_state_success([ "release-runtime-dir-lock", lock_dir ]);
}

function unsigned_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9]/) != null)
        return null;
    return int(value);
}

function update_due_status(now_value, last_run_value, interval_value) {
    let now = unsigned_number(now_value);
    let interval = unsigned_number(interval_value);

    if (now == null || interval == null || interval <= 0)
        return 2;

    let last_run = unsigned_number(last_run_value);
    if (last_run == null)
        last_run = 0;

    if (last_run > 0 && now - last_run < interval)
        return 1;

    return 0;
}

function update_is_due(now_value, last_run_value, interval_value) {
    exit(update_due_status(now_value, last_run_value, interval_value));
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
        total = total + amount * multipliers[unit];
        rest = substr(rest, length(token));
    }

    if (total <= 0)
        return null;

    return int(total + 0.5);
}

function duration_to_seconds(value) {
    let seconds = duration_to_seconds_value(value);
    if (seconds == null)
        exit(1);

    print(seconds, "\n");
}

function due_check_cron_schedule_text(value) {
    let seconds = arg_number(value);

    if (seconds <= 60)
        return "* * * * *";

    if (seconds % 86400 == 0)
        return "0 0 * * *";

    if (seconds % 3600 == 0) {
        let hours = seconds / 3600;
        if (hours >= 1 && hours <= 23)
            return hours == 1 ? "0 * * * *" : "0 */" + hours + " * * *";
    }

    if (seconds % 60 == 0) {
        let minutes = seconds / 60;
        if (minutes >= 1 && minutes <= 59)
            return minutes == 1 ? "* * * * *" : "*/" + minutes + " * * * *";
    }

    return "* * * * *";
}

function due_check_cron_schedule(value) {
    print(due_check_cron_schedule_text(value), "\n");
}

function update_cron_job(interval, command, bin, marker) {
    let seconds = duration_to_seconds_value(interval);
    if (seconds == null)
        exit(1);

    print(due_check_cron_schedule_text(seconds), " ", as_string(bin), " ", as_string(command), " ", as_string(marker), "\n");
}

function subscription_update_cron_job(min_interval_seconds, bin, marker) {
    let seconds = arg_number(min_interval_seconds);
    if (seconds <= 0)
        exit(1);

    print(due_check_cron_schedule_text(seconds), " ", as_string(bin), " subscription_update_if_due ", as_string(marker), "\n");
}

function subscription_update_interval_plan() {
    let min_interval = 0;

    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (line == "")
            continue;

        let separator = index(line, "\t");
        let section = separator >= 0 ? substr(line, 0, separator) : line;
        let interval = separator >= 0 ? substr(line, separator + 1) : "";
        if (interval == "")
            continue;

        let seconds = duration_to_seconds_value(interval);
        if (seconds == null) {
            print("error\t", section, "\t", interval, "\n");
            continue;
        }

        if (min_interval == 0 || seconds < min_interval)
            min_interval = seconds;
    }

    print("min\t", min_interval, "\n");
}

function list_has_remote_references(value) {
    for (let item in split(as_string(value), /[ \t\r\n]+/)) {
        if (match(item, /^https?:\/\//) != null)
            return true;
    }

    return false;
}

function rule_has_list_update_source(section) {
    section = object_or_empty(section);
    if (rule_config == null)
        rule_config = require("config.rule");

    return bool_option(section, "enabled", true) && (
        rule_config.has_community_subnet_list(connections.community_lists_value(section)) ||
        option(section, "remote_domain_lists", "") != "" ||
        option(section, "remote_subnet_lists", "") != "" ||
        length(connections.rule_sets_with_subnets(section)) > 0 ||
        list_has_remote_references(option(section, "domain_ip_lists", ""))
    );
}

function has_list_update_sources(sections) {
    for (let section in sections)
        if (rule_has_list_update_source(section))
            return true;
    return false;
}

function settings_update_interval(settings) {
    settings = object_or_empty(settings);

    if (!bool_option(settings, "list_update_enabled", true))
        return "";

    let value = option(settings, "update_interval", "1d");
    return value != "" ? value : "1d";
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

function section_is_subscription_proxy(section) {
    return bool_option(section, "enabled", true) &&
        connections.is_connections_action(option(section, "action", "")) &&
        length(connections.subscription_urls(section)) > 0;
}

function line_contains_any_marker(line, markers) {
    line = as_string(line);
    for (let marker in markers) {
        marker = as_string(marker);
        if (marker != "" && index(line, marker) >= 0)
            return true;
    }

    return false;
}

function filter_cron_markers_text(data, markers) {
    data = as_string(data);
    if (data == "")
        return "";

    let lines = split(data, "\n");
    let has_trailing_newline = substr(data, length(data) - 1) == "\n";
    let result = "";

    for (let i = 0; i < length(lines); i++) {
        let line = as_string(lines[i]);
        if (i == length(lines) - 1 && has_trailing_newline && line == "")
            continue;
        if (line_contains_any_marker(line, markers))
            continue;
        result += line + "\n";
    }

    return result;
}

function filter_cron_markers(markers) {
    print(filter_cron_markers_text(read_stdin(), markers));
}

function cron_refresh_plan_rows(settings, sections, bin, list_marker, subscription_marker) {
    let status = 0;
    let rows = [];

    if (has_list_update_sources(sections)) {
        let interval = settings_update_interval(settings);
        if (interval == "") {
            push(rows, "list-disabled");
        }
        else {
            let seconds = duration_to_seconds_value(interval);
            if (seconds == null) {
                push(rows, "list-error\t" + as_string(interval));
                status = 1;
            }
            else {
                push(rows, "list\t" + due_check_cron_schedule_text(seconds) + " " + as_string(bin) + " list_update_if_due " + as_string(list_marker));
            }
        }
    }

    let min_interval = 0;
    let subscription_source_count = 0;
    for (let section in sections) {
        section = object_or_empty(section);
        if (!section_is_subscription_proxy(section))
            continue;

        let interval = section_subscription_update_interval(section);
        if (interval == "")
            continue;

        subscription_source_count++;
        let seconds = duration_to_seconds_value(interval);
        if (seconds == null) {
            push(rows, "subscription-error\t" + section_name(section) + "\t" + as_string(interval));
            continue;
        }

        if (min_interval == 0 || seconds < min_interval)
            min_interval = seconds;
    }

    if (subscription_source_count > 0) {
        if (min_interval <= 0)
            status = 1;
        else
            push(rows, "subscription\t" + due_check_cron_schedule_text(min_interval) + " " + as_string(bin) + " subscription_update_if_due " + as_string(subscription_marker));
    }

    return {
        status,
        rows
    };
}

function print_cron_refresh_plan(result) {
    result = object_or_empty(result);
    for (let row in result.rows)
        print(row, "\n");
    exit(int(result.status || 0));
}

function cron_refresh_plan(settings, sections, bin, list_marker, subscription_marker) {
    print_cron_refresh_plan(cron_refresh_plan_rows(settings, sections, bin, list_marker, subscription_marker));
}

function cron_refresh_apply_result(settings, sections, existing_crontab, bin, list_marker, subscription_marker) {
    let plan = cron_refresh_plan_rows(settings, sections, bin, list_marker, subscription_marker);
    let filtered_crontab = filter_cron_markers_text(existing_crontab, [ list_marker, subscription_marker ]);
    let cron_jobs = "";
    let logs = [ { level: "info", message: "The cron job removed" } ];
    let tab = "\t";

    for (let row in plan.rows) {
        let line = as_string(row);
        let separator = index(line, tab);
        let type = separator >= 0 ? substr(line, 0, separator) : line;
        let rest = separator >= 0 ? substr(line, separator + 1) : "";

        if (type == "list") {
            cron_jobs += rest + "\n";
            push(logs, { level: "info", message: "The cron job has been created: " + rest });
        }
        else if (type == "list-disabled") {
            push(logs, { level: "info", message: "Remote list auto-update is disabled" });
        }
        else if (type == "list-error") {
            push(logs, { level: "error", message: "Invalid update_interval value: " + rest });
        }
        else if (type == "subscription") {
            cron_jobs += rest + "\n";
            push(logs, { level: "info", message: "The subscription cron job has been created: " + rest });
        }
        else if (type == "subscription-error") {
            let section_separator = index(rest, tab);
            let section = section_separator >= 0 ? substr(rest, 0, section_separator) : rest;
            let interval = section_separator >= 0 ? substr(rest, section_separator + 1) : "";
            push(logs, { level: "error", message: "Invalid subscription_update_interval value for rule '" + section + "': " + interval });
        }
    }

    return {
        status: int(plan.status || 0),
        crontab: filtered_crontab + (int(plan.status || 0) == 0 ? cron_jobs : ""),
        logs
    };
}

function write_crontab_text(text) {
    let tmp = trim(command_output_from_args([ "mktemp" ]));
    if (tmp == "")
        return false;

    if (!fs.writefile(tmp, as_string(text))) {
        fs.unlink(tmp);
        return false;
    }

    let ok = command_success_from_args([ "crontab", tmp ]);
    fs.unlink(tmp);
    return ok;
}

function log_cron_apply_result(result) {
    for (let item in array_or_empty(object_or_empty(result).logs))
        log_message(item.message, item.level);
}

function remove_cron_jobs(list_marker, subscription_marker) {
    let crontab = command_output_from_args([ "crontab", "-l" ]);
    let result = {
        crontab: filter_cron_markers_text(crontab, [ list_marker, subscription_marker ]),
        logs: [ { level: "info", message: "The cron job removed" } ]
    };

    if (!write_crontab_text(result.crontab))
        exit(1);

    log_cron_apply_result(result);
}

function refresh_cron_from_sources(settings, sections, bin, list_marker, subscription_marker) {
    let result = cron_refresh_apply_result(
        settings,
        sections,
        command_output_from_args([ "crontab", "-l" ]),
        bin,
        list_marker,
        subscription_marker
    );

    if (!write_crontab_text(result.crontab))
        exit(1);

    log_cron_apply_result(result);
    exit(result.status);
}

function list_update_due_status(settings, timestamp_path, now) {
    let interval = settings_update_interval(settings);
    if (interval == "")
        exit(1);

    let seconds = duration_to_seconds_value(interval);
    if (seconds == null) {
        print("error\t", interval, "\n");
        exit(2);
    }

    exit(update_due_status(now, file_first_line_value(timestamp_path), seconds));
}

function subscription_update_section_due_status(section, timestamp_path, now) {
    section = object_or_empty(section);
    let interval = section_subscription_update_interval(section);
    if (interval == "")
        exit(1);

    let seconds = duration_to_seconds_value(interval);
    if (seconds == null) {
        print("error\t", interval, "\n");
        exit(2);
    }

    exit(update_due_status(now, file_first_line_value(timestamp_path), seconds));
}

function stdin_first_ipv4_line() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^[0-9]+\./) != null) {
            print(line, "\n");
            return;
        }
    }
}

function json_length(path) {
    let value = read_json_file(path);
    if (type(value) == "array" || type(value) == "object")
        print(length(value), "\n");
    else
        print("0\n");
}

function job_pid(path) {
    let value = read_json_file(path);
    if (type(value) == "object" && value.pid != null)
        print(as_string(value.pid), "\n");
}

function subscription_job_state_path(job_dir, job_id) {
    job_dir = as_string(job_dir);
    job_id = as_string(job_id);

    if (job_id == "" || job_id == "." || job_id == ".." || match(job_id, /[^A-Za-z0-9._-]/) != null)
        exit(1);

    print(job_dir, "/", job_id, ".json\n");
}

function subscription_job_json_response(success, job_id, message) {
    write_json({
        success: arg_bool(success),
        job_id: as_string(job_id),
        message: as_string(message)
    });
}

function subscription_running_job_state_value(section, source_index, started_at) {
    return {
        success: true,
        running: true,
        kind: "subscription",
        message: "Subscription update is running",
        section: as_string(section),
        source_index: as_string(source_index),
        pid: null,
        started_at: arg_number(started_at),
        updated_at: null,
        exit_code: null
    };
}

function subscription_running_job_state(section, source_index, started_at) {
    write_json(subscription_running_job_state_value(section, source_index, started_at));
}

function job_started_at_within_grace(value, now, grace_seconds) {
    let started_at = arg_number(value);
    now = arg_number(now);
    grace_seconds = arg_number(grace_seconds);

    if (started_at <= 0 || now <= 0)
        return false;

    return now - started_at < grace_seconds;
}

function job_pid_valid(pid) {
    pid = as_string(pid);
    return pid != "" && match(pid, /^[0-9]+$/) != null;
}

function set_subscription_running_job_pid(path, pid) {
    pid = as_string(pid);
    if (!job_pid_valid(pid))
        return false;

    let value = object_or_empty(read_json_file(path));
    if (value.running === true) {
        value.pid = pid;
        return write_state_file(path, value);
    }

    return false;
}

function subscription_job_refresh_plan(path, now, grace_seconds) {
    let value = read_json_file(path);
    if (type(value) != "object" || value.running !== true) {
        print("skip\n");
        return;
    }

    let within_grace = job_started_at_within_grace(value.started_at, now, grace_seconds);
    let pid = as_string(value.pid || "");
    if (!job_pid_valid(pid)) {
        print(within_grace ? "skip\n" : "stale\n");
        return;
    }

    print("pid\t", pid, "\t", within_grace ? "0" : "1", "\n");
}

function subscription_finished_job_state_value(success, message, exit_code, updated_at, section, source_index, started_at) {
    return {
        success: arg_bool(success),
        running: false,
        kind: "subscription",
        message: as_string(message),
        section: as_string(section),
        source_index: as_string(source_index),
        pid: null,
        started_at: arg_number(started_at),
        exit_code: arg_number(exit_code),
        updated_at: arg_number(updated_at)
    };
}

function subscription_finished_job_state(success, message, exit_code, updated_at, section, source_index, started_at) {
    write_json(subscription_finished_job_state_value(success, message, exit_code, updated_at, section, source_index, started_at));
}

function subscription_stale_job_state_value(updated_at, section, source_index, started_at) {
    return {
        success: false,
        running: false,
        kind: "subscription",
        message: "Subscription update worker exited unexpectedly",
        section: as_string(section),
        source_index: as_string(source_index),
        pid: null,
        started_at: arg_number(started_at),
        exit_code: null,
        updated_at: arg_number(updated_at)
    };
}

function subscription_stale_job_state(updated_at, section, source_index, started_at) {
    write_json(subscription_stale_job_state_value(updated_at, section, source_index, started_at));
}

function subscription_status_error(message) {
    write_json({
        success: false,
        running: false,
        message: as_string(message),
        exit_code: null
    });
}

function subscription_status_error_exit(message) {
    subscription_status_error(message);
    exit(1);
}

function valid_subscription_job_id(job_id) {
    job_id = as_string(job_id);
    return job_id != "" && job_id != "." && job_id != ".." && match(job_id, /[^A-Za-z0-9._-]/) == null;
}

function subscription_job_state_path_value(job_dir, job_id) {
    if (!valid_subscription_job_id(job_id))
        return "";
    return as_string(job_dir) + "/" + as_string(job_id) + ".json";
}

function subscription_job_id() {
    let stamp = clock();
    return sprintf("%d-%d", stamp[0], stamp[1]);
}

function ensure_subscription_runtime_dirs() {
    let command = command_env({
        PODKOP_CONFIG_NAME: CONFIG_NAME,
        PODKOP_LIB: LIB_DIR,
        TMP_SING_BOX_FOLDER,
        TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER,
        PODKOP_RUNTIME_STATE_DIR: RUNTIME_STATE_DIR,
        PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR: SUBSCRIPTION_UPDATE_STATE_DIR,
        PODKOP_SUBSCRIPTION_LINKS_DIR: SUBSCRIPTION_LINKS_DIR,
        PODKOP_SUBSCRIPTION_METADATA_DIR: SUBSCRIPTION_METADATA_DIR,
        PODKOP_OUTBOUND_METADATA_DIR: OUTBOUND_METADATA_DIR,
        PODKOP_SECTION_CACHE_DIR: SECTION_CACHE_DIR,
        PODKOP_RUNTIME_CACHE_FORMAT_FILE: RUNTIME_CACHE_FORMAT_FILE,
        PODKOP_RUNTIME_CACHE_FORMAT: RUNTIME_CACHE_FORMAT,
        PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR: PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE
    }) + " " + command_from_args([
        "ucode",
        "-L", LIB_DIR,
        LIB_DIR + "/subscription/cache.uc",
        "ensure-runtime-dirs"
    ]);

    return command_success(command) && ensure_dir(SUBSCRIPTION_JOB_DIR);
}

function subscription_job_output_path(job_id) {
    return SUBSCRIPTION_JOB_DIR + "/" + as_string(job_id) + ".out";
}

function subscription_job_output_path_from_state(path) {
    path = as_string(path);
    if (length(path) >= 5 && substr(path, length(path) - 5) == ".json")
        return substr(path, 0, length(path) - 5) + ".out";
    return path + ".out";
}

function remove_subscription_job_state(path) {
    remove_file(path);
    remove_file(subscription_job_output_path_from_state(path));
}

function subscription_job_running_is(path, expected) {
    let value = read_json_file(path);
    let running = type(value) == "object" && value.running === true;
    return running == arg_bool(expected);
}

function subscription_cleanup_jobs() {
    ensure_dir(SUBSCRIPTION_JOB_DIR);

    command_success_from_args([
        "find",
        SUBSCRIPTION_JOB_DIR,
        "-type", "f",
        "-name", "*.out",
        "-mmin", "+" + as_string(SUBSCRIPTION_JOB_ORPHAN_OUTPUT_TTL_MINUTES),
        "-delete"
    ]);

    let old = command_output_from_args([
        "find",
        SUBSCRIPTION_JOB_DIR,
        "-type", "f",
        "-name", "*.json",
        "-mmin", "+" + as_string(SUBSCRIPTION_JOB_FINISHED_TTL_MINUTES)
    ]);

    for (let path in split(old, "\n")) {
        path = trim(as_string(path));
        if (path != "" && subscription_job_running_is(path, false))
            remove_subscription_job_state(path);
    }
}

function pid_running(pid) {
    pid = as_string(pid);
    return job_pid_valid(pid) && command_success_from_args([ "kill", "-0", pid ]);
}

function write_subscription_stale_job_state(path) {
    let value = object_or_empty(read_json_file(path));
    return write_state_file(path, subscription_stale_job_state_value(
        now_seconds(),
        value.section || "",
        value.source_index || "",
        value.started_at || 0
    ));
}

function refresh_subscription_running_job_state(path) {
    let value = read_json_file(path);
    if (type(value) != "object" || value.running !== true)
        return;

    let now = now_seconds();
    let within_grace = job_started_at_within_grace(value.started_at, now, SUBSCRIPTION_JOB_STALE_GRACE_SECONDS);
    let pid = as_string(value.pid || "");

    if (!job_pid_valid(pid)) {
        if (!within_grace)
            write_subscription_stale_job_state(path);
        return;
    }

    if (pid_running(pid))
        return;
    if (within_grace)
        return;

    command_success_from_args([ "sleep", "1" ]);
    value = read_json_file(path);
    if (type(value) != "object" || value.running !== true)
        return;
    if (pid_running(pid))
        return;

    write_subscription_stale_job_state(path);
}

function finish_subscription_job(path, exit_code, output_file) {
    let value = object_or_empty(read_json_file(path));
    let success = arg_number(exit_code) == 0;
    let message = file_last_nonblank_line_value(
        output_file,
        success ? "Subscription update completed" : "Subscription update failed",
        240
    );

    let ok = write_state_file(path, subscription_finished_job_state_value(
        success,
        message,
        exit_code,
        now_seconds(),
        value.section || "",
        value.source_index || "",
        value.started_at || 0
    ));
    remove_file(output_file);
    return ok;
}

function subscription_worker_env() {
    return {
        PODKOP_CONFIG_NAME: CONFIG_NAME,
        PODKOP_LIB: LIB_DIR,
        PODKOP_BIN: BIN_PATH,
        TMP_SING_BOX_FOLDER,
        TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER,
        PODKOP_RUNTIME_STATE_DIR: RUNTIME_STATE_DIR,
        PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR: SUBSCRIPTION_UPDATE_STATE_DIR,
        PODKOP_SUBSCRIPTION_UPDATE_JOB_DIR: SUBSCRIPTION_JOB_DIR,
        PODKOP_SUBSCRIPTION_LINKS_DIR: SUBSCRIPTION_LINKS_DIR,
        PODKOP_SUBSCRIPTION_METADATA_DIR: SUBSCRIPTION_METADATA_DIR,
        PODKOP_OUTBOUND_METADATA_DIR: OUTBOUND_METADATA_DIR,
        PODKOP_SECTION_CACHE_DIR: SECTION_CACHE_DIR,
        PODKOP_RUNTIME_CACHE_FORMAT_FILE: RUNTIME_CACHE_FORMAT_FILE,
        PODKOP_RUNTIME_CACHE_FORMAT: RUNTIME_CACHE_FORMAT,
        PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR: PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        PODKOP_SUBSCRIPTION_UPDATE_JOB_FINISHED_TTL_MINUTES: SUBSCRIPTION_JOB_FINISHED_TTL_MINUTES,
        PODKOP_SUBSCRIPTION_UPDATE_JOB_ORPHAN_OUTPUT_TTL_MINUTES: SUBSCRIPTION_JOB_ORPHAN_OUTPUT_TTL_MINUTES,
        PODKOP_UI_ACTION_STALE_GRACE_SECONDS: SUBSCRIPTION_JOB_STALE_GRACE_SECONDS
    };
}

function launch_subscription_worker(args) {
    let command_args = [ "ucode", "-L", LIB_DIR, LIB_DIR + "/components/updates.uc" ];
    for (let arg in args)
        push(command_args, arg);

    let command = command_env(subscription_worker_env()) + " " +
        command_from_args(command_args) +
        " >/dev/null 2>&1 1000>&- & echo $!";
    return trim(command_output("sh -c " + shell_quote(command)));
}

function subscription_update_worker(state_file, output_file, section, source_index) {
    let status = command_status(command_from_args([
        BIN_PATH,
        "subscription_update",
        as_string(section),
        as_string(source_index)
    ]) + " >" + shell_quote(output_file) + " 2>&1");

    finish_subscription_job(state_file, status, output_file);
}

function subscription_update_async(section, source_index) {
    if (!ensure_subscription_runtime_dirs()) {
        subscription_job_json_response(false, "", "Failed to create subscription update state directory");
        exit(1);
    }

    subscription_cleanup_jobs();

    let job_id = subscription_job_id();
    let state_file = subscription_job_state_path_value(SUBSCRIPTION_JOB_DIR, job_id);
    if (state_file == "") {
        subscription_job_json_response(false, "", "Failed to prepare subscription update job");
        exit(1);
    }

    if (!write_state_file(state_file, subscription_running_job_state_value(section, source_index, now_seconds()))) {
        subscription_job_json_response(false, "", "Failed to write subscription update state");
        exit(1);
    }

    let output_file = subscription_job_output_path(job_id);
    let pid = launch_subscription_worker([
        "subscription-update-worker",
        state_file,
        output_file,
        as_string(section),
        as_string(source_index)
    ]);

    if (pid == "" || !set_subscription_running_job_pid(state_file, pid)) {
        if (pid != "")
            command_success_from_args([ "kill", pid ]);
        subscription_job_json_response(false, "", "Failed to write subscription update worker pid");
        exit(1);
    }

    subscription_job_json_response(true, job_id, "Subscription update started");
}

function subscription_update_status(job_id) {
    ensure_dir(SUBSCRIPTION_JOB_DIR);
    subscription_cleanup_jobs();

    let state_file = subscription_job_state_path_value(SUBSCRIPTION_JOB_DIR, job_id);
    if (state_file == "")
        subscription_status_error_exit("Invalid subscription update job id");

    if (fs.stat(state_file) == null)
        subscription_status_error_exit("Subscription update job was not found");

    refresh_subscription_running_job_state(state_file);
    print(as_string(fs.readfile(state_file)));
}

function component_job_json_response(success, job_id, message) {
    write_json({
        success: arg_bool(success),
        job_id: as_string(job_id),
        message: as_string(message)
    });
}

function component_action_status_error(message) {
    write_json({
        success: false,
        running: false,
        kind: "component",
        component: "unknown",
        action: "status",
        message: as_string(message),
        current_version: "",
        latest_version: "",
        changed: 0,
        status: "",
        exit_code: null
    });
}

function component_action_status_error_exit(message) {
    component_action_status_error(message);
    exit(1);
}

function component_running_job_state_value(component, action, started_at) {
    return {
        success: true,
        running: true,
        kind: "component",
        component: as_string(component),
        action: as_string(action),
        message: "Component action is running",
        pid: null,
        started_at: arg_number(started_at),
        updated_at: null,
        current_version: "",
        latest_version: "",
        changed: 0,
        status: "",
        exit_code: null
    };
}

function normalize_component_name(component) {
    component = as_string(component);
    if (component == "sing-box" || component == "singbox")
        return "sing_box";
    if (component == "podkop-plus" || component == "podkop_plus")
        return "podkop";
    return component;
}

function valid_component_job_id(job_id) {
    job_id = as_string(job_id);
    return job_id != "" && job_id != "." && job_id != ".." && match(job_id, /[^A-Za-z0-9._-]/) == null;
}

function component_job_state_path_value(job_id) {
    if (!valid_component_job_id(job_id))
        return "";
    return COMPONENT_JOB_DIR + "/" + as_string(job_id) + ".json";
}

function component_job_id() {
    let stamp = clock();
    return sprintf("%d-%d", stamp[0], stamp[1]);
}

function component_job_output_path(job_id) {
    return COMPONENT_JOB_DIR + "/" + as_string(job_id) + ".out";
}

function component_job_output_path_from_state(path) {
    path = as_string(path);
    if (length(path) >= 5 && substr(path, length(path) - 5) == ".json")
        return substr(path, 0, length(path) - 5) + ".out";
    return path + ".out";
}

function remove_component_job_state(path) {
    let output_path = component_job_output_path_from_state(path);
    remove_file(path);
    remove_file(output_path);
    remove_file(output_path + ".json");
}

function component_job_running_is(path, expected) {
    let value = read_json_file(path);
    let running = type(value) == "object" && value.running === true;
    return running == arg_bool(expected);
}

function ensure_component_runtime_dirs() {
    return ensure_dir(COMPONENT_JOB_DIR);
}

function write_component_stale_job_state(path) {
    let value = object_or_empty(read_json_file(path));
    value.success = false;
    value.running = false;
    value.kind = "component";
    value.message = "Component action job is stale or the worker process exited unexpectedly";
    value.changed = 0;
    value.status = "";
    value.exit_code = null;
    value.updated_at = now_seconds();
    return write_state_file(path, value);
}

function refresh_component_running_job_state(path) {
    let value = read_json_file(path);
    if (type(value) != "object" || value.running !== true)
        return;

    let now = now_seconds();
    let within_grace = job_started_at_within_grace(value.started_at, now, COMPONENT_JOB_STALE_GRACE_SECONDS);
    let pid = as_string(value.pid || "");

    if (!job_pid_valid(pid)) {
        if (!within_grace)
            write_component_stale_job_state(path);
        return;
    }

    if (pid_running(pid) || within_grace)
        return;

    command_success_from_args([ "sleep", "1" ]);
    value = read_json_file(path);
    if (type(value) != "object" || value.running !== true)
        return;
    if (pid_running(pid))
        return;

    write_component_stale_job_state(path);
}

function path_basename_without_suffix(path, suffix) {
    let parts = split(as_string(path), "/");
    let name = length(parts) > 0 ? as_string(parts[length(parts) - 1]) : "";
    suffix = as_string(suffix);
    if (length(name) >= length(suffix) && substr(name, length(name) - length(suffix)) == suffix)
        return substr(name, 0, length(name) - length(suffix));
    return name;
}

function component_cleanup_jobs() {
    ensure_dir(COMPONENT_JOB_DIR);

    for (let path in fs.glob(COMPONENT_JOB_DIR + "/*.json"))
        refresh_component_running_job_state(path);

    for (let output_path in fs.glob(COMPONENT_JOB_DIR + "/*.out")) {
        let state_file = component_job_state_path_value(path_basename_without_suffix(output_path, ".out"));
        if (state_file == "" || fs.stat(state_file) == null || !component_job_running_is(state_file, true)) {
            remove_file(output_path);
            remove_file(output_path + ".json");
        }
    }

    command_success_from_args([
        "find",
        COMPONENT_JOB_DIR,
        "-type", "f",
        "-name", "*.out",
        "-mmin", "+" + as_string(COMPONENT_JOB_ORPHAN_OUTPUT_TTL_MINUTES),
        "-delete"
    ]);
    command_success_from_args([
        "find",
        COMPONENT_JOB_DIR,
        "-type", "f",
        "-name", "*.out.json",
        "-mmin", "+" + as_string(COMPONENT_JOB_ORPHAN_OUTPUT_TTL_MINUTES),
        "-delete"
    ]);
    command_success_from_args([
        "find",
        COMPONENT_JOB_DIR,
        "-type", "f",
        "-name", "*.json.*",
        "-mmin", "+10",
        "-delete"
    ]);

    let old = command_output_from_args([
        "find",
        COMPONENT_JOB_DIR,
        "-type", "f",
        "-name", "*.json",
        "-mmin", "+" + as_string(COMPONENT_JOB_FINISHED_TTL_MINUTES)
    ]);

    for (let path in split(old, "\n")) {
        path = trim(as_string(path));
        if (path != "" && component_job_running_is(path, false))
            remove_component_job_state(path);
    }
}

function set_component_running_job_pid(path, pid) {
    pid = as_string(pid);
    if (!job_pid_valid(pid))
        return false;

    let value = object_or_empty(read_json_file(path));
    if (value.running === true) {
        value.pid = pid;
        return write_state_file(path, value);
    }

    return false;
}

function output_json_object(path) {
    let data = as_string(fs.readfile(path) || "");

    try {
        let value = json(data);
        if (type(value) == "object")
            return value;
    }
    catch (e) {
    }

    let result = null;
    for (let line in split(data, "\n")) {
        line = trim(as_string(line));
        let start = index(line, "{");
        if (start < 0)
            continue;
        try {
            let value = json(substr(line, start));
            if (type(value) == "object")
                result = value;
        }
        catch (e) {
        }
    }

    return result;
}

function component_fallback_job_state(component, action, message, exit_code, updated_at) {
    return {
        success: false,
        running: false,
        kind: "component",
        component: as_string(component),
        action: as_string(action),
        message: as_string(message),
        current_version: "",
        latest_version: "",
        changed: 0,
        status: "",
        exit_code: arg_number(exit_code),
        updated_at: arg_number(updated_at)
    };
}

function finish_component_job(path, component, action, exit_code, output_file) {
    let updated_at = now_seconds();
    let value = output_json_object(output_file);
    let ok;

    if (type(value) == "object") {
        value.running = false;
        value.kind = "component";
        value.exit_code = arg_number(exit_code);
        value.updated_at = updated_at;
        ok = write_state_file(path, value);
    }
    else {
        let raw_output = file_last_nonblank_line_value(output_file, "Failed to execute", 240);
        ok = write_state_file(path, component_fallback_job_state(component, action, raw_output, exit_code, updated_at));
    }

    remove_file(output_file);
    remove_file(output_file + ".json");
    return ok;
}

function component_worker_env() {
    return {
        PODKOP_CONFIG_NAME: CONFIG_NAME,
        PODKOP_LIB: LIB_DIR,
        PODKOP_BIN: BIN_PATH,
        PODKOP_SERVICE_INIT: SERVICE_INIT,
        UPDATES_JOB_DIR: COMPONENT_JOB_DIR,
        UPDATES_JOB_FINISHED_TTL_MINUTES: COMPONENT_JOB_FINISHED_TTL_MINUTES,
        UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES: COMPONENT_JOB_ORPHAN_OUTPUT_TTL_MINUTES,
        UPDATES_JOB_STALE_GRACE_SECONDS: COMPONENT_JOB_STALE_GRACE_SECONDS,
        PODKOP_UI_COMPONENT_ACTION_TRACKED: "1"
    };
}

function launch_component_worker(args) {
    let command_args = [ "ucode", "-L", LIB_DIR, LIB_DIR + "/components/updates.uc" ];
    for (let arg in args)
        push(command_args, arg);

    let command = command_env(component_worker_env()) + " " +
        command_from_args(command_args) +
        " >/dev/null 2>&1 1000>&- & echo $!";
    return trim(command_output("sh -c " + shell_quote(command)));
}

function component_action_worker(state_file, output_file, component, action) {
    component = normalize_component_name(component);
    let command = command_env(component_worker_env()) + " " +
        command_from_args([
            "ucode",
            "-L", LIB_DIR,
            LIB_DIR + "/components/action.uc",
            "component-action",
            as_string(component),
            as_string(action)
        ]) + " >" + shell_quote(output_file) + " 2>&1";
    let status = command_status(command);

    finish_component_job(state_file, component, action, status, output_file);
}

function component_action_async(component, action) {
    component = normalize_component_name(component);
    if (!ensure_component_runtime_dirs()) {
        component_job_json_response(false, "", "Failed to create component action state directory");
        exit(1);
    }

    component_cleanup_jobs();

    let job_id = component_job_id();
    let state_file = component_job_state_path_value(job_id);
    if (state_file == "") {
        component_job_json_response(false, "", "Failed to prepare component action job");
        exit(1);
    }

    if (!write_state_file(state_file, component_running_job_state_value(component, action, now_seconds()))) {
        component_job_json_response(false, "", "Failed to write component action state");
        exit(1);
    }

    let output_file = component_job_output_path(job_id);
    let pid = launch_component_worker([
        "component-action-worker",
        state_file,
        output_file,
        as_string(component),
        as_string(action)
    ]);

    if (pid == "" || !set_component_running_job_pid(state_file, pid)) {
        if (pid != "")
            command_success_from_args([ "kill", pid ]);
        component_job_json_response(false, "", "Failed to write component action worker pid");
        exit(1);
    }

    component_job_json_response(true, job_id, "Component action started");
}

function component_action_status(job_id) {
    ensure_dir(COMPONENT_JOB_DIR);
    component_cleanup_jobs();

    let state_file = component_job_state_path_value(job_id);
    if (state_file == "")
        component_action_status_error_exit("Invalid component action job id");

    if (fs.stat(state_file) == null)
        component_action_status_error_exit("Component action job was not found");

    refresh_component_running_job_state(state_file);
    print(as_string(fs.readfile(state_file)));
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

function download_via_proxy_section(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    if (enabled_option == "" || !bool_option(settings, enabled_option, false))
        return "";

    let section_option = download_via_proxy_section_option_for_purpose(purpose);
    let configured = section_option != "" ? option(settings, section_option, "") : "";
    if (configured != "")
        return configured;

    return option(settings, "download_lists_via_proxy_section", "");
}

function service_proxy_port_for_purpose(purpose) {
    return int(SB_SERVICE_MIXED_INBOUND_PORT) + (as_string(purpose || "lists") == "components" ? 1 : 0);
}

function service_proxy_address(settings, purpose) {
    return download_via_proxy_section(settings, purpose) != "" ?
        SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + service_proxy_port_for_purpose(purpose) : "";
}

function download_to_file(url, filepath, proxy_address) {
    let attempt = 1;
    while (attempt <= 3) {
        let command = command_from_args([ "wget", "-O", filepath, url ]);
        if (as_string(proxy_address) != "")
            command = "http_proxy=" + shell_quote("http://" + as_string(proxy_address)) +
                " https_proxy=" + shell_quote("http://" + as_string(proxy_address)) + " " + command;

        if (command_success(command))
            return true;

        log_message("Attempt " + attempt + "/3 to download " + as_string(url) + " failed", "warn");
        command_success_from_args([ "sleep", "2" ]);
        attempt++;
    }

    return false;
}

function convert_crlf_to_lf(path) {
    let data = fs.readfile(as_string(path));
    if (data == null || index(data, "\r") < 0)
        return;

        log_message("Converting CRLF line endings to LF in " + as_string(path), "debug");
    write_file(path, replace(data, /\r/g, ""));
}

function ruleset_module_success(args) {
    let command_args = [ LIB_DIR + "/routing/rulesets.uc" ];
    for (let arg in args)
        push(command_args, arg);
    return module_success(command_args);
}

function domain_ip_list_ruleset_path(section) {
    return TMP_RULESET_FOLDER + "/" + routing_rulesets_module().ruleset_tag(section_name(section), "lists", "") + ".json";
}

function remote_ruleset_path(section, kind) {
    return TMP_RULESET_FOLDER + "/" + routing_rulesets_module().ruleset_tag(section_name(section), "remote", kind) + ".json";
}

function reset_domain_ip_list_ruleset(section) {
    let path = domain_ip_list_ruleset_path(section);
    ensure_dir(TMP_RULESET_FOLDER);
    remove_file(path);
    return ruleset_module_success([ "create-source", path ]);
}

function ensure_ruleset_source(path) {
    ensure_dir(TMP_RULESET_FOLDER);
    if (file_exists_value(path))
        return true;
    return ruleset_module_success([ "create-source", path ]);
}

function cleanup_empty_ruleset(path) {
    if (routing_rulesets_module().has_rules(path))
        return true;
    remove_file(path);
    return false;
}

function add_plain_subnet_file_to_nft_for_section(section, filepath) {
    if (!file_nonempty(filepath))
        return true;

    return nft_module_success([
        "nft-add-subnet-file-for-uci-section",
        section_name(section),
        filepath,
        NFT_TABLE_NAME,
        NFT_COMMON_SET_NAME,
        NFT_IP_PORT_SET_NAME,
        "5000",
        NFT_COMMON6_SET_NAME,
        NFT_IP_PORT6_SET_NAME
    ]);
}

function add_json_ruleset_subnets_to_nft_for_section(section, json_file, label) {
    let unscoped_tmpfile = temp_path();
    let scoped_tmpfile = temp_path();
    if (unscoped_tmpfile == "" || scoped_tmpfile == "") {
        remove_files([ unscoped_tmpfile, scoped_tmpfile ]);
        return false;
    }

    let ok = nft_module_success([
        "nft-add-json-ruleset-subnets-for-uci-section",
        section_name(section),
        json_file,
        label,
        NFT_TABLE_NAME,
        NFT_COMMON_SET_NAME,
        NFT_IP_PORT_SET_NAME,
        unscoped_tmpfile,
        scoped_tmpfile,
        "5000",
        NFT_COMMON6_SET_NAME,
        NFT_IP_PORT6_SET_NAME
    ]);
    remove_files([ unscoped_tmpfile, scoped_tmpfile ]);
    return ok;
}

function import_domain_ip_list_file_into_rulesets(filepath, section) {
    if (!file_exists_value(filepath))
        return true;

    let domains_tmpfile = temp_path();
    let subnets_tmpfile = temp_path();
    if (domains_tmpfile == "" || subnets_tmpfile == "") {
        remove_files([ domains_tmpfile, subnets_tmpfile ]);
        return false;
    }

    let ruleset_filepath = domain_ip_list_ruleset_path(section);
    let ok = nft_module_success([ "split-domain-subnet-file", filepath, domains_tmpfile, subnets_tmpfile ]);
    if (ok)
        ok = ruleset_module_success([ "import-plain-list", domains_tmpfile, ruleset_filepath, "domain_suffix", "domains", "5000" ]);
    if (ok)
        ok = ruleset_module_success([ "import-plain-list", subnets_tmpfile, ruleset_filepath, "ip_cidr", "subnets", "5000" ]);
    if (ok)
        ok = add_plain_subnet_file_to_nft_for_section(section, subnets_tmpfile);

    remove_files([ domains_tmpfile, subnets_tmpfile ]);
    return ok;
}

function import_domain_ip_list_reference_into_rulesets(reference, section, settings) {
    reference = as_string(reference);
    if (match(reference, /^https?:\/\//) == null)
        return import_domain_ip_list_file_into_rulesets(reference, section);

    let tmpfile = temp_path();
    if (tmpfile == "")
        return false;

    let ok = true;
    if (download_to_file(reference, tmpfile, service_proxy_address(settings, "lists")) && file_nonempty(tmpfile)) {
        convert_crlf_to_lf(tmpfile);
        ok = import_domain_ip_list_file_into_rulesets(tmpfile, section);
    }
    else {
        log_message("Failed to download remote domain/IP list " + reference + "; skipping it until the next successful update", "warn");
    }

    remove_file(tmpfile);
    return ok;
}

function rebuild_domain_ip_lists_from_rule(section, settings) {
    if (!bool_option(section, "enabled", true))
        return true;

    let references = list_option_values(section, "domain_ip_lists");
    if (length(references) == 0)
        return true;

    if (!reset_domain_ip_list_ruleset(section))
        return false;

    let ok = true;
    for (let reference in references)
        if (!import_domain_ip_list_reference_into_rulesets(reference, section, settings))
            ok = false;

    cleanup_empty_ruleset(domain_ip_list_ruleset_path(section));
    return ok;
}

function import_builtin_subnets_from_rule(section, settings) {
    if (!bool_option(section, "enabled", true))
        return true;

    let ok = true;
    for (let service in connections.community_lists(section)) {
        if (!singbox_rulesets_module().is_community(service))
            continue;

        let url = BUILTIN_SUBNET_URLS[as_string(service)];
        if (url == null)
            continue;

        let tmpfile = temp_path();
        if (tmpfile == "") {
            ok = false;
            continue;
        }

        if (!download_to_file(url, tmpfile, service_proxy_address(settings, "lists")) || !file_nonempty(tmpfile)) {
            log_message("Failed to download built-in " + as_string(service) + " subnet list; skipping it until the next successful update", "warn");
            remove_file(tmpfile);
            continue;
        }

        if (!nft_module_success([
            "nft-add-community-subnet-file-for-uci-section",
            section_name(section),
            service,
            tmpfile,
            NFT_TABLE_NAME,
            NFT_COMMON_SET_NAME,
            NFT_IP_PORT_SET_NAME,
            NFT_INTERFACE_SET_NAME,
            NFT_DISCORD_SET_NAME,
            NFT_FAKEIP_MARK,
            "5000",
            NFT_COMMON6_SET_NAME,
            NFT_IP_PORT6_SET_NAME,
            NFT_DISCORD6_SET_NAME
        ]))
            ok = false;

        remove_file(tmpfile);
    }

    return ok;
}

function import_custom_ruleset_subnets_from_local(path, format, section, label) {
    if (!file_exists_value(path)) {
        log_message("Local rule set file " + as_string(path) + " not found", "error");
        return false;
    }

    let json_tmpfile = temp_path();
    if (json_tmpfile == "")
        return false;

    let ok = true;
    if (as_string(format) == "binary") {
        if (!command_success_from_args([ "sing-box", "rule-set", "decompile", path, "-o", json_tmpfile ])) {
            log_message("Failed to decompile rule set " + as_string(path), "error");
            ok = false;
        }
    }
    else if (!copy_file(path, json_tmpfile)) {
        log_message("Failed to copy source rule set file " + as_string(path), "error");
        ok = false;
    }

    if (ok && !add_json_ruleset_subnets_to_nft_for_section(section, json_tmpfile, label))
        ok = false;

    remove_file(json_tmpfile);
    return ok;
}

function import_custom_ruleset_subnets_from_remote(url, format, section, label, settings) {
    let remote_tmpfile = temp_path();
    let json_tmpfile = temp_path();
    if (remote_tmpfile == "" || json_tmpfile == "") {
        remove_files([ remote_tmpfile, json_tmpfile ]);
        return false;
    }

    if (!download_to_file(url, remote_tmpfile, service_proxy_address(settings, "lists")) || !file_nonempty(remote_tmpfile)) {
        log_message("Failed to download remote rule set " + as_string(url) + "; skipping it until the next successful update", "warn");
        remove_files([ remote_tmpfile, json_tmpfile ]);
        return true;
    }

    let ok = true;
    if (as_string(format) == "binary") {
        if (!command_success_from_args([ "sing-box", "rule-set", "decompile", remote_tmpfile, "-o", json_tmpfile ])) {
            log_message("Failed to decompile rule set " + as_string(url), "error");
            ok = false;
        }
    }
    else if (!copy_file(remote_tmpfile, json_tmpfile)) {
        log_message("Failed to copy downloaded source rule set " + as_string(url), "error");
        ok = false;
    }

    if (ok && !add_json_ruleset_subnets_to_nft_for_section(section, json_tmpfile, label))
        ok = false;

    remove_files([ remote_tmpfile, json_tmpfile ]);
    return ok;
}

function import_rule_sets_with_subnets_from_rule(section, settings) {
    if (!bool_option(section, "enabled", true))
        return true;

    let references = connections.rule_sets_with_subnets(section);
    if (length(references) == 0)
        return true;

    log_message("Importing subnets from rule sets with subnets for '" + section_name(section) + "' section", "info");
    let ok = true;

    for (let reference in references) {
        reference = as_string(reference);
        log_message("Importing subnets from rule set reference for '" + section_name(section) + "': " + reference, "info");

        let extension = singbox_rulesets_module().file_extension(reference);
        if (match(reference, /^\/.*\.srs$/) != null) {
            if (!import_custom_ruleset_subnets_from_local(reference, "binary", section, "Rule set " + reference))
                ok = false;
        }
        else if (match(reference, /^\/.*\.json$/) != null) {
            if (!import_custom_ruleset_subnets_from_local(reference, "source", section, "Rule set " + reference))
                ok = false;
        }
        else if (match(reference, /^https?:\/\//) != null) {
            let format = extension == "json" ? "source" : (extension == "srs" ? "binary" : singbox_rulesets_module().remote_format(reference));
            if (!import_custom_ruleset_subnets_from_remote(reference, format, section, "Rule set " + reference, settings))
                ok = false;
        }
        else {
            log_message("Unsupported rule set reference for subnet import: " + reference, "error");
            ok = false;
        }
    }

    return ok;
}

function import_domains_from_remote_plain_file(url, section, settings) {
    let tmpfile = temp_path();
    if (tmpfile == "")
        return false;

    if (!download_to_file(url, tmpfile, service_proxy_address(settings, "lists")) || !file_nonempty(tmpfile)) {
        log_message("Failed to download remote domain list " + as_string(url) + "; skipping it until the next successful update", "warn");
        remove_file(tmpfile);
        return true;
    }

    convert_crlf_to_lf(tmpfile);
    let ruleset_path = remote_ruleset_path(section, "domains");
    let ok = ensure_ruleset_source(ruleset_path) &&
        ruleset_module_success([ "import-plain-list", tmpfile, ruleset_path, "domain_suffix", "domains", "5000" ]);
    remove_file(tmpfile);
    return ok;
}

function import_domains_from_remote_domain_lists(section, settings) {
    if (!bool_option(section, "enabled", true))
        return true;

    let references = list_option_values(section, "remote_domain_lists");
    if (length(references) == 0)
        return true;

    log_message("Importing domains from remote domain lists for '" + section_name(section) + "' section", "info");
    let ok = true;
    for (let url in references) {
        log_message("Importing domains from URL: " + as_string(url), "info");
        let extension = singbox_rulesets_module().file_extension(url);
        log_message("Detected file extension: '" + extension + "'", "debug");
        if (extension == "json" || extension == "srs") {
            log_message("No update needed - sing-box manages updates automatically.", "info");
            continue;
        }
        log_message("Import domains from a remote plain-text list", "info");
        if (!import_domains_from_remote_plain_file(url, section, settings))
            ok = false;
    }
    return ok;
}

function import_subnets_from_remote_json_file(url, section, settings) {
    let json_tmpfile = temp_path();
    if (json_tmpfile == "")
        return false;

    if (!download_to_file(url, json_tmpfile, service_proxy_address(settings, "lists")) || !file_nonempty(json_tmpfile)) {
        log_message("Failed to download remote JSON subnet list " + as_string(url) + "; skipping it until the next successful update", "warn");
        remove_file(json_tmpfile);
        return true;
    }

    let ok = add_json_ruleset_subnets_to_nft_for_section(section, json_tmpfile, "Remote JSON rule set " + as_string(url));
    if (!ok)
        log_message("Failed to add subnets from remote JSON list " + as_string(url) + " to nftables", "error");
    remove_file(json_tmpfile);
    return ok;
}

function import_subnets_from_remote_srs_file(url, section, settings) {
    let binary_tmpfile = temp_path();
    let json_tmpfile = temp_path();
    if (binary_tmpfile == "" || json_tmpfile == "") {
        remove_files([ binary_tmpfile, json_tmpfile ]);
        return false;
    }

    if (!download_to_file(url, binary_tmpfile, service_proxy_address(settings, "lists")) || !file_nonempty(binary_tmpfile)) {
        log_message("Failed to download remote SRS subnet list " + as_string(url) + "; skipping it until the next successful update", "warn");
        remove_files([ binary_tmpfile, json_tmpfile ]);
        return true;
    }

    let ok = command_success_from_args([ "sing-box", "rule-set", "decompile", binary_tmpfile, "-o", json_tmpfile ]);
    if (!ok)
        log_message("Failed to decompile binary rule set file", "error");
    if (ok && !add_json_ruleset_subnets_to_nft_for_section(section, json_tmpfile, "Remote SRS rule set " + as_string(url))) {
        log_message("Failed to add subnets from remote SRS list " + as_string(url) + " to nftables", "error");
        ok = false;
    }

    remove_files([ binary_tmpfile, json_tmpfile ]);
    return ok;
}

function import_subnets_from_remote_plain_file(url, section, settings) {
    let tmpfile = temp_path();
    if (tmpfile == "")
        return false;

    if (!download_to_file(url, tmpfile, service_proxy_address(settings, "lists")) || !file_nonempty(tmpfile)) {
        log_message("Failed to download remote plain subnet list " + as_string(url) + "; skipping it until the next successful update", "warn");
        remove_file(tmpfile);
        return true;
    }

    convert_crlf_to_lf(tmpfile);
    let ruleset_path = remote_ruleset_path(section, "subnets");
    let ok = ensure_ruleset_source(ruleset_path) &&
        ruleset_module_success([ "import-plain-list", tmpfile, ruleset_path, "ip_cidr", "subnets", "5000" ]);
    if (ok)
        ok = add_plain_subnet_file_to_nft_for_section(section, tmpfile);
    remove_file(tmpfile);
    return ok;
}

function import_subnets_from_remote_subnet_lists(section, settings) {
    if (!bool_option(section, "enabled", true))
        return true;

    let references = list_option_values(section, "remote_subnet_lists");
    if (length(references) == 0)
        return true;

    log_message("Importing subnets from remote subnet lists for '" + section_name(section) + "' section", "info");
    let ok = true;
    for (let url in references) {
        log_message("Importing subnets from URL: " + as_string(url), "info");
        let extension = singbox_rulesets_module().file_extension(url);
        log_message("Detected file extension: '" + extension + "'", "debug");
        if (extension == "json") {
            log_message("Import subnets from a remote JSON list", "info");
            if (!import_subnets_from_remote_json_file(url, section, settings))
                ok = false;
        }
        else if (extension == "srs") {
            log_message("Import subnets from a remote SRS list", "info");
            if (!import_subnets_from_remote_srs_file(url, section, settings))
                ok = false;
        }
        else {
            log_message("Import subnets from a remote plain-text list", "info");
            if (!import_subnets_from_remote_plain_file(url, section, settings))
                ok = false;
        }
    }
    return ok;
}

function list_update_pid_begin() {
    let existing_pid = trim(as_string(fs.readfile(LIST_UPDATE_PID_FILE) || ""));
    let current_pid = owner_pid();
    if (existing_pid != "" && existing_pid != current_pid && runtime_pid_running(existing_pid)) {
        log_message("Another lists update is already running, skipping", "info");
        return false;
    }

    ensure_parent_dir(LIST_UPDATE_PID_FILE);
    write_file(LIST_UPDATE_PID_FILE, current_pid + "\n");
    return true;
}

function list_update_pid_end() {
    remove_file(LIST_UPDATE_PID_FILE);
}

function dns_probe_passed(proxy_address) {
    if (as_string(proxy_address) != "") {
        log_message("DNS check skipped because list downloads use service proxy", "info");
        return true;
    }

    let attempt = 1;
    while (attempt <= 10) {
        let output = command_output_from_args([ "dig", "+short", "openwrt.org", "A", "+timeout=3", "+tries=1" ]);
        for (let line in split(output, "\n")) {
            if (match(as_string(line), /^[0-9]+\./) != null) {
                log_message("DNS check passed", "info");
                return true;
            }
        }

        log_message("DNS is unavailable [" + attempt + "/10]", "info");
        command_success_from_args([ "sleep", "3" ]);
        attempt++;
    }

    log_message("DNS check failed after 10 attempts; skipping remote lists update until the next attempt", "info");
    return false;
}

function github_probe(proxy_address) {
    let attempt = 1;
    let timeout = 5;
    while (attempt <= 10) {
        let args = [ "curl", "-s", "-m", "" + timeout ];
        if (as_string(proxy_address) != "") {
            push(args, "-x");
            push(args, "http://" + as_string(proxy_address));
        }
        push(args, "https://github.com");

        if (command_success_from_args(args)) {
            log_message(as_string(proxy_address) != "" ? "GitHub connection check passed (via proxy)" : "GitHub connection check passed", "info");
            return true;
        }

        log_message("GitHub is unavailable [" + attempt + "/10] (max-timeout=" + timeout + ")", "info");
        if (timeout < 10)
            timeout++;
        command_success_from_args([ "sleep", "3" ]);
        attempt++;
    }

    log_message("GitHub connection check failed after 10 attempts; trying configured list downloads individually", "info");
    return false;
}

function write_list_update_timestamp(timestamp) {
    ensure_dir(RUNTIME_STATE_DIR);
    write_file(LIST_UPDATE_STATE_FILE, as_string(timestamp) + "\n");
}

function list_update() {
    log_message("Starting lists update", "info");
    if (!list_update_pid_begin())
        exit(0);

    let settings = uci_settings();
    let proxy_address = service_proxy_address(settings, "lists");
    if (!dns_probe_passed(proxy_address)) {
        list_update_pid_end();
        exit(0);
    }
    github_probe(proxy_address);

    log_message("Downloading and processing lists", "info");
    let sections = uci_sections("section");
    let ok = true;

    for (let section in sections)
        if (!rebuild_domain_ip_lists_from_rule(section, settings))
            ok = false;
    for (let section in sections)
        if (!import_builtin_subnets_from_rule(section, settings))
            ok = false;
    for (let section in sections)
        if (!import_domains_from_remote_domain_lists(section, settings))
            ok = false;
    for (let section in sections)
        if (!import_subnets_from_remote_subnet_lists(section, settings))
            ok = false;
    for (let section in sections)
        if (!import_rule_sets_with_subnets_from_rule(section, settings))
            ok = false;

    if (ok) {
        write_list_update_timestamp(now_seconds());
        log_message("Lists update completed successfully", "info");
    }
    else {
        log_message("Lists update failed", "info");
    }

    list_update_pid_end();
    exit(ok ? 0 : 1);
}

function list_update_if_due() {
    let interval = settings_update_interval(uci_settings());
    if (interval == "")
        exit(1);

    let seconds = duration_to_seconds_value(interval);
    if (seconds == null) {
        log_message("Invalid update_interval value: " + interval, "error");
        exit(1);
    }

    let status = update_due_status(now_seconds(), file_first_line_value(LIST_UPDATE_STATE_FILE), seconds);
    if (status == 0)
        list_update();
    if (status == 1)
        exit(0);

    exit(1);
}

function stop_list_update() {
    let pid = trim(as_string(fs.readfile(LIST_UPDATE_PID_FILE) || ""));
    if (pid != "" && runtime_pid_running(pid)) {
        command_success_from_args([ "kill", pid ]);
        log_message("Stopped list_update", "info");
    }
    remove_file(LIST_UPDATE_PID_FILE);
}

function subscription_cache_env() {
    return {
        PODKOP_CONFIG_NAME: CONFIG_NAME,
        PODKOP_LIB: LIB_DIR,
        TMP_SING_BOX_FOLDER,
        TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER,
        PODKOP_RUNTIME_STATE_DIR: RUNTIME_STATE_DIR,
        PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR: SUBSCRIPTION_UPDATE_STATE_DIR,
        PODKOP_SUBSCRIPTION_LINKS_DIR: SUBSCRIPTION_LINKS_DIR,
        PODKOP_SUBSCRIPTION_METADATA_DIR: SUBSCRIPTION_METADATA_DIR,
        PODKOP_OUTBOUND_METADATA_DIR: OUTBOUND_METADATA_DIR,
        PODKOP_SECTION_CACHE_DIR: SECTION_CACHE_DIR,
        PODKOP_RUNTIME_CACHE_FORMAT_FILE: RUNTIME_CACHE_FORMAT_FILE,
        PODKOP_RUNTIME_CACHE_FORMAT: RUNTIME_CACHE_FORMAT,
        PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR: PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        PODKOP_PENDING_RELOAD_FILE: PENDING_RELOAD_FILE,
        PODKOP_SERVICE_INIT: SERVICE_INIT,
        SB_SERVICE_MIXED_INBOUND_ADDRESS,
        SB_SERVICE_MIXED_INBOUND_PORT,
        SB_VARIANT_STATE_FILE
    };
}

function module_env_capture(env, args) {
    let output_path = temp_path();
    if (output_path == "")
        return { status: 1, output: "" };

    let status = command_status(command_env(env) + " " + module_command(args) + " >" + shell_quote(output_path) + " 2>&1");
    let output = as_string(fs.readfile(output_path) || "");
    remove_file(output_path);
    return { status, output };
}

function subscription_cache_capture(args) {
    let command_args = [ LIB_DIR + "/subscription/cache.uc" ];
    for (let arg in args)
        push(command_args, arg);
    return module_env_capture(subscription_cache_env(), command_args);
}

function subscription_cache_success(args) {
    let result = subscription_cache_capture(args);
    if (result.output != "")
        for (let line in split(result.output, "\n"))
            if (trim(as_string(line)) != "")
                log_message("subscription cache: " + line, "debug");
    return result.status == 0;
}

function log_file_lines_from_text(text, level, prefix) {
    for (let line in split(as_string(text), "\n"))
        if (trim(as_string(line)) != "")
            log_message(as_string(prefix) + as_string(line), level);
}

function singbox_runtime_success(args) {
    let command_args = [ LIB_DIR + "/singbox/runtime.uc" ];
    for (let arg in args)
        push(command_args, arg);

    let result = module_env_capture(subscription_cache_env(), command_args);
    if (result.output != "")
        log_file_lines_from_text(result.output, "debug", "sing-box runtime: ");
    return result.status == 0;
}

function write_current_reload_state_clean() {
    return service_state_success([
        "write-current-reload-state-clean",
        RELOAD_STATE_FILE,
        RELOAD_STATE_FORMAT,
        RULE_CONDITION_CACHE_DIR
    ]);
}

function mark_pending_reload(reason) {
    service_state_success([ "mark-pending-reload", PENDING_RELOAD_FILE, reason ]);
}

function run_pending_reload_if_requested() {
    service_state_success([ "run-pending-reload-if-requested", PENDING_RELOAD_FILE, SERVICE_INIT ]);
}

function subscription_update_common_locked(force, target_section, target_source_index) {
    let result = subscription_cache_capture([
        "update-request",
        force ? "1" : "0",
        as_string(target_section),
        as_string(target_source_index)
    ]);
    if (result.status != 0) {
        log_file_lines_from_text(result.output, "error", "subscription update: ");
        return false;
    }

    let fields = split(trim(result.output), /[ \t\r\n]+/);
    let updated = arg_number(fields[0] || "0");
    let failed = arg_number(fields[1] || "0");
    let unchanged = arg_number(fields[2] || "0");
    let superseded = arg_number(fields[3] || "0");

    if (updated == 0) {
        if (superseded > 0) {
            log_message("Subscription update was superseded by newer configuration", "info");
            return true;
        }
        if (failed > 0) {
            log_message("Subscription update finished with errors; keeping the last working cache", "info");
            return false;
        }
        if (unchanged > 0)
            log_message("Subscription update completed: no changes detected", "info");
        else
            log_message("No subscription rules are due for update", "info");
        return true;
    }

    log_message("Reloading sing-box to apply updated subscriptions", "info");
    if (!module_success([ LIB_DIR + "/server/service.uc", "prepare-all-defaults" ]))
        return false;
    if (!module_success([ LIB_DIR + "/config/validator.uc", "validate-runtime" ])) {
        log_message("Runtime config validation failed. Aborted.", "fatal");
        return false;
    }

    if (!singbox_runtime_success([ "configure-service" ]))
        return false;
    if (!singbox_runtime_success([ "init-config", "0", "1", "1" ])) {
        log_message("Failed to rebuild sing-box after subscription update", "error");
        return false;
    }
    if (!service_state_success([ "reload-sing-box-runtime" ]))
        return false;
    if (!write_current_reload_state_clean())
        return false;

    if (failed > 0)
        log_message("Subscription update applied for changed rules; failed rules kept their previous cache", "info");
    else
        log_message("Subscription update completed", "info");
    return true;
}

function subscription_update_common(force, target_section, target_source_index) {
    if (!module_success([ LIB_DIR + "/config/migration.uc", "migrate" ])) {
        log_message("Config migration failed. Aborted.", "fatal");
        exit(1);
    }
    if (!subscription_cache_success([ "ensure-runtime-dirs" ]))
        exit(1);

    force = !!force;
    if (!acquire_runtime_lock(SUBSCRIPTION_UPDATE_LOCK_DIR, force)) {
        log_message("Subscription update is already running", "info");
        if (force)
            mark_pending_reload("subscription_update_busy");
        return force ? 1 : 0;
    }

    if (!acquire_runtime_lock(RELOAD_LOCK_DIR, force)) {
        release_runtime_lock(SUBSCRIPTION_UPDATE_LOCK_DIR);
        log_message("Podkop Plus reload is already running; skipping subscription update", "info");
        if (force)
            mark_pending_reload("reload_busy");
        return force ? 1 : 0;
    }

    let ok = subscription_update_common_locked(force, target_section, target_source_index);
    release_runtime_lock(RELOAD_LOCK_DIR);
    release_runtime_lock(SUBSCRIPTION_UPDATE_LOCK_DIR);
    run_pending_reload_if_requested();
    return ok ? 0 : 1;
}

function subscription_update_if_due() {
    log_message("Starting due subscription update", "info");
    exit(subscription_update_common(false, "", ""));
}

function subscription_update(target_section, target_source_index) {
    if (as_string(target_section) != "")
        log_message("Starting subscription update for rule '" + as_string(target_section) + "'", "info");
    else
        log_message("Starting subscription update", "info");
    exit(subscription_update_common(true, target_section, target_source_index));
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

function fixture_cron_refresh_plan(path, bin, list_marker, subscription_marker) {
    let data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(data);
    cron_refresh_plan(
        object_or_empty(data.settings),
        fixture_section_list(data),
        bin,
        list_marker,
        subscription_marker
    );
}

function fixture_cron_refresh_apply(path, existing_crontab_path, bin, list_marker, subscription_marker) {
    let data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(data);
    let result = cron_refresh_apply_result(
        object_or_empty(data.settings),
        fixture_section_list(data),
        fs.readfile(as_string(existing_crontab_path)) || "",
        bin,
        list_marker,
        subscription_marker
    );

    write_json({
        crontab: result.crontab,
        logs: result.logs
    });
    exit(result.status);
}

function fixture_section_by_name(data, target_name) {
    target_name = as_string(target_name);
    for (let section in fixture_section_list(data))
        if (section_name(section) == target_name)
            return section;
    return {};
}

function uci_cron_refresh_plan(bin, list_marker, subscription_marker) {
    cron_refresh_plan(
        uci_settings(),
        uci_sections("section"),
        bin,
        list_marker,
        subscription_marker
    );
}

function uci_refresh_cron(bin, list_marker, subscription_marker) {
    refresh_cron_from_sources(
        uci_settings(),
        uci_sections("section"),
        bin,
        list_marker,
        subscription_marker
    );
}

function uci_list_update_due_status(timestamp_path, now) {
    list_update_due_status(uci_settings(), timestamp_path, now);
}

function uci_subscription_update_section_due_status(section_name, timestamp_path, now) {
    subscription_update_section_due_status(object_or_empty(uci_core.get_all(CONFIG_NAME, section_name)), timestamp_path, now);
}

function fixture_list_update_due_status(path, timestamp_path, now) {
    let data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(data);
    list_update_due_status(object_or_empty(data.settings), timestamp_path, now);
}

function fixture_subscription_update_section_due_status(path, section_name_value, timestamp_path, now) {
    let data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(data);
    subscription_update_section_due_status(fixture_section_by_name(data, section_name_value), timestamp_path, now);
}

let mode = ARGV[0] || "";

if (mode == "json-length")
    json_length(ARGV[1]);
else if (mode == "update-is-due")
    update_is_due(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "duration-to-seconds")
    duration_to_seconds(ARGV[1]);
else if (mode == "due-check-cron-schedule")
    due_check_cron_schedule(ARGV[1]);
else if (mode == "list-update-cron-job")
    update_cron_job(ARGV[1], "list_update_if_due", ARGV[2], ARGV[3]);
else if (mode == "subscription-update-cron-job")
    subscription_update_cron_job(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "subscription-update-interval-plan")
    subscription_update_interval_plan();
else if (mode == "cron-refresh-plan")
    uci_cron_refresh_plan(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "cron-refresh-plan-fixture")
    fixture_cron_refresh_plan(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "refresh-cron-from-uci")
    uci_refresh_cron(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "refresh-cron-fixture")
    fixture_cron_refresh_apply(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "remove-cron-jobs")
    remove_cron_jobs(ARGV[1], ARGV[2]);
else if (mode == "list-update")
    list_update();
else if (mode == "list-update-if-due")
    list_update_if_due();
else if (mode == "stop-list-update")
    stop_list_update();
else if (mode == "list-update-due-status")
    uci_list_update_due_status(ARGV[1], ARGV[2]);
else if (mode == "list-update-due-status-fixture")
    fixture_list_update_due_status(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "subscription-update-section-due-status")
    uci_subscription_update_section_due_status(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "subscription-update-section-due-status-fixture")
    fixture_subscription_update_section_due_status(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "file-first-line")
    file_first_line(ARGV[1]);
else if (mode == "stdin-first-ipv4-line")
    stdin_first_ipv4_line();
else if (mode == "filter-cron-markers")
    filter_cron_markers([ARGV[1], ARGV[2]]);
else if (mode == "job-pid")
    job_pid(ARGV[1]);
else if (mode == "subscription-job-state-path")
    subscription_job_state_path(ARGV[1], ARGV[2]);
else if (mode == "subscription-job-json-response")
    subscription_job_json_response(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "subscription-running-job-state")
    subscription_running_job_state(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "subscription-job-refresh-plan")
    subscription_job_refresh_plan(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "subscription-finished-job-state")
    subscription_finished_job_state(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "subscription-stale-job-state")
    subscription_stale_job_state(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "subscription-status-error")
    subscription_status_error(ARGV[1]);
else if (mode == "subscription-cleanup-jobs")
    subscription_cleanup_jobs();
else if (mode == "subscription-update-worker")
    subscription_update_worker(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "subscription-update")
    subscription_update(ARGV[1], ARGV[2]);
else if (mode == "subscription-update-if-due")
    subscription_update_if_due();
else if (mode == "subscription-update-async")
    subscription_update_async(ARGV[1], ARGV[2]);
else if (mode == "subscription-update-status")
    subscription_update_status(ARGV[1]);
else if (mode == "component-action-worker")
    component_action_worker(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "component-action-async")
    component_action_async(ARGV[1], ARGV[2]);
else if (mode == "component-action-status")
    component_action_status(ARGV[1]);
else {
    warn("Usage: components/updates.uc <operation> ...\n");
    exit(1);
}
