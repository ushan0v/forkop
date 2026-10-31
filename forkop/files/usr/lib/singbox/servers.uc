#!/usr/bin/env ucode

let common = require("core.common");
let runtime_constants = require("singbox.constants");
let connections = require("config.connections");
let amnezia = require("singbox.amnezia");
let tailscale = require("singbox.tailscale");

let as_string = common.as_string;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let int_option = common.int_option;
let array_or_empty = common.array_or_empty;

// Shared by the generator, the runtime validator and the service preparation. An OpenVPN
// client is its certificate and a WireGuard client its keys and addresses, all router-issued.
const CLIENT_FIELDS = {
    vless: [ "uuid" ],
    vmess: [ "uuid" ],
    trojan: [ "password" ],
    shadowsocks: [ "password" ],
    hysteria2: [ "password" ],
    tuic: [ "uuid", "password" ],
    anytls: [ "password" ],
    mixed: [ "password" ],
    naive: [ "password" ],
    mieru: [ "password" ],
    trusttunnel: [ "password" ],
    openvpn: [ "openvpn_certificate", "openvpn_key", "openvpn_certificate_sha256" ],
    wireguard: [ "wireguard_private_key", "wireguard_public_key", "wireguard_pre_shared_key", "wireguard_address" ],
    amneziawg: [ "wireguard_private_key", "wireguard_public_key", "wireguard_pre_shared_key", "wireguard_address" ],
    tailscale: [],
    json_inbound: []
};
const LOGIN_NAME_PROTOCOLS = { mixed: true, naive: true, mieru: true, trusttunnel: true };
// The option holding the transports of a protocol that offers a choice, and its default.
const NETWORK_OPTIONS = {
    naive: [ "naive_network", "tcp" ],
    trusttunnel: [ "trusttunnel_network", "tcp" ],
    mieru: [ "mieru_transport", "TCP" ],
    openvpn: [ "openvpn_network", "udp" ]
};
const ENDPOINT_TYPES = { tailscale: "tailscale", openvpn: "openvpn-server", wireguard: "wireguard", amneziawg: "amneziawg" };
// Every parameter but the signature packets, which only an initiator sends.
const AMNEZIA_SERVER_KEYS = filter(amnezia.KEYS, (key) => match(key, /^i[1-5]$/) == null);
// OpenVPN's own "keepalive 10 120": the server waits twice the client's timeout, so a client
// that comes back finds its address still there.
const OPENVPN_PING_INTERVAL = "10s";
const OPENVPN_CLIENT_PING_RESTART = "120s";
const OPENVPN_SERVER_PING_RESTART = "240s";
// The 2022 methods a server with clients can serve: a client's key of its own rides in an identity
// header, which SIP022 defines for AES only.
const SHADOWSOCKS_2022_KEY_BYTES = {
    "2022-blake3-aes-128-gcm": 16,
    "2022-blake3-aes-256-gcm": 32
};

function shadowsocks_2022_method(method) {
    return SHADOWSOCKS_2022_KEY_BYTES[as_string(method)] != null;
}

function safe_filename(value) {
    value = as_string(value);
    let result = "";
    for (let i = 0; i < length(value); i++) {
        let ch = substr(value, i, 1);
        result += match(ch, /^[A-Za-z0-9_.-]$/) ? ch : "_";
    }
    return result;
}

function client_user(protocol, client) {
    let name = option(client, "name", client[".name"]);
    if (name == "")
        name = client[".name"];

    if (protocol == "vless") {
        let user = { name, uuid: option(client, "uuid", "") };
        let flow = option(client, "flow", "");
        if (flow != "" && flow != "none")
            user.flow = flow;
        return user;
    }
    if (protocol == "vmess")
        return { name, uuid: option(client, "uuid", ""), alterId: 0 };
    if (protocol == "trojan" || protocol == "hysteria2" || protocol == "anytls" ||
        protocol == "mieru" || protocol == "shadowsocks")
        // Each account carries only its own key; the server key joins it in the link, not here.
        return { name, password: option(client, "password", "") };
    if (protocol == "mixed" || protocol == "naive" || protocol == "trusttunnel")
        return { username: name, password: option(client, "password", "") };
    if (protocol == "tuic")
        return { name, uuid: option(client, "uuid", ""), password: option(client, "password", "") };
    return null;
}

function users(section, protocol) {
    let result = [];
    for (let client in connections.server_clients(section)) {
        let user = client_user(protocol, client);
        if (user != null)
            push(result, user);
    }
    return result;
}

