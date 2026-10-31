let common = require("core.common");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let runtime_constants = require("singbox.constants");
let runtime_dns = require("singbox.dns");
let runtime_route = require("singbox.route");
let runtime_rulesets = require("singbox.rulesets");
let runtime_servers = require("singbox.servers");
let runtime_tailscale = require("singbox.tailscale");
let subscription_headers_module = require("singbox.subscription_headers");
let runtime_urltest = require("singbox.urltest");
let connections = require("config.connections");
let runtime_settings_cache = null;

let as_string = common.as_string;
let strip_internal_fields = common.strip_internal_fields;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let int_option = common.int_option;
const CONFIG_NAME = "forkop";
// The FakeIP server answers only address queries and fails every other type.
const FAKEIP_QUERY_TYPES = [ "A", "AAAA" ];
const OPENCONNECT_RECONNECT_TIMEOUT = "876000h";
const TUNNEL_DNS_SERVER_TYPES = { openconnect: "openconnect", "openvpn-client": "openvpn", tailscale: "tailscale" };

function runtime_generate_unsupported(reason) {
    die(reason);
}

function section_enabled(section) {
    return bool_option(section, "enabled", true);
}

// A server without the switch was never saved from its dialog, so it was never checked.
function server_enabled(section) {
    return bool_option(section, "enabled", false);
}

function runtime_settings() {
    if (runtime_settings_cache == null)
        runtime_settings_cache = object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
    return runtime_settings_cache;
}

function dhcp_dnsmasq_section() {
    return object_or_empty(uci_core.get_all("dhcp", "@dnsmasq[0]"));
}

// sysntpd's servers by name. Over DNS through TLS or HTTPS a clock behind the server's certificate
// gets no answer, and then sysntpd never learns an address to set the clock from.
function ntp_server_names() {
    let ntp = object_or_empty(uci_core.get_all("system", "ntp"));
    if (option(ntp, "enabled", "1") == "0")
        return [];
    return filter(list_option(ntp, "server"), (name) => !core_ip.valid_ip(name));
}

function local_resolver_domain() {
    let value = trim(as_string(option(dhcp_dnsmasq_section(), "domain", "")));
    return value == "" ? "lan" : value;
}

function unmatched_dns_server_tag() {
    return option(runtime_settings(), "unmatched_dns_mode", "forkop") == "router"
        ? runtime_constants.DNSMASQ_DNS_SERVER_TAG
        : runtime_constants.DNS_SERVER_TAG;
}

function settings_update_interval() {
    let settings = runtime_settings();
    if (!bool_option(settings, "list_update_enabled", true))
        return "";

    let update_interval = option(settings, "update_interval", "1d");
    return update_interval != "" ? update_interval : "1d";
}

function apply_remote_ruleset_update_interval(rule_set) {
    let update_interval = settings_update_interval();
    if (update_interval != "")
        rule_set.update_interval = update_interval;
    return rule_set;
}

function outbound_tag(section_name) {
    return runtime_constants.outbound_tag(connections.section_display_name(section_name));
}

function child_outbound_tag(section, display_name) {
    return runtime_constants.child_tag(connections.section_display_name(section), display_name);
}

function download_detour(settings, purpose) {
    if (!connections.download_via_proxy_enabled(settings, purpose))
        return runtime_constants.DIRECT_OUTBOUND_TAG;
    let section_name = connections.download_via_proxy_section(settings, purpose);
    if (section_name == "")
        runtime_generate_unsupported("download " + purpose + " via proxy section is not set");
    return outbound_tag(section_name);
}

function push_remote_ruleset(config, tag_name, format, url) {
    push(config.route.rule_set, apply_remote_ruleset_update_interval({
        type: "remote",
        tag: tag_name,
        format,
        url,
        http_client: { detour: download_detour(runtime_settings(), "lists") }
    }));
}

function ruleset_registered(config, tag_name) {
    for (let rule_set in array_or_empty(config.route && config.route.rule_set)) {
        if (type(rule_set) == "object" && rule_set.tag == tag_name)
            return true;
    }
    return false;
}

function ensure_custom_ruleset(config, reference) {
    let tag_name;

    if (runtime_rulesets.is_community(reference)) {
        tag_name = runtime_rulesets.custom_reference_tag(reference);
        if (!ruleset_registered(config, tag_name))
            push_remote_ruleset(config, tag_name, "binary", runtime_rulesets.community_url(reference));
        return tag_name;
    }

    tag_name = runtime_rulesets.custom_reference_tag(reference);
    if (ruleset_registered(config, tag_name))
        return tag_name;

    if (substr(reference, 0, 1) == "/") {
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: "auto",
            path: reference
        });
    }
    else if (substr(reference, 0, 7) == "http://" || substr(reference, 0, 8) == "https://") {
        push_remote_ruleset(config, tag_name, "auto", reference);
    }
    else {
        runtime_generate_unsupported("rule_set reference is not supported by sing-box config generation");
    }

    return tag_name;
}

function clash_api_config(settings, service_address) {
    let controller = as_string(service_address || "");
    // sing-box listens on 0.0.0.0 over IPv4 only, on :: over both families.
    if (bool_option(settings, "enable_yacd", false) && bool_option(settings, "enable_yacd_wan_access", false))
        controller = "::";
    else if (controller == "")
        controller = "127.0.0.1";

    let result = {
        external_controller: (index(controller, ":") >= 0 ? "[" + controller + "]" : controller) + ":" + runtime_constants.CLASH_API_CONTROLLER_PORT
    };
    let secret = option(settings, "yacd_secret_key", "");
    if (secret != "")
        result.secret = secret;
    if (bool_option(settings, "enable_yacd", false)) {
        result.external_ui = runtime_constants.CLASH_API_UI_DIRECTORY;
        result.external_ui_download_detour = runtime_constants.DIRECT_OUTBOUND_TAG;
    }
    return result;
}

function single_or_array(values) {
    return length(values) == 1 ? values[0] : values;
}

function client_tproxy_inbound_matcher() {
    return [ runtime_constants.TPROXY_INBOUND_TAG, runtime_constants.TPROXY_INBOUND6_TAG ];
}

function system_tproxy_inbound_matcher() {
    return [ runtime_constants.SYSTEM_TPROXY_INBOUND_TAG, runtime_constants.SYSTEM_TPROXY_INBOUND6_TAG ];
}

function tproxy_inbound_matcher() {
    let result = client_tproxy_inbound_matcher();
    for (let inbound in system_tproxy_inbound_matcher())
        push(result, inbound);
    return result;
}

function source_dns_inbound_matcher() {
    return [ runtime_constants.SOURCE_DNS_INBOUND_TAG ];
}

function system_dns_inbound_matcher() {
    return [ runtime_constants.SYSTEM_DNS_INBOUND_TAG ];
}

function captured_dns_inbound_matcher() {
    return [ runtime_constants.SOURCE_DNS_INBOUND_TAG, runtime_constants.SYSTEM_DNS_INBOUND_TAG ];
}

function device_matcher_variants(section, key, dns) {
    let devices = connections.device_matchers(section, key);
    if (!devices.selected)
        return [ dns ? {} : { inbound: tproxy_inbound_matcher() } ];

    let result = [];
    if (length(devices.ips) > 0)
        push(result, {
            inbound: dns ? source_dns_inbound_matcher() : client_tproxy_inbound_matcher(),
            source_ip_cidr: single_or_array(devices.ips)
        });
    if (devices.system)
        push(result, { inbound: dns ? system_dns_inbound_matcher() : system_tproxy_inbound_matcher() });
    return result;
}

function copy_matchers(matchers) {
    let copy = {};
    for (let key, value in matchers)
        copy[key] = value;
    return copy;
}

function apply_matchers(rule, matchers) {
    for (let key, value in matchers)
        rule[key] = value;
}

