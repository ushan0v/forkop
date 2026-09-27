#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;
let array_or_empty = common.array_or_empty;

function starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function uri_encode(value) {
    value = as_string(value);
    let result = "";
    for (let i = 0; i < length(value); i++) {
        let char = substr(value, i, 1);
        let code = ord(char);
        if ((code >= 48 && code <= 57) ||
            (code >= 65 && code <= 90) ||
            (code >= 97 && code <= 122) ||
            char == "-" || char == "_" || char == "." || char == "~")
            result += char;
        else
            result += sprintf("%%%02X", code);
    }
    return result;
}

function base64_encode(value) {
    let encoded = b64enc(as_string(value));
    while (length(encoded) > 0 && substr(encoded, length(encoded) - 1) == "=")
        encoded = substr(encoded, 0, length(encoded) - 1);
    return encoded;
}

function host_port(server, port) {
    server = as_string(server);
    if (index(server, ":") >= 0 && !starts_with(server, "["))
        server = "[" + server + "]";
    return server + ":" + as_string(port);
}

function hysteria2_server_port_entry(value) {
    value = as_string(value);
    let colon = index(value, ":");
    if (colon < 0)
        return value;

    let start = substr(value, 0, colon);
    let end = substr(value, colon + 1);
    if (start == "" || end == "")
        return "";

    return start == end ? start : (start + "-" + end);
}

function hysteria2_server_ports_uri(outbound) {
    let server_ports = array_or_empty(outbound.server_ports);
    if (length(server_ports) == 0)
        return "";

    let result = [];
    for (let item in server_ports) {
        let port = hysteria2_server_port_entry(item);
        if (port != "")
            push(result, port);
    }

    return join(",", result);
}

function add_query(params, key, value) {
    value = as_string(value);
    if (value != "")
        push(params, uri_encode(key) + "=" + uri_encode(value));
}

function add_xhttp_extra_query(params, transport) {
    let extra = {};
    for (let item in [
        ["xPaddingBytes", "x_padding_bytes"],
        ["noGRPCHeader", "no_grpc_header"],
        ["scMaxEachPostBytes", "sc_max_each_post_bytes"],
        ["scMinPostsIntervalMs", "sc_min_posts_interval_ms"],
        ["scStreamUpServerSecs", "sc_stream_up_server_secs"]
    ]) {
        if (transport[item[1]] != null)
            extra[item[0]] = transport[item[1]];
    }

    if (type(transport.xmux) == "object") {
        let xmux = {};
        for (let item in [
            ["maxConcurrency", "max_concurrency"],
            ["maxConnections", "max_connections"],
            ["cMaxReuseTimes", "c_max_reuse_times"],
            ["hMaxRequestTimes", "h_max_request_times"],
            ["hMaxReusableSecs", "h_max_reusable_secs"],
            ["hKeepAlivePeriod", "h_keep_alive_period"]
        ]) {
            if (transport.xmux[item[1]] != null)
                xmux[item[0]] = transport.xmux[item[1]];
        }
        if (length(keys(xmux)) > 0)
            extra.xmux = xmux;
    }

    if (length(keys(extra)) > 0)
        add_query(params, "extra", sprintf("%J", extra));
}

function add_tls_query(params, outbound, trojan_default_tls) {
    let tls = type(outbound.tls) == "object" ? outbound.tls : null;
    if (!tls || tls.enabled === false) {
        if (trojan_default_tls)
            add_query(params, "security", "tls");
        return;
    }

    let reality = type(tls.reality) == "object" ? tls.reality : null;
    if (reality && reality.enabled !== false) {
        add_query(params, "security", "reality");
        add_query(params, "pbk", reality.public_key);
        add_query(params, "sid", reality.short_id);
    }
    else {
        add_query(params, "security", "tls");
    }

    add_query(params, "sni", tls.server_name);
    if (tls.insecure === true)
        add_query(params, "allowInsecure", "1");
    if (type(tls.utls) == "object" && tls.utls.enabled !== false)
        add_query(params, "fp", tls.utls.fingerprint);
    if (type(tls.alpn) == "array" && length(tls.alpn) > 0)
        add_query(params, "alpn", join(",", tls.alpn));
}