function effective_security(section, protocol) {
    let security = option(section, "security", "");
    if (security == "")
        security = protocol == "vless" ? "reality" : "none";

    if (protocol == "shadowsocks" || protocol == "mixed" || protocol == "mieru" ||
        ENDPOINT_TYPES[protocol] != null || protocol == "json_inbound")
        return "none";
    // No client format carries Trojan without TLS.
    if (protocol == "hysteria2" || protocol == "naive" || protocol == "anytls" || protocol == "tuic" ||
        protocol == "trojan" || protocol == "trusttunnel")
        return "tls";
    if (protocol == "vmess" && security == "reality")
        return "none";
    return security;
}

// A NaiveProxy client checks the certificate like a browser and cannot accept an untrusted one.
function certificate_source(section, protocol) {
    return protocol == "naive" || option(section, "tls_certificate_source", "") == "custom" ? "custom" : "self_signed";
}

function certificate_material(section, protocol) {
    return certificate_source(section, protocol) == "custom"
        ? { certificate: option(section, "tls_certificate", ""), key: option(section, "tls_key", "") }
        : { certificate: option(section, "tls_self_signed_certificate", ""), key: option(section, "tls_self_signed_key", "") };
}

function is_router_path(value) {
    return match(trim(as_string(value)), /^\/[^\n]*$/) != null;
}

function maybe_string(object, key, value) {
    value = as_string(value);
    if (value != "")
        object[key] = value;
}

function pem_lines(value) {
    return filter(map(split(as_string(value), "\n"), (line) => rtrim(line, "\r")), (line) => line != "");
}

// sing-box reloads a certificate file when it changes, so one renewed on the router (acme.sh)
// is picked up without an apply.
function apply_material(tls, field, value) {
    value = trim(as_string(value));
    if (value == "")
        return;
    if (is_router_path(value))
        tls[field + "_path"] = value;
    else
        tls[field] = pem_lines(value);
}

function apply_tls(inbound, section, protocol) {
    let security = effective_security(section, protocol);
    if (security == "" || security == "none")
        return;

    let tls = { enabled: true };
    maybe_string(tls, "server_name", option(section, "tls_server_name", ""));
    let alpn = list_option(section, "tls_alpn");
    if (length(alpn) > 0)
        tls.alpn = alpn;

    if (security == "tls") {
        let material = certificate_material(section, protocol);
        apply_material(tls, "certificate", material.certificate);
        apply_material(tls, "key", material.key);
    }
    else if (security == "reality") {
        // The handshake target is the site the SNI names: a target answering for another name would
        // hand a prober a certificate that does not match.
        let reality = {
            enabled: true,
            handshake: {
                server: option(section, "tls_server_name", ""),
                server_port: 443
            },
            private_key: option(section, "reality_private_key", "")
        };
        let short_id = list_option(section, "reality_short_id");
        if (length(short_id) > 0)
            reality.short_id = short_id;
        tls.reality = reality;
    }

    inbound.tls = tls;
}

function apply_transport(inbound, section, protocol) {
    if (protocol != "vless" && protocol != "vmess" && protocol != "trojan")
        return;

    let transport_type = option(section, "transport", "tcp");
    if (transport_type == "" || transport_type == "tcp" || transport_type == "raw")
        return;

    let transport = { type: transport_type };
    let path = option(section, "transport_path", "");
    let host = option(section, "transport_host", "");
    if (transport_type == "ws") {
        maybe_string(transport, "path", path);
        if (host != "")
            transport.headers = { Host: host };
    }
    else if (transport_type == "grpc") {
        maybe_string(transport, "service_name", option(section, "transport_service_name", ""));
    }
    else if (transport_type == "http") {
        maybe_string(transport, "path", path);
        if (host != "")
            transport.host = [ host ];
    }
    else if (transport_type == "httpupgrade") {
        maybe_string(transport, "path", path);
        maybe_string(transport, "host", host);
    }
    else if (transport_type == "xhttp") {
        transport.mode = option(section, "transport_xhttp_mode", "auto");
        transport.path = path != "" ? path : "/";
        maybe_string(transport, "host", host);
    }
    else {
        return;
    }

    inbound.transport = transport;
}

// Accepted, never required; TCP Brutal works only when both sides load the module.
function apply_multiplex(inbound, section, protocol) {
    if (protocol != "vless" && protocol != "vmess" && protocol != "trojan" && protocol != "shadowsocks")
        return;
    if (!bool_option(section, "multiplex_enabled", false))
        return;

    let multiplex = { enabled: true };
    if (bool_option(section, "multiplex_padding", false))
        multiplex.padding = true;

    inbound.multiplex = multiplex;
}

