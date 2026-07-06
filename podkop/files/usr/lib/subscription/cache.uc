#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let connections = require("config.connections");

const CONFIG_NAME = getenv("PODKOP_CONFIG_NAME") || "podkop-plus";
const LIB_DIR = getenv("PODKOP_LIB") || "/usr/lib/podkop-plus";
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || "/tmp/sing-box";
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || TMP_SING_BOX_FOLDER + "/rulesets";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || TMP_SING_BOX_FOLDER + "/subscriptions";
const PODKOP_RUNTIME_STATE_DIR = getenv("PODKOP_RUNTIME_STATE_DIR") || "/var/run/podkop-plus";
const PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR = getenv("PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR") || PODKOP_RUNTIME_STATE_DIR + "/subscription-update";
const PODKOP_SUBSCRIPTION_LINKS_DIR = getenv("PODKOP_SUBSCRIPTION_LINKS_DIR") || PODKOP_RUNTIME_STATE_DIR + "/subscription-links";
const PODKOP_SUBSCRIPTION_METADATA_DIR = getenv("PODKOP_SUBSCRIPTION_METADATA_DIR") || PODKOP_RUNTIME_STATE_DIR + "/subscription-metadata";
const PODKOP_OUTBOUND_METADATA_DIR = getenv("PODKOP_OUTBOUND_METADATA_DIR") || PODKOP_RUNTIME_STATE_DIR + "/outbound-metadata";
const PODKOP_SECTION_CACHE_DIR = getenv("PODKOP_SECTION_CACHE_DIR") || PODKOP_RUNTIME_STATE_DIR + "/section-cache";
const PODKOP_RUNTIME_CACHE_FORMAT_FILE = getenv("PODKOP_RUNTIME_CACHE_FORMAT_FILE") || PODKOP_RUNTIME_STATE_DIR + "/cache-format";
const PODKOP_RUNTIME_CACHE_FORMAT = getenv("PODKOP_RUNTIME_CACHE_FORMAT") || "7";
const PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/podkop-plus/subscription-cache";
const PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE = getenv("PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE") || PODKOP_RUNTIME_STATE_DIR + "/subscription-bootstrap-retry.pid";
const PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR = getenv("PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR") || PODKOP_RUNTIME_STATE_DIR + "/subscription-update.lock";
const PODKOP_PENDING_RELOAD_FILE = getenv("PODKOP_PENDING_RELOAD_FILE") || PODKOP_RUNTIME_STATE_DIR + "/reload.pending";
const PODKOP_SERVICE_INIT = getenv("PODKOP_SERVICE_INIT") || "/etc/init.d/podkop-plus";
const SB_SERVICE_MIXED_INBOUND_ADDRESS = getenv("SB_SERVICE_MIXED_INBOUND_ADDRESS") || "127.0.0.1";
const SB_SERVICE_MIXED_INBOUND_PORT = getenv("SB_SERVICE_MIXED_INBOUND_PORT") || "4534";
const SB_VARIANT_STATE_FILE = getenv("SB_VARIANT_STATE_FILE") || "/etc/podkop-plus/sing-box-variant";
const SB_VERSION_STATE_FILE = getenv("SB_VERSION_STATE_FILE") || "/etc/podkop-plus/sing-box-version";
const ZAPRET_PROVIDER_NFQWS_BIN = getenv("ZAPRET_PROVIDER_NFQWS_BIN") || "/opt/zapret/nfq/nfqws";
const ZAPRET2_PROVIDER_NFQWS2_BIN = getenv("ZAPRET2_PROVIDER_NFQWS2_BIN") || "/opt/zapret2/nfq2/nfqws2";
const BYEDPI_BIN = getenv("BYEDPI_BIN") || "/usr/bin/ciadpi";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let data = fs.readfile("/dev/stdin");
    return data == null ? "" : data;
}

function read_json(path) {
    if (path == null || path == "" || path == "-")
        return null;

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

function write_file(path, value) {
    return fs.writefile(path, value) != null;
}

function write_json(path, value) {
    return write_file(path, sprintf("%J", value) + "\n");
}

function write_stdout_json(value) {
    print(sprintf("%J", value), "\n");
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

function file_has_exact_line(path, needle) {
    let data = fs.readfile(path);
    if (data == null)
        return false;

    needle = as_string(needle);
    for (let line in split(data, "\n"))
        if (as_string(line) == needle)
            return true;

    return false;
}

function whitespace_values(value) {
    let result = [];
    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function state_list_contains(list, value) {
    value = as_string(value);
    if (value == "")
        return false;

    for (let item in whitespace_values(list))
        if (item == value)
            return true;

    return false;
}

function append_state_list_once(list, value) {
    list = trim(as_string(list));
    value = as_string(value);

    if (value == "" || state_list_contains(list, value)) {
        print(list, "\n");
        return;
    }

    print(list, list != "" ? " " : "", value, "\n");
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
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

function bool_value(value, fallback) {
    if (value == null)
        return !!fallback;

    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function bool_option(section, key, fallback) {
    return bool_value(object_or_empty(section)[key], fallback);
}

function unsigned_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9]/) != null)
        return null;
    return int(value);
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

function cache_section_is_safe(section) {
    section = as_string(section);
    return section != "" && index(section, "/") < 0 && index(section, "..") < 0;
}

function append_word_once(words, value) {
    words = trim(as_string(words));
    value = as_string(value);

    if (value == "" || state_list_contains(words, value))
        return words;

    return words + (words != "" ? " " : "") + value;
}

function section_name(section) {
    return as_string(object_or_empty(section)[".name"]);
}

function source_id(section, index) {
    return as_string(section) + "-subscription-" + as_string(index);
}

function subscription_metadata_path(section) {
    section = as_string(section);
    if (!cache_section_is_safe(section))
        return "";
    return PODKOP_SUBSCRIPTION_METADATA_DIR + "/" + section + ".json";
}

function outbound_metadata_path(section) {
    section = as_string(section);
    if (!cache_section_is_safe(section))
        return "";
    return PODKOP_OUTBOUND_METADATA_DIR + "/" + section + ".json";
}

function section_has_subscription_urls(section) {
    return length(connections.subscription_urls(section)) > 0;
}

function section_is_subscription_proxy(section) {
    return bool_option(section, "enabled", true) &&
        connections.is_connections_action(option(section, "action", "")) &&
        section_has_subscription_urls(section);
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

function subscription_source_count(section) {
    return length(connections.subscription_urls(section));
}

function cache_keep_sets(sections) {
    let keep = {
        sections: "",
        sources: "",
        all: ""
    };

    for (let section in sections) {
        section = object_or_empty(section);
        let name = section_name(section);
        if (!cache_section_is_safe(name))
            continue;

        keep.sections = append_word_once(keep.sections, name);
        keep.all = append_word_once(keep.all, name);

        let count = subscription_source_count(section);
        for (let i = 1; i <= count; i++) {
            let source = source_id(name, i);
            if (!cache_section_is_safe(source))
                continue;

            keep.sources = append_word_once(keep.sources, source);
            keep.all = append_word_once(keep.all, source);
        }
    }

    return keep;
}

function runtime_cache_missing(sections, section_cache_dir) {
    section_cache_dir = as_string(section_cache_dir);

    for (let section in sections) {
        section = object_or_empty(section);
        let name = section_name(section);
        if (!section_is_subscription_proxy(section))
            continue;
        if (!cache_section_is_safe(name))
            continue;
        if (fs.stat(section_cache_dir + "/" + name + ".json") == null)
            return true;
    }

    return false;
}

function path_starts_with(path, prefix) {
    path = as_string(path);
    prefix = as_string(prefix);
    if (prefix == "")
        return false;
    return path == prefix || substr(path, 0, length(prefix) + 1) == prefix + "/";
}

function ends_with(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

function cache_name_from_file(path) {
    let slash = rindex(path, "/");
    let file_name = slash >= 0 ? substr(path, slash + 1) : path;

    if (file_name == "cache-format")
        return "";
    if (ends_with(file_name, ".metadata.json"))
        return substr(file_name, 0, length(file_name) - 14);
    if (ends_with(file_name, ".json"))
        return substr(file_name, 0, length(file_name) - 5);
    if (ends_with(file_name, ".url"))
        return substr(file_name, 0, length(file_name) - 4);
    if (ends_with(file_name, ".user_agent"))
        return substr(file_name, 0, length(file_name) - 11);
    if (ends_with(file_name, ".hwid"))
        return substr(file_name, 0, length(file_name) - 5);

    return "";
}

function keep_names_for_path(path, keep, tmp_dir, persistent_dir, section_cache_dir, links_dir, metadata_dir, outbound_metadata_dir) {
    if (path_starts_with(path, tmp_dir) || path_starts_with(path, persistent_dir))
        return keep.sources;
    if (path_starts_with(path, section_cache_dir))
        return keep.all;
    if (path_starts_with(path, links_dir) || path_starts_with(path, metadata_dir) || path_starts_with(path, outbound_metadata_dir))
        return keep.sections;
    return "";
}

function stale_cache_delete_paths(sections, tmp_dir, persistent_dir, section_cache_dir, links_dir, metadata_dir, outbound_metadata_dir) {
    let keep = cache_keep_sets(sections);

    for (let path in split(read_stdin(), "\n")) {
        path = as_string(path);
        if (path == "")
            continue;

        let cache_name = cache_name_from_file(path);
        if (cache_name == "")
            continue;

        let keep_names = keep_names_for_path(path, keep, tmp_dir, persistent_dir, section_cache_dir, links_dir, metadata_dir, outbound_metadata_dir);
        if (state_list_contains(keep_names, cache_name))
            continue;

        print(path, "\n");
    }
}

function fixture_section_list(data) {
    data = object_or_empty(data);
    if (type(data.section) == "array")
        return data.section;
    if (type(data.section) == "object")
        return [ data.section ];
    if (type(data.sections) == "array")
        return data.sections;
    return [];
}

function uci_sections() {
    return uci_core.section_objects(CONFIG_NAME, "section");
}

function maintenance_plan(sections, section_cache_dir) {
    let keep = cache_keep_sets(sections);
    print("sections\t", keep.sections, "\n");
    print("sources\t", keep.sources, "\n");
    print("all\t", keep.all, "\n");
    print("missing\t", runtime_cache_missing(sections, section_cache_dir) ? "1" : "0", "\n");
}

let auto_user_agent_profiles = [
    "Happ",
    "v2rayN",
    "v2rayNG",
    "Mihomo",
    "Clash.Meta"
];

let auto_user_agents = {};
for (let profile in auto_user_agent_profiles)
    auto_user_agents[profile] = true;

function user_agent_supported(user_agent, default_user_agent) {
    user_agent = as_string(user_agent);
    default_user_agent = as_string(default_user_agent);

    if (user_agent == "")
        return false;
    if (user_agent == default_user_agent)
        return true;

    return auto_user_agents[user_agent] == true;
}

function user_agent_matches_config(configured_user_agent, cached_user_agent, default_user_agent) {
    configured_user_agent = as_string(configured_user_agent);
    cached_user_agent = as_string(cached_user_agent);

    if (configured_user_agent != "")
        return cached_user_agent == configured_user_agent;

    return user_agent_supported(cached_user_agent, default_user_agent);
}

let parser_module = null;

function subscription_parser() {
    if (parser_module == null)
        parser_module = require("subscription.parser");
    return parser_module;
}

function subscription_cache_is_usable(path) {
    if (fs.stat(as_string(path)) == null)
        return false;
    return subscription_parser().validate_subscription(path);
}

function source_json_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".json";
}

function source_url_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".url";
}

function source_user_agent_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".user_agent";
}

function source_hwid_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".hwid";
}

function read_text(path) {
    let data = fs.readfile(as_string(path));
    return data == null ? "" : as_string(data);
}

function write_text(path, value) {
    return fs.writefile(as_string(path), as_string(value)) != null;
}

function copy_file(source, target) {
    let data = fs.readfile(as_string(source));
    if (data == null)
        return false;

    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", as_string(target), stamp[0], stamp[1]);
    if (!write_file(tmp_path, data))
        return false;
    if (!fs.rename(tmp_path, as_string(target))) {
        fs.unlink(tmp_path);
        return false;
    }
    return true;
}

function unlink_path(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && stat.size != null && stat.size > 0;
}

