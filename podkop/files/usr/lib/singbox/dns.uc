#!/usr/bin/env ucode

let common = require("core.common");
let core_ip = require("core.ip");
let runtime_constants = require("singbox.constants");
let runtime_url = require("core.url");

let as_string = common.as_string;
let bool_option = common.bool_option;
let list_option = common.list_option;
let object_or_empty = common.object_or_empty;
let option = common.option;
let read_json_file = common.read_json_file;

const DNS_FAILOVER_STATE_FILE = getenv("PODKOP_DNS_FAILOVER_STATE_FILE") || "/var/run/podkop-plus/dns-failover.json";
const DNS_HEALTH_ADDRESS = getenv("PODKOP_DNS_HEALTH_ADDRESS") || "127.0.0.42";
const DNS_HEALTH_PORT_BASE = int(getenv("PODKOP_DNS_HEALTH_PORT_BASE") || "10053");

function server_list(settings, key, fallback) {
    let result = [];
    for (let value in list_option(settings, key)) {
        value = trim(as_string(value));
        if (value != "")
            push(result, value);
    }
    if (length(result) == 0)
        push(result, fallback);
    return result;
}

function arrays_equal(left, right) {
    if (length(left || []) != length(right || []))
        return false;
    for (let i = 0; i < length(left); i++)
        if (as_string(left[i]) != as_string(right[i]))
            return false;
    return true;
}

function detour_tag(settings) {
    if (!bool_option(settings, "dns_detour_enabled", false))
        return "";
    let section_name = option(settings, "dns_detour_section", "");
    return section_name == "" ? "" : runtime_constants.outbound_tag(section_name);
}

function state_template(settings) {
    return {
        version: 1,
        dns_type: option(settings, "dns_type", "udp"),
        dns_detour: detour_tag(settings),
        main_servers: server_list(settings, "dns_server", "77.88.8.8"),
        bootstrap_servers: server_list(settings, "bootstrap_dns_server", "77.88.8.8"),
        main_index: 0,
        bootstrap_index: 0
    };
}

function state_matches(template, state) {
    state = object_or_empty(state);
    return int(state.version || 0) == 1 &&
        as_string(state.dns_type) == template.dns_type &&
        as_string(state.dns_detour) == template.dns_detour &&
        arrays_equal(state.main_servers, template.main_servers) &&
        arrays_equal(state.bootstrap_servers, template.bootstrap_servers);
}

function bounded_index(value, values) {
    let index_value = int(value || 0);
    return index_value >= 0 && index_value < length(values) ? index_value : 0;
}

function normalize_state(settings, state) {
    let result = state_template(settings);
    if (!state_matches(result, state))
        return result;

    result.main_index = bounded_index(object_or_empty(state).main_index, result.main_servers);
    result.bootstrap_index = bounded_index(object_or_empty(state).bootstrap_index, result.bootstrap_servers);
    return result;
}

function runtime_state(settings, override_state) {
    let state = override_state;
    if (state == null)
        state = read_json_file(DNS_FAILOVER_STATE_FILE);
    return normalize_state(settings, state);
}

function active_values(settings, override_state) {
    let state = runtime_state(settings, override_state);
    return {
        state,
        main: state.main_servers[state.main_index],
        bootstrap: state.bootstrap_servers[state.bootstrap_index]
    };
}

function server_from_options(tag_name, dns_type, dns_server, detour) {
    let server = runtime_url.host(dns_server);
    let port = runtime_url.port(dns_server);
    let result = {
        type: "udp",
        tag: tag_name,
        server,
        server_port: 53
    };

    if (dns_type == "udp") {
        if (port != "")
            result.server_port = int(port, 10);
    }
    else if (dns_type == "dot") {
        result.type = "tls";
        result.server_port = port != "" ? int(port, 10) : 853;
    }
    else if (dns_type == "doh") {
        result.type = "https";
        result.server_port = port != "" ? int(port, 10) : 443;
        let path = runtime_url.path(dns_server);
        if (path != "")
            result.path = path;
    }
    else {
        return { unsupported: "unsupported dns_type " + dns_type };
    }

    if (!core_ip.valid_ip(server))
        result.domain_resolver = runtime_constants.BOOTSTRAP_DNS_SERVER_TAG;
    if (as_string(detour) != "")
        result.detour = as_string(detour);

    return result;
}