// Two servers may share a port when one takes TCP and the other UDP.
function transports(protocol, network) {
    network = lc(as_string(network));
    if (protocol == "openvpn")
        return [ network == "tcp" ? "tcp" : "udp" ];
    if (protocol == "hysteria2" || protocol == "tuic" || protocol == "wireguard" || protocol == "amneziawg")
        return [ "udp" ];
    let http = protocol == "naive" || protocol == "trusttunnel";
    if (protocol == "shadowsocks" || (http && network == "tcp_udp"))
        return [ "tcp", "udp" ];
    if ((http || protocol == "mieru") && network == "udp")
        return [ "udp" ];
    return [ "tcp" ];
}

// sing-box serves XHTTP over HTTP/3, on UDP, when TLS other than Reality offers h3 alone.
function serves_xhttp_http3(section) {
    let protocol = option(section, "protocol", "vless");
    return (protocol == "vless" || protocol == "vmess" || protocol == "trojan") &&
        option(section, "transport", "tcp") == "xhttp" &&
        effective_security(section, protocol) == "tls" &&
        join(",", list_option(section, "tls_alpn")) == "h3";
}

function listen_transports(section) {
    if (serves_xhttp_http3(section))
        return [ "udp" ];
    let protocol = option(section, "protocol", "vless");
    let network = NETWORK_OPTIONS[protocol];
    return transports(protocol, network ? option(section, network[0], network[1]) : "");
}

function add_standard_inbound(config, section, protocol, tag_name) {
    let inbound = {
        type: protocol,
        tag: tag_name,
        listen: option(section, "listen", "::"),
        listen_port: int_option(section, "listen_port", "443")
    };

    if (protocol == "shadowsocks") {
        let method = option(section, "shadowsocks_method", "2022-blake3-aes-256-gcm");
        inbound.method = method;
        // A 2022 server needs its own pre-shared key next to the per client keys; the
        // older AEAD methods derive every key from the client password alone.
        if (shadowsocks_2022_method(method))
            inbound.password = option(section, "shadowsocks_psk", "");
        inbound.users = users(section, protocol);
    }
    else if (protocol == "mixed") {
        if (bool_option(section, "mixed_auth_enabled", true)) {
            let server_users = users(section, protocol);
            if (length(server_users) > 0)
                inbound.users = server_users;
        }
    }
    else if (protocol == "hysteria2") {
        inbound.users = users(section, protocol);
        let up_mbps = option(section, "hysteria2_up_mbps", "");
        let down_mbps = option(section, "hysteria2_down_mbps", "");
        if (up_mbps != "")
            inbound.up_mbps = int(up_mbps, 10);
        if (down_mbps != "")
            inbound.down_mbps = int(down_mbps, 10);
        let obfs_type = option(section, "hysteria2_obfs_type", "");
        let obfs_password = option(section, "hysteria2_obfs_password", "");
        if (obfs_type != "" && obfs_password != "")
            inbound.obfs = { type: obfs_type, password: obfs_password };
        maybe_string(inbound, "bbr_profile", option(section, "hysteria2_bbr_profile", ""));
        // sing-box picks the masquerade mode from the URL scheme.
        maybe_string(inbound, "masquerade", option(section, "hysteria2_masquerade", ""));
    }
    else if (protocol == "naive" || protocol == "trusttunnel") {
        inbound.users = users(section, protocol);
        let network = listen_transports(section);
        inbound.network = length(network) == 1 ? network[0] : network;
    }
    else if (protocol == "mieru") {
        inbound.users = users(section, protocol);
        inbound.transport = option(section, "mieru_transport", "TCP");
    }
    else if (protocol == "anytls") {
        inbound.users = users(section, protocol);
    }
    else if (protocol == "tuic") {
        inbound.users = users(section, protocol);
        maybe_string(inbound, "congestion_control", option(section, "tuic_congestion_control", "cubic"));
    }
    else {
        inbound.users = users(section, protocol);
    }

    apply_tls(inbound, section, protocol);
    apply_transport(inbound, section, protocol);
    apply_multiplex(inbound, section, protocol);
    push(config.inbounds, inbound);
}