function base_config(settings, service_address) {
    let log_level = option(settings, "log_level", "warn");
    let rewrite_ttl = int_option(settings, "dns_rewrite_ttl", "60");
    let cache_path = option(settings, "cache_path", "/tmp/sing-box/cache.db");
    let dns_config = runtime_dns.config(settings);
    if (dns_config.unsupported)
        runtime_generate_unsupported(dns_config.unsupported);

    let dns_rules = [
        { action: "reject", query_type: "HTTPS" },
        { action: "reject", domain_suffix: "use-application-dns.net" },
        {
            action: "route",
            server: runtime_constants.FAKEIP_DNS_SERVER_TAG,
            rewrite_ttl,
            query_type: FAKEIP_QUERY_TYPES,
            domain: [ runtime_constants.FAKEIP_TEST_DOMAIN, runtime_constants.CHECK_PROXY_IP_DOMAIN ]
        }
    ];
    let ntp_servers = ntp_server_names();
    if (length(ntp_servers) > 0)
        push(dns_rules, { inbound: runtime_constants.SYSTEM_DNS_INBOUND_TAG, action: "route", server: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG, domain: ntp_servers });

    let dns_servers = [];
    for (let server in dns_config.servers)
        push(dns_servers, server);
    push(dns_servers, {
        type: "fakeip",
        tag: runtime_constants.FAKEIP_DNS_SERVER_TAG,
        inet4_range: runtime_constants.FAKEIP_INET4_RANGE,
        inet6_range: runtime_constants.FAKEIP_INET6_RANGE
    });

    let inbounds = [
        { type: "tproxy", tag: runtime_constants.TPROXY_INBOUND_TAG, listen: runtime_constants.TPROXY_INBOUND_ADDRESS, listen_port: runtime_constants.TPROXY_INBOUND_PORT, tcp_fast_open: true, udp_fragment: true },
        { type: "tproxy", tag: runtime_constants.TPROXY_INBOUND6_TAG, listen: runtime_constants.TPROXY_INBOUND6_ADDRESS, listen_port: runtime_constants.TPROXY_INBOUND_PORT, tcp_fast_open: true, udp_fragment: true },
        { type: "tproxy", tag: runtime_constants.SYSTEM_TPROXY_INBOUND_TAG, listen: runtime_constants.TPROXY_INBOUND_ADDRESS, listen_port: runtime_constants.SYSTEM_TPROXY_INBOUND_PORT, tcp_fast_open: true, udp_fragment: true },
        { type: "tproxy", tag: runtime_constants.SYSTEM_TPROXY_INBOUND6_TAG, listen: runtime_constants.TPROXY_INBOUND6_ADDRESS, listen_port: runtime_constants.SYSTEM_TPROXY_INBOUND_PORT, tcp_fast_open: true, udp_fragment: true },
        { type: "direct", tag: runtime_constants.DNS_INBOUND_TAG, listen: runtime_constants.DNS_INBOUND_ADDRESS, listen_port: runtime_constants.DNS_INBOUND_PORT },
        { type: "direct", tag: runtime_constants.SOURCE_DNS_INBOUND_TAG, listen: runtime_constants.SOURCE_DNS_INBOUND_ADDRESS, listen_port: runtime_constants.SOURCE_DNS_INBOUND_PORT },
        { type: "direct", tag: runtime_constants.SYSTEM_DNS_INBOUND_TAG, listen: runtime_constants.SYSTEM_DNS_INBOUND_ADDRESS, listen_port: runtime_constants.SYSTEM_DNS_INBOUND_PORT }
    ];

    let runtime_context = { default_domain_resolver: runtime_dns.default_domain_resolver(settings) };

    return {
        log: {
            disabled: false,
            level: log_level,
            timestamp: false
        },
        dns: {
            servers: dns_servers,
            rules: dns_rules,
            final: runtime_constants.DNS_SERVER_TAG,
            strategy: option(settings, "dns_strategy", "prefer_ipv4"),
            timeout: option(settings, "dns_timeout", "10s")
        },
        endpoints: [],
        inbounds,
        providers: [],
        outbounds: [
            { type: "direct", tag: runtime_constants.DIRECT_OUTBOUND_TAG }
        ],
        route: runtime_route.config(settings, runtime_context),
        services: [],
        experimental: {
            unified_delay: {
                enabled: bool_option(settings, "unified_delay", true)
            },
            cache_file: {
                enabled: true,
                path: cache_path,
                store_fakeip: true,
                store_subscriptions: true,
                store_warp_config: true
            },
            clash_api: clash_api_config(settings, service_address)
        }
    };
}

function subscription_headers(subscription) {
    let parsed = subscription_headers_module.parse_header_lines(
        connections.subscription_headers(subscription)
    );
    if (!parsed.valid)
        runtime_generate_unsupported("invalid subscription request " + parsed.message);
    return parsed.headers;
}

function regex_escape(value) {
    value = as_string(value);
    let result = "";
    for (let i = 0; i < length(value); i++) {
        let character = substr(value, i, 1);
        if (index("\\.^$|?*+()[]{}", character) >= 0)
            result += "\\";
        result += character;
    }
    return result;
}

function filter_name_pattern(exact_names, regex_pattern) {
    let parts = [];
    for (let value in array_or_empty(exact_names)) {
        value = trim(as_string(value));
        if (value != "")
            push(parts, "^(?:" + regex_escape(value) + ")$");
    }
    regex_pattern = trim(as_string(regex_pattern));
    if (regex_pattern != "")
        push(parts, "(?:" + regex_pattern + ")");
    return length(parts) > 0 ? "(?:" + join("|", parts) + ")" : "";
}

function set_filter_side(result, side, pattern, require_match) {
    if (pattern != "")
        result[side] = pattern;
    else if (require_match)
        result[side] = "a^";
}

function normalized_outbound_types(values, allowed) {
    let supported = {};
    for (let value in array_or_empty(allowed))
        supported[value] = true;

    let result = [];
    let seen = {};
    for (let value in array_or_empty(values)) {
        value = lc(trim(as_string(value)));
        if (value == "" || seen[value] || !supported[value])
            continue;
        seen[value] = true;
        push(result, value);
    }
    return result;
}

function native_filter_options(mode,
    include_names, include_regex,
    exclude_names, exclude_regex, exclude_types) {
    let result = {};
    if (mode == "all")
        return result;
    if (mode == "include")
        set_filter_side(result, "include",
            filter_name_pattern(include_names, include_regex), true);
    if (mode == "include" || mode == "exclude") {
        set_filter_side(result, "exclude",
            filter_name_pattern(exclude_names, exclude_regex), false);
        // Providers hold only outbounds, so an endpoint type could never match.
        let types = normalized_outbound_types(exclude_types, runtime_constants.FILTERABLE_PROVIDER_TYPES);
        if (length(types) > 0)
            result.exclude_types = types;
    }
    return result;
}

function merge_object(target, source) {
    for (let key, value in object_or_empty(source))
        target[key] = value;
    return target;
}

function subscription_provider_filter(subscription) {
    return native_filter_options(
        option(subscription, "server_filter_mode", "all"),
        list_option(subscription, "include_outbounds"), option(subscription, "include_regex", ""),
        list_option(subscription, "exclude_outbounds"), option(subscription, "exclude_regex", ""),
        connections.subscription_exclude_types(subscription)
    );
}

function urltest_provider_filter(section, urltest_id) {
    return native_filter_options(
        connections.urltest_filter_mode(section, urltest_id),
        connections.urltest_include_outbounds(section, urltest_id), connections.urltest_include_regex(section, urltest_id),
        connections.urltest_exclude_outbounds(section, urltest_id), connections.urltest_exclude_regex(section, urltest_id),
        connections.urltest_exclude_types(section, urltest_id)
    );
}

function fallback_level_provider_filter(group_id, level_id) {
    return native_filter_options(
        connections.fallback_level_mode(group_id, level_id),
        connections.fallback_level_include_outbounds(group_id, level_id),
        connections.fallback_level_include_regex(group_id, level_id),
        connections.fallback_level_exclude_outbounds(group_id, level_id),
        connections.fallback_level_exclude_regex(group_id, level_id),
        connections.fallback_level_exclude_types(group_id, level_id)
    );
}

function urltest_leaf_candidate_outbound(outbound) {
    if (type(outbound) != "object")
        return false;

    let t = lc(as_string(outbound.type || ""));
    return t != "selector" && t != "urltest" && t != "fallback" &&
        t != "dns" && t != "block";
}

function assert_unique_outbound_tags(config) {
    let seen = {};
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            runtime_generate_unsupported("generated sing-box outbound is not an object");

        let tag_name = as_string(outbound.tag || "");
        if (tag_name == "")
            runtime_generate_unsupported("generated sing-box outbound has an empty tag");
        if (seen[tag_name])
            runtime_generate_unsupported("generated sing-box config has duplicate outbound tag '" + tag_name + "'");
        seen[tag_name] = true;
    }
}

