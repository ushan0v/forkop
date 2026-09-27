#!/usr/bin/env ucode

let common = require("core.common");
let runtime_constants = require("singbox.constants");

let as_string = common.as_string;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let int_option = common.int_option;
let array_or_empty = common.array_or_empty;

function safe_filename(value) {
    value = as_string(value);
    let result = "";
    for (let i = 0; i < length(value); i++) {
        let ch = substr(value, i, 1);
        result += match(ch, /^[A-Za-z0-9_.-]$/) ? ch : "_";
    }
    return result;
}

function string_to_hex(value) {
    value = as_string(value);
    let result = "";
    for (let i = 0; i < length(value); i++)
        result += sprintf("%02x", ord(substr(value, i, 1)));
    return result;
}

function mtproto_secret(section) {
    let secret = option(section, "mtproto_secret", "");
    let faketls = option(section, "mtproto_faketls", "google.com");
    if (substr(lc(secret), 0, 2) == "ee")
        return secret;
    return "ee" + secret + string_to_hex(faketls);
}

function users(section, protocol) {
    let name = option(section, protocol == "socks" ? "server_username" : "label", section[".name"]);
    if (name == "")
        name = section[".name"];

    if (protocol == "vless") {
        let user = { uuid: option(section, "server_uuid", "") };
        if (name != "")
            user.name = name;
        let flow = option(section, "vless_flow", "");
        if (flow != "" && flow != "none")
            user.flow = flow;
        return [ user ];
    }
    if (protocol == "vmess") {
        let user = {
            uuid: option(section, "server_uuid", ""),
            alterId: int_option(section, "vmess_alter_id", "0")
        };
        if (name != "")
            user.name = name;
        return [ user ];
    }
    if (protocol == "trojan" || protocol == "hysteria2") {
        let user = { password: option(section, "server_password", "") };
        if (name != "")
            user.name = name;
        return [ user ];
    }
    if (protocol == "socks") {
        return [{
            username: name != "" ? name : "user",
            password: option(section, "server_password", "")
        }];
    }
    if (protocol == "mtproto") {
        let user = { secret: mtproto_secret(section) };
        if (name != "")
            user.name = name;
        return [ user ];
    }
    return [];
}

function effective_security(section, protocol) {
    let security = option(section, "security", "");
    if (security == "") {
        if (protocol == "vless")
            security = "reality";
        else if (protocol == "trojan" || protocol == "hysteria2")
            security = "tls";
        else
            security = "none";
    }

    if (protocol == "shadowsocks" || protocol == "socks" || protocol == "mtproto" ||
        protocol == "tailscale" || protocol == "json_inbound")
        return "none";
    if (protocol == "hysteria2")
        return "tls";
    if ((protocol == "vmess" || protocol == "trojan") && security == "reality")
        return protocol == "trojan" ? "tls" : "none";
    return security;
}

function maybe_string(object, key, value) {
    value = as_string(value);
    if (value != "")
        object[key] = value;
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
        maybe_string(tls, "certificate_path", option(section, "tls_certificate_path", ""));
        maybe_string(tls, "key_path", option(section, "tls_key_path", ""));
    }
    else if (security == "reality") {
        let reality = {
            enabled: true,
            handshake: {
                server: option(section, "reality_handshake_server", "www.microsoft.com"),
                server_port: int_option(section, "reality_handshake_server_port", "443")
            },
            private_key: option(section, "reality_private_key", "")
        };
        let short_id = list_option(section, "reality_short_id");
        if (length(short_id) > 0)
            reality.short_id = short_id;
        maybe_string(reality, "max_time_difference", option(section, "reality_max_time_difference", "1m"));
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
        let hosts = list_option(section, "transport_hosts");
        if (length(hosts) > 0)
            transport.host = hosts;
    }
    else if (transport_type == "httpupgrade") {
        maybe_string(transport, "path", path);
        maybe_string(transport, "host", host);
    }
    else if (transport_type == "xhttp") {
        transport.mode = option(section, "transport_xhttp_mode", "auto");
        transport.path = path != "" ? path : "/";
        maybe_string(transport, "host", host);
        transport.headers = {};
        transport.x_padding_bytes = "100-1000";
        transport.no_sse_header = false;
        transport.sc_max_each_post_bytes = 1000000;
        transport.sc_max_buffered_posts = 30;
        transport.sc_stream_up_server_secs = "20-80";
        transport.server_max_header_bytes = 8192;
    }
    else {
        return;
    }

    inbound.transport = transport;
}