function add_json_inbound(config, section, tag_name) {
    let inbound = {};
    try {
        inbound = json(option(section, "inbound_json", ""));
    }
    catch (e) {
        inbound = {};
    }
    if (type(inbound) != "object")
        inbound = {};
    inbound.tag = tag_name;
    push(config.inbounds, inbound);
}

function add_tailscale_endpoint(config, section, tag_name) {
    let section_name = section[".name"];
    let endpoint = {
        type: "tailscale",
        tag: tag_name,
        state_directory: tailscale.server_state_directory(section_name),
        auth_key: option(section, "tailscale_auth_key", ""),
        control_url: option(section, "tailscale_control_url", "https://controlplane.tailscale.com"),
        hostname: option(section, "tailscale_hostname", "forkop-" + safe_filename(section_name)),
        // Inert until approved in the Tailscale console, so a subnet-only server just stays unapproved.
        advertise_exit_node: true
    };
    if (bool_option(section, "tailscale_detour_enabled", false)) {
        let detour_section = option(section, "tailscale_detour_section", "");
        if (detour_section != "")
            endpoint.detour = runtime_constants.outbound_tag(connections.section_display_name(detour_section));
    }
    if (bool_option(section, "tailscale_ephemeral", false))
        endpoint.ephemeral = true;
    // sing-box reads each as a prefix, and the dialog takes a single address too.
    let advertise_routes = map(list_option(section, "tailscale_advertise_routes"),
        (route) => index(route, "/") >= 0 ? route : route + (index(route, ":") >= 0 ? "/128" : "/32"));
    if (length(advertise_routes) > 0)
        endpoint.advertise_routes = advertise_routes;
    push(config.endpoints, endpoint);
}

// The server trusts only the client fingerprints it issued, so removing a client revokes it.
// sing-box issues every certificate, so the check of what a client certificate was issued for
// stays off. Clients get the router's DNS on the tunnel address and, unless told otherwise,
// the default route.
function add_openvpn_endpoint(config, section, tag_name) {
    let pools = list_option(section, "tunnel_address");
    let fingerprints = [];
    for (let client in connections.server_clients(section)) {
        let fingerprint = option(client, "openvpn_certificate_sha256", "");
        if (fingerprint != "")
            push(fingerprints, fingerprint);
    }

    let push_options = {
        dns: map(pools, (pool) => split(pool, "/")[0]),
        ping_interval: OPENVPN_PING_INTERVAL,
        ping_restart: OPENVPN_CLIENT_PING_RESTART
    };
    if (bool_option(section, "tunnel_all_traffic", true)) {
        push_options.redirect_gateway = true;
        push_options.redirect_gateway_flags = length(filter(pools, (pool) => index(pool, ":") >= 0)) > 0
            ? [ "def1", "ipv6" ] : [ "def1" ];
        push_options.block_outside_dns = true;
    }
    else {
        let routes = list_option(section, "tunnel_routes");
        if (length(routes) > 0)
            push_options.routes = routes;
    }

    push(config.endpoints, {
        type: "openvpn-server",
        tag: tag_name,
        listen: option(section, "listen", "::"),
        listen_port: int_option(section, "listen_port", "1194"),
        network: option(section, "openvpn_network", "udp"),
        address: pools,
        tls: {
            certificate: pem_lines(option(section, "openvpn_certificate", "")),
            key: pem_lines(option(section, "openvpn_key", "")),
            peer_fingerprint: fingerprints,
            remote_certificate_tls: "none",
            control_wrap: { type: "tls_crypt", key: pem_lines(option(section, "openvpn_tls_crypt_key", "")) }
        },
        push: push_options,
        ping_interval: OPENVPN_PING_INTERVAL,
        ping_restart: OPENVPN_SERVER_PING_RESTART
    });
}

// A peer's tunnel addresses are the only ones it may send from, so rules tell clients apart by
// address. The endpoint's dialer binds its socket to the default route's interface, where no
// LAN client reaches it, unless it has a bind address, so it gets each family's wildcard.
function add_wireguard_endpoint(config, section, protocol, tag_name) {
    let endpoint = {
        type: protocol,
        tag: tag_name,
        address: list_option(section, "tunnel_address"),
        private_key: option(section, "wireguard_private_key", ""),
        listen_port: int_option(section, "listen_port", "51820"),
        inet4_bind_address: "0.0.0.0",
        inet6_bind_address: "::",
        peers: map(connections.server_clients(section), (client) => ({
            public_key: option(client, "wireguard_public_key", ""),
            pre_shared_key: option(client, "wireguard_pre_shared_key", ""),
            allowed_ips: list_option(client, "wireguard_address")
        }))
    };
    if (protocol == "amneziawg") {
        let parameters = amnezia.object(section, AMNEZIA_SERVER_KEYS);
        if (parameters)
            endpoint.amnezia = parameters;
    }
    push(config.endpoints, endpoint);
}

