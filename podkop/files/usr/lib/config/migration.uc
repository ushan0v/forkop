#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let constants_module = require("core.constants");
let domain_config = require("config.domain");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json = common.write_json;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let object_or_empty = common.object_or_empty;

const CONFIG_NAME = getenv("PODKOP_CONFIG_NAME") || "podkop-plus";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || "/tmp/sing-box/subscriptions";
const PODKOP_RUNTIME_STATE_DIR = getenv("PODKOP_RUNTIME_STATE_DIR") || "/var/run/podkop-plus";
const PODKOP_SUBSCRIPTION_LINKS_DIR = getenv("PODKOP_SUBSCRIPTION_LINKS_DIR") || PODKOP_RUNTIME_STATE_DIR + "/subscription-links";
const PODKOP_SUBSCRIPTION_METADATA_DIR = getenv("PODKOP_SUBSCRIPTION_METADATA_DIR") || PODKOP_RUNTIME_STATE_DIR + "/subscription-metadata";
const PODKOP_OUTBOUND_METADATA_DIR = getenv("PODKOP_OUTBOUND_METADATA_DIR") || PODKOP_RUNTIME_STATE_DIR + "/outbound-metadata";
const PODKOP_SECTION_CACHE_DIR = getenv("PODKOP_SECTION_CACHE_DIR") || PODKOP_RUNTIME_STATE_DIR + "/section-cache";
const PODKOP_RUNTIME_CACHE_FORMAT_FILE = getenv("PODKOP_RUNTIME_CACHE_FORMAT_FILE") || PODKOP_RUNTIME_STATE_DIR + "/cache-format";
const PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/podkop-plus/subscription-cache";
const PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const PODKOP_INTERNAL_CONFIG_TRIGGER_GUARD = getenv("PODKOP_INTERNAL_CONFIG_TRIGGER_GUARD") || "/var/run/podkop-plus.internal-config-change";
const PODKOP_RUNTIME_CACHE_FORMAT = getenv("PODKOP_RUNTIME_CACHE_FORMAT") || "7";
const SERVER_COUNTRY_METHOD_FLAG_EMOJI = "flag_emoji";
const SERVER_COUNTRY_METHOD_COUNTRY_IS = "country_is";

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
        zapret_default_nfqws_opt: as_string(constants.ZAPRET_DEFAULT_NFQWS_OPT)
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

    if (model.settings[".name"] == null)
        model.settings[".name"] = "settings";
    if (model.settings[".type"] == null)
        model.settings[".type"] = "settings";

    for (let section in fixture_section_list(data, "rule"))
        push(model.rules, clone_section(section));
    for (let section in fixture_section_list(data, "section"))
        push(model.sections, clone_section(section));

    return model;
}

function model_from_uci(cursor) {
    let model = {
        settings: clone_section(object_or_empty(cursor.get_all(CONFIG_NAME, "settings"))),
        rules: [],
        sections: []
    };

    cursor.foreach(CONFIG_NAME, "rule", function(section) {
        push(model.rules, clone_section(section));
    });
    cursor.foreach(CONFIG_NAME, "section", function(section) {
        push(model.sections, clone_section(section));
    });

    return model;
}