function canonical_json(value) {
    if (type(value) == "object")
        return "{" + join(",", map(sort(keys(value)), (key) => sprintf("%J", key) + ":" + canonical_json(value[key]))) + "}";
    if (type(value) == "array")
        return "[" + join(",", map(value, (item) => canonical_json(item))) + "]";
    return sprintf("%J", value);
}

function wireguard_identities(endpoint) {
    let type_name = lc(as_string(endpoint.type || ""));
    if (type_name == "warp") {
        let key = as_string(object_or_empty(endpoint.profile).private_key || "");
        return key == "" ? [] : [ "warp/" + key ];
    }
    if (type_name != "wireguard" && type_name != "amneziawg")
        return [];
    return map(array_or_empty(endpoint.peers), (peer) =>
        as_string(endpoint.private_key || "") + "/" + as_string(object_or_empty(peer).public_key || ""));
}

// The core runs endpoints equal apart from their tag on one device; the same client key with
// other settings would be two devices taking one session from each other.
function assert_compatible_wireguard_endpoints(config) {
    let holders = {};
    for (let endpoint in array_or_empty(config.endpoints)) {
        if (type(endpoint) != "object")
            continue;
        for (let identity in wireguard_identities(endpoint)) {
            let first = holders[identity];
            if (first == null) {
                holders[identity] = endpoint;
                continue;
            }
            let names = {};
            for (let name in keys(first)) names[name] = true;
            for (let name in keys(endpoint)) names[name] = true;
            let differences = filter(sort(keys(names)), (name) =>
                name != "tag" && canonical_json(first[name]) != canonical_json(endpoint[name]));
            if (length(differences) > 0)
                runtime_generate_unsupported("endpoints '" + first.tag + "' and '" + endpoint.tag +
                    "' use the same WireGuard key for the same server with different " + join(", ", differences) +
                    ", so they would take the one session the server keeps per key from each other." +
                    " Make these settings the same, or give one of them its own client on the server");
        }
    }
}

function cascade_tag(item) {
    let target = connections.cascade_section(item);
    return target == "" ? "" : outbound_tag(target);
}

function override_rename_rules(values) {
    let result = [];
    for (let value in array_or_empty(values)) {
        let rule = connections.parse_rename_rule(value);
        if (rule == null)
            runtime_generate_unsupported("subscription rename rule must be written as 'pattern => replacement'");
        push(result, rule);
    }
    return result;
}

function override_patch_object(raw) {
    raw = trim(as_string(raw));
    if (raw == "")
        return {};

    let parsed;
    try {
        parsed = json(raw);
    }
    catch (e) {
        runtime_generate_unsupported("subscription override patch is not valid JSON");
    }
    if (type(parsed) != "object")
        runtime_generate_unsupported("subscription override patch is not a JSON object");
    return parsed;
}

function subscription_override_options(subscription) {
    let settings = connections.subscription_override(subscription);
    let result = {};

    let prefix = as_string(settings.prefix);
    if (prefix != "")
        result.prefix = prefix;
    let suffix = as_string(settings.suffix);
    if (suffix != "")
        result.suffix = suffix;
    let rename = override_rename_rules(settings.rename);
    if (length(rename) > 0)
        result.rename = rename;

    let detour = cascade_tag(subscription);
    if (detour != "")
        result.detour = detour;

    let patch = override_patch_object(settings.patch);
    if (length(keys(patch)) > 0)
        result.patch = patch;

    return result;
}

function add_subscription_provider(config, section, subscription) {
    let tag_name = child_outbound_tag(section, connections.subscription_tag(subscription));
    let source = connections.subscription_source(subscription);
    let source_type = connections.subscription_source_type(source);
    if (source_type == "")
        runtime_generate_unsupported("subscription source is not supported by sing-box config generation");

    let provider = merge_object({ type: source_type, tag: tag_name }, subscription_provider_filter(subscription));
    if (source_type == "local") {
        provider.path = source;
    }
    else {
        provider.url = source;
        provider.headers = subscription_headers(subscription);
        if (connections.subscription_update_enabled(subscription))
            provider.update_interval = connections.subscription_update_interval(subscription);

        let download_section = connections.subscription_download_section(subscription);
        if (download_section != "")
            provider.download_detour = outbound_tag(download_section);
    }
    let override = subscription_override_options(subscription);
    if (length(keys(override)) > 0)
        provider.override = override;
    push(config.providers, provider);
    return { tag: tag_name };
}

function add_subscription_providers(config, section) {
    let result = [];
    for (let subscription in connections.subscription_items(section))
        push(result, add_subscription_provider(config, section, subscription));
    return result;
}

function add_manual_link_outbounds(config, section, selector_tags, urltest_candidate_tags) {
    for (let link in connections.connection_link_items(section)) {
        let tag_name = child_outbound_tag(section, connections.link_display_name(link));
        let outbound = { type: "parser", tag: tag_name, link: connections.option(link, "uri", "") };
        let detour = cascade_tag(link);
        if (detour != "")
            outbound.detour = detour;
        push(config.outbounds, outbound);
        push(selector_tags, tag_name);
        push(urltest_candidate_tags, tag_name);
    }
}

function urltest_check_interval(section, urltest_id) {
    let interval = connections.urltest_check_interval(section, urltest_id);
    return interval != "" ? interval : "3m";
}

function unique_string_array(values) {
    let result = [];
    let seen = {};
    for (let value in array_or_empty(values)) {
        value = as_string(value);
        if (value == "" || seen[value])
            continue;
        seen[value] = true;
        push(result, value);
    }
    return result;
}

function object_keys_set(values) {
    let result = {};
    for (let value in array_or_empty(values))
        result[value] = true;
    return result;
}

function tag_display_name(tag, section) {
    tag = as_string(tag);
    let prefix = connections.section_display_name(section) + "/";
    return substr(tag, 0, length(prefix)) == prefix ? substr(tag, length(prefix)) : tag;
}

function regex_match_set(tags, section, regexes) {
    let names = {};
    for (let tag in array_or_empty(tags))
        names[tag] = tag_display_name(tag, section);
    let pattern = trim(as_string(regexes));
    return object_keys_set(runtime_urltest.regex_matching_tag_array(
        tags, names, pattern == "" ? [] : [ pattern ]
    ));
}

function tag_name_filter_matches(tag, section, name_filter, regex_set) {
    let name = trim(tag_display_name(tag, section));
    for (let selected in array_or_empty(name_filter))
        if (trim(as_string(selected)) == name)
            return true;
    return regex_set[tag];
}

function link_scheme(link) {
    link = as_string(link);
    let separator = index(link, "://");
    return separator > 0 ? lc(substr(link, 0, separator)) : "";
}

// A manual link is parsed at runtime, so its outbound takes the type of the link's protocol.
function outbound_effective_type(outbound) {
    outbound = object_or_empty(outbound);
    let type_name = lc(as_string(outbound.type || ""));
    if (type_name == "parser")
        return as_string(
            runtime_constants.LINK_SCHEME_OUTBOUND_TYPES[link_scheme(outbound.link)] || ""
        );
    return type_name;
}

function candidate_outbound_types(config) {
    let result = {};
    for (let group in [ array_or_empty(config.outbounds), array_or_empty(config.endpoints) ])
        for (let outbound in group) {
            if (type(outbound) != "object")
                continue;
            let tag_name = as_string(outbound.tag || "");
            if (tag_name != "")
                result[tag_name] = outbound_effective_type(outbound);
        }
    return result;
}

// exclude_types reaches only provider members, so manual servers are filtered here.
function exclude_typed_candidates(mode, tags, candidate_types, exclude_types) {
    if (mode == "all")
        return tags;

    let excluded = {};
    let types = normalized_outbound_types(exclude_types, runtime_constants.FILTERABLE_GROUP_TYPES);
    if (length(types) == 0)
        return tags;
    for (let value in types)
        excluded[value] = true;

    let result = [];
    for (let tag_name in array_or_empty(tags))
        if (!excluded[as_string(object_or_empty(candidate_types)[tag_name] || "")])
            push(result, tag_name);
    return result;
}

function urltest_all_candidate_outbounds(urltest_candidate_tags) {
    return unique_string_array(urltest_candidate_tags);
}