function add_standard_inbound(config, section, protocol, tag_name) {
    let inbound = {
        type: protocol,
        tag: tag_name,
        listen: option(section, "listen", "0.0.0.0"),
        listen_port: int_option(section, "listen_port", "443")
    };

    if (protocol == "shadowsocks") {
        inbound.method = option(section, "shadowsocks_method", "aes-128-gcm");
        inbound.password = option(section, "server_password", "");
    }
    else if (protocol == "socks") {
        if (bool_option(section, "socks_auth_enabled", true)) {
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
    }
    else if (protocol == "mtproto") {
        inbound.type = "mtproxy";
        inbound.users = users(section, protocol);
        let concurrency = option(section, "mtproto_concurrency", "");
        if (concurrency != "")
            inbound.concurrency = int(concurrency, 10);
        let fronting_port = option(section, "mtproto_domain_fronting_port", "443");
        if (fronting_port != "")
            inbound.domain_fronting_port = int(fronting_port, 10);
        maybe_string(inbound, "domain_fronting_ip", option(section, "mtproto_domain_fronting_ip", ""));
        if (bool_option(section, "mtproto_domain_fronting_proxy_protocol", false))
            inbound.domain_fronting_proxy_protocol = true;
        maybe_string(inbound, "prefer_ip", option(section, "mtproto_prefer_ip", "prefer-ipv4"));
        if (bool_option(section, "mtproto_auto_update", false))
            inbound.auto_update = true;
        if (bool_option(section, "mtproto_allow_fallback_on_unknown_dc", false))
            inbound.allow_fallback_on_unknown_dc = true;
        maybe_string(inbound, "tolerate_time_skewness", option(section, "mtproto_tolerate_time_skewness", "3s"));
        maybe_string(inbound, "idle_timeout", option(section, "mtproto_idle_timeout", "5m"));
        maybe_string(inbound, "handshake_timeout", option(section, "mtproto_handshake_timeout", "10s"));
    }
    else {
        inbound.users = users(section, protocol);
    }

    apply_tls(inbound, section, protocol);
    apply_transport(inbound, section, protocol);
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
        state_directory: "/etc/forkop/tailscale/" + safe_filename(section_name),
        auth_key: option(section, "tailscale_auth_key", ""),
        control_url: option(section, "tailscale_control_url", "https://controlplane.tailscale.com"),
        hostname: option(section, "tailscale_hostname", "forkop-" + safe_filename(section_name))
    };
    if (bool_option(section, "tailscale_accept_routes", false))
        endpoint.accept_routes = true;
    let advertise_routes = list_option(section, "tailscale_advertise_routes");
    if (length(advertise_routes) > 0)
        endpoint.advertise_routes = advertise_routes;
    if (bool_option(section, "tailscale_advertise_exit_node", false))
        endpoint.advertise_exit_node = true;
    push(config.endpoints, endpoint);
}

function add_dns_bypass(config, section) {
    if (option(section, "protocol", "vless") != "tailscale")
        return;

    let section_name = section[".name"];
    let inbound = runtime_constants.server_inbound_tag(section_name);
    let dns_tag = runtime_constants.tailscale_dns_server_tag(section_name);
    let rule_tag = "tailscale-server-dns-" + safe_filename(section_name);
    push(config.dns.servers, {
        type: "tailscale",
        tag: dns_tag,
        endpoint: inbound,
        accept_default_resolvers: true
    });
    push(config.dns.rules, {
        action: "route",
        server: dns_tag,
        inbound,
        __service_tag: rule_tag
    });
}

function add_server(config, section) {
    let section_name = section[".name"];
    let protocol = option(section, "protocol", "vless");
    let tag_name = runtime_constants.server_inbound_tag(section_name);

    if (protocol == "tailscale")
        add_tailscale_endpoint(config, section, tag_name);
    else if (protocol == "json_inbound")
        add_json_inbound(config, section, tag_name);
    else
        add_standard_inbound(config, section, protocol, tag_name);
    add_dns_bypass(config, section);
}

function add_sniff_rule(config, section) {
    let rules = array_or_empty(config.route.rules);
    let rule = {
        action: "sniff",
        inbound: runtime_constants.server_inbound_tag(section[".name"])
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

function clone_rules_for_inbound(config, source_inbound, target_inbound, skip_domain) {
    let cloned_rules = [];
    for (let rule in array_or_empty(config.route.rules)) {
        if (type(rule) != "object")
            continue;
        if (rule.action != "route" && rule.action != "reject")
            continue;
        if (!value_contains(rule.inbound, source_inbound))
            continue;
        if (skip_domain != "" && value_contains(rule.domain, skip_domain))
            continue;
        if (rule.source_ip_cidr != null)
            continue;

        let cloned = clone(rule);
        if (type(cloned) != "object")
            continue;
        cloned.inbound = target_inbound;
        push(cloned_rules, cloned);
    }
    for (let cloned_rule in cloned_rules)
        push(config.route.rules, cloned_rule);
}

return {
    add_server,
    add_sniff_rule,
    clone_rules_for_inbound
};