function export_model(model) {
    let result = {
        settings: model.settings,
        section: model.sections
    };
    if (length(model.rules) > 0)
        result.rule = model.rules;
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

function settings_entry_set_bool_if_missing(map, item, key, value) {
    settings_entry_set_if_missing(map, item, key, value ? "1" : "0");
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
        PODKOP_SUBSCRIPTION_METADATA_DIR + "/" + section + ".json",
        PODKOP_SUBSCRIPTION_LINKS_DIR + "/" + section + ".json",
        PODKOP_OUTBOUND_METADATA_DIR + "/" + section + ".json",
        PODKOP_SECTION_CACHE_DIR + "/" + section + ".json",
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
    if (subscription_user_agent != "") {
        let settings = parse_json_object(option(section, "subscription_url_settings", ""));
        settings_entry_set_if_missing(settings, subscription_url, "user_agent", subscription_user_agent);
        set_option_json(ctx, section, "subscription_url_settings", settings);
    }

    add_list_unique(ctx, section, "subscription_urls", subscription_url);
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

function migrate_connection_url_item_settings(ctx, section) {
    let values = whitespace_list_values(section, "selector_proxy_links");
    if (length(values) == 0)
        return;

    let settings = parse_json_object(option(section, "connection_url_settings", ""));
    let changed = false;
    let udp_over_tcp_enabled = bool_option(section, "enable_udp_over_tcp", false);
    let detour_enabled = bool_option(section, "outbound_detour_enabled", false);
    let detour_section = option(section, "outbound_detour_section", "");

    for (let value in values) {
        if (detour_enabled) {
            settings_entry_set_bool_if_missing(settings, value, "outbound_detour_enabled", true);
            if (detour_section != "")
                settings_entry_set_if_missing(settings, value, "outbound_detour_section", detour_section);
            changed = true;
        }
        if (udp_over_tcp_enabled) {
            settings_entry_set_bool_if_missing(settings, value, "enable_udp_over_tcp", true);
            changed = true;
        }
    }

    if (changed || option(section, "connection_url_settings", "") != "")
        set_option_json(ctx, section, "connection_url_settings", settings);
}

function migrate_subscription_url_item_settings(ctx, section) {
    let values = whitespace_list_values(section, "subscription_urls");
    if (length(values) == 0)
        return;

    let settings = parse_json_object(option(section, "subscription_url_settings", ""));
    let normalized_values = [];
    let seen_values = {};
    let changed = false;
    let update_enabled = bool_option(section, "subscription_update_enabled", true);
    let update_interval = option(section, "subscription_update_interval", "");
    if (update_interval == "")
        update_interval = "1h";

    for (let value in values) {
        let profile = subscription_url_entry_profile(value);
        if (profile.value == "")
            continue;

        if (!seen_values[profile.value]) {
            push(normalized_values, profile.value);
            seen_values[profile.value] = true;
        }

        if (profile.changed) {
            settings_entry_move_if_needed(settings, profile.raw, profile.value);
            settings_entry_set_if_missing(settings, profile.value, "user_agent", profile.user_agent);
        }

        settings_entry_set_bool_if_missing(settings, profile.value, "subscription_update_enabled", update_enabled);
        settings_entry_set_if_missing(settings, profile.value, "subscription_update_interval", update_interval);
        changed = true;
    }

    if (!list_values_equal(values, normalized_values))
        set_list_option(ctx, section, "subscription_urls", normalized_values);

    if (changed || option(section, "subscription_url_settings", "") != "")
        set_option_json(ctx, section, "subscription_url_settings", settings);
}

function migrate_interface_item_settings(ctx, section) {
    normalize_connections_list(ctx, section, "interface", "interfaces");

    let values = option_list_values(section, "interfaces");
    if (length(values) == 0)
        return;

    let settings = parse_json_object(option(section, "interface_settings", ""));
    let changed = false;
    let resolver_enabled = bool_option(section, "domain_resolver_enabled", false);
    let dns_type = option(section, "domain_resolver_dns_type", "");
    let dns_server = option(section, "domain_resolver_dns_server", "");

    for (let value in values) {
        if (resolver_enabled) {
            settings_entry_set_bool_if_missing(settings, value, "domain_resolver_enabled", true);
            settings_entry_set_if_missing(settings, value, "domain_resolver_dns_type", dns_type != "" ? dns_type : "udp");
            settings_entry_set_if_missing(settings, value, "domain_resolver_dns_server", dns_server != "" ? dns_server : "8.8.8.8");
            changed = true;
        }
    }

    if (changed || option(section, "interface_settings", "") != "")
        set_option_json(ctx, section, "interface_settings", settings);
}

function migrate_outbound_json_list(ctx, section) {
    normalize_connections_list(ctx, section, "outbound_json", "outbound_jsons");
}

function migrate_connection_section(ctx, section) {
    migrate_connection_url_item_settings(ctx, section);
    migrate_subscription_url_item_settings(ctx, section);
    migrate_interface_item_settings(ctx, section);
    migrate_outbound_json_list(ctx, section);

    delete_option(ctx, section, "subscription_update_enabled");
    delete_option(ctx, section, "subscription_update_interval");
    delete_option(ctx, section, "enable_udp_over_tcp");
    delete_option(ctx, section, "outbound_detour_enabled");
    delete_option(ctx, section, "outbound_detour_section");
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

function add_domain_values_with_prefix(ctx, section, option_name, prefix, kind) {
    let values = legacy_condition_values(
        kind,
        option(section, option_name + "_text_mode", "0"),
        option(section, "conditions_text_mode", "0"),
        option(section, option_name + "_text", ""),
        section[option_name]
    );

    for (let value in values)
        add_list_unique(ctx, section, "domain_suffix", prefix + value);
}

function migrate_combined_domain_conditions(ctx, section) {
    add_domain_values_with_prefix(ctx, section, "domain", "full:", "domains");
    add_domain_values_with_prefix(ctx, section, "domain_keyword", "keyword:", "generic");
    add_domain_values_with_prefix(ctx, section, "domain_regex", "regex:", "generic");

    delete_option(ctx, section, "domain");
    delete_option(ctx, section, "domain_keyword");
    delete_option(ctx, section, "domain_regex");
    delete_option(ctx, section, "domain_text");
    delete_option(ctx, section, "domain_keyword_text");
    delete_option(ctx, section, "domain_regex_text");
    delete_option(ctx, section, "domain_text_mode");
    delete_option(ctx, section, "domain_keyword_text_mode");
    delete_option(ctx, section, "domain_regex_text_mode");
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
        migrate_connection_section(ctx, section);
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

    migrate_byedpi_cmd_opts(ctx, section);
    migrate_zapret_nfqws_default(ctx, section, constants);
}

function migrate_rule_section(ctx, section, constants) {
    set_section_type(ctx, section, "section");
    migrate_rule(ctx, section, true, constants);
    migrate_combined_domain_conditions(ctx, section);
    push(ctx.model.sections, section);
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
        for (let section in ctx.model.sections) {
            let name = section_name(section);
            if (name == "" || name == target_section)
                continue;

            let urls = whitespace_list_values(section, "subscription_urls");
            if (length(urls) == 0)
                continue;

            let item_settings = parse_json_object(option(section, "subscription_url_settings", ""));
            let changed = false;
            for (let value in urls) {
                settings_entry_set_bool_if_missing(item_settings, value, "download_via_proxy_enabled", true);
                settings_entry_set_if_missing(item_settings, value, "download_via_proxy_section", target_section);
                changed = true;
            }

            if (changed)
                set_option_json(ctx, section, "subscription_url_settings", item_settings);
        }
    }

    delete_option(ctx, settings_section, "download_subscriptions_via_proxy");
}

function migrate_rule_set_settings(ctx, section) {
    let references = option_list_values(section, "rule_set_with_subnets");
    if (length(references) == 0)
        return;

    let settings = parse_json_object(option(section, "rule_set_settings", ""));
    for (let reference in references)
        settings_entry_set_bool_if_missing(settings, reference, "include_subnets", true);
    set_option_json(ctx, section, "rule_set_settings", settings);
}

function migrate_model(model, constants) {
    let ctx = migration_context(model);
    constants = object_or_empty(constants);

    delete_option(ctx, model.settings, "routing_excluded_ips");
    migrate_list_update_enabled(ctx);

    for (let section in model.rules)
        migrate_rule_section(ctx, section, constants);
    model.rules = [];

    for (let section in model.sections) {
        migrate_rule(ctx, section, false, constants);
        migrate_combined_domain_conditions(ctx, section);
        migrate_rule_set_settings(ctx, section);
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
        shell_quote(PODKOP_SUBSCRIPTION_LINKS_DIR) + " " +
        shell_quote(PODKOP_SUBSCRIPTION_METADATA_DIR) + " " +
        shell_quote(PODKOP_OUTBOUND_METADATA_DIR) + " " +
        shell_quote(PODKOP_SECTION_CACHE_DIR));
}

function ensure_runtime_dirs() {
    ensure_dir(TMP_SUBSCRIPTION_FOLDER);
    ensure_dir(PODKOP_RUNTIME_STATE_DIR);
    ensure_dir(PODKOP_SUBSCRIPTION_LINKS_DIR);
    ensure_dir(PODKOP_SUBSCRIPTION_METADATA_DIR);
    ensure_dir(PODKOP_OUTBOUND_METADATA_DIR);
    ensure_dir(PODKOP_SECTION_CACHE_DIR);
}

function ensure_runtime_cache_format() {
    ensure_dir(PODKOP_RUNTIME_STATE_DIR);

    if (first_line(PODKOP_RUNTIME_CACHE_FORMAT_FILE) != PODKOP_RUNTIME_CACHE_FORMAT) {
        clear_subscription_runtime_cache();
        ensure_runtime_dirs();
        fs.writefile(PODKOP_RUNTIME_CACHE_FORMAT_FILE, PODKOP_RUNTIME_CACHE_FORMAT + "\n");
    }

    if (first_line(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) != PODKOP_RUNTIME_CACHE_FORMAT) {
        run("rm -rf " + shell_quote(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR));
        ensure_dir(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        run("chmod 700 " + shell_quote(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR) + " >/dev/null 2>&1");
        fs.writefile(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE, PODKOP_RUNTIME_CACHE_FORMAT + "\n");
        run("chmod 600 " + shell_quote(PODKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) + " >/dev/null 2>&1");
    }
}

function remove_legacy_server_country_cache() {
    fs.unlink(PODKOP_RUNTIME_STATE_DIR + "/server-country-cache.json");
}

function remove_cache_path(path) {
    path = as_string(path);
    if (index(path, "*") >= 0)
        run("rm -f " + path);
    else
        fs.unlink(path);
}

function apply_operations(cursor, operations) {
    for (let op in operations) {
        if (op.op == "set")
            cursor.set(CONFIG_NAME, op.section, op.option, op.value);
        else if (op.op == "delete")
            cursor.delete(CONFIG_NAME, op.section, op.option);
        else if (op.op == "add_list")
            cursor.set(CONFIG_NAME, op.section, op.option, op.values);
        else if (op.op == "set_list")
            cursor.set(CONFIG_NAME, op.section, op.option, op.values);
        else if (op.op == "set_type")
            cursor.set(CONFIG_NAME, op.section, op.type);
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
        fs.unlink(PODKOP_INTERNAL_CONFIG_TRIGGER_GUARD);
        return;
    }

    let stamp = clock();
    let tmp_path = PODKOP_INTERNAL_CONFIG_TRIGGER_GUARD + "." + stamp[0] + "." + stamp[1];
    fs.writefile(tmp_path, as_string(stamp[0]) + "\n" + hash + "\n");
    if (!fs.rename(tmp_path, PODKOP_INTERNAL_CONFIG_TRIGGER_GUARD))
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