function urltest_matching_candidate_outbounds(urltest_candidate_tags, section, name_filter, regexes) {
    let regex_set = regex_match_set(urltest_candidate_tags, section, regexes);
    let result = [];

    for (let tag in array_or_empty(urltest_candidate_tags)) {
        if (tag_name_filter_matches(tag, section, name_filter, regex_set))
            push(result, tag);
    }

    return unique_string_array(result);
}

function urltest_exclude_outbounds(all_outbounds, excluded_outbounds) {
    let excluded = object_keys_set(excluded_outbounds);
    let result = [];
    for (let tag in array_or_empty(all_outbounds)) {
        if (!excluded[tag])
            push(result, tag);
    }
    return result;
}

function filter_candidate_outbounds(mode, section, urltest_candidate_tags,
    include_names, include_regex,
    exclude_names, exclude_regex) {
    let all_outbounds = urltest_all_candidate_outbounds(urltest_candidate_tags);
    if (mode == "all")
        return all_outbounds;

    let include_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        section,
        include_names,
        include_regex
    );
    let exclude_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        section,
        exclude_names,
        exclude_regex
    );
    let matched = mode == "include" ? include_outbounds : all_outbounds;
    return urltest_exclude_outbounds(matched, exclude_outbounds);
}

function urltest_filtered_outbounds(section, urltest_id, urltest_candidate_tags, candidate_types) {
    let mode = connections.urltest_filter_mode(section, urltest_id);
    return filter_candidate_outbounds(
        mode,
        section,
        exclude_typed_candidates(mode, urltest_candidate_tags, candidate_types,
            connections.urltest_exclude_types(section, urltest_id)),
        connections.urltest_include_outbounds(section, urltest_id),
        connections.urltest_include_regex(section, urltest_id),
        connections.urltest_exclude_outbounds(section, urltest_id),
        connections.urltest_exclude_regex(section, urltest_id)
    );
}

function fallback_level_filtered_outbounds(section, group_id, level_id, urltest_candidate_tags, candidate_types) {
    let mode = connections.fallback_level_mode(group_id, level_id);
    if (mode == "direct")
        return [ runtime_constants.DIRECT_OUTBOUND_TAG ];

    return filter_candidate_outbounds(
        mode,
        section,
        exclude_typed_candidates(mode, urltest_candidate_tags, candidate_types,
            connections.fallback_level_exclude_types(group_id, level_id)),
        connections.fallback_level_include_outbounds(group_id, level_id),
        connections.fallback_level_include_regex(group_id, level_id),
        connections.fallback_level_exclude_outbounds(group_id, level_id),
        connections.fallback_level_exclude_regex(group_id, level_id)
    );
}

function fallback_levels_with_outbounds(section, group_id, urltest_candidate_tags, candidate_types) {
    let result = [];
    let assigned = {};

    for (let level_id in connections.fallback_levels(group_id)) {
        let outbounds = [];
        for (let tag_name in fallback_level_filtered_outbounds(section, group_id, level_id, urltest_candidate_tags, candidate_types)) {
            if (!assigned[tag_name]) {
                assigned[tag_name] = true;
                push(outbounds, tag_name);
            }
        }

        push(result, {
            id: level_id,
            displayName: connections.fallback_level_display_name(group_id, level_id),
            order: int(connections.fallback_level_order(group_id, level_id), 10),
            mode: connections.fallback_level_mode(group_id, level_id),
            outbounds
        });
    }

    return result;
}

function provider_tags(provider_refs) {
    let result = [];
    for (let provider in array_or_empty(provider_refs))
        if (type(provider) == "object" && as_string(provider.tag || "") != "")
            push(result, as_string(provider.tag));
    return result;
}

function section_group_items(section) {
    let result = [];
    for (let urltest_id in connections.urltests(section))
        push(result, {
            kind: "urltest",
            id: urltest_id,
            display_name: connections.urltest_display_name(section, urltest_id)
        });
    for (let group_id in connections.fallback_groups(section))
        push(result, {
            kind: "fallback",
            id: group_id,
            display_name: connections.fallback_group_display_name(section, group_id)
        });
    return result;
}

// Every tag is allocated before any group is built, since a Fallback level can name a URLTest.
function allocate_group_tags(section, items) {
    let by_name = {};
    for (let item in items) {
        item.tag = child_outbound_tag(section, item.display_name);
        let name = trim(as_string(item.display_name));
        if (item.kind == "urltest" && name != "" && by_name[name] == null)
            by_name[name] = item.tag;
    }
    return by_name;
}

function included_group_tags(names, group_tags_by_name, own_tag) {
    let result = [];
    let seen = {};
    for (let name in array_or_empty(names)) {
        let tag_name = as_string(object_or_empty(group_tags_by_name)[trim(as_string(name))] || "");
        if (tag_name == "" || tag_name == own_tag || seen[tag_name])
            continue;
        seen[tag_name] = true;
        push(result, tag_name);
    }
    return result;
}

function append_unique_tags(target, tags) {
    let seen = {};
    for (let tag_name in array_or_empty(target))
        seen[tag_name] = true;
    for (let tag_name in array_or_empty(tags)) {
        if (seen[tag_name])
            continue;
        seen[tag_name] = true;
        push(target, tag_name);
    }
    return target;
}

function group_has_members(descriptor) {
    if (descriptor.kind == "urltest")
        return length(array_or_empty(descriptor.outbound.outbounds)) > 0 ||
            length(array_or_empty(descriptor.outbound.providers)) > 0;

    for (let level in array_or_empty(descriptor.outbound.groups))
        if (length(array_or_empty(level.outbounds)) > 0 ||
            length(array_or_empty(level.providers)) > 0)
            return true;
    return false;
}

function prune_group_member_list(members, available, group_tags) {
    let filtered = [];
    for (let tag_name in array_or_empty(members))
        if (!group_tags[tag_name] || available[tag_name])
            push(filtered, tag_name);
    return filtered;
}

function usable_group_descriptors(descriptors, group_tags) {
    let result = descriptors;
    for (let changed = true; changed; ) {
        changed = false;
        let available = {};
        for (let descriptor in result)
            available[descriptor.tag] = true;

        for (let descriptor in result) {
            if (descriptor.kind == "urltest") {
                let members = prune_group_member_list(descriptor.outbound.outbounds, available, group_tags);
                if (length(members) != length(array_or_empty(descriptor.outbound.outbounds)))
                    changed = true;
                descriptor.outbound.outbounds = members;
                continue;
            }
            for (let level in array_or_empty(descriptor.outbound.groups)) {
                let members = prune_group_member_list(level.outbounds, available, group_tags);
                if (length(members) != length(array_or_empty(level.outbounds)))
                    changed = true;
                level.outbounds = members;
            }
        }

        let kept = [];
        for (let descriptor in result) {
            if (group_has_members(descriptor))
                push(kept, descriptor);
            else
                changed = true;
        }
        result = kept;
    }
    return result;
}

// A URLTest a Fallback includes is one of its members, so the section goes through the Fallback.
function default_group_tag(descriptors) {
    let members = {};
    for (let descriptor in descriptors)
        if (descriptor.kind == "fallback")
            for (let level in array_or_empty(descriptor.outbound.groups))
                for (let tag_name in array_or_empty(level.outbounds))
                    members[tag_name] = true;
    for (let descriptor in descriptors)
        if (!members[descriptor.tag])
            return descriptor.tag;
    return null;
}

function build_urltest_outbound(section, item, urltest_candidate_tags, candidate_types, provider_refs) {
    let urltest_id = item.id;
    let urltest_outbounds = urltest_filtered_outbounds(section, urltest_id, urltest_candidate_tags, candidate_types);
    let urltest_outbound = {
        type: "urltest",
        tag: item.tag,
        outbounds: urltest_outbounds,
        url: connections.urltest_testing_url(section, urltest_id),
        expected_status: connections.urltest_expected_status(section, urltest_id),
        interval: urltest_check_interval(section, urltest_id),
        // The core reads 0 as its default of 50 ms.
        tolerance: max(1, int(connections.urltest_tolerance(section, urltest_id), 10)),
        interrupt_exist_connections: connections.urltest_interrupt_exist_connections(section, urltest_id)
    };
    let providers = provider_tags(provider_refs);
    if (length(providers) > 0)
        urltest_outbound.providers = providers;
    merge_object(urltest_outbound, urltest_provider_filter(section, urltest_id));
    let idle_timeout = connections.urltest_idle_timeout(section, urltest_id);
    if (idle_timeout != "")
        urltest_outbound.idle_timeout = idle_timeout;

    return urltest_outbound;
}