function add_server(config, section) {
    let section_name = section[".name"];
    let protocol = option(section, "protocol", "vless");
    let tag_name = runtime_constants.server_inbound_tag(connections.server_display_name(section));

    if (protocol == "tailscale")
        add_tailscale_endpoint(config, section, tag_name);
    else if (protocol == "openvpn")
        add_openvpn_endpoint(config, section, tag_name);
    else if (protocol == "wireguard" || protocol == "amneziawg")
        add_wireguard_endpoint(config, section, protocol, tag_name);
    else if (protocol == "json_inbound")
        add_json_inbound(config, section, tag_name);
    else
        add_standard_inbound(config, section, protocol, tag_name);
}

// The user the core reports (the account name; for OpenVPN the certificate's common name, its
// section) or, for WireGuard, the client's tunnel addresses. Rules match accounts on auth_user:
// sing-box drops a rule that carries a user field.
function client_match(section, client) {
    let protocol = option(section, "protocol", "vless");
    if (protocol == "wireguard" || protocol == "amneziawg") {
        let addresses = list_option(client, "wireguard_address");
        return length(addresses) > 0 ? { source_ip_cidr: addresses } : null;
    }
    let user = protocol == "openvpn" ? client[".name"] : option(client, "name", "");
    return user != "" ? { auth_user: user } : null;
}

function core_type(protocol) {
    return ENDPOINT_TYPES[protocol] ?? protocol;
}

function is_endpoint(protocol) {
    return ENDPOINT_TYPES[protocol] != null;
}

function add_sniff_rule(config, section) {
    let rules = array_or_empty(config.route.rules);
    let rule = {
        action: "sniff",
        inbound: runtime_constants.server_inbound_tag(connections.server_display_name(section))
    };
    let insert_at = 0;
    while (insert_at < length(rules) && type(rules[insert_at]) == "object" && rules[insert_at].action == "sniff")
        insert_at++;

    let result = [];
    for (let i = 0; i < insert_at; i++)
        push(result, rules[i]);
    push(result, rule);
    for (let i = insert_at; i < length(rules); i++)
        push(result, rules[i]);
    config.route.rules = result;
}

function clone(value) {
    try {
        return json(sprintf("%J", value));
    }
    catch (e) {
        return null;
    }
}

function value_contains(value, item) {
    if (type(value) == "array") {
        for (let entry in value)
            if (entry == item)
                return true;
        return false;
    }
    return value == item;
}

// Narrows the clones to one account, for a client following the shared rules when its server
// does not; a section narrowed by ports or devices becomes a logical AND with the narrowing.
function identity_rule(rule) {
    return rule.type == "logical" ? rule.rules?.[0] : rule;
}

function clone_rules_for_inbound(config, source_inbound, target_inbound, skip_domain, client) {
    let cloned_rules = [];
    for (let rule in array_or_empty(config.route.rules)) {
        if (type(rule) != "object")
            continue;
        if (rule.action != "route" && rule.action != "reject")
            continue;
        let identity = identity_rule(rule);
        if (type(identity) != "object" || !value_contains(identity.inbound, source_inbound))
            continue;
        if (skip_domain != "" && value_contains(identity.domain, skip_domain))
            continue;
        // Device filters name the router's clients, which a server's are not.
        if (length(filter(rule.type == "logical" ? rule.rules : [ rule ], (part) => part?.source_ip_cidr != null)) > 0)
            continue;

        let cloned = clone(rule);
        let cloned_identity = identity_rule(cloned);
        cloned_identity.inbound = target_inbound;
        for (let key, value in client ?? {})
            cloned_identity[key] = value;
        push(cloned_rules, cloned);
    }
    for (let cloned_rule in cloned_rules)
        push(config.route.rules, cloned_rule);
}

return {
    CLIENT_FIELDS,
    LOGIN_NAME_PROTOCOLS,
    SHADOWSOCKS_2022_KEY_BYTES,
    add_server,
    add_sniff_rule,
    clone_rules_for_inbound,
    transports,
    serves_xhttp_http3,
    listen_transports,
    client_match,
    core_type,
    is_endpoint,
    effective_security,
    certificate_source,
    certificate_material,
    is_router_path
};
