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
    value = as_string(value);
    return value == "true" || value == "1" || value == "yes" || value == "on";
}

function number_arg(value) {
    value = as_string(value);
    return value == "" ? null : int(value, 10);
}

function normalize_port_number(value) {
    value = trim(as_string(value));
    if (!match(value, /^\d+$/))
        return "";

    let port = int(value, 10);
    if (port < 1 || port > 65535)
        return "";

    return "" + port;
}

function parse_hysteria2_server_ports(value) {
    value = as_string(value);
    if (index(value, ",") < 0 && index(value, "-") < 0)
        return null;

    let result = [];
    for (let entry in split(value, ",")) {
        entry = trim(as_string(entry));
        if (entry == "")
            return null;

        let dash = index(entry, "-");
        if (dash >= 0) {
            if (index(substr(entry, dash + 1), "-") >= 0)
                return null;

            let start = normalize_port_number(substr(entry, 0, dash));
            let end = normalize_port_number(substr(entry, dash + 1));
            if (start == "" || end == "" || int(start, 10) > int(end, 10))
                return null;

            push(result, start + ":" + end);
        }
        else {
            let port = normalize_port_number(entry);
            if (port == "")
                return null;

            push(result, port + ":" + port);
        }
    }

    return length(result) > 0 ? result : null;
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

function object_file_arg(path) {
    let parsed = read_json_file(path);
    return type(parsed) == "object" ? parsed : {};
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

function optional_json_value(object, key, value) {
    value = as_string(value);
    if (value != "")
        object[key] = json_arg(value);
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

function patch_outbounds(config, tags, patch) {
    let tag_set = {};
    for (let tag in tags)
        tag_set[as_string(tag)] = true;

    for (let outbound in ensure_array(config, "outbounds")) {
        if (type(outbound) == "object" && tag_set[as_string(outbound.tag)]) {
            for (let key, value in patch)
                outbound[key] = value;
        }
    }
}

function patch_inbound(config, tag, patch) {
    for (let inbound in ensure_array(config, "inbounds")) {
        if (type(inbound) == "object" && inbound.tag == tag) {
            for (let key, value in patch)
                inbound[key] = value;
        }
    }
}

function add_dns_server(config, server) {
    push(ensure_array(ensure_object(config, "dns"), "servers"), server);
}

function add_outbound(config, outbound) {
    push(ensure_array(config, "outbounds"), outbound);
}

function add_endpoint(config, endpoint) {
    push(ensure_array(config, "endpoints"), endpoint);
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

function add_tailscale_dns_server(config, args) {
    let server = {
        type: "tailscale",
        tag: as_string(args[0]),
        endpoint: as_string(args[1])
    };
    if (bool_arg(args[2]))
        server.accept_default_resolvers = true;
    add_dns_server(config, server);
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

function add_raw_inbound(config, args) {
    let inbound = json_arg(args[1]);
    if (type(inbound) != "object")
        inbound = {};
    inbound.tag = as_string(args[0]);
    push(ensure_array(config, "inbounds"), inbound);
}

function add_raw_inbound_file(config, args) {
    let inbound = object_file_arg(args[1]);
    inbound.tag = as_string(args[0]);
    push(ensure_array(config, "inbounds"), inbound);
}

function add_vless_inbound_file(config, args) {
    push(ensure_array(config, "inbounds"), {
        type: "vless",
        tag: as_string(args[0]),
        listen: as_string(args[1]),
        listen_port: number_arg(args[2]),
        users: array_file_arg(args[3])
    });
}

function add_trojan_inbound_file(config, args) {
    push(ensure_array(config, "inbounds"), {
        type: "trojan",
        tag: as_string(args[0]),
        listen: as_string(args[1]),
        listen_port: number_arg(args[2]),
        users: array_file_arg(args[3])
    });
}

function add_vmess_inbound_file(config, args) {
    push(ensure_array(config, "inbounds"), {
        type: "vmess",
        tag: as_string(args[0]),
        listen: as_string(args[1]),
        listen_port: number_arg(args[2]),
        users: array_file_arg(args[3])
    });
}

function add_socks_inbound_file(config, args) {
    let inbound = {
        type: "socks",
        tag: as_string(args[0]),
        listen: as_string(args[1]),
        listen_port: number_arg(args[2])
    };
    let users = array_file_arg(args[3]);
    if (length(users) > 0)
        inbound.users = users;
    push(ensure_array(config, "inbounds"), inbound);
}

function add_shadowsocks_inbound(config, args) {
    push(ensure_array(config, "inbounds"), {
        type: "shadowsocks",
        tag: as_string(args[0]),
        listen: as_string(args[1]),
        listen_port: number_arg(args[2]),
        method: as_string(args[3]),
        password: as_string(args[4])
    });
}

function add_hysteria2_inbound_file(config, args) {
    let inbound = {
        type: "hysteria2",
        tag: as_string(args[0]),
        listen: as_string(args[1]),
        listen_port: number_arg(args[2]),
        users: array_file_arg(args[3])
    };

    optional_number(inbound, "up_mbps", args[4]);
    optional_number(inbound, "down_mbps", args[5]);

    let obfs_type = as_string(args[6]);
    let obfs_password = as_string(args[7]);
    if (obfs_type != "" && obfs_password != "") {
        inbound.obfs = {
            type: obfs_type,
            password: obfs_password
        };
    }

    push(ensure_array(config, "inbounds"), inbound);
}

function add_mtproxy_inbound_file(config, args) {
    let inbound = {
        type: "mtproxy",
        tag: as_string(args[0]),
        listen: as_string(args[1]),
        listen_port: number_arg(args[2]),
        users: array_file_arg(args[3])
    };

    optional_number(inbound, "concurrency", args[4]);
    optional_number(inbound, "domain_fronting_port", args[5]);
    optional_string(inbound, "domain_fronting_ip", args[6]);
    if (bool_arg(args[7]))
        inbound.domain_fronting_proxy_protocol = true;
    optional_string(inbound, "prefer_ip", args[8]);
    if (bool_arg(args[9]))
        inbound.auto_update = true;
    if (bool_arg(args[10]))
        inbound.allow_fallback_on_unknown_dc = true;
    optional_string(inbound, "tolerate_time_skewness", args[11]);
    optional_string(inbound, "idle_timeout", args[12]);
    optional_string(inbound, "handshake_timeout", args[13]);

    push(ensure_array(config, "inbounds"), inbound);
}

function add_tailscale_endpoint(config, args) {
    let endpoint = {
        type: "tailscale",
        tag: as_string(args[0])
    };

    optional_string(endpoint, "state_directory", args[1]);
    optional_string(endpoint, "auth_key", args[2]);
    optional_string(endpoint, "control_url", args[3]);
    if (bool_arg(args[4]))
        endpoint.ephemeral = true;
    optional_string(endpoint, "hostname", args[5]);
    if (bool_arg(args[6]))
        endpoint.accept_routes = true;
    optional_string(endpoint, "exit_node", args[7]);
    if (bool_arg(args[8]))
        endpoint.exit_node_allow_lan_access = true;

    let advertise_routes = json_arg(args[9]);
    if (type(advertise_routes) == "array" && length(advertise_routes) > 0)
        endpoint.advertise_routes = advertise_routes;
    if (bool_arg(args[10]))
        endpoint.advertise_exit_node = true;
    optional_string(endpoint, "udp_timeout", args[11]);

    add_endpoint(config, endpoint);
}

function set_tls_for_inbound(config, args) {
    let tag = as_string(args[0]);
    let security = as_string(args[1]);
    if (security == "" || security == "none")
        return;

    let tls = { enabled: true };
    optional_string(tls, "server_name", args[2]);

    let alpn = json_arg(args[3]);
    if (type(alpn) == "array" && length(alpn) > 0)
        tls.alpn = alpn;

    if (security == "tls") {
        optional_string(tls, "certificate_path", args[4]);
        optional_string(tls, "key_path", args[5]);
    }
    else if (security == "reality") {
        let handshake = {
            server: as_string(args[6]),
            server_port: number_arg(args[7])
        };
        let reality = {
            enabled: true,
            handshake,
            private_key: as_string(args[8])
        };

        let short_id = json_arg(args[9]);
        if (type(short_id) == "array" && length(short_id) > 0)
            reality.short_id = short_id;
        optional_string(reality, "max_time_difference", args[10]);
        tls.reality = reality;
    }

    patch_inbound(config, tag, { tls });
}

function set_transport_for_inbound(config, args) {
    let tag = as_string(args[0]);
    let transport_type = as_string(args[1]);
    if (transport_type == "" || transport_type == "tcp" || transport_type == "raw")
        return;

    let transport = { type: transport_type };

    if (transport_type == "ws") {
        optional_string(transport, "path", args[2]);
        if (as_string(args[3]) != "")
            transport.headers = { Host: as_string(args[3]) };
    }
    else if (transport_type == "grpc") {
        optional_string(transport, "service_name", args[4]);
    }
    else if (transport_type == "http") {
        optional_string(transport, "path", args[2]);
        let hosts = json_arg(args[5]);
        if (type(hosts) == "array" && length(hosts) > 0)
            transport.host = hosts;
    }
    else if (transport_type == "httpupgrade") {
        optional_string(transport, "path", args[2]);
        optional_string(transport, "host", args[3]);
    }
    else if (transport_type == "xhttp") {
        let mode = as_string(args[6]);
        if (mode != "auto" && mode != "packet-up" && mode != "stream-up" && mode != "stream-one")
            mode = "auto";

        transport.mode = mode;
        transport.path = as_string(args[2]) != "" ? as_string(args[2]) : "/";
        optional_string(transport, "host", args[3]);
        transport.headers = {};
        transport.x_padding_bytes = "100-1000";
        transport.no_sse_header = false;
        transport.sc_max_each_post_bytes = 1000000;
        transport.sc_max_buffered_posts = 30;
        transport.sc_stream_up_server_secs = "20-80";
        transport.server_max_header_bytes = 8192;
    }

    patch_inbound(config, tag, { transport });
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

function add_http_outbound(config, args) {
    let outbound = {
        type: "http",
        tag: as_string(args[0]),
        server: as_string(args[1]),
        server_port: number_arg(args[2])
    };
    optional_string(outbound, "username", args[3]);
    optional_string(outbound, "password", args[4]);
    if (bool_arg(args[5]))
        outbound.tls = { enabled: true };
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
    let server_port = as_string(args[2]);
    let outbound = {
        type: "hysteria2",
        tag: as_string(args[0]),
        server: as_string(args[1]),
        password: as_string(args[3])
    };
    let server_ports = parse_hysteria2_server_ports(server_port);
    if (server_ports != null)
        outbound.server_ports = server_ports;
    else if (index(server_port, ",") >= 0 || index(server_port, "-") >= 0)
        outbound.server_ports = [ server_port ];
    else
        outbound.server_port = number_arg(server_port);

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
    optional_json_value(transport, "x_padding_bytes", args[4]);
    if (as_string(args[5]) != "")
        transport.no_grpc_header = bool_arg(args[5]);
    optional_json_value(transport, "sc_max_each_post_bytes", args[6]);
    optional_json_value(transport, "sc_min_posts_interval_ms", args[7]);
    optional_json_value(transport, "sc_stream_up_server_secs", args[8]);
    optional_json_value(transport, "xmux", args[9]);
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

function set_outbound_detour(config, args) {
    let detour = as_string(args[1]);
    if (detour != "")
        patch_outbound(config, as_string(args[0]), { detour });
}

function set_outbounds_detour(config, args) {
    let detour = as_string(args[1]);
    if (detour != "")
        patch_outbounds(config, array_arg(args[0]), { detour });
}

function add_interface_outbound(config, args) {
    let outbound = {
        type: "direct",
        tag: as_string(args[0]),
        bind_interface: as_string(args[1])
    };
    optional_string(outbound, "domain_resolver", args[2]);
    optional_number(outbound, "routing_mark", args[3]);
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
    optional_number(config.route, "default_mark", args[4]);
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

function json_arg_nonempty(value) {
    let parsed = json_arg(value);

    if (type(parsed) == "array")
        return length(parsed) > 0 ? parsed : null;
    if (type(parsed) == "object")
        return length(keys(parsed)) > 0 ? parsed : null;

    let string_value = as_string(parsed);
    return string_value != "" ? parsed : null;
}

function patch_tagged_rule_if_nonempty(rules, tag, key, value) {
    value = json_arg_nonempty(value);
    if (value != null)
        patch_tagged_rule(rules, tag, key, value);
}

function add_route_rule_with_matchers(config, args) {
    let tag = as_string(args[0]);
    let inbound = as_string(args[1]);
    let outbound = as_string(args[2]);
    let action = as_string(args[3]);
    let route = ensure_object(config, "route");
    let rules = ensure_array(route, "rules");

    if (action == "reject") {
        let rule = { action: "reject" };
        optional_string(rule, "inbound", inbound);
        rule[SERVICE_TAG] = tag;
        push(rules, rule);
    }
    else {
        let rule = {
            action: "route",
            inbound,
            outbound
        };
        rule[SERVICE_TAG] = tag;
        push(rules, rule);
    }

    let matcher_keys = [
        "domain",
        "domain_suffix",
        "domain_keyword",
        "domain_regex",
        "ip_cidr",
        "port",
        "port_range",
        "source_ip_cidr"
    ];
    for (let i = 0; i < length(matcher_keys); i++)
        patch_tagged_rule_if_nonempty(rules, tag, matcher_keys[i], args[4 + i]);
}

function copy_rule_matchers(rule) {
    let copied = {};
    for (let key in ["inbound", "source_ip_cidr", "domain", "domain_suffix", "domain_keyword", "domain_regex", "rule_set", "port", "port_range"]) {
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

function patch_rule_set_reference(config, args) {
    let route_tag = as_string(args[0]);
    let dns_tag = as_string(args[1]);
    let rule_set_tag = as_string(args[2]);

    if (route_tag != "" && rule_set_tag != "")
        patch_tagged_rule(ensure_array(ensure_object(config, "route"), "rules"), route_tag, "rule_set", rule_set_tag);
    if (dns_tag != "" && rule_set_tag != "")
        patch_tagged_rule(ensure_array(ensure_object(config, "dns"), "rules"), dns_tag, "rule_set", rule_set_tag);
}

function patch_dns_route_rule_matchers(config, args) {
    let rules = ensure_array(ensure_object(config, "dns"), "rules");
    let tag = as_string(args[0]);
    let matcher_keys = [
        "domain",
        "domain_suffix",
        "domain_keyword",
        "domain_regex"
    ];
    for (let i = 0; i < length(matcher_keys); i++)
        patch_tagged_rule_if_nonempty(rules, tag, matcher_keys[i], args[1 + i]);
}

function add_reject_route_rule(config, args) {
    let rule = {
        action: "reject"
    };
    optional_string(rule, "inbound", args[1]);
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
        for (let entry in value) {
            if (entry == item)
                return true;
        }
        return false;
    }
    return value == item;
}

function clone_route_rules_for_inbound(config, args) {
    let source_inbound = as_string(args[0]);
    let target_inbound = as_string(args[1]);
    let skip_domain = as_string(args[2]);
    let route = ensure_object(config, "route");
    let rules = ensure_array(route, "rules");
    let cloned_rules = [];

    for (let rule in rules) {
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
        push(rules, cloned_rule);
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

function add_remote_ruleset_reference(config, args) {
    add_remote_ruleset(config, [
        args[2],
        args[3],
        args[4],
        args[5],
        args[6]
    ]);
    patch_rule_set_reference(config, [
        args[0],
        args[1],
        args[2]
    ]);
}

function add_local_ruleset_reference(config, args) {
    add_local_ruleset(config, [
        args[2],
        args[3],
        args[4]
    ]);
    patch_rule_set_reference(config, [
        args[0],
        args[1],
        args[2]
    ]);
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
    "add-tailscale-dns-server": add_tailscale_dns_server,
    "add-dns-route-rule": add_dns_route_rule,
    "patch-dns-route-rule": patch_dns_route_rule,
    "add-dns-reject-rule": add_dns_reject_rule,
    "add-tproxy-inbound": add_tproxy_inbound,
    "add-direct-inbound": add_direct_inbound,
    "add-mixed-inbound": add_mixed_inbound,
    "add-raw-inbound": add_raw_inbound,
    "add-raw-inbound-file": add_raw_inbound_file,
    "add-vless-inbound-file": add_vless_inbound_file,
    "add-trojan-inbound-file": add_trojan_inbound_file,
    "add-vmess-inbound-file": add_vmess_inbound_file,
    "add-socks-inbound-file": add_socks_inbound_file,
    "add-shadowsocks-inbound": add_shadowsocks_inbound,
    "add-hysteria2-inbound-file": add_hysteria2_inbound_file,
    "add-mtproxy-inbound-file": add_mtproxy_inbound_file,
    "add-tailscale-endpoint": add_tailscale_endpoint,
    "set-inbound-tls": set_tls_for_inbound,
    "set-inbound-transport": set_transport_for_inbound,
    "add-direct-outbound": add_direct_outbound,
    "add-socks-outbound": add_socks_outbound,
    "add-http-outbound": add_http_outbound,
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
    "set-outbound-detour": set_outbound_detour,
    "set-outbounds-detour": set_outbounds_detour,
    "add-interface-outbound": add_interface_outbound,
    "add-raw-outbound": add_raw_outbound,
    "add-urltest-outbound": add_urltest_outbound,
    "add-urltest-outbound-file": add_urltest_outbound_file,
    "add-selector-outbound": add_selector_outbound,
    "add-selector-outbound-file": add_selector_outbound_file,
    "configure-route": configure_route,
    "add-route-rule": add_route_rule,
    "add-route-rule-with-matchers": add_route_rule_with_matchers,
    "add-resolve-rule": add_resolve_rule,
    "patch-route-rule": patch_route_rule,
    "patch-rule-set-reference": patch_rule_set_reference,
    "patch-dns-route-rule-matchers": patch_dns_route_rule_matchers,
    "add-reject-route-rule": add_reject_route_rule,
    "add-hijack-dns-route-rule": add_hijack_dns_route_rule,
    "add-options-route-rule": add_options_route_rule,
    "sniff-route-rule": sniff_route_rule,
    "clone-route-rules-for-inbound": clone_route_rules_for_inbound,
    "add-inline-ruleset": add_inline_ruleset,
    "add-inline-ruleset-rule": add_inline_ruleset_rule,
    "add-local-ruleset": add_local_ruleset,
    "add-remote-ruleset": add_remote_ruleset,
    "add-remote-ruleset-reference": add_remote_ruleset_reference,
    "add-local-ruleset-reference": add_local_ruleset_reference,
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