function files_equal(left, right) {
    let left_data = fs.readfile(as_string(left));
    let right_data = fs.readfile(as_string(right));
    return left_data != null && right_data != null && left_data == right_data;
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

function command_args_with(base, extra) {
    let result = [];

    for (let arg in base)
        push(result, arg);
    for (let arg in extra)
        push(result, arg);

    return result;
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

function command_success_from_args(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_status_from_args(args) {
    let status = int(system(command_from_args(args)));
    return status > 255 ? int(status / 256) : status;
}

function run_silent(command) {
    system(command + " >/dev/null 2>&1");
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "podkop-plus", "[" + level + "] " + as_string(message) ]);
}

function ensure_dir(path) {
    run_silent("mkdir -p " + shell_quote(path));
}

function chmod_path(path, mode) {
    run_silent("chmod " + shell_quote(mode) + " " + shell_quote(path));
}

function ensure_runtime_dirs() {
    ensure_dir(TMP_SING_BOX_FOLDER);
    ensure_dir(TMP_RULESET_FOLDER);
    ensure_dir(TMP_SUBSCRIPTION_FOLDER);
    ensure_dir(PODKOP_RUNTIME_STATE_DIR);
    ensure_dir(PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR);
    ensure_dir(PODKOP_SUBSCRIPTION_LINKS_DIR);
    ensure_dir(PODKOP_SUBSCRIPTION_METADATA_DIR);
    ensure_dir(PODKOP_OUTBOUND_METADATA_DIR);
    ensure_dir(PODKOP_SECTION_CACHE_DIR);
}

function clear_subscription_runtime_cache() {
    run_silent("rm -rf " +
        shell_quote(TMP_SUBSCRIPTION_FOLDER) + " " +
        shell_quote(PODKOP_SUBSCRIPTION_LINKS_DIR) + " " +
        shell_quote(PODKOP_SUBSCRIPTION_METADATA_DIR) + " " +
        shell_quote(PODKOP_OUTBOUND_METADATA_DIR) + " " +
        shell_quote(PODKOP_SECTION_CACHE_DIR));
}

function ensure_runtime_cache_format() {
    ensure_dir(PODKOP_RUNTIME_STATE_DIR);

    if (file_first_line_value(PODKOP_RUNTIME_CACHE_FORMAT_FILE) != PODKOP_RUNTIME_CACHE_FORMAT) {
        log_message("Runtime subscription cache format changed; clearing old subscription cache", "info");
        clear_subscription_runtime_cache();
        ensure_runtime_dirs();
        write_file(PODKOP_RUNTIME_CACHE_FORMAT_FILE, PODKOP_RUNTIME_CACHE_FORMAT + "\n");
    }

    if (file_first_line_value(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) != PODKOP_RUNTIME_CACHE_FORMAT) {
        run_silent("rm -rf " + shell_quote(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR));
        ensure_dir(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        chmod_path(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, "700");
        write_file(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE, PODKOP_RUNTIME_CACHE_FORMAT + "\n");
        chmod_path(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE, "600");
    }
}

function remove_legacy_server_country_cache() {
    unlink_path(PODKOP_RUNTIME_STATE_DIR + "/server-country-cache.json");
}

function temp_path(dir, section, kind) {
    ensure_dir(dir);
    let stamp = clock();
    return sprintf("%s/%s.%s.%d.%d", dir, as_string(section), as_string(kind), stamp[0], stamp[1]);
}

function move_file(source, target) {
    unlink_path(target);
    return fs.rename(as_string(source), as_string(target));
}

function write_text_if_changed(path, value) {
    path = as_string(path);
    value = as_string(value);

    if (fs.readfile(path) == value) {
        chmod_path(path, "600");
        return true;
    }

    let tmp_path = sprintf("%s.%d.%d.tmp", path, clock()[0], clock()[1]);
    if (!write_file(tmp_path, value)) {
        unlink_path(tmp_path);
        return false;
    }
    if (!fs.rename(tmp_path, path)) {
        unlink_path(tmp_path);
        return false;
    }

    chmod_path(path, "600");
    return true;
}

function copy_file_if_changed(source, target) {
    if (!file_nonempty(source))
        return false;
    if (files_equal(source, target)) {
        chmod_path(target, "600");
        return true;
    }
    if (!copy_file(source, target))
        return false;

    chmod_path(target, "600");
    return true;
}

function get_device_model() {
    let model = fs.readfile("/tmp/sysinfo/model");
    model = trim(as_string(model));
    return model != "" ? model : "OpenWrt Router";
}

function generate_hwid() {
    let mac = trim(as_string(fs.readfile("/sys/class/net/eth0/address")));
    if (mac == "")
        mac = trim(as_string(fs.readfile("/sys/class/net/br-lan/address")));

    let input = mac + "-" + get_device_model();
    let output = command_output("printf %s " + shell_quote(input) + " | md5sum");
    let hash = length(whitespace_values(output)) > 0 ? substr(whitespace_values(output)[0], 0, 16) : "";
    return substr(hash, 0, 4) + "-" + substr(hash, 4, 4) + "-" + substr(hash, 8, 4) + "-" + substr(hash, 12, 4);
}

function hwid_matches_config(configured_hwid, cached_hwid) {
    configured_hwid = as_string(configured_hwid);
    cached_hwid = as_string(cached_hwid);

    if (configured_hwid != "")
        return cached_hwid == configured_hwid;

    return cached_hwid == "" || cached_hwid == generate_hwid();
}

function restore_persistent_subscription_cache(source_section, tmp_dir, persistent_dir, expected_url, expected_user_agent, expected_hwid, default_user_agent) {
    if (!cache_section_is_safe(source_section))
        return false;

    let runtime_json = source_json_path(tmp_dir, source_section);
    if (subscription_cache_is_usable(runtime_json))
        return true;

    let persistent_json = source_json_path(persistent_dir, source_section);
    if (!subscription_cache_is_usable(persistent_json))
        return false;

    let cached_url = read_text(source_url_path(persistent_dir, source_section));
    let cached_user_agent = read_text(source_user_agent_path(persistent_dir, source_section));
    let cached_hwid = read_text(source_hwid_path(persistent_dir, source_section));
    if (cached_url != as_string(expected_url))
        return false;
    if (!user_agent_matches_config(expected_user_agent, cached_user_agent, default_user_agent))
        return false;
    if (!hwid_matches_config(expected_hwid, cached_hwid))
        return false;

    return copy_file(persistent_json, runtime_json) &&
        write_text(source_url_path(tmp_dir, source_section), cached_url) &&
        write_text(source_user_agent_path(tmp_dir, source_section), cached_user_agent) &&
        write_text(source_hwid_path(tmp_dir, source_section), cached_hwid);
}

function subscription_source_profile(section, entry) {
    let parsed = subscription_parser().parse_subscription_source_entry(entry);
    if (type(parsed) != "object" || parsed.valid !== true)
        return parsed;

    let user_agent = connections.subscription_user_agent(section, entry);
    if (user_agent != "")
        parsed.user_agent = user_agent;

    parsed.hwid = connections.subscription_hwid(section, entry);
    parsed.download_section = connections.subscription_download_section(section, entry);
    parsed.update_enabled = connections.subscription_update_enabled(section, entry);
    parsed.update_interval = connections.subscription_update_interval(section, entry);
    parsed.show_dashboard_metadata = connections.subscription_dashboard_metadata_enabled(section, entry);
    return parsed;
}

function source_cache_profile_matches(parsed, cached_url, cached_user_agent, cached_hwid, default_user_agent) {
    return cached_url == as_string(parsed.url) &&
        user_agent_matches_config(parsed.user_agent, cached_user_agent, default_user_agent) &&
        hwid_matches_config(parsed.hwid, cached_hwid);
}

function section_current_usable_cache(section, tmp_dir, persistent_dir, default_user_agent) {
    section = object_or_empty(section);
    let name = section_name(section);
    if (!section_has_subscription_urls(section) || !cache_section_is_safe(name))
        return false;

    let index = 0;
    for (let entry in connections.subscription_urls(section)) {
        index++;
        let parsed = subscription_source_profile(section, entry);
        if (type(parsed) != "object" || parsed.valid !== true)
            continue;

        let source_section = source_id(name, index);
        if (!restore_persistent_subscription_cache(
            source_section,
            tmp_dir,
            persistent_dir,
            parsed.url,
            parsed.user_agent,
            parsed.hwid,
            default_user_agent
        ))
            continue;

        if (!subscription_cache_is_usable(source_json_path(tmp_dir, source_section)))
            continue;

        let cached_url = read_text(source_url_path(tmp_dir, source_section));
        let cached_user_agent = read_text(source_user_agent_path(tmp_dir, source_section));
        let cached_hwid = read_text(source_hwid_path(tmp_dir, source_section));
        if (source_cache_profile_matches(parsed, cached_url, cached_user_agent, cached_hwid, default_user_agent))
            return true;
    }

    return false;
}

function uci_section(section_name_value) {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, section_name_value));
}

function uci_named_section(section_name_value) {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, section_name_value));
}

function list_option(section, key) {
    let value = object_or_empty(section)[key];
    if (type(value) == "array")
        return value;
    if (as_string(value) != "")
        return [ as_string(value) ];
    return [];
}

function find_section(sections, name) {
    name = as_string(name);
    for (let section in sections) {
        section = object_or_empty(section);
        if (section_name(section) == name)
            return section;
    }
    return {};
}

function file_executable(path) {
    let stat = fs.stat(as_string(path));
    if (stat == null || stat.mode == null)
        return false;

    return (int(stat.mode) & 73) != 0;
}

function sing_box_service_running() {
    return command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/state.uc", "sing-box-service-running" ]);
}

function provider_action_is_available(action) {
    if (action == "byedpi")
        return file_executable(BYEDPI_BIN);
    if (action == "zapret")
        return file_executable(ZAPRET_PROVIDER_NFQWS_BIN);
    if (action == "zapret2")
        return file_executable(ZAPRET2_PROVIDER_NFQWS2_BIN);
    return false;
}

function section_current_usable_cache_by_name(sections, section, default_user_agent) {
    return section_current_usable_cache(find_section(sections, section), TMP_SUBSCRIPTION_FOLDER, PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, default_user_agent);
}

function section_has_non_subscription_connection_sources(section) {
    return length(connections.connection_urls(section)) > 0 ||
        length(connections.interfaces(section)) > 0 ||
        length(connections.outbound_jsons(section)) > 0;
}

function subscription_download_target_section_is_ready(sections, download_section, startup_blocked_sections, default_user_agent) {
    download_section = as_string(download_section);
    if (download_section == "" || state_list_contains(startup_blocked_sections, download_section))
        return false;

    let section = find_section(sections, download_section);
    if (!bool_option(section, "enabled", true))
        return false;

    let action = option(section, "action", "");
    if (connections.is_connections_action(action)) {
        if (section_has_non_subscription_connection_sources(section))
            return true;
        if (section_current_usable_cache_by_name(sections, download_section, default_user_agent))
            return true;

        return false;
    }

    return provider_action_is_available(action);
}

function subscription_bootstrap_download_section_is_ready(sections, startup_blocked_sections, default_user_agent) {
    let any_target = false;

    for (let section_name_value in whitespace_values(startup_blocked_sections)) {
        let section = find_section(sections, section_name_value);
        let source_can_retry = false;

        for (let entry in connections.subscription_urls(section)) {
            let parsed = subscription_source_profile(section, entry);
            let download_section = as_string(object_or_empty(parsed).download_section);
            if (download_section == "" || download_section == section_name_value)
                continue;
            any_target = true;

            if (subscription_download_target_section_is_ready(sections, download_section, startup_blocked_sections, default_user_agent)) {
                source_can_retry = true;
                break;
            }
        }

        if (!source_can_retry)
            return false;
    }

    if (!any_target)
        log_message("Subscription startup cannot be deferred because unavailable subscription-only rules have no download-through-section target", "error");

    return any_target;
}

function cache_candidate_paths() {
    let result = [];
    for (let dir in [
        TMP_SUBSCRIPTION_FOLDER,
        PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        PODKOP_SECTION_CACHE_DIR,
        PODKOP_SUBSCRIPTION_LINKS_DIR,
        PODKOP_SUBSCRIPTION_METADATA_DIR,
        PODKOP_OUTBOUND_METADATA_DIR
    ]) {
        let entries = fs.lsdir(dir);
        if (type(entries) != "array")
            continue;
        for (let entry in entries) {
            let path = dir + "/" + as_string(entry);
            let stat = fs.stat(path);
            if (stat != null && stat.type == "file")
                push(result, path);
        }
    }
    return result;
}

