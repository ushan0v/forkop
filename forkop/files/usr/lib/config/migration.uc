#!/usr/bin/env ucode

// Keep migrations in this file. A migration is identified by a stable name;
// release checks are optional conditions inside the migration itself.

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let constants_module = require("core.constants");
let singbox_constants_module = require("singbox.constants");
let domain_config = require("config.domain");
let subscription_share_link = require("subscription.share_link");

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
const FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT") || "7";
const FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD = getenv("FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD") || "/var/run/forkop.internal-config-change";
const FORKOP_RUNTIME_CACHE_FORMAT = getenv("FORKOP_RUNTIME_CACHE_FORMAT") || "8";
const CONFIG_VERSION_OPTION = "config_version";
const APPLIED_MIGRATIONS_OPTION = "applied_migrations";
const SERVER_COUNTRY_METHOD_FLAG_EMOJI = "flag_emoji";
const SERVER_COUNTRY_METHOD_COUNTRY_IS = "country_is";
const CHILD_ITEM_TYPES = [
    "subscription_url",
    "section_interface",
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

// Podkop Plus -> Forkop source migration.
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

function migrate_interface_item_settings(ctx, section) {
    let owner = section_name(section);
    let resolver_enabled = bool_option(section, "domain_resolver_enabled", false) ? "1" : "0";
    let dns_type = option(section, "domain_resolver_dns_type", "udp") || "udp";
    let dns_server = option(section, "domain_resolver_dns_server", "8.8.8.8") || "8.8.8.8";
    let seen_values = {};

    for (let child in ctx.model.section_interface || []) {
        if (option(child, "section", "") != owner)
            continue;

        let value = option(child, "name", "");
        if (value == "" || seen_values[value])
            continue;

        seen_values[value] = true;
        set_option_if_missing(ctx, child, "domain_resolver_enabled", resolver_enabled);
        set_option_if_missing(ctx, child, "domain_resolver_dns_type", dns_type);
        set_option_if_missing(ctx, child, "domain_resolver_dns_server", dns_server);
    }

    let values = option_list_values(section, "interfaces");
    let legacy_interface = option(section, "interface", "");
    if (legacy_interface != "")
        push(values, legacy_interface);

    for (let value in values) {
        value = as_string(value);
        if (value == "" || seen_values[value])
            continue;

        seen_values[value] = true;
        let child = create_child_for_section(ctx, section, "section_interface");
        set_option(ctx, child, "name", value);
        set_option(ctx, child, "domain_resolver_enabled", resolver_enabled);
        set_option(ctx, child, "domain_resolver_dns_type", dns_type);
        set_option(ctx, child, "domain_resolver_dns_server", dns_server);
    }

    delete_option(ctx, section, "interface");
    delete_option(ctx, section, "interfaces");
    delete_option(ctx, section, "interface_settings");
    delete_option(ctx, section, "domain_resolver_enabled");
    delete_option(ctx, section, "domain_resolver_dns_type");
    delete_option(ctx, section, "domain_resolver_dns_server");
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

    let outbound_json = option(section, "outbound_json", "");
    if (outbound_json != "") {
        let outbound;
        try {
            outbound = json(outbound_json);
        }
        catch (e) {
            outbound = null;
        }

        if (type(outbound) == "object" && trim(as_string(outbound.tag || "")) == "") {
            let existing = option_list_values(section, "outbound_jsons");
            let taken = {};
            for (let value in existing) {
                try {
                    let item = json(value);
                    let tag_name = type(item) == "object" ? trim(as_string(item.tag || "")) : "";
                    if (tag_name != "")
                        taken[tag_name] = true;
                }
                catch (e) {
                }
            }

            let base = singbox_constants_module.outbound_tag(
                section_name(section) + "-json-" + (length(existing) + 1)
            );
            let tag_name = base;
            for (let suffix = 1; taken[tag_name]; suffix++)
                tag_name = base + "-" + suffix;
            outbound.tag = tag_name;
            set_option(ctx, section, "outbound_json", sprintf("%J", outbound));
        }
    }

    normalize_connections_list(ctx, section, "outbound_json", "outbound_jsons");
}

function migrate_connection_section(ctx, section, constants, legacy_connection_kind) {
    migrate_subscription_url_item_settings(ctx, section);
    migrate_urltest_item_settings(ctx, section, constants);
    migrate_interface_item_settings(ctx, section);
    migrate_outbound_json_list(ctx, section, legacy_connection_kind);

    delete_option(ctx, section, "subscription_update_enabled");
    delete_option(ctx, section, "subscription_update_interval");
    delete_option(ctx, section, "enable_udp_over_tcp");
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

function version_parts(value) {
    let matched = match(as_string(value), /^([0-9]+)\.([0-9]+)\.([0-9]+)$/);
    if (!matched)
        return [ 0, 0, 0 ];
    return [ int(matched[1]), int(matched[2]), int(matched[3]) ];
}

function compare_versions(left, right) {
    left = version_parts(left);
    right = version_parts(right);
    for (let i = 0; i < 3; i++) {
        if (left[i] < right[i])
            return -1;
        if (left[i] > right[i])
            return 1;
    }
    return 0;
}

function release_at_most(ctx, version) {
    return compare_versions(ctx.source_release, version) <= 0;
}

function migrate_interface_sections(ctx) {
    if (!release_at_most(ctx, "1.0.1"))
        return;

    for (let section in ctx.model.sections)
        migrate_interface_item_settings(ctx, section);
}

function migrate_enable_component_checks(ctx) {
    if (!release_at_most(ctx, "1.0.1"))
        return;

    set_option(ctx, ctx.model.settings, "component_update_check_enabled", "1");
}

const MIGRATIONS = [
    { id: "interface_sections", run: migrate_interface_sections },
    { id: "enable_component_checks", run: migrate_enable_component_checks }
];

function apply_migrations(ctx) {
    ctx.source_release = option(ctx.model.settings, CONFIG_VERSION_OPTION, "");

    let applied = [];
    let seen = {};
    let added = false;
    for (let id in list_option(ctx.model.settings, APPLIED_MIGRATIONS_OPTION)) {
        id = as_string(id);
        if (id == "" || seen[id])
            continue;
        seen[id] = true;
        push(applied, id);
    }

    for (let migration in MIGRATIONS) {
        if (seen[migration.id])
            continue;

        migration.run(ctx);
        seen[migration.id] = true;
        push(applied, migration.id);
        added = true;
    }

    if (added)
        set_list_option(ctx, ctx.model.settings, APPLIED_MIGRATIONS_OPTION, applied);

    if (release_at_most(ctx, "1.0.1"))
        set_option(ctx, ctx.model.settings, CONFIG_VERSION_OPTION, "1.0.2");
}

function migrate_podkop_model(model, constants) {
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
    apply_migrations(ctx);

    return ctx;
}

function migrate_forkop_model(model) {
    let ctx = migration_context(model);
    apply_migrations(ctx);
    return ctx;
}

// Runtime UCI adapter and external command dispatcher.
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
    ensure_dir(FORKOP_SUBSCRIPTION_METADATA_DIR);
    ensure_dir(FORKOP_OUTBOUND_METADATA_DIR);
    ensure_dir(FORKOP_SECTION_CACHE_DIR);
}

function ensure_runtime_cache_format() {
    ensure_dir(FORKOP_RUNTIME_STATE_DIR);

    if (first_line(FORKOP_RUNTIME_CACHE_FORMAT_FILE) != FORKOP_RUNTIME_CACHE_FORMAT) {
        if (first_line(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) == FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT)
            subscription_share_link.populate_subscription_dir(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        clear_subscription_runtime_cache();
        ensure_runtime_dirs();
        fs.writefile(FORKOP_RUNTIME_CACHE_FORMAT_FILE, FORKOP_RUNTIME_CACHE_FORMAT + "\n");
    }

    if (first_line(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) != FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT) {
        run("rm -rf " + shell_quote(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR));
        ensure_dir(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        run("chmod 700 " + shell_quote(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR) + " >/dev/null 2>&1");
        fs.writefile(FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE, FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT + "\n");
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

function migrate_model(model, source) {
    return source == "podkop"
        ? migrate_podkop_model(model, constants_context())
        : migrate_forkop_model(model);
}

function migrate_runtime(source) {
    ensure_runtime_cache_format();
    remove_legacy_server_country_cache();

    let cursor = runtime_cursor();
    cursor.load(CONFIG_NAME);
    let ctx = migrate_model(model_from_uci(cursor), source);
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

function migrate_fixture(path, source) {
    let ctx = migrate_model(model_from_fixture(path), source);
    write_json({
        changed: ctx.changed,
        config: export_model(ctx.model),
        operations: ctx.operations,
        removed_caches: ctx.removed_caches
    });
}

function main(argv) {
    let mode = argv[0] || "";

    if (mode == "migrate")
        return migrate_runtime("forkop") ? 0 : 1;
    if (mode == "migrate-podkop")
        return migrate_runtime("podkop") ? 0 : 1;
    if (mode == "commit")
        return commit_runtime() ? 0 : 1;
    if (mode == "migrate-fixture") {
        migrate_fixture(argv[1], argv[2] || "forkop");
        return 0;
    }

    warn("Usage: config/migration.uc migrate\n");
    warn("       config/migration.uc migrate-podkop\n");
    warn("       config/migration.uc commit\n");
    warn("       config/migration.uc migrate-fixture <fixture.json> [forkop|podkop]\n");
    return 1;
}

function module_exports() {
    return {
        main: main,
        migrate_model: migrate_model,
        migrate_forkop_model: migrate_forkop_model,
        migrate_podkop_model: migrate_podkop_model,
        mark_internal_config_guard: mark_internal_config_guard
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

exit(main(ARGV));