function build_fallback_group_outbound(section, item, urltest_candidate_tags, candidate_types, group_tags_by_name, provider_refs) {
    let group_id = item.id;
    let levels = fallback_levels_with_outbounds(section, group_id, urltest_candidate_tags, candidate_types);
    let providers = provider_tags(provider_refs);
    let outbound = {
        type: "fallback",
        tag: item.tag,
        groups: []
    };

    for (let level in levels) {
        let native_level = {
            outbounds: level.outbounds
        };
        if (level.mode != "direct") {
            native_level.outbounds = append_unique_tags(included_group_tags(
                connections.fallback_level_include_groups(group_id, level.id), group_tags_by_name, item.tag
            ), level.outbounds);
            if (length(providers) > 0)
                native_level.providers = providers;
            merge_object(native_level, fallback_level_provider_filter(group_id, level.id));
        }

        push(outbound.groups, native_level);
    }

    outbound.url = connections.fallback_group_health_check_url(section, group_id);
    outbound.interval = connections.fallback_group_health_check_interval(section, group_id);
    outbound.timeout = connections.fallback_group_health_check_timeout(section, group_id);
    outbound.attempt_timeout = connections.fallback_group_attempt_timeout(section, group_id);
    outbound.expected_status = connections.fallback_group_expected_status(section, group_id);
    outbound.idle_timeout = connections.fallback_group_idle_timeout(section, group_id);
    outbound.interrupt_exist_connections = connections.fallback_group_interrupt_exist_connections(section, group_id);

    return outbound;
}

function add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, provider_refs) {
    let section_name = section[".name"];
    let selector_tag = outbound_tag(section_name);
    let selector_outbounds = [];
    let selector_default = selector_tags[0];
    let urltest_tags = [];
    let fallback_tags = [];
    let candidate_types = candidate_outbound_types(config);
    let items = section_group_items(section);
    let group_tags_by_name = allocate_group_tags(section, items);
    let group_tags = {};
    for (let item in items)
        group_tags[item.tag] = true;

    let descriptors = [];
    for (let item in items) {
        let outbound = item.kind == "urltest"
            ? build_urltest_outbound(section, item, urltest_candidate_tags, candidate_types, provider_refs)
            : build_fallback_group_outbound(section, item, urltest_candidate_tags, candidate_types, group_tags_by_name, provider_refs);
        push(descriptors, { kind: item.kind, tag: item.tag, outbound });
    }

    let groups = usable_group_descriptors(descriptors, group_tags);
    for (let descriptor in groups) {
        push(config.outbounds, descriptor.outbound);
        push(descriptor.kind == "urltest" ? urltest_tags : fallback_tags, descriptor.tag);
    }

    for (let tag in urltest_tags)
        push(selector_outbounds, tag);
    for (let tag in fallback_tags)
        push(selector_outbounds, tag);
    for (let tag in selector_tags)
        push(selector_outbounds, tag);

    let group_default = default_group_tag(groups);
    if (group_default != null)
        selector_default = group_default;

    let selector = {
        type: "selector",
        tag: selector_tag,
        outbounds: selector_outbounds,
        interrupt_exist_connections: true
    };
    let providers = provider_tags(provider_refs);
    if (length(providers) > 0)
        selector.providers = providers;
    if (selector_default != null && as_string(selector_default) != "")
        selector.default = selector_default;
    push(config.outbounds, selector);
}

function add_service_mixed_proxy_inbound(config, tag_name, listen_port, outbound) {
    push(config.inbounds, {
        type: "mixed",
        tag: tag_name,
        listen: runtime_constants.SERVICE_MIXED_INBOUND_ADDRESS,
        listen_port
    });
    push(config.route.rules, {
        action: "route",
        inbound: tag_name,
        outbound
    });
}

function first_outbound_section(sections) {
    for (let section in sections) {
        if (connections.is_connections_action(option(section, "action", "")))
            return section;
    }
    return null;
}

// For what runs outside the core and cannot name an outbound: the page's WARP profile requests.
function add_service_mixed_proxy(config, settings) {
    if (connections.download_via_proxy_enabled(settings, "warp_profiles"))
        add_service_mixed_proxy_inbound(config, runtime_constants.WARP_PROFILES_MIXED_INBOUND_TAG,
            runtime_constants.WARP_PROFILES_MIXED_INBOUND_PORT, download_detour(settings, "warp_profiles"));
}

function interface_domain_resolver_detour_tag(section, interface_name, interface_tag) {
    if (!connections.interface_domain_resolver_dns_detour_enabled(section, interface_name))
        return interface_tag;

    let target_section = connections.interface_domain_resolver_dns_detour_section(section, interface_name);
    if (target_section == "")
        runtime_generate_unsupported("interface '" + interface_name + "' routes resolver DNS through a section, but no section is selected");

    return outbound_tag(target_section);
}

function add_interface_connection_outbound(config, section, interface_index, interface_name, selector_tags, urltest_candidate_tags) {
    let section_name = section[".name"];
    let tag_name = child_outbound_tag(section, connections.interface_display_name(section, interface_name));

    let domain_resolver = "";
    if (connections.interface_domain_resolver_enabled(section, interface_name)) {
        domain_resolver = runtime_constants.domain_resolver_tag(section_name + "-interface-" + interface_index);
        let unsupported = runtime_dns.add_uri_server_group(
            config.dns.servers,
            connections.interface_domain_resolver_dns_servers(section, interface_name),
            domain_resolver,
            connections.interface_domain_resolver_dns_fallback_strategy(section, interface_name),
            interface_domain_resolver_detour_tag(section, interface_name, tag_name),
            false
        );
        if (unsupported != "")
            runtime_generate_unsupported(unsupported);
    }

    let outbound = {
        type: "direct",
        tag: tag_name,
        bind_interface: interface_name,
        domain_resolver,
        routing_mark: runtime_constants.OUTBOUND_MARK
    };
    if (domain_resolver == "")
        delete outbound.domain_resolver;

    push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    push(urltest_candidate_tags, tag_name);
}

function add_connection_interfaces(config, section, selector_tags, urltest_candidate_tags) {
    let items = connections.interfaces(section);
    for (let i = 0; i < length(items); i++)
        add_interface_connection_outbound(config, section, i + 1, items[i], selector_tags, urltest_candidate_tags);
}

function parse_outbound_json(value) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        return null;
    }

    return type(value) == "object" ? value : null;
}

function add_connection_tunnels(config, section, selector_tags, urltest_candidate_tags) {
    let items = connections.tunnel_items(section);
    let section_name = section[".name"];

    for (let i = 0; i < length(items); i++) {
        let tunnel = items[i];
        let endpoint = connections.tunnel_endpoint(tunnel);
        let endpoint_type = lc(as_string(endpoint.type || ""));
        let wrapper_kind = lc(as_string(connections.option(tunnel, "kind", "wireguard")));
        if (wrapper_kind != "json" &&
            (endpoint_type != "wireguard" && endpoint_type != "amneziawg" && endpoint_type != "warp" && endpoint_type != "tailscale" &&
                endpoint_type != "openvpn-client" && endpoint_type != "openconnect"))
            runtime_generate_unsupported("tunnel " + (i + 1) + " has an unsupported endpoint type");

        let tag_name = child_outbound_tag(section, connections.tunnel_display_name(tunnel, i + 1));
        endpoint.tag = tag_name;

        if (wrapper_kind != "json" && (endpoint_type == "wireguard" || endpoint_type == "amneziawg" || endpoint_type == "warp" ||
            endpoint_type == "openvpn-client" || endpoint_type == "openconnect")) {
            let detour = cascade_tag(tunnel);
            if (detour != "")
                endpoint.detour = detour;
        }

        // The core gives up on an OpenConnect server after five minutes of failed reconnects.
        if (wrapper_kind != "json" && endpoint_type == "openconnect" && endpoint.reconnect_timeout == null)
            endpoint.reconnect_timeout = OPENCONNECT_RECONNECT_TIMEOUT;

        if (wrapper_kind != "json" && endpoint_type == "warp" && endpoint.profile != null &&
            connections.download_via_proxy_enabled(runtime_settings(), "warp_profiles"))
            endpoint.profile.detour = download_detour(runtime_settings(), "warp_profiles");

        if (wrapper_kind != "json" && endpoint_type == "tailscale") {
            let detour_section = connections.option(tunnel, "tailscale_detour_section", "");
            if (detour_section != "")
                endpoint.detour = outbound_tag(detour_section);
            if (as_string(endpoint.state_directory || "") == "")
                endpoint.state_directory = runtime_tailscale.tunnel_state_directory(section_name, as_string(tunnel[".name"] || (i + 1)));
            if (as_string(endpoint.exit_node || "") != "")
                endpoint.exit_node_allow_lan_access = true;
        }

        push(config.endpoints, endpoint);
        push(selector_tags, tag_name);
        push(urltest_candidate_tags, tag_name);

        let dns_type = TUNNEL_DNS_SERVER_TYPES[endpoint_type];
        if (wrapper_kind != "json" && dns_type != null && bool_option(tunnel, "accept_server_dns", true))
            push(config.dns.servers, { type: dns_type, tag: tag_name, endpoint: tag_name, __tunnel: true });
    }
}