function prune_stale_subscription_caches_for_sections(sections) {
    ensure_runtime_dirs();
    let keep = cache_keep_sets(sections);

    for (let path in cache_candidate_paths()) {
        let cache_name = cache_name_from_file(path);
        if (cache_name == "")
            continue;

        let keep_names = keep_names_for_path(
            path,
            keep,
            TMP_SUBSCRIPTION_FOLDER,
            PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
            PODKOP_SECTION_CACHE_DIR,
            PODKOP_SUBSCRIPTION_LINKS_DIR,
            PODKOP_SUBSCRIPTION_METADATA_DIR,
            PODKOP_OUTBOUND_METADATA_DIR
        );
        if (!state_list_contains(keep_names, cache_name))
            unlink_path(path);
    }
}

function append_user_agent_candidate(result, seen, candidate, default_user_agent) {
    candidate = as_string(candidate);
    if (!user_agent_supported(candidate, default_user_agent) || seen[candidate])
        return;

    seen[candidate] = true;
    push(result, candidate);
}

function write_user_agent_candidates(path, configured_user_agent, preferred_user_agent, default_user_agent) {
    path = as_string(path);
    configured_user_agent = as_string(configured_user_agent);
    preferred_user_agent = as_string(preferred_user_agent);
    default_user_agent = as_string(default_user_agent);

    if (configured_user_agent != "") {
        if (!write_file(path, configured_user_agent + "\n"))
            exit(1);
        return;
    }

    let result = [];
    let seen = {};
    let candidates = [ default_user_agent, preferred_user_agent ];
    for (let profile in auto_user_agent_profiles)
        push(candidates, profile);

    for (let candidate in candidates)
        append_user_agent_candidate(result, seen, candidate, default_user_agent);

    if (!write_file(path, length(result) > 0 ? join("\n", result) + "\n" : ""))
        exit(1);
}

function write_empty_link() {
    write_stdout_json({ link: "" });
}

function write_empty_outbound_metadata() {
    write_stdout_json({
        names: {},
        countries: {}
    });
}

function is_array(value) {
    return type(value) == "array";
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function int_or_zero(value) {
    value = as_string(value);
    if (match(value, /^[0-9]+$/) == null)
        return 0;
    return int(value);
}

function count_label(count, singular, plural) {
    count = int(count || 0);
    return as_string(count) + " " + (count == 1 ? singular : plural);
}

function subscription_file_stats(path) {
    let value = object_or_empty(read_json(path));
    return {
        outbounds: length(array_or_empty(value.outbounds)),
        skipped: int_or_zero(value.skipped)
    };
}

function subscription_import_stats_text(path) {
    let stats = subscription_file_stats(path);
    let text = count_label(stats.outbounds, "proxy entry", "proxy entries");
    if (stats.skipped > 0)
        text += ", " + count_label(stats.skipped, "skipped entry", "skipped entries");
    return text;
}

function subscription_source_summary(section_name_value, source_index, normalized_path, result) {
    let prefix = "Subscription source " + as_string(source_index) + " for rule '" + as_string(section_name_value) + "'";
    let stats = subscription_import_stats_text(normalized_path);

    if (result == "unchanged")
        return prefix + " is unchanged: " + stats;
    if (result == "runtime-unchanged")
        return prefix + " refreshed: runtime proxy entries are unchanged (" + stats + ")";
    return prefix + " imported: " + stats;
}

function log_subscription_source_summary(section_name_value, source_index, normalized_path, result) {
    log_message(subscription_source_summary(section_name_value, source_index, normalized_path, result), "info");
}

function object_key_count(value) {
    return type(value) == "object" ? length(keys(value)) : 0;
}

function valid_metadata_object(value) {
    return type(value) == "object" && object_key_count(value) > 1;
}

function json_length(path) {
    let value = read_json(path);
    if (type(value) == "array" || type(value) == "object")
        print(length(value), "\n");
    else
        print("0\n");
}

function object_has_extra_keys(path) {
    return object_key_count(read_json(path)) > 1;
}

function safe_section(section) {
    return type(section) == "string" && match(section, /^[A-Za-z0-9_-]+$/);
}

function cache_path(cache_dir, section) {
    return cache_dir + "/" + section + ".json";
}

function load_cache(cache_dir, section) {
    return object_or_empty(read_json(cache_path(cache_dir, section)));
}

function normalize_cache(cache, section, format_version) {
    cache.version = int(format_version || 0);
    cache.section = as_string(section);
    cache.links = object_or_empty(cache.links);
    cache.linkRefs = object_or_empty(cache.linkRefs);
    cache.outboundMetadata = object_or_empty(cache.outboundMetadata);
    cache.outboundMetadata.names = object_or_empty(cache.outboundMetadata.names);
    cache.outboundMetadata.countries = object_or_empty(cache.outboundMetadata.countries);
    cache.servers = object_or_empty(cache.servers);
    cache.urltestCandidateTags = array_or_empty(cache.urltestCandidateTags);
    cache.urltestGroups = object_or_empty(cache.urltestGroups);
    cache.subscriptionMetadata = array_or_empty(cache.subscriptionMetadata);
    return cache;
}

function save_cache(cache_dir, section, format_version, cache) {
    cache = normalize_cache(cache, section, format_version);
    let path = cache_path(cache_dir, section);
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);

    if (!write_json(tmp_path, cache))
        exit(1);
    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        exit(1);
    }
}

function write_link_cache(cache_dir, format_version, section, links_path, link_refs_path) {
    let cache = load_cache(cache_dir, section);
    cache.links = object_or_empty(read_json(links_path));
    cache.linkRefs = object_or_empty(read_json(link_refs_path));
    save_cache(cache_dir, section, format_version, cache);
}

function write_outbound_metadata(cache_dir, format_version, section, names_path, countries_path, servers_path) {
    let cache = load_cache(cache_dir, section);
    cache.outboundMetadata = {
        names: object_or_empty(read_json(names_path)),
        countries: object_or_empty(read_json(countries_path))
    };
    cache.servers = object_or_empty(read_json(servers_path));
    save_cache(cache_dir, section, format_version, cache);
}

function metadata_array_from_file(metadata_path) {
    let metadata = read_json(metadata_path);
    let result = [];

    if (is_array(metadata)) {
        for (let item in metadata) {
            if (valid_metadata_object(item))
                push(result, item);
        }
    }
    else if (valid_metadata_object(metadata)) {
        push(result, metadata);
    }

    return result;
}

function write_subscription_metadata(cache_dir, format_version, section, metadata_path) {
    let cache = load_cache(cache_dir, section);
    cache.subscriptionMetadata = metadata_array_from_file(metadata_path);
    save_cache(cache_dir, section, format_version, cache);
}

function read_metadata_items_from_cache(cache_dir, section, legacy_path) {
    let cache = load_cache(cache_dir, section);
    let metadata = cache.subscriptionMetadata;

    if (type(metadata) != "array")
        metadata = read_json(legacy_path);

    let result = [];
    if (is_array(metadata)) {
        for (let item in metadata) {
            if (valid_metadata_object(item))
                push(result, item);
        }
    }
    else if (valid_metadata_object(metadata)) {
        push(result, metadata);
    }

    return result;
}

function metadata_source_index(item) {
    if (type(item) != "object")
        return null;
    let value = item.sourceIndex != null ? item.sourceIndex : item.source_index;
    if (value == null || as_string(value) == "")
        return null;
    return int(value);
}

function metadata_source_section(item) {
    if (type(item) != "object")
        return "";
    return as_string(item.sourceSection != null ? item.sourceSection : item.source_section);
}

function metadata_items_have_source_markers(items) {
    for (let item in items) {
        if (metadata_source_index(item) != null || metadata_source_section(item) != "")
            return true;
    }
    return false;
}

function metadata_matches_source(item, source_index, source_section, has_source_markers) {
    if (!has_source_markers)
        return false;

    let item_section = metadata_source_section(item);
    let item_index = metadata_source_index(item);
    return (item_section != "" && item_section == source_section) ||
        (item_section == "" && item_index == source_index);
}

function attach_source_metadata(item, source_index, source_section) {
    if (type(item) != "object")
        item = {};
    item.sourceIndex = source_index;
    item.sourceSection = as_string(source_section);
    return item;
}

function append_metadata_file(array_path, metadata_path, source_index, source_section) {
    if (array_path == null || array_path == "")
        return;

    let array = array_or_empty(read_json(array_path));
    let metadata = read_json(metadata_path);
    source_index = int(source_index || 0);
    source_section = as_string(source_section);

    if (valid_metadata_object(metadata)) {
        push(array, attach_source_metadata(metadata, source_index, source_section));
        write_json(array_path, array);
    }
}

function append_cached_metadata(array_path, cache_dir, section, legacy_path, source_index, source_section) {
    if (array_path == null || array_path == "")
        return;

    let array = array_or_empty(read_json(array_path));
    let items = read_metadata_items_from_cache(cache_dir, section, legacy_path);
    source_index = int(source_index || 0);
    source_section = as_string(source_section);

    let has_source_markers = metadata_items_have_source_markers(items);
    let selected = null;
    if (has_source_markers) {
        for (let item in items) {
            if (metadata_matches_source(item, source_index, source_section, true)) {
                selected = item;
                break;
            }
        }
    }
    else if (source_index > 0 && source_index <= length(items)) {
        selected = items[source_index - 1];
    }

    if (valid_metadata_object(selected)) {
        push(array, attach_source_metadata(selected, source_index, source_section));
        write_json(array_path, array);
    }
}

function write_source_metadata(cache_dir, format_version, section, source_index, source_section, metadata_path, legacy_path) {
    let cache = load_cache(cache_dir, section);
    let items = read_metadata_items_from_cache(cache_dir, section, legacy_path);
    let kept = [];
    let has_source_markers = metadata_items_have_source_markers(items);
    source_index = int(source_index || 0);
    source_section = as_string(source_section);

    for (let index, item in items) {
        let keep = has_source_markers ?
            !metadata_matches_source(item, source_index, source_section, true) :
            (index + 1) != source_index;
        if (keep && valid_metadata_object(item))
            push(kept, item);
    }

    let metadata = read_json(metadata_path);
    if (valid_metadata_object(metadata))
        push(kept, attach_source_metadata(metadata, source_index, source_section));

    sort(kept, function(first, second) {
        let first_index = metadata_source_index(first) || 999999;
        let second_index = metadata_source_index(second) || 999999;
        return first_index == second_index ? 0 : (first_index < second_index ? -1 : 1);
    });

    cache.subscriptionMetadata = kept;
    save_cache(cache_dir, section, format_version, cache);
}

function starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function uri_encode(value) {
    value = as_string(value);
    let result = "";
    for (let i = 0; i < length(value); i++) {
        let char = substr(value, i, 1);
        let code = ord(char);
        if ((code >= 48 && code <= 57) ||
            (code >= 65 && code <= 90) ||
            (code >= 97 && code <= 122) ||
            char == "-" || char == "_" || char == "." || char == "~")
            result += char;
        else
            result += sprintf("%%%02X", code);
    }
    return result;
}

function base64_encode(value) {
    let encoded = b64enc(as_string(value));
    while (length(encoded) > 0 && substr(encoded, length(encoded) - 1) == "=")
        encoded = substr(encoded, 0, length(encoded) - 1);
    return encoded;
}

function host_port(server, port) {
    server = as_string(server);
    if (index(server, ":") >= 0 && !starts_with(server, "["))
        server = "[" + server + "]";
    return server + ":" + as_string(port);
}

function hysteria2_server_port_entry(value) {
    value = as_string(value);
    let colon = index(value, ":");
    if (colon < 0)
        return value;

    let start = substr(value, 0, colon);
    let end = substr(value, colon + 1);
    if (start == "" || end == "")
        return "";

    return start == end ? start : (start + "-" + end);
}

function hysteria2_server_ports_uri(outbound) {
    let server_ports = array_or_empty(outbound.server_ports);
    if (length(server_ports) == 0)
        return "";

    let result = [];
    for (let item in server_ports) {
        let port = hysteria2_server_port_entry(item);
        if (port != "")
            push(result, port);
    }

    return join(",", result);
}

