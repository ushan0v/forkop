#!/usr/bin/env ucode

let common = require("core.common");

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;

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
    return whitespace_list_value(section, "subscription_urls");
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

function has_connection_sources(section) {
    return length(connection_urls(section)) > 0 ||
        length(subscription_urls(section)) > 0 ||
        length(interfaces(section)) > 0 ||
        length(outbound_jsons(section)) > 0;
}

function connection_url_settings(section, value) {
    return item_settings(section, "connection_url_settings", value);
}

function subscription_url_settings(section, value) {
    return item_settings(section, "subscription_url_settings", value);
}

function interface_settings(section, value) {
    return item_settings(section, "interface_settings", value);
}

function subscription_update_enabled(section, value) {
    return item_bool(section, "subscription_url_settings", value, "subscription_update_enabled",
        bool_option(section, "subscription_update_enabled", true));
}

function subscription_update_interval(section, value) {
    return item_option(section, "subscription_url_settings", value, "subscription_update_interval",
        option(section, "subscription_update_interval", "1h") || "1h");
}

function subscription_dashboard_metadata_enabled(section, value) {
    return item_bool(section, "subscription_url_settings", value, "show_dashboard_metadata", true);
}

function subscription_hide_urltest_group_outbounds(section, value) {
    return item_bool(section, "subscription_url_settings", value, "hide_urltest_group_outbounds", true);
}

function subscription_hide_detour_outbounds(section, value) {
    return item_bool(section, "subscription_url_settings", value, "hide_detour_outbounds", true);
}

function subscription_user_agent(section, value) {
    return item_option(section, "subscription_url_settings", value, "user_agent", "");
}

function subscription_hwid(section, value) {
    return item_option(section, "subscription_url_settings", value, "hwid", "");
}

function subscription_download_section(section, value) {
    if (!item_bool(section, "subscription_url_settings", value, "download_via_proxy_enabled", false))
        return "";

    return item_option(section, "subscription_url_settings", value, "download_via_proxy_section", "");
}

function connection_detour_enabled(section, value) {
    return item_bool(section, "connection_url_settings", value, "outbound_detour_enabled",
        bool_option(section, "outbound_detour_enabled", false));
}

function connection_detour_section(section, value) {
    return item_option(section, "connection_url_settings", value, "outbound_detour_section",
        option(section, "outbound_detour_section", ""));
}

function connection_udp_over_tcp(section, value) {
    return item_bool(section, "connection_url_settings", value, "enable_udp_over_tcp",
        bool_option(section, "enable_udp_over_tcp", false));
}

function interface_domain_resolver_enabled(section, value) {
    return item_bool(section, "interface_settings", value, "domain_resolver_enabled",
        bool_option(section, "domain_resolver_enabled", false));
}

function interface_domain_resolver_dns_type(section, value) {
    return item_option(section, "interface_settings", value, "domain_resolver_dns_type",
        option(section, "domain_resolver_dns_type", "udp") || "udp");
}

function interface_domain_resolver_dns_server(section, value) {
    return item_option(section, "interface_settings", value, "domain_resolver_dns_server",
        option(section, "domain_resolver_dns_server", "8.8.8.8") || "8.8.8.8");
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
    has_connection_sources,
    connection_url_settings,
    subscription_url_settings,
    interface_settings,
    subscription_update_enabled,
    subscription_update_interval,
    subscription_dashboard_metadata_enabled,
    subscription_hide_urltest_group_outbounds,
    subscription_hide_detour_outbounds,
    subscription_user_agent,
    subscription_hwid,
    subscription_download_section,
    connection_detour_enabled,
    connection_detour_section,
    connection_udp_over_tcp,
    interface_domain_resolver_enabled,
    interface_domain_resolver_dns_type,
    interface_domain_resolver_dns_server,
    subscription_download_targets,
    subscription_download_target_port
};
