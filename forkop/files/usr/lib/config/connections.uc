#!/usr/bin/env ucode

let common = require("core.common");
let uci_core = require("core.uci");
let rule_config = require("config.rule");
let amnezia = require("singbox.amnezia");

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const SYSTEM_DEVICE_VALUE = "@system";
const DEFAULT_DOMAIN_RESOLVER_DNS_SERVER = "8.8.8.8";
const ITEM_TYPES = [
    "section",
    "server",
    "server_client",
    "subscription_url",
    "section_interface",
    "connection_link",
    "urltest",
    "fallback_group",
    "fallback_level",
    "tunnel",
    "tunnel_peer"
];
let item_sections = null;

function raw_option(section, key) {
    return object_or_empty(section)[key];
}

let option = common.option;
let bool_option = common.bool_option;

function list_value(section, key) {
    let value = raw_option(section, key);
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;

    value = as_string(value);
    return value == "" ? [] : [ value ];
}

function list_contains(values, value) {
    for (let item in values)
        if (item == value)
            return true;
    return false;
}

function device_matchers(section, key) {
    let values = list_value(section, key);
    let result = { selected: length(values) > 0, system: false, ips: [] };
    let seen = {};
    for (let value in values) {
        value = trim(as_string(value));
        if (value == SYSTEM_DEVICE_VALUE)
            result.system = true;
        else {
            let normalized = rule_config.normalize_domain_subnet_value(value, "subnets");
            if (normalized != null && !seen[normalized]) {
                seen[normalized] = true;
                push(result.ips, normalized);
            }
        }
    }
    return result;
}

function excluded_devices(settings) {
    let values = common.words(option(settings, "routing_excluded_ips", ""));
    return {
        router: index(values, SYSTEM_DEVICE_VALUE) >= 0,
        addresses: filter(values, (value) => value != SYSTEM_DEVICE_VALUE)
    };
}

function section_name(section) {
    return option(section, ".name", "");
}

function section_names(sections) {
    return map(sections, (section) => section_name(section));
}