function add_query(params, key, value) {
    value = as_string(value);
    if (value != "")
        push(params, uri_encode(key) + "=" + uri_encode(value));
}

function add_xhttp_extra_query(params, transport) {
    let extra = {};
    for (let item in [
        ["xPaddingBytes", "x_padding_bytes"],
        ["noGRPCHeader", "no_grpc_header"],
        ["scMaxEachPostBytes", "sc_max_each_post_bytes"],
        ["scMinPostsIntervalMs", "sc_min_posts_interval_ms"],
        ["scStreamUpServerSecs", "sc_stream_up_server_secs"]
    ]) {
        if (transport[item[1]] != null)
            extra[item[0]] = transport[item[1]];
    }

    if (type(transport.xmux) == "object") {
        let xmux = {};
        for (let item in [
            ["maxConcurrency", "max_concurrency"],
            ["maxConnections", "max_connections"],
            ["cMaxReuseTimes", "c_max_reuse_times"],
            ["hMaxRequestTimes", "h_max_request_times"],
            ["hMaxReusableSecs", "h_max_reusable_secs"],
            ["hKeepAlivePeriod", "h_keep_alive_period"]
        ]) {
            if (transport.xmux[item[1]] != null)
                xmux[item[0]] = transport.xmux[item[1]];
        }
        if (length(keys(xmux)) > 0)
            extra.xmux = xmux;
    }

    if (length(keys(extra)) > 0)
        add_query(params, "extra", sprintf("%J", extra));
}

function add_tls_query(params, outbound, trojan_default_tls) {
    let tls = type(outbound.tls) == "object" ? outbound.tls : null;
    if (!tls || tls.enabled === false) {
        if (trojan_default_tls)
            add_query(params, "security", "tls");
        return;
    }

    let reality = type(tls.reality) == "object" ? tls.reality : null;
    if (reality && reality.enabled !== false) {
        add_query(params, "security", "reality");
        add_query(params, "pbk", reality.public_key);
        add_query(params, "sid", reality.short_id);
    }
    else {
        add_query(params, "security", "tls");
    }

    add_query(params, "sni", tls.server_name);
    if (tls.insecure === true)
        add_query(params, "allowInsecure", "1");
    if (type(tls.utls) == "object" && tls.utls.enabled !== false)
        add_query(params, "fp", tls.utls.fingerprint);
    if (type(tls.alpn) == "array" && length(tls.alpn) > 0)
        add_query(params, "alpn", join(",", tls.alpn));
}

function add_transport_query(params, outbound) {
    let transport = type(outbound.transport) == "object" ? outbound.transport : null;
    if (!transport) {
        add_query(params, "type", "tcp");
        return;
    }

    let transport_type = as_string(transport.type);
    add_query(params, "type", transport_type != "" ? transport_type : "tcp");

    if (transport_type == "ws") {
        add_query(params, "path", transport.path);
        if (type(transport.headers) == "object")
            add_query(params, "host", transport.headers.Host || transport.headers.host);
    }
    else if (transport_type == "grpc") {
        add_query(params, "serviceName", transport.service_name);
    }
    else if (transport_type == "http") {
        add_query(params, "path", transport.path);
        if (type(transport.host) == "array" && length(transport.host) > 0)
            add_query(params, "host", join(",", transport.host));
        else
            add_query(params, "host", transport.host);
    }
    else if (transport_type == "xhttp") {
        add_query(params, "path", transport.path);
        add_query(params, "host", transport.host);
        add_query(params, "mode", transport.mode);
        add_xhttp_extra_query(params, transport);
    }
}

function query_string(params) {
    return length(params) == 0 ? "" : "?" + join("&", params);
}

function fragment(outbound) {
    let tag = as_string(outbound.tag);
    return tag == "" ? "" : "#" + uri_encode(tag);
}