function json_outbound_reference_tag(reference, tag_map) {
    reference = as_string(reference);
    if (tag_map[reference])
        return tag_map[reference];
    if (connections.section_exists(reference))
        return outbound_tag(reference);
    return reference;
}

function rewrite_json_outbound_references(outbounds, tag_map) {
    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        for (let key in [ "detour", "default" ]) {
            let reference = as_string(outbound[key] || "");
            if (reference != "")
                outbound[key] = json_outbound_reference_tag(reference, tag_map);
        }

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag_name in outbound.outbounds) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    push(rewritten, json_outbound_reference_tag(tag_name, tag_map));
            }
            outbound.outbounds = rewritten;
        }
    }
}

function prepare_json_connection_outbounds(section) {
    let items = connections.outbound_jsons(section);
    let prepared = [];
    let outbounds = [];
    let tag_map = {};

    for (let i = 0; i < length(items); i++) {
        let outbound = parse_outbound_json(items[i]);
        if (outbound == null)
            runtime_generate_unsupported("JSON outbound is invalid");

        let display_name = connections.outbound_json_display_name(outbound, i + 1);
        let tag_name = child_outbound_tag(section, display_name);
        tag_map[display_name] = tag_name;

        outbound.tag = tag_name;
        push(outbounds, outbound);
        push(prepared, {
            outbound,
            displayName: display_name
        });
    }

    rewrite_json_outbound_references(outbounds, tag_map);
    return prepared;
}

function add_connection_json_outbounds(config, section, selector_tags, urltest_candidate_tags) {
    for (let item in prepare_json_connection_outbounds(section)) {
        let outbound = item.outbound;
        let tag_name = outbound.tag;
        push(config.outbounds, outbound);
        push(selector_tags, tag_name);
        if (urltest_leaf_candidate_outbound(outbound))
            push(urltest_candidate_tags, tag_name);
    }
}

function add_connections_outbound(config, section) {
    let selector_tags = [];
    let urltest_candidate_tags = [];
    let provider_refs = add_subscription_providers(config, section);
    add_manual_link_outbounds(config, section, selector_tags, urltest_candidate_tags);
    let interface_tags = [];
    let tunnel_tags = [];
    let json_tags = [];
    add_connection_interfaces(config, section, interface_tags, urltest_candidate_tags);
    add_connection_tunnels(config, section, tunnel_tags, urltest_candidate_tags);
    add_connection_json_outbounds(config, section, json_tags, urltest_candidate_tags);
    for (let tags in [ interface_tags, tunnel_tags, json_tags ])
        for (let tag_name in tags)
            push(selector_tags, tag_name);

    if (length(selector_tags) == 0 && length(provider_refs) == 0)
        runtime_generate_unsupported("connection section has no usable outbounds");

    add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, provider_refs);
}


function ensure_community_ruleset(config, section_name, community) {
    if (!runtime_rulesets.is_community(community))
        runtime_generate_unsupported("unknown community list " + community);

    let tag_name = runtime_rulesets.community_tag(section_name, community);
    if (!ruleset_registered(config, tag_name))
        push_remote_ruleset(config, tag_name, "binary", runtime_rulesets.community_url(community));
    return {
        tag: tag_name,
        kind: "domains"
    };
}

function add_domain_array(rule, key, values) {
    if (length(values) > 0)
        rule[key] = values;
}

function push_dns_matcher_rule(config, rule) {
    push(config.dns.rules, rule);
}

function section_has_port_matchers(section) {
    return connections.rule_ports_csv(section) != "";
}

function section_dns_server(section) {
    return option(section, "action", "") == "bypass" && !section_has_port_matchers(section)
        ? runtime_constants.DNS_SERVER_TAG
        : runtime_constants.FAKEIP_DNS_SERVER_TAG;
}

// Single-label names, the DHCP domain and reverse lookups are what the local resolver is
// authoritative for, so they stay with it.
function add_local_zone_rules(config, matchers, rewrite_ttl) {
    for (let zone in [ { domain_regex: "^[^.]+$" }, { domain_suffix: "." + local_resolver_domain() }, { query_type: [ "PTR" ] } ]) {
        let rule = copy_matchers(matchers);
        rule.action = "route";
        rule.server = runtime_constants.DNSMASQ_DNS_SERVER_TAG;
        rule.rewrite_ttl = rewrite_ttl;
        apply_matchers(rule, zone);
        push_dns_matcher_rule(config, rule);
    }
}

// Every query the matchers take goes to the server, except the local zone: a catch-all leaves
// local names alone as the capture leaves local addresses.
function add_device_dns_rules(config, matchers, server, rewrite_ttl) {
    if (server != runtime_constants.DNSMASQ_DNS_SERVER_TAG)
        add_local_zone_rules(config, matchers, rewrite_ttl);
    let rule = copy_matchers(matchers);
    rule.action = "route";
    rule.server = server;
    rule.rewrite_ttl = rewrite_ttl;
    push_dns_matcher_rule(config, rule);
}

function add_section_dns_matcher_rule(config, section, matchers, rewrite_ttl) {
    for (let device_matchers in device_matcher_variants(section, "source_ip_cidr", true)) {
        let rule = copy_matchers(matchers);
        apply_matchers(rule, device_matchers);
        rule.action = "route";
        rule.server = section_dns_server(section);
        if (rule.server == runtime_constants.FAKEIP_DNS_SERVER_TAG)
            rule.query_type = FAKEIP_QUERY_TYPES;
        // A query has no destination address or port, so only the domains of a set can match it;
        // the core refuses a set of subnets alone in a DNS rule that reads the whole set.
        if (rule.rule_set != null)
            rule.rule_set_domain_only = true;
        rule.rewrite_ttl = rewrite_ttl;
        push_dns_matcher_rule(config, rule);
    }
}

// The local resolver is whoever owns loopback port 53: dnsmasq, or AdGuard Home in front of
// it. sing-box marks its own socket, so this query is not captured again.
function add_source_aware_dns_support(config) {
    push(config.dns.servers, {
        type: "udp",
        tag: runtime_constants.DNSMASQ_DNS_SERVER_TAG,
        server: "127.0.0.1",
        server_port: 53
    });
}

function static_hosts_config() {
    let hosts = runtime_dns.static_hosts(runtime_settings());
    if (hosts.unsupported)
        runtime_generate_unsupported(hosts.unsupported);
    return hosts;
}

// Static records answer before sing-box dials the destination, so direct sections reach
// names the configured DNS servers cannot resolve.
function add_static_hosts_support(config, hosts) {
    if (length(hosts.domains) == 0)
        return;

    push(config.dns.servers, {
        type: "hosts",
        tag: runtime_constants.HOSTS_DNS_SERVER_TAG,
        predefined: hosts.predefined
    });
    push(config.route.rules, {
        action: "resolve",
        server: runtime_constants.HOSTS_DNS_SERVER_TAG,
        domain: hosts.domains
    });
}

