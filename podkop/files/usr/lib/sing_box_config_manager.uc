#!/usr/bin/env ucode

let fs = require("fs");

let SERVICE_TAG = "__service_tag";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_config() {
    try {
        let config = json(read_stdin());
        return type(config) == "object" ? config : {};
    }
    catch (e) {
        return {};
    }
}

function read_json_file(path) {
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

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function bool_arg(value) {
    return as_string(value) == "true";
}

function number_arg(value) {
    value = as_string(value);
    return value == "" ? null : int(value, 10);
}

function json_arg(value) {
    value = as_string(value);
    try {
        return json(value);
    }
    catch (e) {
        return value;
    }
}

function array_arg(value) {
    let parsed = json_arg(value);
    return type(parsed) == "array" ? parsed : [];
}

function array_file_arg(path) {
    let parsed = read_json_file(path);
    return type(parsed) == "array" ? parsed : [];
}

function optional_string(object, key, value) {
    value = as_string(value);
    if (value != "")
        object[key] = value;
}

function optional_number(object, key, value) {
    let parsed = number_arg(value);
    if (parsed != null)
        object[key] = parsed;
}

function ensure_object(config, key) {
    if (type(config[key]) != "object")
        config[key] = {};
    return config[key];
}

function ensure_array(object, key) {
    if (type(object[key]) != "array")
        object[key] = [];
    return object[key];
}

function extend_key_value(current_value, new_value) {
    let result = [];

    if (type(current_value) == "array") {
        for (let item in current_value)
            push(result, item);
    }
    else {
        push(result, current_value);
    }

    if (type(new_value) == "array") {
        for (let item in new_value)
            push(result, item);
    }
    else {
        push(result, new_value);
    }

    return result;
}

function patch_tagged_rule(rules, tag, key, value) {
    for (let rule in rules) {
        if (type(rule) == "object" && rule[SERVICE_TAG] == tag) {
            if (rule[key] != null)
                rule[key] = extend_key_value(rule[key], value);
            else
                rule[key] = value;
        }
    }
}

function patch_outbound(config, tag, patch) {
    for (let outbound in ensure_array(config, "outbounds")) {
        if (type(outbound) == "object" && outbound.tag == tag) {
            for (let key, value in patch)
                outbound[key] = value;
        }
    }
}

function add_dns_server(config, server) {
    push(ensure_array(ensure_object(config, "dns"), "servers"), server);
}

function add_outbound(config, outbound) {
    push(ensure_array(config, "outbounds"), outbound);
}

function add_rule(config, section, rule) {
    push(ensure_array(ensure_object(config, section), "rules"), rule);
}

function add_rule_set(config, rule_set) {
    push(ensure_array(ensure_object(config, "route"), "rule_set"), rule_set);
}

function clean_service_tags(value) {
    if (type(value) == "array") {
        for (let i = 0; i < length(value); i++)
            value[i] = clean_service_tags(value[i]);
        return value;
    }

    if (type(value) == "object") {
        delete value[SERVICE_TAG];
        for (let key, item in value)
            value[key] = clean_service_tags(item);
    }

    return value;
}

function configure_log(config, args) {
    config.log = {
        disabled: bool_arg(args[0]),
        level: as_string(args[1]),
        timestamp: bool_arg(args[2])
    };
}

function configure_dns(config, args) {
    let current = type(config.dns) == "object" ? config.dns : {};
    config.dns = {
        servers: type(current.servers) == "array" ? current.servers : [],
        rules: type(current.rules) == "array" ? current.rules : [],
        final: as_string(args[0]),
        strategy: as_string(args[1]),
        independent_cache: bool_arg(args[2])
    };
}

function add_udp_dns_server(config, args) {
    let server = {
        type: "udp",
        tag: as_string(args[0]),
        server: as_string(args[1]),
        server_port: number_arg(args[2])
    };
    optional_string(server, "domain_resolver", args[3]);
    optional_string(server, "detour", args[4]);
    add_dns_server(config, server);
}

function add_tls_dns_server(config, args) {
    let server = {
        type: "tls",
        tag: as_string(args[0]),
        server: as_string(args[1]),
        server_port: number_arg(args[2])
    };
    optional_string(server, "domain_resolver", args[3]);
    optional_string(server, "detour", args[4]);
    add_dns_server(config, server);
}

function add_https_dns_server(config, args) {
    let server = {
        type: "https",
        tag: as_string(args[0]),
        server: as_string(args[1]),
        server_port: number_arg(args[2])
    };
    optional_string(server, "path", args[3]);
    optional_string(server, "headers", args[4]);
    optional_string(server, "domain_resolver", args[5]);
    optional_string(server, "detour", args[6]);
    add_dns_server(config, server);
}

function add_fakeip_dns_server(config, args) {
    add_dns_server(config, {
        type: "fakeip",
        tag: as_string(args[0]),
        inet4_range: as_string(args[1])
    });
}

function add_dns_route_rule(config, args) {
    let rule = {
        action: "route",
        server: as_string(args[0])
    };
    rule[SERVICE_TAG] = as_string(args[1]);
    add_rule(config, "dns", rule);
}

function patch_dns_route_rule(config, args) {
    patch_tagged_rule(ensure_array(ensure_object(config, "dns"), "rules"), as_string(args[0]), as_string(args[1]), json_arg(args[2]));
}

function add_dns_reject_rule(config, args) {
    let rule = { action: "reject" };
    rule[as_string(args[0])] = json_arg(args[1]);
    add_rule(config, "dns", rule);
}

function add_tproxy_inbound(config, args) {
    push(ensure_array(config, "inbounds"), {
        type: "tproxy",
        tag: as_string(args[0]),
        listen: as_string(args[1]),
        listen_port: number_arg(args[2]),
        tcp_fast_open: bool_arg(args[3]),
        udp_fragment: bool_arg(args[4])
    });
}

function add_direct_inbound(config, args) {
    push(ensure_array(config, "inbounds"), {
        type: "direct",
        tag: as_string(args[0]),
        listen: as_string(args[1]),
        listen_port: number_arg(args[2])
    });
}

function add_mixed_inbound(config, args) {
    let inbound = {
        type: "mixed",
        tag: as_string(args[0]),
        listen: as_string(args[1]),
        listen_port: number_arg(args[2])
    };
    let username = as_string(args[3]);
    let password = as_string(args[4]);
    if (username != "" && password != "") {
        inbound.users = [{
            username,
            password
        }];
    }
    push(ensure_array(config, "inbounds"), inbound);
}

function add_direct_outbound(config, args) {
    let outbound = {
        type: "direct",
        tag: as_string(args[0])
    };
    optional_number(outbound, "routing_mark", args[1]);
    add_outbound(config, outbound);
}

function add_socks_outbound(config, args) {
    let outbound = {
        type: "socks",
        tag: as_string(args[0]),
        server: as_string(args[1]),
        server_port: number_arg(args[2])
    };
    optional_string(outbound, "version", args[3]);
    optional_string(outbound, "username", args[4]);
    optional_string(outbound, "password", args[5]);
    optional_string(outbound, "network", args[6]);
    if (as_string(args[7]) != "") {
        outbound.udp_over_tcp = {
            enabled: true,
            version: number_arg(args[7])
        };
    }
    add_outbound(config, outbound);
}

function add_shadowsocks_outbound(config, args) {
    let outbound = {
        type: "shadowsocks",
        tag: as_string(args[0]),
        server: as_string(args[1]),
        server_port: number_arg(args[2]),
        method: as_string(args[3]),
        password: as_string(args[4])
    };
    optional_string(outbound, "network", args[5]);
    if (as_string(args[6]) != "") {
        outbound.udp_over_tcp = {
            enabled: true,
            version: number_arg(args[6])
        };
    }
    optional_string(outbound, "plugin", args[7]);
    optional_string(outbound, "plugin_opts", args[8]);
    add_outbound(config, outbound);
}

function add_vless_outbound(config, args) {
    let outbound = {
        type: "vless",
        tag: as_string(args[0]),
        server: as_string(args[1]),
        server_port: number_arg(args[2]),
        uuid: as_string(args[3])
    };
    optional_string(outbound, "flow", args[4]);
    optional_string(outbound, "network", args[5]);
    optional_string(outbound, "packet_encoding", args[6]);
    add_outbound(config, outbound);
}

function add_trojan_outbound(config, args) {
    let outbound = {
        type: "trojan",
        tag: as_string(args[0]),
        server: as_string(args[1]),
        server_port: number_arg(args[2]),
        password: as_string(args[3])
    };
    optional_string(outbound, "network", args[4]);
    add_outbound(config, outbound);
}

function add_hysteria2_outbound(config, args) {
    let outbound = {
        type: "hysteria2",
        tag: as_string(args[0]),
        server: as_string(args[1]),
        server_port: number_arg(args[2]),
        password: as_string(args[3])
    };
    if (as_string(args[4]) != "" && as_string(args[5]) != "") {
        outbound.obfs = {
            type: as_string(args[4]),
            password: as_string(args[5])
        };
    }
    optional_number(outbound, "up_mbps", args[6]);
    optional_number(outbound, "down_mbps", args[7]);
    optional_string(outbound, "network", args[8]);
    add_outbound(config, outbound);
}

function set_grpc_transport(config, args) {
    let transport = { type: "grpc" };
    optional_string(transport, "service_name", args[1]);
    optional_string(transport, "idle_timeout", args[2]);
    optional_string(transport, "ping_timeout", args[3]);
    optional_string(transport, "permit_without_stream", args[4]);
    patch_outbound(config, as_string(args[0]), { transport });
}

function set_ws_transport(config, args) {
    let transport = {
        type: "ws",
        path: as_string(args[1])
    };
    if (as_string(args[2]) != "")
        transport.headers = { Host: as_string(args[2]) };
    optional_number(transport, "max_early_data", args[3]);
    optional_string(transport, "early_data_header_name", args[4]);
    patch_outbound(config, as_string(args[0]), { transport });
}

function set_http_transport(config, args) {
    let transport = { type: "http" };
    optional_string(transport, "path", args[1]);
    let hosts = array_arg(args[2]);
    if (length(hosts) > 0)
        transport.host = hosts;
    patch_outbound(config, as_string(args[0]), { transport });
}

function set_httpupgrade_transport(config, args) {
    let transport = { type: "httpupgrade" };
    optional_string(transport, "path", args[1]);
    optional_string(transport, "host", args[2]);
    patch_outbound(config, as_string(args[0]), { transport });
}

function set_xhttp_transport(config, args) {
    let mode = as_string(args[3]);
    if (mode != "auto" && mode != "packet-up" && mode != "stream-up" && mode != "stream-one")
        mode = "auto";

    let transport = {
        type: "xhttp",
        mode,
        path: as_string(args[1]) != "" ? as_string(args[1]) : "/",
        x_padding_bytes: "100-1000",
        no_grpc_header: false,
        sc_max_each_post_bytes: 1000000,
        sc_min_posts_interval_ms: 30
    };
    optional_string(transport, "host", args[2]);
    patch_outbound(config, as_string(args[0]), { transport });
}

function set_tls(config, args) {
    let tls = { enabled: true };
    optional_string(tls, "server_name", args[1]);
    if (bool_arg(args[2]))
        tls.insecure = true;

    let alpn = json_arg(args[3]);
    if (alpn != null)
        tls.alpn = alpn;

    if (as_string(args[4]) != "") {
        tls.utls = {
            enabled: true,
            fingerprint: as_string(args[4])
        };
    }
    if (as_string(args[5]) != "") {
        tls.reality = {
            enabled: true,
            public_key: as_string(args[5]),
            short_id: as_string(args[6])
        };
    }
    patch_outbound(config, as_string(args[0]), { tls });
}

function add_interface_outbound(config, args) {
    let outbound = {
        type: "direct",
        tag: as_string(args[0]),
        bind_interface: as_string(args[1])
    };
    optional_string(outbound, "domain_resolver", args[2]);
    add_outbound(config, outbound);
}

function add_raw_outbound(config, args) {
    let outbound = json_arg(args[1]);
    if (type(outbound) != "object")
        outbound = {};
    outbound.tag = as_string(args[0]);
    add_outbound(config, outbound);
}

function add_urltest_outbound(config, args) {
    let outbound = {
        type: "urltest",
        tag: as_string(args[0]),
        outbounds: array_arg(args[1])
    };
    optional_string(outbound, "url", args[2]);
    optional_string(outbound, "interval", args[3]);
    optional_number(outbound, "tolerance", args[4]);
    optional_string(outbound, "idle_timeout", args[5]);
    if (bool_arg(args[6]))
        outbound.interrupt_exist_connections = true;
    add_outbound(config, outbound);
}

function add_urltest_outbound_file(config, args) {
    let outbound = {
        type: "urltest",
        tag: as_string(args[0]),
        outbounds: array_file_arg(args[1])
    };
    optional_string(outbound, "url", args[2]);
    optional_string(outbound, "interval", args[3]);
    optional_number(outbound, "tolerance", args[4]);
    optional_string(outbound, "idle_timeout", args[5]);
    if (bool_arg(args[6]))
        outbound.interrupt_exist_connections = true;
    add_outbound(config, outbound);
}

function add_selector_outbound(config, args) {
    let outbound = {
        type: "selector",
        tag: as_string(args[0]),
        outbounds: array_arg(args[1]),
        default: as_string(args[2])
    };
    if (bool_arg(args[3]))
        outbound.interrupt_exist_connections = true;
    add_outbound(config, outbound);
}

function add_selector_outbound_file(config, args) {
    let outbound = {
        type: "selector",
        tag: as_string(args[0]),
        outbounds: array_file_arg(args[1]),
        default: as_string(args[2])
    };
    if (bool_arg(args[3]))
        outbound.interrupt_exist_connections = true;
    add_outbound(config, outbound);
}

function configure_route(config, args) {
    let current = type(config.route) == "object" ? config.route : {};
    config.route = {
        rules: type(current.rules) == "array" ? current.rules : [],
        rule_set: type(current.rule_set) == "array" ? current.rule_set : [],
        final: as_string(args[0]),
        auto_detect_interface: bool_arg(args[1]),
        default_domain_resolver: as_string(args[2])
    };
    optional_string(config.route, "default_interface", args[3]);
}

function add_route_rule(config, args) {
    let rule = {
        action: "route",
        inbound: as_string(args[1]),
        outbound: as_string(args[2])
    };
    rule[SERVICE_TAG] = as_string(args[0]);
    add_rule(config, "route", rule);
}

function copy_rule_matchers(rule) {
    let copied = {};
    for (let key in ["inbound", "source_ip_cidr", "domain", "domain_suffix", "domain_keyword", "domain_regex", "rule_set"]) {
        if (rule[key] != null)
            copied[key] = rule[key];
    }
    return copied;
}

function add_resolve_rule(config, args) {
    let route = ensure_object(config, "route");
    let rules = ensure_array(route, "rules");
    let updated = [];

    for (let rule in rules) {
        if (type(rule) == "object" && rule[SERVICE_TAG] == as_string(args[0])) {
            let resolve = copy_rule_matchers(rule);
            resolve.action = "resolve";
            resolve.server = as_string(args[2]) != "" ? as_string(args[2]) : "dns-server";
            resolve[SERVICE_TAG] = as_string(args[1]);
            push(updated, resolve);
        }
        push(updated, rule);
    }

    route.rules = updated;
}

function patch_route_rule(config, args) {
    patch_tagged_rule(ensure_array(ensure_object(config, "route"), "rules"), as_string(args[0]), as_string(args[1]), json_arg(args[2]));
}

function add_reject_route_rule(config, args) {
    let rule = {
        action: "reject",
        inbound: as_string(args[1])
    };
    rule[SERVICE_TAG] = as_string(args[0]);
    add_rule(config, "route", rule);
}

function add_hijack_dns_route_rule(config, args) {
    let rule = { action: "hijack-dns" };
    rule[as_string(args[0])] = json_arg(args[1]);
    add_rule(config, "route", rule);
}

function add_options_route_rule(config, args) {
    let rule = { action: "route-options" };
    rule[SERVICE_TAG] = as_string(args[0]);
    add_rule(config, "route", rule);
}

function sniff_route_rule(config, args) {
    let rule = { action: "sniff" };
    rule[as_string(args[0])] = json_arg(args[1]);
    add_rule(config, "route", rule);
}

function add_inline_ruleset(config, args) {
    add_rule_set(config, {
        type: "inline",
        tag: as_string(args[0])
    });
}

function add_inline_ruleset_rule(config, args) {
    let rule_sets = ensure_array(ensure_object(config, "route"), "rule_set");
    let tag = as_string(args[0]);
    let key = as_string(args[1]);
    let value = json_arg(args[2]);
    for (let rule_set in rule_sets) {
        if (type(rule_set) == "object" && rule_set.tag == tag) {
            if (rule_set[key] != null)
                rule_set[key] = extend_key_value(rule_set[key], value);
            else
                rule_set[key] = value;
        }
    }
}

function add_local_ruleset(config, args) {
    add_rule_set(config, {
        type: "local",
        tag: as_string(args[0]),
        format: as_string(args[1]),
        path: as_string(args[2])
    });
}

function add_remote_ruleset(config, args) {
    let rule_set = {
        type: "remote",
        tag: as_string(args[0]),
        format: as_string(args[1]),
        url: as_string(args[2])
    };
    optional_string(rule_set, "download_detour", args[3]);
    optional_string(rule_set, "update_interval", args[4]);
    add_rule_set(config, rule_set);
}

function configure_cache_file(config, args) {
    let experimental = ensure_object(config, "experimental");
    experimental.cache_file = {
        enabled: bool_arg(args[0]),
        path: as_string(args[1]),
        store_fakeip: bool_arg(args[2])
    };
}

function configure_clash_api(config, args) {
    let experimental = ensure_object(config, "experimental");
    experimental.clash_api = {
        external_controller: as_string(args[0])
    };
    optional_string(experimental.clash_api, "external_ui", args[1]);
    optional_string(experimental.clash_api, "secret", args[2]);
}

let handlers = {
    "configure-log": configure_log,
    "configure-dns": configure_dns,
    "add-udp-dns-server": add_udp_dns_server,
    "add-tls-dns-server": add_tls_dns_server,
    "add-https-dns-server": add_https_dns_server,
    "add-fakeip-dns-server": add_fakeip_dns_server,
    "add-dns-route-rule": add_dns_route_rule,
    "patch-dns-route-rule": patch_dns_route_rule,
    "add-dns-reject-rule": add_dns_reject_rule,
    "add-tproxy-inbound": add_tproxy_inbound,
    "add-direct-inbound": add_direct_inbound,
    "add-mixed-inbound": add_mixed_inbound,
    "add-direct-outbound": add_direct_outbound,
    "add-socks-outbound": add_socks_outbound,
    "add-shadowsocks-outbound": add_shadowsocks_outbound,
    "add-vless-outbound": add_vless_outbound,
    "add-trojan-outbound": add_trojan_outbound,
    "add-hysteria2-outbound": add_hysteria2_outbound,
    "set-grpc-transport": set_grpc_transport,
    "set-ws-transport": set_ws_transport,
    "set-http-transport": set_http_transport,
    "set-httpupgrade-transport": set_httpupgrade_transport,
    "set-xhttp-transport": set_xhttp_transport,
    "set-tls": set_tls,
    "add-interface-outbound": add_interface_outbound,
    "add-raw-outbound": add_raw_outbound,
    "add-urltest-outbound": add_urltest_outbound,
    "add-urltest-outbound-file": add_urltest_outbound_file,
    "add-selector-outbound": add_selector_outbound,
    "add-selector-outbound-file": add_selector_outbound_file,
    "configure-route": configure_route,
    "add-route-rule": add_route_rule,
    "add-resolve-rule": add_resolve_rule,
    "patch-route-rule": patch_route_rule,
    "add-reject-route-rule": add_reject_route_rule,
    "add-hijack-dns-route-rule": add_hijack_dns_route_rule,
    "add-options-route-rule": add_options_route_rule,
    "sniff-route-rule": sniff_route_rule,
    "add-inline-ruleset": add_inline_ruleset,
    "add-inline-ruleset-rule": add_inline_ruleset_rule,
    "add-local-ruleset": add_local_ruleset,
    "add-remote-ruleset": add_remote_ruleset,
    "configure-cache-file": configure_cache_file,
    "configure-clash-api": configure_clash_api
};

let mode = ARGV[0] || "";

if (mode == "normalize-arg") {
    write_json(json_arg(ARGV[1]));
    exit(0);
}

let config = read_config();

if (mode == "save-config") {
    let path = ARGV[1] || "";
    if (path == "" || !fs.writefile(path, sprintf("%J", clean_service_tags(config)) + "\n"))
        exit(1);
    exit(0);
}

let handler = handlers[mode];
if (!handler) {
    warn("Usage: sing_box_config_manager.uc <operation> [args...]\n");
    exit(1);
}

handler(config, slice(ARGV, 1));
write_json(config);