function serialize_vless(outbound) {
    if (as_string(outbound.uuid) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    add_tls_query(params, outbound, false);
    add_transport_query(params, outbound);
    let encryption = as_string(outbound.encryption);
    if (encryption != "" && encryption != "none")
        add_query(params, "encryption", encryption);
    add_query(params, "flow", outbound.flow);
    add_query(params, "packetEncoding", outbound.packet_encoding);
    return "vless://" + uri_encode(outbound.uuid) + "@" +
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_trojan(outbound) {
    if (as_string(outbound.password) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    add_tls_query(params, outbound, true);
    add_transport_query(params, outbound);
    return "trojan://" + uri_encode(outbound.password) + "@" +
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_shadowsocks(outbound) {
    if (as_string(outbound.method) == "" || as_string(outbound.password) == "" ||
        as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let userinfo = base64_encode(as_string(outbound.method) + ":" + as_string(outbound.password));
    return userinfo == "" ? "" :
        "ss://" + userinfo + "@" + host_port(outbound.server, outbound.server_port) + fragment(outbound);
}

function serialize_socks(outbound) {
    if (as_string(outbound.server) == "" || outbound.server_port == null)
        return "";

    let scheme = "socks" + as_string(outbound.version || "5");
    let auth = "";
    if (as_string(outbound.username) != "") {
        auth = uri_encode(outbound.username);
        if (as_string(outbound.password) != "")
            auth += ":" + uri_encode(outbound.password);
        auth += "@";
    }

    return scheme + "://" + auth + host_port(outbound.server, outbound.server_port) + fragment(outbound);
}

function serialize_hysteria2(outbound) {
    let port = hysteria2_server_ports_uri(outbound);
    if (port == "" && outbound.server_port != null)
        port = as_string(outbound.server_port);

    if (as_string(outbound.password) == "" || as_string(outbound.server) == "" || port == "")
        return "";

    let params = [];
    let tls = type(outbound.tls) == "object" ? outbound.tls : null;
    if (tls) {
        add_query(params, "sni", tls.server_name);
        if (tls.insecure === true)
            add_query(params, "insecure", "1");
        if (type(tls.alpn) == "array" && length(tls.alpn) > 0)
            add_query(params, "alpn", join(",", tls.alpn));
    }
    if (type(outbound.obfs) == "object") {
        add_query(params, "obfs", outbound.obfs.type);
        add_query(params, "obfs-password", outbound.obfs.password);
    }

    return "hysteria2://" + uri_encode(outbound.password) + "@" +
        host_port(outbound.server, port) + query_string(params) + fragment(outbound);
}

function serialize_vmess(outbound) {
    if (as_string(outbound.uuid) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";

    let vmess = {
        v: "2",
        ps: as_string(outbound.tag),
        add: as_string(outbound.server),
        port: as_string(outbound.server_port),
        id: as_string(outbound.uuid),
        aid: as_string(outbound.alter_id || 0),
        scy: as_string(outbound.security || "auto"),
        net: "tcp",
        type: "none",
        host: "",
        path: "",
        tls: "",
        sni: ""
    };

    if (type(outbound.tls) == "object" && outbound.tls.enabled !== false) {
        vmess.tls = "tls";
        vmess.sni = as_string(outbound.tls.server_name);
        if (type(outbound.tls.utls) == "object")
            vmess.fp = as_string(outbound.tls.utls.fingerprint);
    }

    if (type(outbound.transport) == "object") {
        vmess.net = as_string(outbound.transport.type || "tcp");
        if (vmess.net == "ws") {
            vmess.path = as_string(outbound.transport.path);
            if (type(outbound.transport.headers) == "object")
                vmess.host = as_string(outbound.transport.headers.Host || outbound.transport.headers.host);
        }
        else if (vmess.net == "grpc") {
            vmess.path = as_string(outbound.transport.service_name);
        }
        else if (vmess.net == "http") {
            vmess.path = as_string(outbound.transport.path);
            if (type(outbound.transport.host) == "array" && length(outbound.transport.host) > 0)
                vmess.host = join(",", outbound.transport.host);
            else
                vmess.host = as_string(outbound.transport.host);
        }
    }

    let encoded = base64_encode(sprintf("%J", vmess));
    return encoded == "" ? "" : "vmess://" + encoded;
}

function serialize_outbound_link(outbound) {
    if (type(outbound) != "object")
        return "";

    let outbound_type = as_string(outbound.type);
    if (outbound_type == "vless")
        return serialize_vless(outbound);
    if (outbound_type == "trojan")
        return serialize_trojan(outbound);
    if (outbound_type == "shadowsocks")
        return serialize_shadowsocks(outbound);
    if (outbound_type == "socks")
        return serialize_socks(outbound);
    if (outbound_type == "hysteria2")
        return serialize_hysteria2(outbound);
    if (outbound_type == "vmess")
        return serialize_vmess(outbound);
    return "";
}

function is_copyable_link(value) {
    value = lc(as_string(value));
    let prefixes = [
        "vless://", "vmess://", "trojan://", "ss://", "ssr://",
        "hysteria2://", "hy2://", "tuic://",
        "socks4://", "socks4a://", "socks5://"
    ];
    for (let prefix in prefixes) {
        if (starts_with(value, prefix))
            return true;
    }
    return false;
}

function get_source_link(subscription_dir, ref) {
    if (type(ref) != "object")
        return "";

    let source_section = as_string(ref.sourceSection || ref.source_section);
    let source_index = int(ref.sourceIndex || ref.source_index || 0);
    if (!safe_section(source_section) || source_index < 1)
        return "";

    let source = read_json(subscription_dir + "/" + source_section + ".json");
    if (type(source) != "object" || type(source.outbounds) != "array")
        return "";

    let outbound = source.outbounds[source_index - 1];
    if (type(outbound) != "object")
        return "";

    let link = as_string(outbound.share_link);
    if (link == "")
        link = serialize_outbound_link(outbound);
    return is_copyable_link(link) ? link : "";
}

function get_link(cache_dir, subscription_dir, section, tag, legacy_links_dir) {
    let cache = load_cache(cache_dir, section);
    let links = object_or_empty(cache.links);
    let link_refs = object_or_empty(cache.linkRefs);
    let link = as_string(links[tag]);

    if (!is_copyable_link(link))
        link = get_source_link(subscription_dir, link_refs[tag]);

    if (!is_copyable_link(link) && legacy_links_dir != null && legacy_links_dir != "") {
        let legacy = object_or_empty(read_json(legacy_links_dir + "/" + section + ".json"));
        link = as_string(legacy[tag]);
    }

    if (!is_copyable_link(link))
        link = "";

    write_stdout_json({ link: link });
}

function get_link_states(cache_dir, section, legacy_links_dir) {
    let cache = load_cache(cache_dir, section);
    let result = {};

    for (let tag, link in object_or_empty(cache.links))
        result[tag] = is_copyable_link(link);
    for (let tag, _ in object_or_empty(cache.linkRefs))
        result[tag] = true;

    if (length(keys(result)) == 0 && legacy_links_dir != null && legacy_links_dir != "") {
        let legacy = object_or_empty(read_json(legacy_links_dir + "/" + section + ".json"));
        for (let tag, link in legacy)
            result[tag] = is_copyable_link(link);
    }

    write_stdout_json(result);
}

function get_outbound_metadata(cache_dir, section, legacy_path) {
    let cache = load_cache(cache_dir, section);
    let metadata = cache.outboundMetadata;
    if (type(metadata) != "object")
        metadata = read_json(legacy_path);
    metadata = object_or_empty(metadata);
    let names = object_or_empty(metadata.names);
    let countries = object_or_empty(metadata.countries);
    let candidate_tags = array_or_empty(cache.urltestCandidateTags);
    let groups = object_or_empty(cache.urltestGroups);
    let result = {
        names: {},
        countries: {}
    };

    if (length(candidate_tags) > 0) {
        for (let tag in candidate_tags) {
            tag = as_string(tag);
            if (tag == "")
                continue;
            if (names[tag] != null)
                result.names[tag] = names[tag];
            if (countries[tag] != null)
                result.countries[tag] = countries[tag];
        }
    }
    else {
        for (let tag, name in names) {
            if (!groups[tag])
                result.names[tag] = name;
        }
        for (let tag, country in countries) {
            if (!groups[tag])
                result.countries[tag] = country;
        }
    }

    write_stdout_json(result);
}

function get_subscription_metadata(cache_dir, section, legacy_path) {
    let items = read_metadata_items_from_cache(cache_dir, section, legacy_path);
    if (length(items) > 0)
        write_stdout_json(items);
    else
        print("{}\n");
}

function persistent_metadata_path(source_section) {
    return PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/" + as_string(source_section) + ".metadata.json";
}

function remove_subscription_source_runtime_cache(source_section) {
    if (!cache_section_is_safe(source_section))
        return;

    unlink_path(source_json_path(TMP_SUBSCRIPTION_FOLDER, source_section));
    unlink_path(source_url_path(TMP_SUBSCRIPTION_FOLDER, source_section));
    unlink_path(source_user_agent_path(TMP_SUBSCRIPTION_FOLDER, source_section));
    unlink_path(source_hwid_path(TMP_SUBSCRIPTION_FOLDER, source_section));
}

function persist_subscription_cache(source_section, subscription_json_path, subscription_url, effective_user_agent, effective_hwid, metadata_path) {
    if (!cache_section_is_safe(source_section) || !subscription_cache_is_usable(subscription_json_path))
        return false;

    ensure_dir(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
    chmod_path(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, "700");

    let persistent_json = source_json_path(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source_section);
    let persistent_url = source_url_path(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source_section);
    let persistent_user_agent = source_user_agent_path(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source_section);
    let persistent_hwid = source_hwid_path(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source_section);
    let persistent_metadata = persistent_metadata_path(source_section);
    let previous_url = read_text(persistent_url);
    let previous_user_agent = read_text(persistent_user_agent);
    let previous_hwid = read_text(persistent_hwid);
    let can_keep_previous_metadata = previous_url == as_string(subscription_url) &&
        previous_user_agent == as_string(effective_user_agent) &&
        previous_hwid == as_string(effective_hwid) &&
        file_nonempty(persistent_metadata) &&
        object_has_extra_keys(persistent_metadata);

    if (!copy_file_if_changed(subscription_json_path, persistent_json) ||
        !write_text_if_changed(persistent_url, subscription_url) ||
        !write_text_if_changed(persistent_user_agent, effective_user_agent) ||
        !write_text_if_changed(persistent_hwid, effective_hwid))
        return false;

    if (metadata_path != null && metadata_path != "" && file_nonempty(metadata_path) && object_has_extra_keys(metadata_path)) {
        if (!copy_file_if_changed(metadata_path, persistent_metadata))
            return false;
    }
    else if (!can_keep_previous_metadata) {
        unlink_path(persistent_metadata);
    }

    return true;
}

function append_persistent_source_metadata(array_path, source_index, source_section) {
    let metadata_path = persistent_metadata_path(source_section);
    if (!file_nonempty(metadata_path))
        return false;

    append_metadata_file(array_path, metadata_path, source_index, source_section);
    return true;
}

function append_available_cached_metadata(array_path, section, source_index, source_section) {
    if (array_path == null || array_path == "")
        return false;

    let before = length(array_or_empty(read_json(array_path)));
    append_persistent_source_metadata(array_path, source_index, source_section) ||
        append_cached_metadata(array_path, PODKOP_SECTION_CACHE_DIR, section, PODKOP_SUBSCRIPTION_METADATA_DIR + "/" + section + ".json", source_index, source_section);
    return length(array_or_empty(read_json(array_path))) > before;
}

function get_kernel_version() {
    return trim(command_output_from_args([ "uname", "-r" ]));
}

function sing_box_version_from_output(output) {
    let first = split(as_string(output), "\n")[0] || "";
    let fields = whitespace_values(first);
    return length(fields) > 0 ? fields[length(fields) - 1] : "";
}

function get_sing_box_version() {
    if (trim(as_string(fs.readfile(SB_VARIANT_STATE_FILE))) == "extended-compressed") {
        let version_state = trim(as_string(fs.readfile(SB_VERSION_STATE_FILE)));
        if (version_state != "")
            return version_state;
    }

    if (!command_success_from_args([ "sh", "-c", "command -v sing-box" ]))
        return "";

    return sing_box_version_from_output(command_output_from_args([ "sing-box", "version" ]));
}

function get_subscription_user_agent(custom_user_agent) {
    custom_user_agent = as_string(custom_user_agent);
    if (custom_user_agent != "")
        return custom_user_agent;

    let version = get_sing_box_version();
    return "sing-box/" + (version != "" ? version : "unknown");
}

function user_agent_candidates(configured_user_agent, preferred_user_agent, default_user_agent) {
    configured_user_agent = as_string(configured_user_agent);
    if (configured_user_agent != "")
        return [ configured_user_agent ];

    let result = [];
    let seen = {};
    let candidates = [ default_user_agent, preferred_user_agent ];
    for (let profile in auto_user_agent_profiles)
        push(candidates, profile);

    for (let candidate in candidates) {
        candidate = as_string(candidate);
        if (user_agent_supported(candidate, default_user_agent) && !seen[candidate]) {
            seen[candidate] = true;
            push(result, candidate);
        }
    }

    return result;
}

function get_subscription_hwid(custom_hwid) {
    custom_hwid = as_string(custom_hwid);
    return custom_hwid != "" ? custom_hwid : generate_hwid();
}

function download_subscription(url, filepath, http_proxy_address, headers_filepath, effective_user_agent, effective_hwid) {
    let retries = 3;
    let wait_seconds = 2;
    let timeout = 15;
    let stamp = clock();
    let suffix = sprintf(".part.%d.%d", stamp[0], stamp[1]);
    let tmpfile = filepath + suffix;
    let headers_tmpfile = headers_filepath != "" ? headers_filepath + suffix : "";
    let resolution_failed = false;

    unlink_path(tmpfile);
    if (headers_tmpfile != "")
        unlink_path(headers_tmpfile);

    for (let attempt = 1; attempt <= retries; attempt++) {
        let args = [
            "curl", "-fL", "-sS",
            "--connect-timeout", timeout,
            "--speed-time", timeout,
            "--speed-limit", "1"
        ];

        if (http_proxy_address != "") {
            push(args, "-x");
            push(args, "http://" + http_proxy_address);
        }
        if (headers_tmpfile != "") {
            push(args, "-D");
            push(args, headers_tmpfile);
        }

        push(args, "-o");
        push(args, tmpfile);
        for (let header in [
            "User-Agent: " + get_subscription_user_agent(effective_user_agent),
            "X-HWID: " + get_subscription_hwid(effective_hwid),
            "X-Device-OS: OpenWrt Linux",
            "X-Device-Model: " + get_device_model(),
            "X-Ver-OS: " + get_kernel_version(),
            "Accept-Language: ru-RU,en,*",
            "X-Device-Locale: EN"
        ]) {
            push(args, "-H");
            push(args, header);
        }
        push(args, url);

        let status = command_status_from_args(args);
        if (status == 0 && file_nonempty(tmpfile)) {
            move_file(tmpfile, filepath);
            if (headers_filepath != "") {
                if (file_nonempty(headers_tmpfile))
                    move_file(headers_tmpfile, headers_filepath);
                else {
                    unlink_path(headers_filepath);
                    unlink_path(headers_tmpfile);
                }
            }
            return 0;
        }

        unlink_path(tmpfile);
        unlink_path(headers_tmpfile);

        if (status == 5 || status == 6) {
            resolution_failed = true;
            break;
        }

        if (attempt < retries)
            system("sleep " + int(wait_seconds));
    }

    unlink_path(tmpfile);
    unlink_path(headers_tmpfile);
    return resolution_failed ? 6 : 1;
}

function copy_valid_metadata_output(metadata_tmpfile, metadata_output_path) {
    if (metadata_output_path == null || metadata_output_path == "")
        return;

    if (file_nonempty(metadata_tmpfile) && object_has_extra_keys(metadata_tmpfile))
        copy_file(metadata_tmpfile, metadata_output_path) || unlink_path(metadata_output_path);
    else
        unlink_path(metadata_output_path);
}

function copy_persistent_metadata_output(source_section, metadata_output_path) {
    if (metadata_output_path == null || metadata_output_path == "")
        return;

    let metadata_path = persistent_metadata_path(source_section);
    if (file_nonempty(metadata_path) && object_has_extra_keys(metadata_path))
        copy_file(metadata_path, metadata_output_path) || unlink_path(metadata_output_path);
}

function subscription_config_is_current(section_name_value, subscription_url, subscription_user_agent, subscription_hwid, sections) {
    let section = find_section(sections, section_name_value);
    for (let entry in connections.subscription_urls(section)) {
        let parsed = subscription_source_profile(section, entry);
        if (type(parsed) == "object" && parsed.valid === true &&
            as_string(parsed.url) == as_string(subscription_url) &&
            as_string(parsed.user_agent) == as_string(subscription_user_agent) &&
            as_string(parsed.hwid) == as_string(subscription_hwid))
            return true;
    }

    return false;
}

function get_subscription_download_proxy_address(section_name_value, sections, parsed, phase) {
    let download_section = as_string(object_or_empty(parsed).download_section);
    if (download_section == "" || download_section == as_string(section_name_value))
        return "";

    let port = connections.subscription_download_target_port(sections, download_section, int(SB_SERVICE_MIXED_INBOUND_PORT));
    if (port <= 0)
        return "";

    if (!sing_box_service_running()) {
        if (phase == "startup")
            log_message("Subscription source for rule '" + section_name_value + "' is configured to download via rule '" + download_section + "', but sing-box is not running yet; downloading it directly during startup", "warn");
        else
            log_message("Subscription source for rule '" + section_name_value + "' is configured to download via rule '" + download_section + "', but sing-box service proxy is not running; downloading it directly", "warn");
        return "";
    }

    let address = SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + as_string(port);
    log_message("Downloading subscription for rule '" + section_name_value + "' via service proxy " + address, "debug");
    return address;
}

function download_subscription_into_cache(section_name_value, subscription_url, subscription_json_path, subscription_url_cache_path, service_proxy_address_value, subscription_user_agent, subscription_hwid, source_index, cache_section, metadata_output_path, sections) {
    ensure_dir(TMP_SUBSCRIPTION_FOLDER);
    let subscription_user_agent_cache_path = source_user_agent_path(TMP_SUBSCRIPTION_FOLDER, cache_section);
    let subscription_hwid_cache_path = source_hwid_path(TMP_SUBSCRIPTION_FOLDER, cache_section);
    let raw_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, cache_section, "download");
    let headers_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, cache_section, "headers");
    let normalized_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, cache_section, "normalized");
    let metadata_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, cache_section, "metadata");
    let cached_user_agent = read_text(subscription_user_agent_cache_path);
    let default_user_agent = get_subscription_user_agent("");
    let parser = subscription_parser();

    let attempt_index = 0;
    for (let effective_user_agent in user_agent_candidates(subscription_user_agent, cached_user_agent, default_user_agent)) {
        attempt_index++;
        unlink_path(raw_tmpfile);
        unlink_path(headers_tmpfile);
        unlink_path(normalized_tmpfile);
        unlink_path(metadata_tmpfile);

        let effective_hwid = get_subscription_hwid(subscription_hwid);
        let download_status = download_subscription(subscription_url, raw_tmpfile, service_proxy_address_value, headers_tmpfile, effective_user_agent, effective_hwid);
        if (download_status != 0) {
            if (metadata_output_path != "")
                unlink_path(metadata_output_path);
            if (download_status == 6) {
                log_message("Subscription download failed for rule '" + section_name_value + "' because the subscription host could not be resolved; compatibility retries skipped", "warn");
                break;
            }
            else if (subscription_user_agent != "")
                log_message("Subscription download failed for rule '" + section_name_value + "' with the configured request profile", "warn");
            else
                log_message("Subscription download attempt " + attempt_index + " failed for rule '" + section_name_value + "'; trying another compatibility profile", "warn");
            continue;
        }

        if (parser.try_decode_gzip_content_file(raw_tmpfile))
            log_message("Decoded gzip-compressed subscription body for rule '" + section_name_value + "'", "info");

        parser.extract_ui_metadata_file(headers_tmpfile, raw_tmpfile, metadata_tmpfile) || unlink_path(metadata_tmpfile);
        copy_valid_metadata_output(metadata_tmpfile, metadata_output_path);

        if (!parser.normalize_content_validated(raw_tmpfile, normalized_tmpfile)) {
            if (metadata_output_path != "")
                unlink_path(metadata_output_path);
            if (subscription_user_agent != "")
                log_message("Downloaded subscription for rule '" + section_name_value + "' is invalid with the configured request profile", "error");
            else
                log_message("Downloaded subscription for rule '" + section_name_value + "' is invalid; trying another compatibility profile", "warn");
            continue;
        }

        if (!subscription_config_is_current(section_name_value, subscription_url, subscription_user_agent, subscription_hwid, sections)) {
            log_message("Subscription source settings changed while updating rule '" + section_name_value + "'; discarding superseded download", "warn");
            if (metadata_output_path != "")
                unlink_path(metadata_output_path);
            unlink_path(raw_tmpfile);
            unlink_path(headers_tmpfile);
            unlink_path(normalized_tmpfile);
            unlink_path(metadata_tmpfile);
            return 4;
        }

        if (files_equal(normalized_tmpfile, subscription_json_path)) {
            write_text(subscription_url_cache_path, subscription_url);
            write_text(subscription_user_agent_cache_path, effective_user_agent);
            write_text(subscription_hwid_cache_path, effective_hwid);
            persist_subscription_cache(cache_section, subscription_json_path, subscription_url, effective_user_agent, effective_hwid, metadata_tmpfile) ||
                log_message("Failed to persist last working subscription cache for source '" + cache_section + "'", "warn");
            if (!file_nonempty(metadata_output_path))
                copy_persistent_metadata_output(cache_section, metadata_output_path);
            unlink_path(raw_tmpfile);
            unlink_path(headers_tmpfile);
            unlink_path(normalized_tmpfile);
            unlink_path(metadata_tmpfile);
            log_subscription_source_summary(section_name_value, source_index, subscription_json_path, "unchanged");
            return 2;
        }

        if (file_nonempty(subscription_json_path) && parser.runtime_outbounds_equal(normalized_tmpfile, subscription_json_path)) {
            if (!move_file(normalized_tmpfile, subscription_json_path)) {
                if (metadata_output_path != "")
                    unlink_path(metadata_output_path);
                unlink_path(raw_tmpfile);
                unlink_path(headers_tmpfile);
                unlink_path(metadata_tmpfile);
                return 1;
            }

            write_text(subscription_url_cache_path, subscription_url);
            write_text(subscription_user_agent_cache_path, effective_user_agent);
            write_text(subscription_hwid_cache_path, effective_hwid);
            persist_subscription_cache(cache_section, subscription_json_path, subscription_url, effective_user_agent, effective_hwid, metadata_tmpfile) ||
                log_message("Failed to persist last working subscription cache for source '" + cache_section + "'", "warn");
            if (!file_nonempty(metadata_output_path))
                copy_persistent_metadata_output(cache_section, metadata_output_path);
            unlink_path(raw_tmpfile);
            unlink_path(headers_tmpfile);
            unlink_path(metadata_tmpfile);
            log_subscription_source_summary(section_name_value, source_index, subscription_json_path, "runtime-unchanged");
            return 2;
        }

        if (!move_file(normalized_tmpfile, subscription_json_path)) {
            if (metadata_output_path != "")
                unlink_path(metadata_output_path);
            unlink_path(raw_tmpfile);
            unlink_path(headers_tmpfile);
            unlink_path(metadata_tmpfile);
            return 1;
        }

        write_text(subscription_url_cache_path, subscription_url);
        write_text(subscription_user_agent_cache_path, effective_user_agent);
        write_text(subscription_hwid_cache_path, effective_hwid);
        persist_subscription_cache(cache_section, subscription_json_path, subscription_url, effective_user_agent, effective_hwid, metadata_tmpfile) ||
            log_message("Failed to persist last working subscription cache for source '" + cache_section + "'", "warn");
        if (!file_nonempty(metadata_output_path))
            copy_persistent_metadata_output(cache_section, metadata_output_path);
        unlink_path(raw_tmpfile);
        unlink_path(headers_tmpfile);
        unlink_path(metadata_tmpfile);
        log_subscription_source_summary(section_name_value, source_index, subscription_json_path, "imported");
        return 0;
    }

    if (metadata_output_path != "")
        unlink_path(metadata_output_path);
    unlink_path(raw_tmpfile);
    unlink_path(headers_tmpfile);
    unlink_path(normalized_tmpfile);
    unlink_path(metadata_tmpfile);
    if (subscription_user_agent != "")
        log_message("Configured subscription request profile for rule '" + section_name_value + "' did not produce valid proxy entries", "error");
    else
        log_message("No compatible subscription request profile produced valid proxy entries for rule '" + section_name_value + "'", "error");
    return 1;
}

function cached_source_status(source_section, parsed) {
    restore_persistent_subscription_cache(
        source_section,
        TMP_SUBSCRIPTION_FOLDER,
        PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        parsed.url,
        parsed.user_agent,
        parsed.hwid,
        get_subscription_user_agent("")
    );

    let json_path = source_json_path(TMP_SUBSCRIPTION_FOLDER, source_section);
    let url_path = source_url_path(TMP_SUBSCRIPTION_FOLDER, source_section);
    let user_agent_path = source_user_agent_path(TMP_SUBSCRIPTION_FOLDER, source_section);
    let hwid_path = source_hwid_path(TMP_SUBSCRIPTION_FOLDER, source_section);
    let had_usable_cache = subscription_cache_is_usable(json_path);
    if (!had_usable_cache)
        unlink_path(json_path);

    let cached_url = read_text(url_path);
    let cached_user_agent = read_text(user_agent_path);
    let cached_hwid = read_text(hwid_path);
    if (had_usable_cache &&
        !source_cache_profile_matches(parsed, cached_url, cached_user_agent, cached_hwid, get_subscription_user_agent(""))) {
        remove_subscription_source_runtime_cache(source_section);
        return {
            usable: false,
            current: false,
            cached_url: "",
            cached_user_agent: "",
            cached_hwid: ""
        };
    }

    return {
        usable: had_usable_cache,
        current: had_usable_cache,
        cached_url,
        cached_user_agent,
        cached_hwid
    };
}

function update_subscription_source(section_name_value, index_value, entry, phase, metadata_output_path) {
    ensure_runtime_dirs();
    let sections = uci_sections();
    let settings = uci_named_section("settings");
    let index = int(index_value || 0);
    let section = find_section(sections, section_name_value);
    let parsed = subscription_source_profile(section, entry);
    if (type(parsed) != "object" || parsed.valid !== true) {
        log_message("Invalid subscription URL in rule '" + section_name_value + "': " + as_string(parsed.error || "Invalid subscription source entry"), "error");
        return 1;
    }

    let source_section = source_id(section_name_value, index);
    let status = cached_source_status(source_section, parsed);
    if (status.usable && !status.current) {
        log_message("Discarding stale subscription cache for rule '" + section_name_value + "' source '" + index + "' because source settings changed", "info");
        remove_subscription_source_runtime_cache(source_section);
    }

    let proxy = get_subscription_download_proxy_address(section_name_value, sections, parsed, phase || "runtime");
    return download_subscription_into_cache(
        section_name_value,
        parsed.url,
        source_json_path(TMP_SUBSCRIPTION_FOLDER, source_section),
        source_url_path(TMP_SUBSCRIPTION_FOLDER, source_section),
        proxy,
        parsed.user_agent,
        parsed.hwid,
        index,
        source_section,
        as_string(metadata_output_path),
        sections
    );
}

function subscription_update_timestamp_path(section_name_value) {
    return PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR + "/" + as_string(section_name_value) + ".timestamp";
}

function current_timestamp_value() {
    let value = trim(command_output_from_args([ "date", "+%s" ]));
    return unsigned_number(value) == null ? "" : value;
}

function write_subscription_update_timestamp(section_name_value) {
    let timestamp = current_timestamp_value();
    if (timestamp == "")
        return;

    ensure_dir(PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR);
    write_file(subscription_update_timestamp_path(section_name_value), timestamp + "\n");
}

function subscription_update_due_result(section) {
    section = object_or_empty(section);
    let interval = section_subscription_update_interval(section);
    if (interval == "")
        return 1;

    let seconds = duration_to_seconds_value(interval);
    if (seconds == null) {
        log_message("Invalid subscription_update_interval value for rule '" + section_name(section) + "': " + interval, "error");
        return 2;
    }

    return update_due_status(current_timestamp_value(), file_first_line_value(subscription_update_timestamp_path(section_name(section))), seconds);
}

function finalize_subscription_section_metadata(section_name_value, metadata_tmpfile, superseded) {
    if (as_string(metadata_tmpfile) == "")
        return;

    if (!superseded) {
        if (length(array_or_empty(read_json(metadata_tmpfile))) > 0)
            write_subscription_metadata(PODKOP_SECTION_CACHE_DIR, PODKOP_RUNTIME_CACHE_FORMAT, section_name_value, metadata_tmpfile);
        else
            write_subscription_metadata(PODKOP_SECTION_CACHE_DIR, PODKOP_RUNTIME_CACHE_FORMAT, section_name_value, "");
    }

    unlink_path(metadata_tmpfile);
}

function update_count_summary(updated, unchanged, failed) {
    let parts = [];
    if (updated > 0)
        push(parts, count_label(updated, "source updated", "sources updated"));
    if (unchanged > 0)
        push(parts, count_label(unchanged, "source unchanged", "sources unchanged"));
    if (failed > 0)
        push(parts, count_label(failed, "source failed", "sources failed"));
    return length(parts) > 0 ? join(", ", parts) : "no subscription sources checked";
}

function subscription_update_section(section, force) {
    section = object_or_empty(section);
    if (!section_is_subscription_proxy(section))
        return 3;

    let section_name_value = section_name(section);
    if (!force) {
        let due_result = subscription_update_due_result(section);
        if (due_result == 1)
            return 3;
        if (due_result != 0)
            return 1;
    }

    ensure_runtime_dirs();
    log_message("Updating subscriptions for rule '" + section_name_value + "'", "info");

    let metadata_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, section_name_value, "metadata-section");
    write_json(metadata_tmpfile, []);

    let changed = 0;
    let unchanged = 0;
    let failed = 0;
    let superseded = 0;
    let total = 0;

    for (let entry in connections.subscription_urls(section)) {
        total++;
        if (!force && !connections.subscription_update_enabled(section, entry))
            continue;
        let source_section = source_id(section_name_value, total);
        let metadata_output_path = temp_path(TMP_SUBSCRIPTION_FOLDER, source_section, "metadata-output");
        let update_result = update_subscription_source(section_name_value, total, entry, "runtime", metadata_output_path);

        if (update_result == 0) {
            append_metadata_file(metadata_tmpfile, metadata_output_path, total, source_section);
            changed++;
        }
        else if (update_result == 2) {
            append_metadata_file(metadata_tmpfile, metadata_output_path, total, source_section);
            unchanged++;
        }
        else if (update_result == 4) {
            superseded++;
        }
        else {
            append_available_cached_metadata(metadata_tmpfile, section_name_value, total, source_section);
            failed++;
        }

        unlink_path(metadata_output_path);
    }

    if (total == 0) {
        unlink_path(metadata_tmpfile);
        log_message("Subscription URL is not set for rule '" + section_name_value + "'", "info");
        return 1;
    }

    let update_result = 2;
    if (changed > 0)
        update_result = 0;
    else if (failed > 0)
        update_result = 1;
    else if (superseded > 0)
        update_result = 4;

    finalize_subscription_section_metadata(section_name_value, metadata_tmpfile, superseded > 0);

    if (update_result == 0) {
        write_subscription_update_timestamp(section_name_value);
        log_message("Subscription update for rule '" + section_name_value + "' completed: " + update_count_summary(changed, unchanged, failed), "info");
    }
    else if (update_result == 2) {
        write_subscription_update_timestamp(section_name_value);
        log_message("Subscription update for rule '" + section_name_value + "' completed: no changes (" + count_label(unchanged, "source checked", "sources checked") + ")", "info");
    }
    else if (update_result == 4) {
        log_message("Subscription update for rule '" + section_name_value + "' was superseded by newer URLs", "info");
    }
    else {
        log_message("Subscription update for rule '" + section_name_value + "' failed: " + update_count_summary(changed, unchanged, failed), "warn");
    }

    return update_result;
}

function source_index_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9]/) != null)
        return null;

    let result = int(value);
    return result > 0 ? result : null;
}