function add_static_hosts_dns_rule(config, hosts) {
    if (length(hosts.domains) == 0)
        return;

    push_dns_matcher_rule(config, {
        action: "route",
        server: runtime_constants.HOSTS_DNS_SERVER_TAG,
        domain: hosts.domains,
        rewrite_ttl: int_option(runtime_settings(), "dns_rewrite_ttl", "60")
    });
}

// Unmatched queries take the Forkop DNS, or the local resolver when configured so. The
// resolver's own upstream queries are never captured, so this cannot loop.
function add_source_aware_dns_fallback(config) {
    let rewrite_ttl = int_option(runtime_settings(), "dns_rewrite_ttl", "60");
    add_device_dns_rules(config, { inbound: captured_dns_inbound_matcher() }, unmatched_dns_server_tag(), rewrite_ttl);
}

// The names a tunnel's server declares resolve through that server when the tunnel dials
// them: the endpoint's lookups pass every captured-query rule, a device's stop before this.
function add_tunnel_dns_rules(config) {
    for (let server in config.dns.servers)
        if (server.__tunnel)
            push_dns_matcher_rule(config, { preferred_by: server.tag, action: "route", server: server.tag });
}

function dns_action_server_tag(section_name) {
    return runtime_constants.tag(section_name, "dns-server");
}

function dns_action_detour_tag(section) {
    if (!bool_option(section, "dns_detour_enabled", false))
        return "";
    let target_section = option(section, "dns_detour_section", "");
    return target_section == "" ? "" : outbound_tag(target_section);
}

function add_dns_server_for_section(config, section) {
    let unsupported = runtime_dns.add_uri_server_group(
        config.dns.servers,
        runtime_dns.server_list(section, "dns_server", ""),
        dns_action_server_tag(section[".name"]),
        option(section, "dns_fallback_strategy", "parallel"),
        dns_action_detour_tag(section),
        false
    );
    if (unsupported != "")
        runtime_generate_unsupported(unsupported);
}

function add_dns_action_rules_for_section(config, section) {
    let destinations = connections.destinations(section);
    let domain = destinations.domain;
    let domain_suffix = destinations.domain_suffix;
    let domain_keyword = destinations.domain_keyword;
    let domain_regex = destinations.domain_regex;
    let rule_set_tags = [];
    let section_name = section[".name"];
    let fully_routed_devices = connections.device_matchers(section, "fully_routed_ips");

    for (let community in connections.community_lists(section)) {
        let ensured = ensure_community_ruleset(config, section_name, as_string(community));
        push(rule_set_tags, ensured.tag);
    }
    for (let reference in connections.rule_sets(section)) {
        push(rule_set_tags, ensure_custom_ruleset(config, as_string(reference)));
    }

    let rewrite_ttl = int_option(runtime_settings(), "dns_rewrite_ttl", "60");
    let server_tag = dns_action_server_tag(section_name);
    let has_inline_domains = length(domain) > 0 || length(domain_suffix) > 0 ||
        length(domain_keyword) > 0 || length(domain_regex) > 0;

    if (fully_routed_devices.selected)
        for (let device_matchers in device_matcher_variants(section, "fully_routed_ips", true))
            add_device_dns_rules(config, device_matchers, server_tag, rewrite_ttl);
    if (has_inline_domains) {
        for (let device_matchers in device_matcher_variants(section, "source_ip_cidr", true)) {
            let dns_rule = {
                action: "route",
                server: server_tag,
                rewrite_ttl
            };
            add_domain_array(dns_rule, "domain", domain);
            add_domain_array(dns_rule, "domain_suffix", domain_suffix);
            add_domain_array(dns_rule, "domain_keyword", domain_keyword);
            add_domain_array(dns_rule, "domain_regex", domain_regex);
            apply_matchers(dns_rule, device_matchers);
            push_dns_matcher_rule(config, dns_rule);
        }
    }
    if (length(rule_set_tags) > 0) {
        for (let device_matchers in device_matcher_variants(section, "source_ip_cidr", true)) {
            let dns_rule = {
                action: "route",
                server: server_tag,
                rewrite_ttl,
                rule_set: single_or_array(rule_set_tags),
                // A DNS query has no destination address or port, so only the domain half of a rule set
                // can match it.
                rule_set_domain_only: true
            };
            apply_matchers(dns_rule, device_matchers);
            push_dns_matcher_rule(config, dns_rule);
        }
    }
    if (!has_inline_domains && length(rule_set_tags) == 0 && !fully_routed_devices.selected)
        runtime_generate_unsupported("DNS action '" + section_name + "' has no domain matchers");
}

function add_port_matchers(rule, section) {
    let ports = [];
    let port_ranges = [];
    for (let value in split(connections.rule_ports_csv(section), ",")) {
        let dash = index(value, "-");
        if (value == "")
            continue;
        if (dash < 0)
            push(ports, int(value));
        else
            push(port_ranges, substr(value, 0, dash) + ":" + substr(value, dash + 1));
    }

    if (length(ports) > 0)
        rule.port = ports;
    if (length(port_ranges) > 0)
        rule.port_range = port_ranges;
}

function add_fully_routed_ips_rules(config, section) {
    let devices = connections.device_matchers(section, "fully_routed_ips");
    if (!devices.selected)
        return;

    if (option(section, "action", "") == "bypass")
        for (let dns_matchers in device_matcher_variants(section, "fully_routed_ips", true))
            add_device_dns_rules(config, dns_matchers, unmatched_dns_server_tag(), int_option(runtime_settings(), "dns_rewrite_ttl", "60"));

    let target = runtime_route.target(section, outbound_tag(section[".name"]));
    if (target.unsupported)
        runtime_generate_unsupported(target.unsupported);

    for (let device_matchers in device_matcher_variants(section, "fully_routed_ips", false)) {
        let route_rule = { action: target.action };
        if (target.outbound)
            route_rule.outbound = target.outbound;
        apply_matchers(route_rule, device_matchers);
        push(config.route.rules, route_rule);
    }
}

// sing-box hands a rule-set branch's matches back to the rule including it, so ports and
// source addresses inside a branch would widen the section; they go to a separate AND branch.
const RULE_SET_CONSTRAINT_KEYS = [ "port", "port_range", "source_ip_cidr" ];

function constrain_rule_set_by_section(route_rule, target) {
    if (route_rule.rule_set == null)
        return route_rule;

    let constraint = {};
    let constrained = false;
    for (let key in RULE_SET_CONSTRAINT_KEYS) {
        if (route_rule[key] == null)
            continue;
        constraint[key] = route_rule[key];
        constrained = true;
    }
    if (!constrained)
        return route_rule;

    let identity_rule = copy_matchers(route_rule);
    delete identity_rule.action;
    delete identity_rule.outbound;
    for (let key in RULE_SET_CONSTRAINT_KEYS)
        delete identity_rule[key];

    let result = {
        type: "logical",
        mode: "and",
        rules: [ identity_rule, constraint ],
        action: target.action
    };
    if (target.outbound)
        result.outbound = target.outbound;
    return result;
}