function display_name(section) {
    section = object_or_empty(section);
    let name = trim(option(section, "label", ""));
    return name != "" ? name : section_name(section);
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

function item_index_from_uci() {
    let index = empty_item_sections();
    for (let type_name in ITEM_TYPES)
        for (let section in uci_core.section_objects(CONFIG_NAME, type_name))
            add_item_section(index, type_name, section);
    return index;
}

// Reads the committed configuration afresh rather than what this process loaded earlier.
function load() {
    uci_core.reset();
    item_sections = item_index_from_uci();
}

function get_item_sections() {
    if (item_sections == null)
        item_sections = item_index_from_uci();
    return item_sections;
}

function child_section(type_name, item_id) {
    return object_or_empty(object_or_empty(object_or_empty(get_item_sections())[type_name]).by_name)[as_string(item_id)];
}

function named_display_name(type_name, value) {
    if (type(value) == "object")
        return display_name(value);
    let section = child_section(type_name, value);
    return type(section) == "object" ? display_name(section) : as_string(value);
}

function section_display_name(value) {
    return named_display_name("section", value);
}

function section_exists(value) {
    return type(child_section("section", value)) == "object";
}

function server_display_name(value) {
    return named_display_name("server", value);
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

function server_clients(server) {
    return child_items_by_owner("server_client", "server", section_name(server));
}

function child_item_by_value(parent, type_name, value_key, value) {
    value = as_string(value);
    for (let child in child_items(parent, type_name))
        if (option(child, value_key, "") == value)
            return child;
    return null;
}

function child_values(parent, type_name, value_key) {
    let result = [];
    for (let child in child_items(parent, type_name)) {
        let value = option(child, value_key, "");
        if (value != "")
            push(result, value);
    }
    return result;
}

function is_connections_action(action) {
    return as_string(action) == "connection";
}

// A subscription is its item, not its address: two of them may fetch one address.
function subscription_items(section) {
    let result = [];
    for (let child in child_items(section, "subscription_url"))
        if (option(child, "url", "") != "")
            push(result, child);
    return result;
}

function subscription_source(subscription) {
    return option(subscription, "url", "");
}

function subscription_source_type(value) {
    value = lc(trim(as_string(value)));
    if (substr(value, 0, 7) == "http://" || substr(value, 0, 8) == "https://")
        return "remote";
    if (substr(value, 0, 1) == "/")
        return "local";
    return "";
}

function interfaces(section) {
    return child_values(section, "section_interface", "name");
}

function outbound_jsons(section) {
    return list_value(section, "outbound_jsons");
}

function child_order_sort(left, right) {
    let left_order = int(option(left, "order", "0"), 10);
    let right_order = int(option(right, "order", "0"), 10);
    if (left_order != right_order)
        return left_order < right_order ? -1 : 1;

    let left_name = section_name(left);
    let right_name = section_name(right);
    return left_name == right_name ? 0 : (left_name < right_name ? -1 : 1);
}

function connection_link_items(section) {
    let result = child_items(section, "connection_link");
    sort(result, child_order_sort);
    return result;
}

function tunnel_items(section) {
    let result = child_items(section, "tunnel");
    sort(result, child_order_sort);
    return result;
}

function tunnels(section) {
    return section_names(tunnel_items(section));
}

function tunnel_child(section, value) {
    return owned_child_section(section, "tunnel", value);
}

function tunnel_peer_items(tunnel_id) {
    let result = child_items_by_owner("tunnel_peer", "tunnel", tunnel_id);
    sort(result, child_order_sort);
    return result;
}

function tunnel_endpoint(tunnel) {
    tunnel = object_or_empty(tunnel);
    let kind = lc(trim(as_string(option(tunnel, "kind", "wireguard"))));

    if (kind == "json" || kind == "openvpn-client" || kind == "openconnect") {
        try {
            let endpoint = json(option(tunnel, "endpoint_json", ""));
            return type(endpoint) == "object" ? endpoint : {};
        }
        catch (e) {
            return {};
        }
    }

    let endpoint = { type: kind };

    if (kind == "tailscale") {
        endpoint.auth_key = trim(as_string(option(tunnel, "tailscale_auth_key", "")));
        endpoint.hostname = trim(as_string(option(tunnel, "tailscale_hostname", "")));
        endpoint.control_url = trim(as_string(option(tunnel, "tailscale_control_url", "https://controlplane.tailscale.com")));
        endpoint.accept_routes = bool_option(tunnel, "tailscale_accept_routes", true);
        let exit_node = trim(as_string(option(tunnel, "tailscale_exit_node", "")));
        if (exit_node != "")
            endpoint.exit_node = exit_node;
        let detour = trim(as_string(option(tunnel, "tailscale_detour_section", "")));
        if (detour != "")
            endpoint.detour = detour;
        return endpoint;
    }

    if (kind == "warp") {
        let address = trim(as_string(option(tunnel, "warp_address", "")));
        let port = trim(as_string(option(tunnel, "warp_port", "")));
        if (address != "") endpoint.address = address;
        if (port != "") endpoint.port = int(port, 10);
        let keepalive = trim(as_string(option(tunnel, "warp_keepalive", "")));
        if (keepalive != "")
            endpoint.persistent_keepalive_interval = index(keepalive, "-") >= 0 ? keepalive : int(keepalive, 10);
        let profile = {};
        for (let key in [ "id", "auth_token", "private_key", "license_key" ]) {
            let value = trim(as_string(option(tunnel, "warp_profile_" + key, "")));
            if (value != "")
                profile[key] = value;
        }
        if (length(keys(profile)) > 0)
            endpoint.profile = profile;
        let one_sided = amnezia.object(tunnel, amnezia.ONE_SIDED_KEYS);
        if (one_sided)
            endpoint.amnezia = one_sided;
        return endpoint;
    }

    endpoint.address = list_value(tunnel, "address");
    endpoint.private_key = trim(as_string(option(tunnel, "private_key", "")));
    let listen_port = int(option(tunnel, "listen_port", "0"), 10);
    if (listen_port > 0)
        endpoint.listen_port = listen_port;
    let mtu = int(option(tunnel, "mtu", "0"), 10);
    if (mtu > 0)
        endpoint.mtu = mtu;

    endpoint.peers = [];
    for (let peer in tunnel_peer_items(section_name(tunnel))) {
        let item = {
            address: trim(as_string(option(peer, "address", ""))),
            port: int(option(peer, "port", "0"), 10),
            public_key: trim(as_string(option(peer, "public_key", ""))),
            allowed_ips: list_value(peer, "allowed_ips")
        };
        let pre_shared_key = trim(as_string(option(peer, "pre_shared_key", "")));
        if (pre_shared_key != "")
            item.pre_shared_key = pre_shared_key;
        let keepalive = trim(as_string(option(peer, "persistent_keepalive_interval", "")));
        if (keepalive != "")
            item.persistent_keepalive_interval = index(keepalive, "-") >= 0 ? keepalive : int(keepalive, 10);
        push(endpoint.peers, item);
    }

    // AmneziaWG takes the whole parameter set, plain WireGuard only what one side can add alone.
    if (kind == "amneziawg" || kind == "wireguard") {
        let parameters = amnezia.object(tunnel, kind == "amneziawg" ? amnezia.KEYS : amnezia.ONE_SIDED_KEYS);
        if (parameters)
            endpoint.amnezia = parameters;
    }

    return endpoint;
}

function urltests(section) {
    return section_names(child_items(section, "urltest"));
}

function fallback_groups(section) {
    return section_names(child_items(section, "fallback_group"));
}

function fallback_group_child(section, value) {
    return owned_child_section(section, "fallback_group", value);
}

function fallback_level_child(group_id, value) {
    let child = child_section("fallback_level", value);
    if (type(child) != "object")
        return null;
    return option(child, "group", "") == as_string(group_id) ? child : null;
}

function fallback_level_items(group_id) {
    let result = child_items_by_owner("fallback_level", "group", group_id);
    sort(result, child_order_sort);
    return result;
}

function fallback_levels(group_id) {
    return section_names(fallback_level_items(group_id));
}

function community_lists(section) {
    return list_value(section, "community_lists");
}

function rule_sets(section) {
    return list_value(section, "rule_set");
}

function rule_sets_with_subnets(section) {
    return list_value(section, "rule_set_with_subnets");
}

function destinations(section) {
    return rule_config.destination_conditions(option(section, "destinations", ""));
}

function download_via_proxy_flag_option(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy";
    if (purpose == "warp_profiles")
        return "warp_profiles_via_proxy";
    return "";
}

function download_via_proxy_enabled(settings, purpose) {
    let flag = download_via_proxy_flag_option(purpose);
    return flag != "" && bool_option(settings, flag, false);
}

function download_via_proxy_section(settings, purpose) {
    if (!download_via_proxy_enabled(settings, purpose))
        return "";

    purpose = as_string(purpose || "lists");
    if (purpose == "warp_profiles")
        return option(settings, "warp_profiles_via_proxy_section", "");
    return option(settings, "download_lists_via_proxy_section", "");
}

function rule_ports_csv(section) {
    return rule_config.rule_ports_csv_value(list_value(section, "ports"));
}

function has_dns_matchers(section) {
    let parsed = destinations(section);
    return length(parsed.domain) > 0 || length(parsed.domain_suffix) > 0 ||
        length(parsed.domain_keyword) > 0 || length(parsed.domain_regex) > 0 ||
        length(community_lists(section)) > 0 ||
        length(rule_sets(section)) > 0 ||
        length(rule_sets_with_subnets(section)) > 0;
}

function has_connection_sources(section) {
    return length(connection_link_items(section)) > 0 ||
        length(subscription_items(section)) > 0 ||
        length(interfaces(section)) > 0 ||
        length(outbound_jsons(section)) > 0 ||
        length(tunnels(section)) > 0;
}

function cascade_section(item) {
    return trim(option(item, "detour_section", ""));
}

function interface_child(section, value) {
    return child_item_by_value(section, "section_interface", "name", value);
}

function interface_display_name(section, value) {
    let display_name = trim(option(interface_child(section, value), "display_name", ""));
    return display_name != "" ? display_name : value;
}

function link_display_name(link) {
    return trim(option(link, "name", ""));
}

function tunnel_display_name(tunnel, index) {
    let name = lc(trim(option(tunnel, "kind", "wireguard"))) == "json"
        ? as_string(tunnel_endpoint(tunnel).tag || "")
        : option(tunnel, "name", "");
    name = trim(as_string(name));
    return name != "" ? name : "Tunnel #" + index;
}

function outbound_json_display_name(outbound, index) {
    let name = trim(as_string(object_or_empty(outbound).tag || ""));
    return name != "" ? name : "JSON outbound #" + index;
}

function interface_domain_resolver_enabled(section, value) {
    return bool_option(interface_child(section, value), "domain_resolver_enabled", false);
}

function interface_domain_resolver_dns_servers(section, value) {
    let result = [];
    for (let entry in list_value(interface_child(section, value), "domain_resolver_dns_server")) {
        entry = trim(as_string(entry));
        if (entry != "")
            push(result, entry);
    }
    return length(result) > 0 ? result : [ DEFAULT_DOMAIN_RESOLVER_DNS_SERVER ];
}

function interface_domain_resolver_dns_fallback_strategy(section, value) {
    let strategy = option(interface_child(section, value), "domain_resolver_dns_fallback_strategy", "parallel");
    return strategy != "" ? strategy : "parallel";
}

function interface_domain_resolver_dns_detour_enabled(section, value) {
    return bool_option(interface_child(section, value), "domain_resolver_dns_detour_enabled", false);
}

function interface_domain_resolver_dns_detour_section(section, value) {
    return interface_domain_resolver_dns_detour_enabled(section, value)
        ? option(interface_child(section, value), "domain_resolver_dns_detour_section", "")
        : "";
}

function urltest_child(section, value) {
    return owned_child_section(section, "urltest", value);
}

function subscription_remote(subscription) {
    return subscription_source_type(subscription_source(subscription)) == "remote";
}

function subscription_update_enabled(subscription) {
    return subscription_remote(subscription) &&
        bool_option(subscription, "subscription_update_enabled", true);
}

function subscription_update_interval(subscription) {
    return subscription_remote(subscription)
        ? option(subscription, "subscription_update_interval", "1h")
        : "";
}

function subscription_headers(subscription) {
    return subscription_remote(subscription) ? list_value(subscription, "header") : [];
}

function subscription_tag(subscription) {
    return trim(option(subscription, "tag", ""));
}

function subscription_tags(section) {
    return map(subscription_items(section), (subscription) => subscription_tag(subscription));
}

function subscription_exclude_types(subscription) {
    return list_value(subscription, "exclude_types");
}

// "pattern => replacement"; the first separator wins.
function parse_rename_rule(value) {
    value = as_string(value);
    let separator = index(value, "=>");
    if (separator < 0)
        return null;

    let pattern = trim(substr(value, 0, separator));
    if (pattern == "")
        return null;

    return { pattern, target: trim(substr(value, separator + 2)) };
}

function subscription_override(subscription) {
    return {
        prefix: option(subscription, "override_prefix", ""),
        suffix: option(subscription, "override_suffix", ""),
        rename: list_value(subscription, "override_rename"),
        patch: option(subscription, "override_patch", "")
    };
}

function subscription_download_section(subscription) {
    if (!subscription_remote(subscription) || !bool_option(subscription, "download_via_proxy_enabled", false))
        return "";
    return option(subscription, "download_via_proxy_section", "");
}

function urltest_check_interval(section, value) {
    return option(urltest_child(section, value), "check_interval", "3m");
}

function urltest_tolerance(section, value) {
    return option(urltest_child(section, value), "tolerance", "50");
}

function urltest_testing_url(section, value) {
    return option(urltest_child(section, value), "testing_url", "https://www.gstatic.com/generate_204");
}

function urltest_expected_status(section, value) {
    return option(urltest_child(section, value), "expected_status", "*");
}

function urltest_bandwidth_options(section, value) {
    let child = urltest_child(section, value);
    if (!bool_option(child, "bandwidth_enabled", false))
        return null;
    return {
        enabled: true,
        strategy: option(child, "bandwidth_strategy", "qualify"),
        speed_tolerance: int(option(child, "bandwidth_speed_tolerance", "20"), 10),
        adaptive: bool_option(child, "bandwidth_adaptive", false),
        selected_interval: option(child, "bandwidth_selected_interval", "10m"),
        url: option(child, "bandwidth_url", ""),
        interval: option(child, "bandwidth_interval", "6h"),
        timeout: option(child, "bandwidth_timeout", "10s"),
        max_bytes: int(option(child, "bandwidth_sample_mib", "32"), 10) * 1048576,
        minimum_mbps: int(option(child, "bandwidth_minimum_mbps", "50"), 10),
        confirmations: int(option(child, "bandwidth_confirmations", "2"), 10)
    };
}

function urltest_display_name(section, value) {
    return option(urltest_child(section, value), "name", as_string(value));
}

function urltest_idle_timeout(section, value) {
    return option(urltest_child(section, value), "idle_timeout", "");
}

function urltest_interrupt_exist_connections(section, value) {
    return bool_option(urltest_child(section, value), "interrupt_exist_connections", false);
}

function urltest_filter_mode(section, value) {
    return option(urltest_child(section, value), "server_filter_mode", "all");
}

function urltest_include_outbounds(section, value) {
    return list_value(urltest_child(section, value), "include_outbounds");
}

function urltest_include_regex(section, value) {
    return option(urltest_child(section, value), "include_regex", "");
}

function urltest_exclude_outbounds(section, value) {
    return list_value(urltest_child(section, value), "exclude_outbounds");
}

function urltest_exclude_regex(section, value) {
    return option(urltest_child(section, value), "exclude_regex", "");
}

function urltest_exclude_types(section, value) {
    return list_value(urltest_child(section, value), "exclude_types");
}

function fallback_group_display_name(section, value) {
    return option(fallback_group_child(section, value), "name", as_string(value));
}

function fallback_group_health_check_url(section, value) {
    return option(fallback_group_child(section, value), "health_check_url", "https://www.gstatic.com/generate_204");
}

function fallback_group_health_check_interval(section, value) {
    return option(fallback_group_child(section, value), "health_check_interval", "5m");
}

function fallback_group_health_check_timeout(section, value) {
    return option(fallback_group_child(section, value), "health_check_timeout", "5s");
}

function fallback_group_attempt_timeout(section, value) {
    return option(fallback_group_child(section, value), "attempt_timeout", "5s");
}

function fallback_group_expected_status(section, value) {
    return option(fallback_group_child(section, value), "expected_status", "*");
}

function fallback_group_idle_timeout(section, value) {
    return option(fallback_group_child(section, value), "idle_timeout", "5m");
}

function fallback_group_interrupt_exist_connections(section, value) {
    return bool_option(fallback_group_child(section, value), "interrupt_exist_connections", false);
}

function fallback_level_display_name(group_id, value) {
    return option(fallback_level_child(group_id, value), "name", as_string(value));
}

function fallback_level_order(group_id, value) {
    return option(fallback_level_child(group_id, value), "order", "0");
}

function fallback_level_mode(group_id, value) {
    return option(fallback_level_child(group_id, value), "server_filter_mode", "include");
}

function fallback_level_include_outbounds(group_id, value) {
    return list_value(fallback_level_child(group_id, value), "include_outbounds");
}

function fallback_level_include_regex(group_id, value) {
    return option(fallback_level_child(group_id, value), "include_regex", "");
}

function fallback_level_exclude_outbounds(group_id, value) {
    return list_value(fallback_level_child(group_id, value), "exclude_outbounds");
}

function fallback_level_exclude_regex(group_id, value) {
    return option(fallback_level_child(group_id, value), "exclude_regex", "");
}

function fallback_level_include_groups(group_id, value) {
    return list_value(fallback_level_child(group_id, value), "include_groups");
}

function fallback_level_exclude_types(group_id, value) {
    return list_value(fallback_level_child(group_id, value), "exclude_types");
}

// Each runs as "<section>/<name>", the name groups, filters and the Dashboard use.
function section_child_names(section) {
    let result = [];
    for (let link in connection_link_items(section))
        push(result, { kind: "link", name: link_display_name(link) });
    for (let value in interfaces(section))
        push(result, { kind: "interface", name: interface_display_name(section, value) });
    let tunnel_list = tunnel_items(section);
    for (let i = 0; i < length(tunnel_list); i++)
        push(result, { kind: "tunnel", name: tunnel_display_name(tunnel_list[i], i + 1) });
    let jsons = outbound_jsons(section);
    for (let i = 0; i < length(jsons); i++)
        push(result, { kind: "json", name: outbound_json_display_name(common.parse_json(jsons[i]), i + 1) });
    for (let value in urltests(section))
        push(result, { kind: "urltest", name: urltest_display_name(section, value) });
    for (let value in fallback_groups(section))
        push(result, { kind: "fallback", name: fallback_group_display_name(section, value) });
    return result;
}

return {
    SYSTEM_DEVICE_VALUE,
    destinations,
    rule_ports_csv,
    download_via_proxy_enabled,
    download_via_proxy_section,
    option,
    device_matchers,
    excluded_devices,
    load,
    is_connections_action,
    connection_link_items,
    subscription_items,
    subscription_source,
    subscription_source_type,
    interfaces,
    outbound_jsons,
    tunnels,
    tunnel_items,
    tunnel_child,
    tunnel_endpoint,
    urltests,
    community_lists,
    rule_sets,
    rule_sets_with_subnets,
    has_dns_matchers,
    has_connection_sources,
    cascade_section,
    subscription_update_enabled,
    subscription_update_interval,
    subscription_headers,
    subscription_exclude_types,
    subscription_override,
    parse_rename_rule,
    subscription_tag,
    subscription_tags,
    subscription_download_section,
    interface_display_name,
    link_display_name,
    tunnel_display_name,
    outbound_json_display_name,
    section_child_names,
    interface_domain_resolver_enabled,
    interface_domain_resolver_dns_servers,
    interface_domain_resolver_dns_fallback_strategy,
    interface_domain_resolver_dns_detour_enabled,
    interface_domain_resolver_dns_detour_section,
    urltest_check_interval,
    urltest_child,
    urltest_tolerance,
    urltest_testing_url,
    urltest_expected_status,
    urltest_display_name,
    urltest_idle_timeout,
    urltest_interrupt_exist_connections,
    urltest_filter_mode,
    urltest_include_outbounds,
    urltest_bandwidth_options,
    urltest_include_regex,
    urltest_exclude_outbounds,
    urltest_exclude_regex,
    urltest_exclude_types,
    fallback_groups,
    fallback_levels,
    fallback_group_display_name,
    fallback_group_health_check_url,
    fallback_group_health_check_interval,
    fallback_group_health_check_timeout,
    fallback_group_attempt_timeout,
    fallback_group_expected_status,
    fallback_group_idle_timeout,
    fallback_group_interrupt_exist_connections,
    fallback_level_display_name,
    fallback_level_order,
    fallback_level_mode,
    fallback_level_include_outbounds,
    fallback_level_include_regex,
    fallback_level_exclude_outbounds,
    fallback_level_exclude_regex,
    fallback_level_exclude_types,
    fallback_level_include_groups,
    section_display_name,
    section_exists,
    server_display_name,
    server_clients
};