function subscription_update_selected_source(sections, section_name_value, source_index_value, force) {
    if (!cache_section_is_safe(section_name_value)) {
        log_message("Invalid subscription rule name", "error");
        return 1;
    }

    let source_index = source_index_number(source_index_value);
    if (source_index == null) {
        log_message("Invalid subscription source index for rule '" + section_name_value + "'", "error");
        return 1;
    }

    let section = find_section(sections, section_name_value);
    if (!section_is_subscription_proxy(section)) {
        log_message("Rule '" + section_name_value + "' has no subscription sources", "info");
        return 1;
    }

    if (!force) {
        let due_result = subscription_update_due_result(section);
        if (due_result == 1)
            return 3;
        if (due_result != 0)
            return 1;
    }

    ensure_runtime_dirs();
    log_message("Updating subscription source " + source_index + " for rule '" + section_name_value + "'", "info");

    let current_index = 0;
    let selected_entry = null;
    for (let entry in connections.subscription_urls(section)) {
        current_index++;
        if (current_index == source_index) {
            selected_entry = entry;
            break;
        }
    }

    if (selected_entry == null) {
        log_message("Subscription source '" + source_index + "' was not found for rule '" + section_name_value + "'", "info");
        return 1;
    }

    let source_section = source_id(section_name_value, source_index);
    let metadata_output_path = temp_path(TMP_SUBSCRIPTION_FOLDER, source_section, "metadata-output");
    let update_result = update_subscription_source(section_name_value, source_index, selected_entry, "runtime", metadata_output_path);

    if (update_result == 0 || update_result == 2)
        write_source_metadata(
            PODKOP_SECTION_CACHE_DIR,
            PODKOP_RUNTIME_CACHE_FORMAT,
            section_name_value,
            source_index,
            source_section,
            metadata_output_path,
            PODKOP_SUBSCRIPTION_METADATA_DIR + "/" + section_name_value + ".json"
        );

    unlink_path(metadata_output_path);

    if (update_result == 0) {
        write_subscription_update_timestamp(section_name_value);
    }
    else if (update_result == 2) {
        write_subscription_update_timestamp(section_name_value);
    }
    else if (update_result == 4) {
        log_message("Subscription source '" + source_index + "' update for rule '" + section_name_value + "' was superseded by newer URLs", "info");
    }
    else {
        log_message("Failed to download subscription source '" + source_index + "' for rule '" + section_name_value + "'", "info");
    }

    return update_result;
}