function add_transport_query(params, outbound) {
    let transport = type(outbound.transport) == "object" ? outbound.transport : null;
    if (!transport) {
        add_query(params, "type", "tcp");
        return;
    }

    let transport_type = as_string(transport.type);
    add_query(params, "type", transport_type != "" ? transport_type : "tcp");

    if (transport_type == "ws") {
        add_query(params, "path", transport.path);
        if (type(transport.headers) == "object")
            add_query(params, "host", transport.headers.Host || transport.headers.host);
    }
    else if (transport_type == "grpc") {
        add_query(params, "serviceName", transport.service_name);
    }
    else if (transport_type == "http") {
        add_query(params, "path", transport.path);
        if (type(transport.host) == "array" && length(transport.host) > 0)
            add_query(params, "host", join(",", transport.host));
        else
            add_query(params, "host", transport.host);
    }
    else if (transport_type == "xhttp") {
        add_query(params, "path", transport.path);
        add_query(params, "host", transport.host);
        add_query(params, "mode", transport.mode);
        add_xhttp_extra_query(params, transport);
    }
}

function query_string(params) {
    return length(params) == 0 ? "" : "?" + join("&", params);
}

function fragment(outbound) {
    let tag = as_string(outbound.tag);
    return tag == "" ? "" : "#" + uri_encode(tag);
}