function add_combined_route_for_section(config, section) {
    let destinations = connections.destinations(section);
    let domain = destinations.domain;
    let domain_suffix = destinations.domain_suffix;
    let domain_keyword = destinations.domain_keyword;
    let domain_regex = destinations.domain_regex;
    let ip_cidr = destinations.ip_cidr;
    let rule_set_tags = [];
    let section_name = section[".name"];

    add_fully_routed_ips_rules(config, section);

    for (let community in connections.community_lists(section))
        push(rule_set_tags, ensure_community_ruleset(config, section_name, as_string(community)).tag);
    for (let reference in connections.rule_sets(section))
        push(rule_set_tags, ensure_custom_ruleset(config, as_string(reference)));
    for (let reference in connections.rule_sets_with_subnets(section))
        push(rule_set_tags, ensure_custom_ruleset(config, as_string(reference)));

    let target = runtime_route.target(section, outbound_tag(section_name));
    if (target.unsupported)
        runtime_generate_unsupported(target.unsupported);
    let base_rule = { action: target.action };
    if (target.outbound)
        base_rule.outbound = target.outbound;
    add_port_matchers(base_rule, section);

    // sing-box ANDs a rule set of more than one rule with the domains of the rule naming it.
    let route_rules = [];
    if (length(domain) > 0 || length(domain_suffix) > 0 || length(domain_keyword) > 0 ||
        length(domain_regex) > 0 || length(ip_cidr) > 0) {
        let destination_rule = copy_matchers(base_rule);
        add_domain_array(destination_rule, "domain", domain);
        add_domain_array(destination_rule, "domain_suffix", domain_suffix);
        add_domain_array(destination_rule, "domain_keyword", domain_keyword);
        add_domain_array(destination_rule, "domain_regex", domain_regex);
        if (length(ip_cidr) > 0)
            destination_rule.ip_cidr = ip_cidr;
        push(route_rules, destination_rule);
    }
    if (length(rule_set_tags) > 0)
        push(route_rules, { ...base_rule, rule_set: single_or_array(rule_set_tags) });
    if (length(route_rules) == 0 && (base_rule.port != null || base_rule.port_range != null))
        push(route_rules, base_rule);

    for (let route_rule in route_rules)
        for (let device_matchers in device_matcher_variants(section, "source_ip_cidr", false)) {
            let device_route_rule = copy_matchers(route_rule);
            apply_matchers(device_route_rule, device_matchers);
            push(config.route.rules, constrain_rule_set_by_section(device_route_rule, target));
        }

    let rewrite_ttl = int_option(runtime_settings(), "dns_rewrite_ttl", "60");
    if (length(domain) > 0 || length(domain_suffix) > 0 || length(domain_keyword) > 0 || length(domain_regex) > 0) {
        let dns_rule = {};
        add_domain_array(dns_rule, "domain", domain);
        add_domain_array(dns_rule, "domain_suffix", domain_suffix);
        add_domain_array(dns_rule, "domain_keyword", domain_keyword);
        add_domain_array(dns_rule, "domain_regex", domain_regex);
        add_section_dns_matcher_rule(config, section, dns_rule, rewrite_ttl);
    }
    if (length(rule_set_tags) > 0) {
        add_section_dns_matcher_rule(config, section, {
            rule_set: single_or_array(rule_set_tags)
        }, rewrite_ttl);
    }
}

function add_outbound_for_section(config, section) {
    let action = option(section, "action", "");
    let section_name = section[".name"];

    if (connections.is_connections_action(action))
        add_connections_outbound(config, section);
    else if (action == "bypass") {
        /* route-only action */
    }
    else if (action == "block") {
        /* route-only action */
    }
    else if (action == "dns") {
        add_dns_server_for_section(config, section);
    }
    else {
        runtime_generate_unsupported("unsupported action " + action);
    }
}

function add_route_for_section(config, section) {
    if (option(section, "action", "") == "dns")
        add_dns_action_rules_for_section(config, section);
    else
        add_combined_route_for_section(config, section);
}

function add_service_route_rules(config, sections) {
    let first = first_outbound_section(sections);
    if (first != null) {
        push(config.route.rules, {
            action: "route",
            inbound: tproxy_inbound_matcher(),
            outbound: outbound_tag(first[".name"]),
            domain: runtime_constants.CHECK_PROXY_IP_DOMAIN
        });
    }
    // The check service answers on 8443 that a request came through Forkop. Diagnostics shows
    // the router's address there as the direct one, so no section may take the request.
    push(config.route.rules, {
        action: "route",
        outbound: runtime_constants.DIRECT_OUTBOUND_TAG,
        domain: runtime_constants.FAKEIP_TEST_DOMAIN,
        override_port: 8443
    });
}

function enabled_sections() {
    let result = [];
    for (let section in uci_core.section_objects(CONFIG_NAME, "section"))
        if (section_enabled(section))
            push(result, section);
    return result;
}

function runtime_sections(sections) {
    let result = [];
    for (let section in sections)
        if (!connections.is_connections_action(option(section, "action", "")) || connections.has_connection_sources(section))
            push(result, section);
    return result;
}

function enabled_servers() {
    let result = [];
    for (let section in uci_core.section_objects(CONFIG_NAME, "server"))
        if (server_enabled(section))
            push(result, section);
    return result;
}

// Whether the configuration gives sing-box a section or a server to run.
function runnable() {
    connections.load();
    return length(runtime_sections(enabled_sections())) > 0 || length(enabled_servers()) > 0;
}

function section_by_name(sections, name) {
    name = as_string(name);
    for (let section in sections)
        if (as_string(section[".name"]) == name)
            return section;
    return null;
}

// "rules" clones the shared set onto the inbound and is handled by the caller.
function server_route_rule(sections, routing_mode, routing_section_name, label) {
    if (routing_mode == "direct")
        return { action: "route", outbound: runtime_constants.DIRECT_OUTBOUND_TAG };

    if (routing_mode != "section")
        runtime_generate_unsupported("unsupported " + label + " routing_mode " + routing_mode);

    let routing_section = section_by_name(sections, routing_section_name);
    if (routing_section == null)
        runtime_generate_unsupported(label + " references missing routing section " + routing_section_name);
    let action = option(routing_section, "action", "");
    if (action == "bypass" || action == "block")
        runtime_generate_unsupported(label + " routing section " + routing_section_name + " cannot use action " + action);
    let target = runtime_route.target(routing_section, outbound_tag(routing_section[".name"]));
    if (target.unsupported)
        runtime_generate_unsupported(target.unsupported);

    let rule = { action: target.action };
    if (target.outbound)
        rule.outbound = target.outbound;
    return rule;
}

// Accounts with a route of their own. An account that follows the shared rules gets them
// cloned only when its server does not clone them already.
function add_server_client_routes(config, server, sections, inbound, server_mode) {
    for (let client in connections.server_clients(server)) {
        if (!bool_option(client, "routing_override", false))
            continue;

        let identity = runtime_servers.client_match(server, client);
        if (identity == null)
            continue;

        let client_mode = option(client, "routing_mode", "direct");
        if (client_mode == "rules") {
            if (server_mode != "rules")
                runtime_servers.clone_rules_for_inbound(
                    config,
                    runtime_constants.TPROXY_INBOUND_TAG,
                    inbound,
                    runtime_constants.CHECK_PROXY_IP_DOMAIN,
                    identity
                );
            continue;
        }

        let rule = server_route_rule(
            sections,
            client_mode,
            option(client, "routing_section", ""),
            "server client '" + option(client, "name", client[".name"]) + "'"
        );
        rule.inbound = inbound;
        for (let key, value in identity)
            rule[key] = value;
        push(config.route.rules, rule);
    }
}

function add_server_routes(config, servers, sections) {
    for (let server in servers) {
        runtime_servers.add_sniff_rule(config, server);

        let inbound = runtime_constants.server_inbound_tag(connections.server_display_name(server));
        let routing_mode = option(server, "routing_mode", "rules");
        add_server_client_routes(config, server, sections, inbound, routing_mode);
        if (routing_mode == "rules") {
            runtime_servers.clone_rules_for_inbound(
                config,
                runtime_constants.TPROXY_INBOUND_TAG,
                inbound,
                runtime_constants.CHECK_PROXY_IP_DOMAIN
            );
        }
        else {
            let rule = server_route_rule(
                sections,
                routing_mode,
                option(server, "routing_section", ""),
                "server"
            );
            rule.inbound = inbound;
            push(config.route.rules, rule);
        }
    }
}

// Throws with the reason when the configuration cannot be expressed.
// context: { service_address }
function build(context) {
    context = object_or_empty(context);
    connections.load();
    runtime_settings_cache = null;
    let settings = runtime_settings();

    let sections = runtime_sections(enabled_sections());
    let servers = enabled_servers();
    if (length(sections) == 0 && length(servers) == 0)
        runtime_generate_unsupported("no usable sections or servers");

    let config = base_config(settings, context.service_address);
    add_source_aware_dns_support(config);
    let static_hosts = static_hosts_config();
    add_static_hosts_support(config, static_hosts);
    for (let server in servers)
        runtime_servers.add_server(config, server);
    for (let section in sections)
        add_outbound_for_section(config, section);
    add_service_route_rules(config, sections);
    for (let section in sections)
        add_route_for_section(config, section);
    add_static_hosts_dns_rule(config, static_hosts);
    add_source_aware_dns_fallback(config);
    add_tunnel_dns_rules(config);
    add_server_routes(config, servers, sections);
    add_service_mixed_proxy(config, settings);

    assert_unique_outbound_tags(config);
    assert_compatible_wireguard_endpoints(config);
    return strip_internal_fields(config);
}

return { build, runnable };