function empty_subscription_update_summary() {
    return {
        updated: 0,
        failed: 0,
        unchanged: 0,
        superseded: 0
    };
}

function add_subscription_update_result(summary, result) {
    if (result == 0)
        summary.updated++;
    else if (result == 1)
        summary.failed++;
    else if (result == 2)
        summary.unchanged++;
    else if (result == 4)
        summary.superseded++;
}

function print_subscription_update_summary(summary) {
    print(summary.updated, "\t", summary.failed, "\t", summary.unchanged, "\t", summary.superseded, "\n");
}

function subscription_update_request(force_value, target_section_name, target_source_index) {
    let force = as_string(force_value) == "1";
    let sections = uci_sections();
    let summary = empty_subscription_update_summary();

    target_section_name = as_string(target_section_name);
    target_source_index = as_string(target_source_index);

    if (target_section_name != "") {
        if (target_source_index != "")
            add_subscription_update_result(summary, subscription_update_selected_source(sections, target_section_name, target_source_index, force));
        else
            add_subscription_update_result(summary, subscription_update_section(find_section(sections, target_section_name), force));
        print_subscription_update_summary(summary);
        return;
    }

    for (let section in sections)
        add_subscription_update_result(summary, subscription_update_section(section, force));

    print_subscription_update_summary(summary);
}

function ensure_subscription_source_for_prepare(state, section, source_index, entry, metadata_tmpfile) {
    let section_name_value = section_name(section);
    let parsed = subscription_source_profile(section, entry);
    if (type(parsed) != "object" || parsed.valid !== true) {
        log_message("Invalid subscription source for rule '" + section_name_value + "': " + as_string(parsed.error || "Invalid subscription source entry"), "error");
        state.startup_blocked = true;
        return false;
    }

    let source_section = source_id(section_name_value, source_index);
    let cached = cached_source_status(source_section, parsed);
    if (cached.usable && cached.current) {
        append_available_cached_metadata(metadata_tmpfile, section_name_value, source_index, source_section);
        return true;
    }

    if (state.no_refresh) {
        log_message("No current subscription cache for rule '" + section_name_value + "' source '" + source_index + "'; skipping refresh during scoped runtime rebuild", "warn");
        return false;
    }

    let metadata_output_path = metadata_tmpfile != "" ? temp_path(TMP_SUBSCRIPTION_FOLDER, source_section, "metadata-output") : "";
    let proxy = get_subscription_download_proxy_address(section_name_value, state.sections, parsed, state.phase);
    let update_result = download_subscription_into_cache(
        section_name_value,
        parsed.url,
        source_json_path(TMP_SUBSCRIPTION_FOLDER, source_section),
        source_url_path(TMP_SUBSCRIPTION_FOLDER, source_section),
        proxy,
        parsed.user_agent,
        parsed.hwid,
        source_index,
        source_section,
        metadata_output_path,
        state.sections
    );

    if (update_result == 0 || update_result == 2) {
        append_metadata_file(metadata_tmpfile, metadata_output_path, source_index, source_section);
        unlink_path(metadata_output_path);
        return true;
    }

    unlink_path(metadata_output_path);

    if (cached.usable && cached.current) {
        log_message("Keeping cached subscription for rule '" + section_name_value + "' until a fresh download succeeds", "warn");
        append_available_cached_metadata(metadata_tmpfile, section_name_value, source_index, source_section);
        return true;
    }

    log_message("No usable subscription cache for rule '" + section_name_value + "'", "warn");
    return false;
}

function prepare_subscription_cache_section(state, section) {
    section = object_or_empty(section);
    if (!section_is_subscription_proxy(section))
        return;

    let section_name_value = section_name(section);
    let metadata_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, section_name_value, "metadata-section");
    write_json(metadata_tmpfile, []);

    let total = 0;
    let ready = 0;
    let failed = 0;
    for (let entry in connections.subscription_urls(section)) {
        total++;
        if (ensure_subscription_source_for_prepare(state, section, total, entry, metadata_tmpfile))
            ready++;
        else {
            failed++;
            state.unavailable_sources = append_word_once(state.unavailable_sources, source_id(section_name_value, total));
        }
    }

    if (total > 0 && ready == 0) {
        if (section_has_non_subscription_connection_sources(section)) {
            log_message("All subscription sources for rule '" + section_name_value + "' are unavailable; starting with manual proxy links only", "warn");
        }
        else {
            if (state.phase == "startup")
                log_message("No usable subscription cache for rule '" + section_name_value + "' and no manual proxy links are configured; checking whether startup can be bootstrapped through the selected proxy/VPN rule", "warn");
            else
                log_message("No usable subscription cache for rule '" + section_name_value + "' and no manual proxy links are configured; fast runtime generation cannot use this rule", "warn");
            state.startup_blocked_sections = append_word_once(state.startup_blocked_sections, section_name_value);
        }
    }
    else if (failed > 0) {
        log_message("Skipping unavailable subscription source(s) for rule '" + section_name_value + "'; using available outbounds", "warn");
    }

    let metadata_count = length(array_or_empty(read_json(metadata_tmpfile)));
    if (metadata_count > 0)
        write_subscription_metadata(PODKOP_SECTION_CACHE_DIR, PODKOP_RUNTIME_CACHE_FORMAT, section_name_value, metadata_tmpfile);
    else
        write_subscription_metadata(PODKOP_SECTION_CACHE_DIR, PODKOP_RUNTIME_CACHE_FORMAT, section_name_value, "");
    unlink_path(metadata_tmpfile);
}

function prepared_runtime_cache_should_skip(sections, section_cache_dir, phase, already_prepared) {
    return as_string(phase) == "runtime" &&
        as_string(already_prepared) == "1" &&
        !runtime_cache_missing(sections, section_cache_dir);
}

function prepare_subscription_caches(phase, already_prepared, no_refresh) {
    phase = as_string(phase || "startup");
    let sections = uci_sections();

    if (prepared_runtime_cache_should_skip(sections, PODKOP_SECTION_CACHE_DIR, phase, already_prepared)) {
        print("\n");
        return 0;
    }

    ensure_runtime_dirs();
    let state = {
        phase,
        sections,
        settings: uci_named_section("settings"),
        startup_blocked: false,
        startup_blocked_sections: "",
        unavailable_sources: "",
        no_refresh: as_string(no_refresh) == "1"
    };

    prune_stale_subscription_caches_for_sections(sections);
    for (let section in sections)
        prepare_subscription_cache_section(state, section);

    if (state.startup_blocked)
        return 1;

    if (state.startup_blocked_sections == "") {
        print("\n");
        return 0;
    }

    if (phase == "startup" && subscription_bootstrap_download_section_is_ready(sections, state.startup_blocked_sections, get_subscription_user_agent(""))) {
        log_message("Starting temporarily without subscription-only rule(s): " + state.startup_blocked_sections + ". They will be retried through the service proxy after sing-box starts", "warn");
        print(state.startup_blocked_sections, "\n");
        return 0;
    }

    for (let section in whitespace_values(state.startup_blocked_sections))
        log_message("No usable subscription cache for rule '" + section + "' and no manual proxy links are configured; startup cannot continue", "error");

    return 1;
}

function current_pid() {
    return trim(command_output("sh -c 'echo $PPID'"));
}

