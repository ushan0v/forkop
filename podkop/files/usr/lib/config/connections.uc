#!/usr/bin/env ucode

let common = require("core.common");
let uci_core = require("core.uci");

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;

const CONFIG_NAME = getenv("PODKOP_CONFIG_NAME") || "podkop-plus";
const ITEM_TYPES = [
    "subscription_url",
    "urltest",
    "priority_group",
    "priority_level"
];

let item_sections = null;

function raw_option(section, key) {
    return object_or_empty(section)[key];
}

function option(section, key, fallback) {
    return common.option(section, key, fallback);
}

function bool_value(value, fallback) {
    if (value == null || value == "")
        return !!fallback;

    value = as_string(value);
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function bool_option(section, key, fallback) {
    return bool_value(raw_option(section, key), fallback);
}

function list_value(section, key) {
    let value = raw_option(section, key);
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;

    value = as_string(value);
    return value == "" ? [] : [ value ];
}

function whitespace_list_value(section, key) {
    let value = raw_option(section, key);
    if (type(value) == "array")
        return value;
    return common.list_option(section, key);
}

function section_name(section) {
    return option(section, ".name", "");
}

function empty_item_sections() {
    let result = {};
    for (let type_name in ITEM_TYPES) {
        result[type_name] = {
            by_name: {},
            list: []
        };
    }
    return result;
}

function add_item_section(index, type_name, section) {
    section = object_or_empty(section);
    let name = section_name(section);
    if (name == "")
        return;

    if (index[type_name] == null)
        index[type_name] = { by_name: {}, list: [] };
    index[type_name].by_name[name] = section;
    push(index[type_name].list, section);
}

function item_index_from_cursor(cursor, config_name) {
    let index = empty_item_sections();
    if (cursor == null)
        return index;

    config_name = as_string(config_name || CONFIG_NAME);
    for (let type_name in ITEM_TYPES) {
        try {
            cursor.foreach(config_name, type_name, function(section) {
                add_item_section(index, type_name, section);
            });
        }
        catch (e) {
        }
    }

    return index;
}

function fixture_section_list(data, type_name) {
    data = object_or_empty(data);
    let value = data[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = data[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function item_index_from_data(data) {
    let index = empty_item_sections();
    for (let type_name in ITEM_TYPES)
        for (let section in fixture_section_list(data, type_name))
            add_item_section(index, type_name, section);
    return index;
}

function item_index_from_uci() {
    let index = empty_item_sections();
    for (let type_name in ITEM_TYPES)
        for (let section in uci_core.section_objects(CONFIG_NAME, type_name))
            add_item_section(index, type_name, section);
    return index;
}

function set_item_sections(index) {
    item_sections = type(index) == "object" ? index : empty_item_sections();
}

function set_item_sections_from_cursor(cursor, config_name) {
    set_item_sections(item_index_from_cursor(cursor, config_name));
}

function set_item_sections_from_data(data) {
    set_item_sections(item_index_from_data(data));
}

function get_item_sections() {
    if (item_sections == null)
        item_sections = item_index_from_uci();
    return item_sections;
}

function child_section(type_name, item_id) {
    return object_or_empty(object_or_empty(object_or_empty(get_item_sections())[type_name]).by_name)[as_string(item_id)];
}

function owned_child_section(parent, type_name, item_id) {
    let child = child_section(type_name, item_id);
    if (type(child) != "object")
        return null;
    return option(child, "section", "") == section_name(parent) ? child : null;
}

function child_items(parent, type_name) {
    let result = [];
    for (let child in object_or_empty(object_or_empty(get_item_sections())[type_name]).list || [])
        if (option(child, "section", "") == section_name(parent))
            push(result, child);
    return result;
}

function child_items_by_owner(type_name, owner_key, owner_value) {
    owner_value = as_string(owner_value);
    let result = [];
    for (let child in object_or_empty(object_or_empty(get_item_sections())[type_name]).list || [])
        if (option(child, owner_key, "") == owner_value)
            push(result, child);
    return result;
}

function child_item_by_value(parent, type_name, value_key, value) {
    value = as_string(value);
    for (let child in child_items(parent, type_name))
        if (option(child, value_key, "") == value)
            return child;
    return null;
}

function child_option(child, key, fallback) {
    if (type(child) != "object")
        return as_string(fallback);
    return option(child, key, fallback);
}

function child_option_alias(child, keys, fallback) {
    if (type(child) != "object")
        return as_string(fallback);
    for (let key in keys) {
        let value = raw_option(child, key);
        if (value != null)
            return as_string(value);
    }
    return as_string(fallback);
}

function child_bool(child, key, fallback) {
    if (type(child) != "object")
        return !!fallback;
    return bool_option(child, key, fallback);
}

function child_list(child, key, fallback) {
    if (type(child) != "object")
        return fallback == null ? [] : fallback;
    let value = raw_option(child, key);
    if (value == null)
        value = fallback;
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;

    value = as_string(value);
    return value == "" ? [] : [ value ];
}

function child_list_alias(child, keys, fallback) {
    if (type(child) == "object") {
        for (let key in keys) {
            let value = raw_option(child, key);
            if (value != null)
                return child_list(child, key, []);
        }
    }
    return fallback == null ? [] : fallback;
}

function child_values(parent, type_name, value_key, legacy_key) {
    let items = child_items(parent, type_name);
    if (length(items) > 0) {
        let result = [];
        for (let child in items) {
            let value = option(child, value_key, "");
            if (value != "")
                push(result, value);
        }
        return result;
    }
    return legacy_key == "" ? [] : whitespace_list_value(parent, legacy_key);
}

function settings_map(section, key) {
    let value = option(section, key, "");
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

function item_settings(section, key, item) {
    return object_or_empty(settings_map(section, key)[as_string(item)]);
}

function item_option(section, key, item, option_name, fallback) {
    let value = item_settings(section, key, item)[option_name];
    if (value == null)
        return as_string(fallback);
    return as_string(value);
}

function item_bool(section, key, item, option_name, fallback) {
    return bool_value(item_settings(section, key, item)[option_name], fallback);
}

function item_list(section, key, item, option_name, fallback) {
    let value = item_settings(section, key, item)[option_name];
    if (value == null)
        value = fallback;
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;

    value = as_string(value);
    return value == "" ? [] : [ value ];
}

function is_legacy_connection_action(action) {
    action = as_string(action);
    return action == "proxy" || action == "outbound" || action == "vpn";
}

function is_connections_action(action) {
    action = as_string(action);
    return action == "connection" || is_legacy_connection_action(action);
}

function normalize_action(action) {
    action = as_string(action);
    return is_connections_action(action) ? "connection" : action;
}

function action(section) {
    return normalize_action(option(section, "action", ""));
}

function connection_urls(section) {
    return whitespace_list_value(section, "selector_proxy_links");
}

function subscription_urls(section) {
    return child_values(section, "subscription_url", "url", "subscription_urls");
}

function interfaces(section) {
    let result = list_value(section, "interfaces");
    if (length(result) == 0) {
        let value = option(section, "interface", "");
        if (value != "")
            push(result, value);
    }
    return result;
}

function outbound_jsons(section) {
    let result = list_value(section, "outbound_jsons");
    if (length(result) == 0) {
        let value = option(section, "outbound_json", "");
        if (value != "")
            push(result, value);
    }
    return result;
}

function urltests(section) {
    let result = [];
    for (let child in child_items(section, "urltest")) {
        let id = section_name(child);
        if (id != "")
            push(result, id);
    }
    if (length(result) > 0)
        return result;

    return bool_option(section, "urltest_enabled", false) ? [ "urltest" ] : [];
}

function priority_groups(section) {
    let result = [];
    for (let child in child_items(section, "priority_group")) {
        let id = section_name(child);
        if (id != "")
            push(result, id);
    }
    return result;
}

function priority_group_child(section, value) {
    return owned_child_section(section, "priority_group", value);
}

function priority_group_settings(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child : {};
}

function priority_level_child(group_id, value) {
    let child = child_section("priority_level", value);
    if (type(child) != "object")
        return null;
    return option(child, "group", "") == as_string(group_id) ? child : null;
}

function priority_level_sort(left, right) {
    let left_order = int(option(left, "order", "0"), 10);
    let right_order = int(option(right, "order", "0"), 10);
    if (left_order != right_order)
        return left_order < right_order ? -1 : 1;

    let left_name = section_name(left);
    let right_name = section_name(right);
    return left_name == right_name ? 0 : (left_name < right_name ? -1 : 1);
}

function priority_level_items(group_id) {
    let result = child_items_by_owner("priority_level", "group", group_id);
    sort(result, priority_level_sort);
    return result;
}

function priority_levels(group_id) {
    let result = [];
    for (let child in priority_level_items(group_id)) {
        let id = section_name(child);
        if (id != "")
            push(result, id);
    }
    return result;
}

function community_lists(section) {
    return whitespace_list_value(section, "community_lists");
}

function rule_sets(section) {
    return whitespace_list_value(section, "rule_set");
}

function rule_sets_with_subnets(section) {
    return whitespace_list_value(section, "rule_set_with_subnets");
}

function list_option_value_from_array(values) {
    return join(" ", values || []);
}

function community_lists_value(section) {
    return list_option_value_from_array(community_lists(section));
}

function rule_sets_value(section) {
    return list_option_value_from_array(rule_sets(section));
}

function rule_sets_with_subnets_value(section) {
    return list_option_value_from_array(rule_sets_with_subnets(section));
}

function has_connection_sources(section) {
    return length(connection_urls(section)) > 0 ||
        length(subscription_urls(section)) > 0 ||
        length(interfaces(section)) > 0 ||
        length(outbound_jsons(section)) > 0;
}

function subscription_url_settings(section, value) {
    let child = child_item_by_value(section, "subscription_url", "url", value);
    return child != null ? child : item_settings(section, "subscription_url_settings", value);
}

function urltest_child(section, value) {
    let child = owned_child_section(section, "urltest", value);
    if (child != null)
        return child;

    return child_item_by_value(section, "urltest", "id", value);
}

function urltest_settings(section, value) {
    let child = urltest_child(section, value);
    return child != null ? child : item_settings(section, "urltest_settings", value);
}

function subscription_update_enabled(section, value) {
    let child = child_item_by_value(section, "subscription_url", "url", value);
    if (child != null)
        return child_bool(child, "subscription_update_enabled", true);
    return item_bool(section, "subscription_url_settings", value, "subscription_update_enabled",
        bool_option(section, "subscription_update_enabled", true));
}

function subscription_update_interval(section, value) {
    let child = child_item_by_value(section, "subscription_url", "url", value);
    if (child != null)
        return child_option(child, "subscription_update_interval", "1h");
    return item_option(section, "subscription_url_settings", value, "subscription_update_interval",
        option(section, "subscription_update_interval", "1h") || "1h");
}

function subscription_dashboard_metadata_enabled(section, value) {
    let child = child_item_by_value(section, "subscription_url", "url", value);
    if (child != null)
        return child_bool(child, "show_dashboard_metadata", true);
    return item_bool(section, "subscription_url_settings", value, "show_dashboard_metadata", true);
}

function subscription_auto_user_agent(section, value) {
    let child = child_item_by_value(section, "subscription_url", "url", value);
    if (child != null) {
        if (raw_option(child, "auto_user_agent") != null)
            return child_bool(child, "auto_user_agent", true);
        return child_option(child, "user_agent", "") == "";
    }

    let settings = item_settings(section, "subscription_url_settings", value);
    if (raw_option(settings, "auto_user_agent") != null)
        return item_bool(section, "subscription_url_settings", value, "auto_user_agent", true);
    return item_option(section, "subscription_url_settings", value, "user_agent", "") == "";
}

function subscription_auto_hwid(section, value) {
    let child = child_item_by_value(section, "subscription_url", "url", value);
    if (child != null) {
        if (raw_option(child, "auto_hwid") != null)
            return child_bool(child, "auto_hwid", true);
        return child_option(child, "hwid", "") == "";
    }

    let settings = item_settings(section, "subscription_url_settings", value);
    if (raw_option(settings, "auto_hwid") != null)
        return item_bool(section, "subscription_url_settings", value, "auto_hwid", true);
    return item_option(section, "subscription_url_settings", value, "hwid", "") == "";
}

function subscription_include_urltest_groups(section, value) {
    let child = child_item_by_value(section, "subscription_url", "url", value);
    if (child != null)
        return child_bool(child, "include_urltest_groups", true);
    return item_bool(section, "subscription_url_settings", value, "include_urltest_groups", true);
}

function subscription_hide_urltest_group_outbounds(section, value) {
    let child = child_item_by_value(section, "subscription_url", "url", value);
    if (child != null)
        return child_bool(child, "hide_urltest_group_outbounds", true);
    return item_bool(section, "subscription_url_settings", value, "hide_urltest_group_outbounds", true);
}

function subscription_hide_detour_outbounds(section, value) {
    let child = child_item_by_value(section, "subscription_url", "url", value);
    if (child != null)
        return child_bool(child, "hide_detour_outbounds", true);
    return item_bool(section, "subscription_url_settings", value, "hide_detour_outbounds", true);
}

function subscription_prefix_nodes(section, value) {
    let child = child_item_by_value(section, "subscription_url", "url", value);
    if (child != null)
        return child_bool(child, "prefix_nodes", false);
    return item_bool(section, "subscription_url_settings", value, "prefix_nodes", false);
}

function subscription_node_prefix(section, value) {
    if (!subscription_prefix_nodes(section, value))
        return "";

    let child = child_item_by_value(section, "subscription_url", "url", value);
    let prefix = child != null
        ? child_option(child, "node_prefix", "")
        : item_option(section, "subscription_url_settings", value, "node_prefix", "");
    return trim(as_string(prefix));
}

function subscription_user_agent(section, value) {
    if (subscription_auto_user_agent(section, value))
        return "";

    let child = child_item_by_value(section, "subscription_url", "url", value);
    let configured = child != null
        ? child_option(child, "user_agent", "")
        : item_option(section, "subscription_url_settings", value, "user_agent", "");
    return configured != "" ? configured : "sing-box";
}

function subscription_hwid(section, value) {
    if (subscription_auto_hwid(section, value))
        return "";

    let child = child_item_by_value(section, "subscription_url", "url", value);
    if (child != null)
        return child_option(child, "hwid", "");
    return item_option(section, "subscription_url_settings", value, "hwid", "");
}

function subscription_download_section(section, value) {
    let child = child_item_by_value(section, "subscription_url", "url", value);
    if (child != null) {
        if (!child_bool(child, "download_via_proxy_enabled", false))
            return "";
        return child_option(child, "download_via_proxy_section", "");
    }

    if (!item_bool(section, "subscription_url_settings", value, "download_via_proxy_enabled", false))
        return "";

    return item_option(section, "subscription_url_settings", value, "download_via_proxy_section", "");
}

function urltest_check_interval(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_option_alias(child, [ "check_interval", "urltest_check_interval" ], "3m");
    return item_option(section, "urltest_settings", value, "urltest_check_interval",
        option(section, "urltest_check_interval", "3m") || "3m");
}

function urltest_tolerance(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_option_alias(child, [ "tolerance", "urltest_tolerance" ], "50");
    return item_option(section, "urltest_settings", value, "urltest_tolerance",
        option(section, "urltest_tolerance", "50") || "50");
}

function urltest_testing_url(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_option_alias(child, [ "testing_url", "urltest_testing_url" ], "https://www.gstatic.com/generate_204");
    return item_option(section, "urltest_settings", value, "urltest_testing_url",
        option(section, "urltest_testing_url", "https://www.gstatic.com/generate_204") || "https://www.gstatic.com/generate_204");
}

function urltest_display_name(section, value) {
    let fallback = as_string(value);
    if (fallback == "urltest" && length(child_items(section, "urltest")) == 0)
        fallback = "Fastest";
    let child = urltest_child(section, value);
    if (child != null)
        return child_option_alias(child, [ "name", "display_name" ], fallback);
    return item_option(section, "urltest_settings", value, "display_name", fallback);
}

function urltest_idle_timeout(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_option(child, "idle_timeout", "");
    return item_option(section, "urltest_settings", value, "idle_timeout", "");
}

function urltest_interrupt_exist_connections(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_bool(child, "interrupt_exist_connections", true);
    return item_bool(section, "urltest_settings", value, "interrupt_exist_connections", true);
}

function urltest_filter_mode(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_option_alias(child, [ "filter_mode", "urltest_filter_mode" ], "disabled");
    return item_option(section, "urltest_settings", value, "urltest_filter_mode",
        option(section, "urltest_filter_mode", "disabled") || "disabled");
}

function urltest_detect_server_country(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_option(child, "detect_server_country", "flag_emoji");
    return item_option(section, "urltest_settings", value, "detect_server_country",
        option(section, "detect_server_country", "flag_emoji") || "flag_emoji");
}

function urltest_hide_added_outbounds(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_bool(child, "hide_added_outbounds", false);
    return item_bool(section, "urltest_settings", value, "hide_added_outbounds", false);
}

function urltest_pin_dashboard(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_bool(child, "pin_dashboard", true);
    return item_bool(section, "urltest_settings", value, "pin_dashboard", true);
}

function urltest_include_countries(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_list_alias(child, [ "include_countries", "urltest_include_countries" ], []);
    return item_list(section, "urltest_settings", value, "urltest_include_countries",
        list_value(section, "urltest_include_countries"));
}

function urltest_include_outbounds(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_list_alias(child, [ "include_outbounds", "urltest_include_outbounds" ], []);
    return item_list(section, "urltest_settings", value, "urltest_include_outbounds",
        list_value(section, "urltest_include_outbounds"));
}

function urltest_include_regex(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_list_alias(child, [ "include_regex", "urltest_include_regex" ], []);
    return item_list(section, "urltest_settings", value, "urltest_include_regex",
        list_value(section, "urltest_include_regex"));
}

function urltest_exclude_countries(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_list_alias(child, [ "exclude_countries", "urltest_exclude_countries" ], []);
    return item_list(section, "urltest_settings", value, "urltest_exclude_countries",
        list_value(section, "urltest_exclude_countries"));
}

function urltest_exclude_outbounds(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_list_alias(child, [ "exclude_outbounds", "urltest_exclude_outbounds" ], []);
    return item_list(section, "urltest_settings", value, "urltest_exclude_outbounds",
        list_value(section, "urltest_exclude_outbounds"));
}

function urltest_exclude_regex(section, value) {
    let child = urltest_child(section, value);
    if (child != null)
        return child_list_alias(child, [ "exclude_regex", "urltest_exclude_regex" ], []);
    return item_list(section, "urltest_settings", value, "urltest_exclude_regex",
        list_value(section, "urltest_exclude_regex"));
}

function priority_group_display_name(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_option(child, "name", as_string(value)) : as_string(value);
}

function priority_group_health_url(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_option(child, "health_url", "https://www.gstatic.com/generate_204") : "https://www.gstatic.com/generate_204";
}

function priority_group_active_check_interval(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_option(child, "active_check_interval", "5s") : "5s";
}

function priority_group_check_timeout(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_option(child, "check_timeout", "2s") : "2s";
}

function priority_group_recovery_check_interval(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_option(child, "recovery_check_interval", "15s") : "15s";
}

function priority_group_pick_fastest(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_bool(child, "pick_fastest", false) : false;
}

function priority_group_switch_to_faster_same_priority(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_bool(child, "switch_to_faster_same_priority", false) : false;
}

function priority_group_fastest_check_interval(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_option(child, "fastest_check_interval", "3m") : "3m";
}

function priority_group_interrupt_exist_connections(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_bool(child, "interrupt_exist_connections", true) : true;
}

function priority_group_hide_added_outbounds(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_bool(child, "hide_added_outbounds", false) : false;
}

function priority_group_pin_dashboard(section, value) {
    let child = priority_group_child(section, value);
    return child != null ? child_bool(child, "pin_dashboard", true) : true;
}

function priority_level_display_name(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_option(child, "name", as_string(value)) : as_string(value);
}

function priority_level_order(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_option(child, "order", "0") : "0";
}

function priority_level_direct(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_bool(child, "direct", false) : false;
}

function priority_level_filter_mode(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_option(child, "filter_mode", "include") : "include";
}

function priority_level_include_countries(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list_alias(child, [ "include_countries", "country" ], []) : [];
}

function priority_level_include_outbounds(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list_alias(child, [ "include_outbounds", "server_name" ], []) : [];
}

function priority_level_include_regex(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list_alias(child, [ "include_regex", "regex" ], []) : [];
}

function priority_level_exclude_countries(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "exclude_countries", []) : [];
}

function priority_level_exclude_outbounds(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "exclude_outbounds", []) : [];
}

function priority_level_exclude_regex(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_list(child, "exclude_regex", []) : [];
}

function priority_level_countries(group_id, value) {
    return priority_level_include_countries(group_id, value);
}

function priority_level_outbounds(group_id, value) {
    return priority_level_include_outbounds(group_id, value);
}

function priority_level_regex(group_id, value) {
    return priority_level_include_regex(group_id, value);
}

function priority_level_detect_server_country(group_id, value) {
    let child = priority_level_child(group_id, value);
    return child != null ? child_option(child, "detect_server_country", "flag_emoji") : "flag_emoji";
}

function append_unique(result, seen, value) {
    value = as_string(value);
    if (value == "" || seen[value])
        return;
    seen[value] = true;
    push(result, value);
}

function subscription_download_targets(sections) {
    let result = [];
    let seen = {};

    for (let section in sections) {
        section = object_or_empty(section);
        let name = option(section, ".name", "");

        for (let source in subscription_urls(section)) {
            let target = subscription_download_section(section, source);
            if (target != "" && target != name)
                append_unique(result, seen, target);
        }
    }

    return result;
}

function subscription_download_target_port(sections, target, base_port) {
    target = as_string(target);
    base_port = int(base_port || 0);

    let targets = subscription_download_targets(sections);
    for (let i = 0; i < length(targets); i++)
        if (targets[i] == target)
            return base_port + 2 + i;

    return 0;
}

return {
    option,
    bool_option,
    list_value,
    whitespace_list_value,
    set_item_sections,
    set_item_sections_from_cursor,
    set_item_sections_from_data,
    settings_map,
    item_settings,
    item_option,
    item_bool,
    is_connections_action,
    normalize_action,
    action,
    connection_urls,
    subscription_urls,
    interfaces,
    outbound_jsons,
    urltests,
    community_lists,
    rule_sets,
    rule_sets_with_subnets,
    community_lists_value,
    rule_sets_value,
    rule_sets_with_subnets_value,
    has_connection_sources,
    subscription_url_settings,
    urltest_settings,
    subscription_update_enabled,
    subscription_update_interval,
    subscription_dashboard_metadata_enabled,
    subscription_auto_user_agent,
    subscription_auto_hwid,
    subscription_include_urltest_groups,
    subscription_hide_urltest_group_outbounds,
    subscription_hide_detour_outbounds,
    subscription_prefix_nodes,
    subscription_node_prefix,
    subscription_user_agent,
    subscription_hwid,
    subscription_download_section,
    urltest_check_interval,
    urltest_tolerance,
    urltest_testing_url,
    urltest_display_name,
    urltest_idle_timeout,
    urltest_interrupt_exist_connections,
    urltest_filter_mode,
    urltest_detect_server_country,
    urltest_hide_added_outbounds,
    urltest_pin_dashboard,
    urltest_include_countries,
    urltest_include_outbounds,
    urltest_include_regex,
    urltest_exclude_countries,
    urltest_exclude_outbounds,
    urltest_exclude_regex,
    priority_groups,
    priority_group_settings,
    priority_levels,
    priority_group_display_name,
    priority_group_health_url,
    priority_group_active_check_interval,
    priority_group_check_timeout,
    priority_group_recovery_check_interval,
    priority_group_pick_fastest,
    priority_group_switch_to_faster_same_priority,
    priority_group_fastest_check_interval,
    priority_group_interrupt_exist_connections,
    priority_group_hide_added_outbounds,
    priority_group_pin_dashboard,
    priority_level_display_name,
    priority_level_order,
    priority_level_direct,
    priority_level_filter_mode,
    priority_level_include_countries,
    priority_level_include_outbounds,
    priority_level_include_regex,
    priority_level_exclude_countries,
    priority_level_exclude_outbounds,
    priority_level_exclude_regex,
    priority_level_countries,
    priority_level_outbounds,
    priority_level_regex,
    priority_level_detect_server_country,
    subscription_download_targets,
    subscription_download_target_port
};