function serialize_vless(outbound) {
    if (as_string(outbound.uuid) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    add_tls_query(params, outbound, false);
    add_transport_query(params, outbound);
    let encryption = as_string(outbound.encryption);
    if (encryption != "" && encryption != "none")
        add_query(params, "encryption", encryption);
    add_query(params, "flow", outbound.flow);
    add_query(params, "packetEncoding", outbound.packet_encoding);
    return "vless://" + uri_encode(outbound.uuid) + "@" +
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_trojan(outbound) {
    if (as_string(outbound.password) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    add_tls_query(params, outbound, true);
    add_transport_query(params, outbound);
    return "trojan://" + uri_encode(outbound.password) + "@" +
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_shadowsocks(outbound) {
    if (as_string(outbound.method) == "" || as_string(outbound.password) == "" ||
        as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let userinfo = base64_encode(as_string(outbound.method) + ":" + as_string(outbound.password));
    return userinfo == "" ? "" :
        "ss://" + userinfo + "@" + host_port(outbound.server, outbound.server_port) + fragment(outbound);
}

function serialize_socks(outbound) {
    if (as_string(outbound.server) == "" || outbound.server_port == null)
        return "";

    let scheme = "socks" + as_string(outbound.version || "5");
    let auth = "";
    if (as_string(outbound.username) != "") {
        auth = uri_encode(outbound.username);
        if (as_string(outbound.password) != "")
            auth += ":" + uri_encode(outbound.password);
        auth += "@";
    }

    return scheme + "://" + auth + host_port(outbound.server, outbound.server_port) + fragment(outbound);
}

function serialize_hysteria2(outbound) {
    let port = hysteria2_server_ports_uri(outbound);
    if (port == "" && outbound.server_port != null)
        port = as_string(outbound.server_port);

    if (as_string(outbound.password) == "" || as_string(outbound.server) == "" || port == "")
        return "";

    let params = [];
    let tls = type(outbound.tls) == "object" ? outbound.tls : null;
    if (tls) {
        add_query(params, "sni", tls.server_name);
        if (tls.insecure === true)
            add_query(params, "insecure", "1");
        if (type(tls.alpn) == "array" && length(tls.alpn) > 0)
            add_query(params, "alpn", join(",", tls.alpn));
    }
    if (type(outbound.obfs) == "object") {
        add_query(params, "obfs", outbound.obfs.type);
        add_query(params, "obfs-password", outbound.obfs.password);
    }

    return "hysteria2://" + uri_encode(outbound.password) + "@" +
        host_port(outbound.server, port) + query_string(params) + fragment(outbound);
}

function serialize_vmess(outbound) {
    if (as_string(outbound.uuid) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";

    let vmess = {
        v: "2",
        ps: as_string(outbound.tag),
        add: as_string(outbound.server),
        port: as_string(outbound.server_port),
        id: as_string(outbound.uuid),
        aid: as_string(outbound.alter_id || 0),
        scy: as_string(outbound.security || "auto"),
        net: "tcp",
        type: "none",
        host: "",
        path: "",
        tls: "",
        sni: ""
    };

    if (type(outbound.tls) == "object" && outbound.tls.enabled !== false) {
        vmess.tls = "tls";
        vmess.sni = as_string(outbound.tls.server_name);
        if (type(outbound.tls.utls) == "object")
            vmess.fp = as_string(outbound.tls.utls.fingerprint);
    }

    if (type(outbound.transport) == "object") {
        vmess.net = as_string(outbound.transport.type || "tcp");
        if (vmess.net == "ws") {
            vmess.path = as_string(outbound.transport.path);
            if (type(outbound.transport.headers) == "object")
                vmess.host = as_string(outbound.transport.headers.Host || outbound.transport.headers.host);
        }
        else if (vmess.net == "grpc") {
            vmess.path = as_string(outbound.transport.service_name);
        }
        else if (vmess.net == "http") {
            vmess.path = as_string(outbound.transport.path);
            if (type(outbound.transport.host) == "array" && length(outbound.transport.host) > 0)
                vmess.host = join(",", outbound.transport.host);
            else
                vmess.host = as_string(outbound.transport.host);
        }
    }

    let encoded = base64_encode(sprintf("%J", vmess));
    return encoded == "" ? "" : "vmess://" + encoded;
}

function serialize_outbound_link(outbound) {
    if (type(outbound) != "object")
        return "";

    let outbound_type = as_string(outbound.type);
    if (outbound_type == "vless")
        return serialize_vless(outbound);
    if (outbound_type == "trojan")
        return serialize_trojan(outbound);
    if (outbound_type == "shadowsocks")
        return serialize_shadowsocks(outbound);
    if (outbound_type == "socks")
        return serialize_socks(outbound);
    if (outbound_type == "hysteria2")
        return serialize_hysteria2(outbound);
    if (outbound_type == "vmess")
        return serialize_vmess(outbound);
    return "";
}

function is_copyable_link(value) {
    value = lc(as_string(value));
    let prefixes = [
        "vless://", "vmess://", "trojan://", "ss://", "ssr://",
        "hysteria2://", "hy2://", "tuic://",
        "socks4://", "socks4a://", "socks5://"
    ];
    for (let prefix in prefixes) {
        if (starts_with(value, prefix))
            return true;
    }
    return false;
}

function populate_subscription_links(subscription) {
    if (type(subscription) != "object" || type(subscription.outbounds) != "array")
        return 0;

    let changed = 0;
    for (let outbound in subscription.outbounds) {
        if (type(outbound) != "object" || is_copyable_link(outbound.share_link))
            continue;

        let link = serialize_outbound_link(outbound);
        if (link == "")
            continue;

        outbound.share_link = link;
        changed++;
    }

    return changed;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function populate_subscription_file(path) {
    path = as_string(path);
    let data = fs.readfile(path);
    if (data == null)
        return false;

    let subscription;
    try {
        subscription = json(data);
    }
    catch (e) {
        return false;
    }

    if (populate_subscription_links(subscription) == 0)
        return true;

    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);
    if (fs.writefile(tmp_path, sprintf("%J\n", subscription)) == null)
        return false;

    system("chmod 600 " + shell_quote(tmp_path) + " >/dev/null 2>&1");
    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        return false;
    }

    return true;
}

function populate_subscription_dir(path) {
    path = as_string(path);
    let ok = true;
    for (let file_path in fs.glob(path + "/*.json"))
        if (!populate_subscription_file(file_path))
            ok = false;

    return ok;
}

return {
    serialize_outbound_link,
    is_copyable_link,
    populate_subscription_links,
    populate_subscription_file,
    populate_subscription_dir
};