function pid_running(pid) {
    pid = as_string(pid);
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function state_ucode_status(args) {
    return command_status_from_args(command_args_with([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/state.uc" ], args)) == 0;
}

function mark_pending_subscription_recovery_reload() {
    state_ucode_status([ "mark-pending-reload", PODKOP_PENDING_RELOAD_FILE, "subscription_deferred_recovery" ]);
}

function trigger_subscription_recovery_reload(worker) {
    if (worker)
        command_status_from_args([ PODKOP_SERVICE_INIT, "reload", "subscription_deferred_recovery" ]);
    else
        mark_pending_subscription_recovery_reload();
}

function subscription_bootstrap_retry_result(deferred_sections) {
    let sections = uci_sections();
    let default_user_agent = get_subscription_user_agent("");
    let result = {
        recovered: "",
        remaining: ""
    };

    for (let section in whitespace_values(deferred_sections)) {
        let value = find_section(sections, section);
        if (!section_is_subscription_proxy(value)) {
            log_message("Deferred subscription rule '" + section + "' no longer has subscription proxy sources; removing it from bootstrap retry list", "warn");
            result.recovered = append_word_once(result.recovered, section);
            continue;
        }

        log_message("Retrying deferred subscription rule '" + section + "' through the service proxy", "info");
        let update_result = subscription_update_section(value, true);
        if (update_result == 0 || update_result == 2) {
            result.recovered = append_word_once(result.recovered, section);
            continue;
        }

        if (section_current_usable_cache_by_name(sections, section, default_user_agent)) {
            log_message("Deferred subscription rule '" + section + "' has a usable cache after retry despite partial update errors", "warn");
            result.recovered = append_word_once(result.recovered, section);
            continue;
        }

        result.remaining = append_word_once(result.remaining, section);
        log_message("Deferred subscription rule '" + section + "' is still unavailable; keeping it disabled for this startup", "warn");
    }

    return result;
}

function worker_env() {
    return {
        PODKOP_CONFIG_NAME: CONFIG_NAME,
        PODKOP_LIB: LIB_DIR,
        TMP_SING_BOX_FOLDER,
        TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER,
        PODKOP_RUNTIME_STATE_DIR,
        PODKOP_SUBSCRIPTION_UPDATE_STATE_DIR,
        PODKOP_SUBSCRIPTION_LINKS_DIR,
        PODKOP_SUBSCRIPTION_METADATA_DIR,
        PODKOP_OUTBOUND_METADATA_DIR,
        PODKOP_SECTION_CACHE_DIR,
        PODKOP_RUNTIME_CACHE_FORMAT_FILE,
        PODKOP_RUNTIME_CACHE_FORMAT,
        PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE,
        PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR,
        PODKOP_PENDING_RELOAD_FILE,
        PODKOP_SERVICE_INIT,
        SB_SERVICE_MIXED_INBOUND_ADDRESS,
        SB_SERVICE_MIXED_INBOUND_PORT,
        SB_VARIANT_STATE_FILE,
        SB_VERSION_STATE_FILE,
        ZAPRET_PROVIDER_NFQWS_BIN,
        ZAPRET2_PROVIDER_NFQWS2_BIN,
        BYEDPI_BIN
    };
}

function launch_self_worker(args) {
    let command_args = command_args_with([ "ucode", "-L", LIB_DIR, LIB_DIR + "/subscription/cache.uc" ], args);
    let command = command_env(worker_env()) + " " + command_from_args(command_args) + " >/dev/null 2>&1 1000>&- & echo $!";
    return trim(command_output("sh -c " + shell_quote(command)));
}

function start_deferred_subscription_bootstrap_retry_worker(deferred_sections) {
    deferred_sections = trim(as_string(deferred_sections));
    if (deferred_sections == "")
        return;

    ensure_runtime_dirs();
    let existing_pid = trim(file_first_line_value(PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE));
    if (pid_running(existing_pid)) {
        log_message("Subscription bootstrap retry worker is already running with PID " + existing_pid, "debug");
        return;
    }

    let pid = launch_self_worker([ "deferred-bootstrap-worker", deferred_sections ]);
    if (pid != "")
        write_file(PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE, pid + "\n");
    log_message("Started subscription bootstrap retry worker for rule(s): " + deferred_sections, "info");
}

function stop_deferred_subscription_bootstrap_retry_worker() {
    let pid = trim(file_first_line_value(PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE));
    if (pid_running(pid)) {
        command_success_from_args([ "kill", pid ]);
        log_message("Stopped subscription bootstrap retry worker", "info");
    }
    unlink_path(PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE);
}

function run_deferred_subscription_bootstrap(deferred_sections) {
    deferred_sections = trim(as_string(deferred_sections));
    if (deferred_sections == "")
        return;

    log_message("Waiting for sing-box service proxy before retrying deferred subscription rule(s): " + deferred_sections, "info");
    let ready = false;
    for (let attempt = 1; attempt <= 10; attempt++) {
        if (sing_box_service_running()) {
            ready = true;
            break;
        }
        system("sleep 1");
    }

    if (!ready) {
        log_message("sing-box service proxy did not become ready in time; deferred subscription rule(s) will remain disabled until the next successful subscription update", "warn");
        start_deferred_subscription_bootstrap_retry_worker(deferred_sections);
        return;
    }

    let result = subscription_bootstrap_retry_result(deferred_sections);
    if (result.recovered != "") {
        log_message("Recovered deferred subscription rule(s): " + result.recovered + "; scheduling Podkop Plus reload", "info");
        trigger_subscription_recovery_reload(false);
    }

    if (result.remaining != "") {
        log_message("Some deferred subscription rule(s) are still disabled for this startup: " + result.remaining, "warn");
        start_deferred_subscription_bootstrap_retry_worker(result.remaining);
    }
}

function deferred_subscription_bootstrap_retry_worker(remaining_sections) {
    remaining_sections = trim(as_string(remaining_sections));

    while (remaining_sections != "") {
        system("sleep 30");
        if (!sing_box_service_running()) {
            log_message("Stopping subscription bootstrap retry worker because sing-box is not running", "warn");
            break;
        }

        ensure_runtime_dirs();
        if (!state_ucode_status([ "acquire-runtime-dir-lock", PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR, current_pid() ])) {
            log_message("Subscription bootstrap retry skipped because another subscription update is running", "debug");
            continue;
        }

        let result = subscription_bootstrap_retry_result(remaining_sections);
        state_ucode_status([ "release-runtime-dir-lock", PODKOP_SUBSCRIPTION_UPDATE_LOCK_DIR ]);

        if (result.recovered != "") {
            log_message("Recovered deferred subscription rule(s): " + result.recovered + "; reloading Podkop Plus", "info");
            trigger_subscription_recovery_reload(true);
        }

        remaining_sections = result.remaining;
    }

    unlink_path(PODKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE);
}

let mode = ARGV[0] || "";

if (mode == "write-link-cache") {
    let cache_dir = ARGV[1], format_version = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        exit(1);
    write_link_cache(cache_dir, format_version, section, ARGV[4], ARGV[5]);
}
else if (mode == "file-first-line") {
    file_first_line(ARGV[1]);
}
else if (mode == "file-has-exact-line") {
    exit(file_has_exact_line(ARGV[1], ARGV[2]) ? 0 : 1);
}
else if (mode == "state-list-contains") {
    exit(state_list_contains(ARGV[1], ARGV[2]) ? 0 : 1);
}
else if (mode == "append-state-list-once") {
    append_state_list_once(ARGV[1], ARGV[2]);
}
else if (mode == "maintenance-plan") {
    maintenance_plan(uci_sections(), ARGV[1]);
}
else if (mode == "maintenance-plan-fixture") {
    let data = object_or_empty(read_json(ARGV[1]));
    connections.set_item_sections_from_data(data);
    maintenance_plan(fixture_section_list(data), ARGV[2]);
}
else if (mode == "runtime-cache-needs-rebuild") {
    exit(runtime_cache_missing(uci_sections(), ARGV[1]) ? 0 : 1);
}
else if (mode == "runtime-cache-needs-rebuild-fixture") {
    let data = object_or_empty(read_json(ARGV[1]));
    connections.set_item_sections_from_data(data);
    exit(runtime_cache_missing(fixture_section_list(data), ARGV[2]) ? 0 : 1);
}
else if (mode == "prepared-runtime-cache-should-skip-fixture") {
    let data = object_or_empty(read_json(ARGV[1]));
    connections.set_item_sections_from_data(data);
    exit(prepared_runtime_cache_should_skip(fixture_section_list(data), ARGV[2], ARGV[3], ARGV[4]) ? 0 : 1);
}
else if (mode == "ensure-runtime-dirs") {
    ensure_runtime_dirs();
}
else if (mode == "clear-runtime-cache") {
    clear_subscription_runtime_cache();
}
else if (mode == "ensure-runtime-cache-format") {
    ensure_runtime_cache_format();
}
else if (mode == "remove-legacy-server-country-cache") {
    remove_legacy_server_country_cache();
}
else if (mode == "stale-cache-delete-paths") {
    stale_cache_delete_paths(uci_sections(), ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]);
}
else if (mode == "stale-cache-delete-paths-fixture") {
    let data = object_or_empty(read_json(ARGV[1]));
    connections.set_item_sections_from_data(data);
    stale_cache_delete_paths(fixture_section_list(data), ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
}
else if (mode == "section-current-usable-cache") {
    exit(section_current_usable_cache(uci_section(ARGV[1]), ARGV[2], ARGV[3], ARGV[4]) ? 0 : 1);
}
else if (mode == "restore-persistent-source") {
    let expected_hwid = ARGV[7] == null ? "" : ARGV[6];
    let default_user_agent = ARGV[7] == null ? ARGV[6] : ARGV[7];
    exit(restore_persistent_subscription_cache(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], expected_hwid, default_user_agent) ? 0 : 1);
}
else if (mode == "persist-source-cache") {
    let effective_hwid = ARGV[6] == null ? "" : ARGV[5];
    let metadata_path = ARGV[6] == null ? ARGV[5] : ARGV[6];
    exit(persist_subscription_cache(ARGV[1], ARGV[2], ARGV[3], ARGV[4], effective_hwid, metadata_path) ? 0 : 1);
}
else if (mode == "section-current-usable-cache-fixture") {
    let data = object_or_empty(read_json(ARGV[1]));
    connections.set_item_sections_from_data(data);
    let target = as_string(ARGV[2]);
    let selected = {};
    for (let section in fixture_section_list(data)) {
        if (section_name(section) == target) {
            selected = section;
            break;
        }
    }
    exit(section_current_usable_cache(selected, ARGV[3], ARGV[4], ARGV[5]) ? 0 : 1);
}
else if (mode == "user-agent-supported") {
    exit(user_agent_supported(ARGV[1], ARGV[2]) ? 0 : 1);
}
else if (mode == "user-agent-matches-config") {
    exit(user_agent_matches_config(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
}
else if (mode == "write-user-agent-candidates") {
    write_user_agent_candidates(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
}
else if (mode == "source-id") {
    print(source_id(ARGV[1], int(ARGV[2] || 0)), "\n");
}
else if (mode == "subscription-metadata-path") {
    let path = subscription_metadata_path(ARGV[1]);
    if (path == "")
        exit(1);
    print(path, "\n");
}
else if (mode == "outbound-metadata-path") {
    let path = outbound_metadata_path(ARGV[1]);
    if (path == "")
        exit(1);
    print(path, "\n");
}
else if (mode == "section-is-subscription-proxy") {
    exit(section_is_subscription_proxy(uci_section(ARGV[1])) ? 0 : 1);
}
else if (mode == "update-source") {
    exit(update_subscription_source(ARGV[1], ARGV[2], ARGV[3], ARGV[4] || "runtime", ARGV[5] || ""));
}
else if (mode == "update-section") {
    exit(subscription_update_section(find_section(uci_sections(), ARGV[1] || ""), as_string(ARGV[2] || "0") == "1"));
}
else if (mode == "update-request") {
    subscription_update_request(ARGV[1] || "0", ARGV[2] || "", ARGV[3] || "");
}
else if (mode == "prepare-caches") {
    exit(prepare_subscription_caches(ARGV[1] || "startup", ARGV[2] || "0", ARGV[3] || "0"));
}
else if (mode == "run-deferred-bootstrap") {
    run_deferred_subscription_bootstrap(ARGV[1] || "");
}
else if (mode == "start-deferred-bootstrap-worker") {
    start_deferred_subscription_bootstrap_retry_worker(ARGV[1] || "");
}
else if (mode == "stop-deferred-bootstrap-worker") {
    stop_deferred_subscription_bootstrap_retry_worker();
}
else if (mode == "deferred-bootstrap-worker") {
    deferred_subscription_bootstrap_retry_worker(ARGV[1] || "");
}
else if (mode == "json-length") {
    json_length(ARGV[1]);
}
else if (mode == "subscription-import-stats") {
    print(subscription_import_stats_text(ARGV[1]), "\n");
}
else if (mode == "subscription-source-summary") {
    print(subscription_source_summary(ARGV[1], ARGV[2], ARGV[3], ARGV[4]), "\n");
}
else if (mode == "object-has-extra-keys") {
    exit(object_has_extra_keys(ARGV[1]) ? 0 : 1);
}
else if (mode == "write-outbound-metadata") {
    let cache_dir = ARGV[1], format_version = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        exit(1);
    write_outbound_metadata(cache_dir, format_version, section, ARGV[4], ARGV[5], ARGV[6]);
}
else if (mode == "write-subscription-metadata") {
    let cache_dir = ARGV[1], format_version = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        exit(1);
    write_subscription_metadata(cache_dir, format_version, section, ARGV[4]);
}
else if (mode == "append-metadata-file") {
    append_metadata_file(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
}
else if (mode == "append-cached-metadata") {
    append_cached_metadata(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]);
}
else if (mode == "write-source-metadata") {
    let cache_dir = ARGV[1], format_version = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        exit(1);
    write_source_metadata(cache_dir, format_version, section, ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
}
else if (mode == "get-link") {
    let cache_dir = ARGV[1], subscription_dir = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        write_empty_link();
    else
        get_link(cache_dir, subscription_dir, section, ARGV[4] || "", ARGV[5] || "");
}
else if (mode == "get-link-states") {
    let cache_dir = ARGV[1], section = ARGV[2];
    if (!safe_section(section))
        print("{}\n");
    else
        get_link_states(cache_dir, section, ARGV[3] || "");
}
else if (mode == "get-outbound-metadata") {
    let cache_dir = ARGV[1], section = ARGV[2];
    if (!safe_section(section))
        write_empty_outbound_metadata();
    else
        get_outbound_metadata(cache_dir, section, ARGV[3]);
}
else if (mode == "empty-link") {
    write_empty_link();
}
else if (mode == "empty-outbound-metadata") {
    write_empty_outbound_metadata();
}
else if (mode == "get-subscription-metadata") {
    let cache_dir = ARGV[1], section = ARGV[2];
    if (!safe_section(section))
        print("{}\n");
    else
        get_subscription_metadata(cache_dir, section, ARGV[3]);
}
else {
    warn("Usage: subscription/cache.uc <mode> ...\n");
    exit(1);
}