function bootstrap_server(tag_name, value) {
    let server = runtime_url.host(value);
    let port = runtime_url.port(value);
    return {
        type: "udp",
        tag: tag_name,
        server: server != "" ? server : value,
        server_port: port != "" ? int(port, 10) : 53
    };
}

function server_config(settings, override_state) {
    let active = active_values(settings, override_state);
    return server_from_options(
        runtime_constants.DNS_SERVER_TAG,
        active.state.dns_type,
        active.main,
        active.state.dns_detour
    );
}

function bootstrap_config(settings, override_state) {
    let active = active_values(settings, override_state);
    return bootstrap_server(runtime_constants.BOOTSTRAP_DNS_SERVER_TAG, active.bootstrap);
}

function failover_enabled(settings) {
    let state = state_template(settings);
    return length(state.main_servers) > 1 || length(state.bootstrap_servers) > 1;
}

function health_tag(kind, index_value, suffix) {
    return "dns-health-" + as_string(kind) + "-" + as_string(index_value + 1) + "-" + as_string(suffix);
}

function health_port(kind, index_value) {
    if (kind == "active")
        return DNS_HEALTH_PORT_BASE + 2000;
    return DNS_HEALTH_PORT_BASE + int(index_value) * 2 + (kind == "bootstrap" ? 1 : 0);
}

function add_active_health_inbound(result) {
    let inbound_tag = "dns-health-active-main-in";
    push(result.inbounds, {
        type: "direct",
        tag: inbound_tag,
        listen: DNS_HEALTH_ADDRESS,
        listen_port: health_port("active", 0)
    });
    push(result.rules, {
        action: "route",
        inbound: inbound_tag,
        server: runtime_constants.DNS_SERVER_TAG,
        disable_cache: true
    });
    push(result.sniff_inbounds, inbound_tag);
}

function add_health_candidate(result, kind, index_value, server) {
    let server_tag = health_tag(kind, index_value, "server");
    let inbound_tag = health_tag(kind, index_value, "in");
    let dns_server = kind == "main"
        ? server_from_options(server_tag, result.state.dns_type, server, result.state.dns_detour)
        : bootstrap_server(server_tag, server);

    if (dns_server.unsupported) {
        result.unsupported = dns_server.unsupported;
        return;
    }

    push(result.servers, dns_server);
    push(result.inbounds, {
        type: "direct",
        tag: inbound_tag,
        listen: DNS_HEALTH_ADDRESS,
        listen_port: health_port(kind, index_value)
    });
    push(result.rules, {
        action: "route",
        inbound: inbound_tag,
        server: server_tag,
        disable_cache: true
    });
    push(result.sniff_inbounds, inbound_tag);
}

function config(settings, override_state) {
    let state = runtime_state(settings, override_state);
    let main = server_config(settings, state);
    if (main.unsupported)
        return { unsupported: main.unsupported };

    let result = {
        state,
        servers: [ bootstrap_config(settings, state), main ],
        inbounds: [],
        rules: [],
        sniff_inbounds: []
    };

    if (length(state.main_servers) > 1 || length(state.bootstrap_servers) > 1)
        add_active_health_inbound(result);

    if (length(state.main_servers) > 1)
        for (let i = 0; i < length(state.main_servers); i++)
            add_health_candidate(result, "main", i, state.main_servers[i]);

    if (length(state.bootstrap_servers) > 1)
        for (let i = 0; i < length(state.bootstrap_servers); i++)
            add_health_candidate(result, "bootstrap", i, state.bootstrap_servers[i]);

    return result;
}

function default_domain_resolver(settings) {
    return bool_option(settings, "dns_detour_enabled", false)
        ? runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
        : runtime_constants.DNS_SERVER_TAG;
}

return {
    DNS_FAILOVER_STATE_FILE,
    DNS_HEALTH_ADDRESS,
    active_values,
    arrays_equal,
    bootstrap_config,
    config,
    default_domain_resolver,
    detour_tag,
    failover_enabled,
    health_port,
    normalize_state,
    runtime_state,
    server_config,
    server_from_options,
    server_list,
    state_matches,
    state_template
};
