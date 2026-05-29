#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function trim(value) {
    value = as_string(value);
    let start = 0;
    let end = length(value);

    while (start < end) {
        let c = substr(value, start, 1);
        if (c != " " && c != "\t" && c != "\r" && c != "\n")
            break;
        start++;
    }

    while (end > start) {
        let c = substr(value, end - 1, 1);
        if (c != " " && c != "\t" && c != "\r" && c != "\n")
            break;
        end--;
    }

    return substr(value, start, end - start);
}

function first_non_ws_char(value) {
    value = as_string(value);
    for (let i = 0; i < length(value); i++) {
        let c = substr(value, i, 1);
        if (c != " " && c != "\t" && c != "\r" && c != "\n")
            return c;
    }
    return "";
}

function starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function is_supported_share_link(line) {
    return starts_with(line, "ss://") ||
        starts_with(line, "vmess://") ||
        starts_with(line, "vless://") ||
        starts_with(line, "trojan://") ||
        starts_with(line, "hysteria2://") ||
        starts_with(line, "hy2://") ||
        starts_with(line, "socks://") ||
        starts_with(line, "socks4://") ||
        starts_with(line, "socks4a://") ||
        starts_with(line, "socks5://");
}

function split_csv(value) {
    let result = [];
    for (let item in split(as_string(value), ",")) {
        if (item != "")
            push(result, item);
    }
    return result;
}

function is_true(value) {
    if (value == null || value == "")
        return false;
    let normalized = lc(as_string(value));
    return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on";
}

function is_integer_string(value) {
    if (type(value) != "string" || value == "")
        return false;
    for (let i = 0; i < length(value); i++) {
        let code = ord(substr(value, i, 1));
        if (code < 48 || code > 57)
            return false;
    }
    return true;
}

function json_decode_text(text) {
    try {
        return json(as_string(text));
    }
    catch (e) {
        return null;
    }
}

function read_file(path) {
    return fs.readfile(path);
}

function read_json_file(path) {
    let data = read_file(path);
    return data == null ? null : json_decode_text(data);
}

function write_json_file(path, value) {
    return fs.writefile(path, sprintf("%J", value) + "\n");
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function base64_decode(value) {
    value = as_string(value);
    if (index(value, "\n") >= 0 || index(value, "\r") >= 0 || index(value, "\t") >= 0 || index(value, " ") >= 0)
        value = replace(value, /\s+/g, "");
    if (index(value, "-") >= 0)
        value = replace(value, /-/g, "+");
    if (index(value, "_") >= 0)
        value = replace(value, /_/g, "/");
    if (value == "")
        return null;

    let remainder = length(value) % 4;
    if (remainder == 1)
        return null;
    if (remainder > 1) {
        for (let i = 0; i < 4 - remainder; i++)
            value += "=";
    }

    return b64dec(value);
}

function urldecode(value) {
    value = as_string(value);
    if (index(value, "%") < 0 && index(value, "+") < 0)
        return value;

    if (index(value, "+") >= 0)
        value = replace(value, /\+/g, " ");
    if (index(value, "%") < 0)
        return value;
    return replace(value, /%([0-9A-Fa-f][0-9A-Fa-f])/g, function(all, hex_value) {
        return chr(hex(hex_value));
    });
}

let fragment_prefix_decode_cache = {};
let fragment_decode_cache = {};
let query_parse_cache = {};

function urldecode_fragment(value) {
    value = as_string(value);
    if (index(value, "%") < 0 && index(value, "+") < 0)
        return value;
    if (value in fragment_decode_cache)
        return fragment_decode_cache[value];

    let marker = rindex(value, "%23");
    if (marker >= 0) {
        let suffix = substr(value, marker + 3);
        if (is_integer_string(suffix)) {
            let prefix = substr(value, 0, marker + 3);
            if (!(prefix in fragment_prefix_decode_cache))
                fragment_prefix_decode_cache[prefix] = urldecode(prefix);
            let decoded = fragment_prefix_decode_cache[prefix] + suffix;
            fragment_decode_cache[value] = decoded;
            return decoded;
        }
    }

    let decoded = urldecode(value);
    fragment_decode_cache[value] = decoded;
    return decoded;
}

function parse_query(query) {
    let params = {};
    query = as_string(query);
    if (query == "")
        return params;
    if (query in query_parse_cache)
        return query_parse_cache[query];

    for (let pair in split(query, "&")) {
        if (pair == "")
            continue;
        let equals = index(pair, "=");
        let key = equals >= 0 ? substr(pair, 0, equals) : pair;
        let value = equals >= 0 ? substr(pair, equals + 1) : "";
        key = urldecode(key);
        if (key != "")
            params[key] = urldecode(value);
    }

    query_parse_cache[query] = params;
    return params;
}

function parse_host_port(value) {
    value = as_string(value);
    if (length(value) > 0 && substr(value, length(value) - 1) == "/")
        value = substr(value, 0, length(value) - 1);
    if (starts_with(value, "[")) {
        let m = match(value, /^\[([^\]]+)\]:(\d+)$/);
        return m ? [m[1], int(m[2])] : ["", null];
    }

    let colon = rindex(value, ":");
    if (colon < 0)
        return ["", null];

    let host = substr(value, 0, colon);
    let port = substr(value, colon + 1);
    if (!is_integer_string(port))
        return ["", null];
    return [host, int(port)];
}

function parse_url(url) {
    let scheme_pos = index(url, "://");
    if (scheme_pos <= 0)
        return null;

    let scheme = lc(substr(url, 0, scheme_pos));
    let rest = substr(url, scheme_pos + 3);
    let fragment = "";
    let hash_pos = index(rest, "#");
    if (hash_pos >= 0) {
        fragment = urldecode_fragment(substr(rest, hash_pos + 1));
        rest = substr(rest, 0, hash_pos);
    }

    let query = "";
    let question_pos = index(rest, "?");
    if (question_pos >= 0) {
        query = substr(rest, question_pos + 1);
        rest = substr(rest, 0, question_pos);
    }

    let slash_pos = index(rest, "/");
    let authority = slash_pos >= 0 ? substr(rest, 0, slash_pos) : rest;
    let userinfo = "";
    let hostport = authority;
    let at_pos = rindex(authority, "@");
    if (at_pos >= 0) {
        userinfo = urldecode(substr(authority, 0, at_pos));
        hostport = substr(authority, at_pos + 1);
    }

    let host_port = parse_host_port(hostport);
    return {
        scheme: scheme,
        userinfo: userinfo,
        host: host_port[0] || "",
        port: host_port[1],
        query: parse_query(query),
        fragment: fragment
    };
}

function normalize_utls_fingerprint(value) {
    if (value == null || value == "")
        return "";

    let allowed = {
        "": true,
        chrome: true,
        firefox: true,
        edge: true,
        safari: true,
        "360": true,
        ios: true,
        android: true,
        randomized: true,
        randomizedalpn: true,
        randomizednoalpn: true
    };

    value = as_string(value);
    return allowed[value] ? value : "chrome";
}

function add_tls(url, security, default_tls) {
    let query = object_or_empty(url.query);
    let sni = query.sni || query.peer || "";
    let insecure = query.allowInsecure || query.insecure || "";
    let alpn = query.alpn || "";
    let transport = query.type || "";
    if (transport == "xhttp" && alpn == "")
        alpn = "h2,http/1.1";

    let fingerprint = normalize_utls_fingerprint(query.fp || "");
    let public_key = query.pbk || "";
    let short_id = query.sid || "";

    if (security == "reality" && public_key == "")
        return [null, false];
    if ((security == "reality" || public_key != "") && fingerprint == "")
        fingerprint = "chrome";

    let tls_enabled = false;
    if (security == "tls" || security == "xtls" || security == "reality")
        tls_enabled = true;
    else if (security == null || security == "")
        tls_enabled = default_tls || sni != "" || alpn != "" || fingerprint != "" || public_key != "";

    if (!tls_enabled)
        return [null, true];

    let tls = { enabled: true };
    if (sni != "")
        tls.server_name = sni;
    if (is_true(insecure))
        tls.insecure = true;
    if (alpn != "")
        tls.alpn = split_csv(alpn);
    if (fingerprint != "")
        tls.utls = { enabled: true, fingerprint: fingerprint };
    if (security == "reality" || public_key != "") {
        tls.reality = { enabled: true };
        if (public_key != "")
            tls.reality.public_key = public_key;
        if (short_id != "")
            tls.reality.short_id = short_id;
    }

    return [tls, true];
}

function add_transport(url) {
    let query = object_or_empty(url.query);
    let transport = query.type || "";
    if (transport == "" || transport == "tcp")
        return null;

    let path = query.path || "";
    let host = query.host || "";
    let early_data = query.ed || "";
    let grpc_service_name = query.serviceName || "";
    let xhttp_mode = query.mode || "auto";
    let sni = query.sni || "";

    if (xhttp_mode != "auto" && xhttp_mode != "packet-up" && xhttp_mode != "stream-up" && xhttp_mode != "stream-one")
        xhttp_mode = "auto";

    if (transport == "ws") {
        let result = { type: "ws", path: path != "" ? path : "/" };
        if (host != "")
            result.headers = { Host: host };
        if (is_integer_string(early_data))
            result.max_early_data = int(early_data);
        return result;
    }
    if (transport == "grpc") {
        let result = { type: "grpc" };
        if (grpc_service_name != "")
            result.service_name = grpc_service_name;
        return result;
    }
    if (transport == "http" || transport == "h2") {
        let result = { type: "http" };
        if (path != "")
            result.path = path;
        if (host != "")
            result.host = split_csv(host);
        return result;
    }
    if (transport == "httpupgrade") {
        let result = { type: "httpupgrade" };
        if (path != "")
            result.path = path;
        if (host != "")
            result.host = host;
        return result;
    }
    if (transport == "xhttp") {
        if (path == "")
            path = "/";
        if (host == "")
            host = sni;
        let result = {
            type: "xhttp",
            mode: xhttp_mode,
            path: path,
            x_padding_bytes: "100-1000",
            no_grpc_header: false,
            sc_max_each_post_bytes: 1000000,
            sc_min_posts_interval_ms: 30
        };
        if (host != "")
            result.host = host;
        return result;
    }

    return null;
}

function valid_port(port) {
    let port_type = type(port);
    return (port_type == "int" || port_type == "double") && port >= 1 && port <= 65535 && int(port) == port;
}

function process_vless(raw, url) {
    if (url.host == "" || !valid_port(url.port) || url.userinfo == "")
        return null;

    let flow = url.query.flow || "";
    if (flow != "" && flow != "xtls-rprx-vision")
        return null;

    let packet_encoding = url.query.packetEncoding || "";
    if (packet_encoding != "xudp" && packet_encoding != "packetaddr")
        packet_encoding = "";

    let outbound = {
        type: "vless",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: url.port,
        uuid: url.userinfo
    };
    if (flow != "")
        outbound.flow = flow;
    if (packet_encoding != "")
        outbound.packet_encoding = packet_encoding;

    let tls_result = add_tls(url, url.query.security || "", false);
    if (!tls_result[1])
        return null;
    if (tls_result[0])
        outbound.tls = tls_result[0];

    let transport = add_transport(url);
    if (transport)
        outbound.transport = transport;
    return outbound;
}

function process_trojan(raw, url) {
    if (url.host == "" || !valid_port(url.port) || url.userinfo == "")
        return null;

    let outbound = {
        type: "trojan",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: url.port,
        password: url.userinfo
    };

    let tls_result = add_tls(url, url.query.security || "", true);
    if (!tls_result[1])
        return null;
    if (tls_result[0])
        outbound.tls = tls_result[0];

    let transport = add_transport(url);
    if (transport)
        outbound.transport = transport;
    return outbound;
}

function process_socks(raw, url) {
    if (url.host == "" || !valid_port(url.port))
        return null;

    let username = "", password = "";
    if (url.userinfo != "") {
        let colon = index(url.userinfo, ":");
        if (colon >= 0) {
            username = urldecode(substr(url.userinfo, 0, colon));
            password = urldecode(substr(url.userinfo, colon + 1));
            if (username == password)
                password = "";
        }
        else {
            username = urldecode(url.userinfo);
        }
    }

    let outbound = {
        type: "socks",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: url.port
    };
    let version = substr(url.scheme, 5);
    if (version != "")
        outbound.version = version;
    if (username != "")
        outbound.username = username;
    if (password != "")
        outbound.password = password;
    return outbound;
}

function is_shadowsocks_userinfo_format(value) {
    if (type(value) != "string")
        return false;
    let first = index(value, ":");
    if (first <= 0 || first >= length(value) - 1)
        return false;
    let rest = substr(value, first + 1);
    let second = index(rest, ":");
    return second < 0 || index(substr(rest, second + 1), ":") < 0;
}

function process_shadowsocks(raw) {
    if (!starts_with(raw, "ss://"))
        return null;

    let body = substr(raw, 5);
    let fragment = "";
    let hash_pos = index(body, "#");
    if (hash_pos >= 0) {
        fragment = urldecode(substr(body, hash_pos + 1));
        body = substr(body, 0, hash_pos);
    }

    let query = "";
    let question_pos = index(body, "?");
    if (question_pos >= 0) {
        query = substr(body, question_pos + 1);
        body = substr(body, 0, question_pos);
    }

    let userinfo, hostport;
    let at_pos = rindex(body, "@");
    if (at_pos >= 0) {
        userinfo = substr(body, 0, at_pos);
        hostport = substr(body, at_pos + 1);
    }
    else {
        let decoded = base64_decode(body);
        if (!decoded)
            return null;
        at_pos = rindex(decoded, "@");
        if (at_pos < 0)
            return null;
        userinfo = substr(decoded, 0, at_pos);
        hostport = substr(decoded, at_pos + 1);
    }

    userinfo = urldecode(userinfo);
    if (!is_shadowsocks_userinfo_format(userinfo)) {
        let decoded = base64_decode(userinfo);
        if (!decoded)
            return null;
        userinfo = decoded;
    }

    let cred_colon = index(userinfo, ":");
    let host_port = parse_host_port(hostport);
    if (cred_colon <= 0)
        return null;
    let method = substr(userinfo, 0, cred_colon);
    let password = substr(userinfo, cred_colon + 1);
    if (method == "" || method == "ss" || password == "" || host_port[0] == "" || !valid_port(host_port[1]))
        return null;

    let params = parse_query(query);
    let plugin = params.plugin || "";
    let plugin_opts = params["plugin-opts"] || "";
    if (plugin != "" && plugin_opts == "") {
        let parsed_plugin = match(plugin, /^([^;]+);(.*)$/);
        if (parsed_plugin) {
            plugin = parsed_plugin[1];
            plugin_opts = parsed_plugin[2];
        }
    }

    let outbound = {
        type: "shadowsocks",
        tag: fragment != "" ? fragment : (host_port[0] + ":" + host_port[1]),
        share_link: raw,
        server: host_port[0],
        server_port: host_port[1],
        method: method,
        password: password
    };
    if (plugin != "")
        outbound.plugin = plugin;
    if (plugin_opts != "")
        outbound.plugin_opts = plugin_opts;
    return outbound;
}

function process_hysteria2(raw, url) {
    if (url.host == "" || !valid_port(url.port) || url.userinfo == "")
        return null;

    let password = url.userinfo;
    let colon = index(password, ":");
    if (colon >= 0)
        password = substr(password, colon + 1);
    if (password == "")
        return null;

    let tls = { enabled: true };
    if ((url.query.sni || "") != "")
        tls.server_name = url.query.sni;
    if (is_true(url.query.insecure))
        tls.insecure = true;
    if ((url.query.alpn || "") != "")
        tls.alpn = split_csv(url.query.alpn);

    let outbound = {
        type: "hysteria2",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: url.port,
        password: password,
        tls: tls
    };
    if ((url.query.network || "") != "")
        outbound.network = url.query.network;
    if (is_integer_string(url.query.upmbps || ""))
        outbound.up_mbps = int(url.query.upmbps);
    if (is_integer_string(url.query.downmbps || ""))
        outbound.down_mbps = int(url.query.downmbps);
    if ((url.query.obfs || "") != "" && url.query.obfs != "none") {
        outbound.obfs = { type: url.query.obfs };
        if ((url.query["obfs-password"] || "") != "")
            outbound.obfs.password = url.query["obfs-password"];
    }
    return outbound;
}

function string_value(value) {
    return value == null ? "" : as_string(value);
}

function process_vmess_json(raw, decoded) {
    let vmess = json_decode_text(decoded);
    if (type(vmess) != "object")
        return null;

    let server = string_value(vmess.add);
    let port = int(vmess.port || 0);
    let uuid = string_value(vmess.id);
    if (server == "" || !valid_port(port) || uuid == "")
        return null;

    let outbound = {
        type: "vmess",
        tag: string_value(vmess.ps) != "" ? string_value(vmess.ps) : (server + ":" + port),
        share_link: raw,
        server: server,
        server_port: port,
        uuid: uuid,
        security: string_value(vmess.scy) != "" ? string_value(vmess.scy) : "auto"
    };

    let alter_id = int(vmess.aid || 0);
    if (as_string(vmess.aid) != "")
        outbound.alter_id = alter_id;

    if (vmess.tls === true || vmess.tls == "tls" || vmess.tls == "true") {
        let fingerprint = normalize_utls_fingerprint(string_value(vmess.fp));
        let tls = { enabled: true };
        if (string_value(vmess.sni) != "")
            tls.server_name = string_value(vmess.sni);
        if (string_value(vmess.alpn) != "")
            tls.alpn = split_csv(string_value(vmess.alpn));
        if (fingerprint != "")
            tls.utls = { enabled: true, fingerprint: fingerprint };
        outbound.tls = tls;
    }

    let network = string_value(vmess.net);
    if (network == "ws") {
        outbound.transport = {
            type: "ws",
            path: string_value(vmess.path) != "" ? string_value(vmess.path) : "/"
        };
        if (string_value(vmess.host) != "")
            outbound.transport.headers = { Host: string_value(vmess.host) };
    }
    else if (network == "grpc") {
        outbound.transport = { type: "grpc" };
        if (string_value(vmess.path) != "")
            outbound.transport.service_name = string_value(vmess.path);
    }
    else if (network == "http" || network == "h2") {
        outbound.transport = { type: "http" };
        if (string_value(vmess.path) != "")
            outbound.transport.path = string_value(vmess.path);
        if (string_value(vmess.host) != "")
            outbound.transport.host = split_csv(string_value(vmess.host));
    }

    return outbound;
}

function process_vmess(raw) {
    if (!starts_with(raw, "vmess://"))
        return null;

    let encoded = substr(raw, 8);
    let hash_pos = index(encoded, "#");
    if (hash_pos >= 0)
        encoded = substr(encoded, 0, hash_pos);
    let decoded = base64_decode(encoded);
    if (!decoded)
        return null;
    if (index(decoded, "\r") >= 0 || index(decoded, "\n") >= 0)
        decoded = replace(decoded, /[\r\n]/g, "");
    let trimmed = trim(decoded);
    if (substr(trimmed, 0, 1) != "{" || substr(trimmed, length(trimmed) - 1) != "}")
        return null;
    return process_vmess_json(raw, trimmed);
}

function parse_share_link(line) {
    if (starts_with(line, "vmess://"))
        return process_vmess(line);
    if (starts_with(line, "ss://"))
        return process_shadowsocks(line);

    let url = parse_url(line);
    if (!url)
        return null;

    if (url.scheme == "vless")
        return process_vless(line, url);
    if (url.scheme == "trojan")
        return process_trojan(line, url);
    if (url.scheme == "hysteria2" || url.scheme == "hy2")
        return process_hysteria2(line, url);
    if (match(url.scheme, /^socks/))
        return process_socks(line, url);
    return null;
}

function clean_scalar(value) {
    value = trim(value);
    let first = substr(value, 0, 1);
    let last = substr(value, length(value) - 1);
    if (length(value) >= 2 && ((first == "\"" && last == "\"") || (first == "'" && last == "'")))
        return substr(value, 1, length(value) - 2);
    return value;
}

function leading_indent(value) {
    let m = match(as_string(value), /^[ \t]*/);
    return m ? length(m[0]) : 0;
}

function find_top_level_colon(value) {
    let depth = 0, quote = "", escaped = false;
    for (let i = 0; i < length(value); i++) {
        let char = substr(value, i, 1);
        if (quote != "") {
            if (escaped)
                escaped = false;
            else if (char == "\\")
                escaped = true;
            else if (char == quote)
                quote = "";
        }
        else if (char == "\"" || char == "'")
            quote = char;
        else if (char == "{" || char == "[")
            depth++;
        else if (char == "}" || char == "]")
            depth--;
        else if (char == ":" && depth == 0)
            return i;
    }
    return null;
}

function split_top_level(value, separator) {
    let result = [], depth = 0, quote = "", escaped = false, start = 0;
    for (let i = 0; i < length(value); i++) {
        let char = substr(value, i, 1);
        if (quote != "") {
            if (escaped)
                escaped = false;
            else if (char == "\\")
                escaped = true;
            else if (char == quote)
                quote = "";
        }
        else if (char == "\"" || char == "'")
            quote = char;
        else if (char == "{" || char == "[")
            depth++;
        else if (char == "}" || char == "]")
            depth--;
        else if (char == separator && depth == 0) {
            push(result, substr(value, start, i - start));
            start = i + 1;
        }
    }
    push(result, substr(value, start));
    return result;
}

function set_record_field(record, key, value) {
    key = clean_scalar(key);
    value = clean_scalar(value);
    if (key == "")
        return;
    if (record.fields[key] == null)
        push(record.keys, key);
    record.fields[key] = value;
}

function parse_clash_pair(record, part, prefix) {
    part = trim(part);
    let colon = find_top_level_colon(part);
    if (colon == null)
        return;
    let key = clean_scalar(substr(part, 0, colon));
    let value = trim(substr(part, colon + 1));
    if (substr(value, 0, 1) == "{" && substr(value, length(value) - 1) == "}")
        parse_clash_map(record, value, prefix + key + ".");
    else
        set_record_field(record, prefix + key, value);
}

function parse_clash_map(record, value, prefix) {
    value = trim(value);
    if (substr(value, 0, 1) == "{")
        value = substr(value, 1);
    if (substr(value, length(value) - 1) == "}")
        value = substr(value, 0, length(value) - 1);

    for (let part in split_top_level(value, ","))
        parse_clash_pair(record, part, prefix);
}

function empty_clash_record() {
    return {
        fields: {},
        keys: [],
        context: "",
        context_indent: -1
    };
}

function clash_record_has_fields(record) {
    return length(record.keys) > 0;
}

function emit_clash_record(records, record) {
    if (!clash_record_has_fields(record))
        return empty_clash_record();

    let item = {};
    for (let key in record.keys) {
        if (record.fields[key] != null)
            item[key] = record.fields[key];
    }
    push(records, item);
    return empty_clash_record();
}

let clash_nested_keys = {
    "ws-opts": true,
    "grpc-opts": true,
    "reality-opts": true,
    "obfs-opts": true,
    headers: true
};

function parse_clash_block_line(record, line) {
    let indent = leading_indent(line);
    let text = trim(line);
    if (text == "")
        return;

    let colon = index(text, ":");
    if (colon < 0)
        return;

    let key = clean_scalar(substr(text, 0, colon));
    let value = trim(substr(text, colon + 1));

    if (record.context != "" && indent <= record.context_indent) {
        record.context = "";
        record.context_indent = -1;
    }

    if (value == "") {
        if (clash_nested_keys[key]) {
            if (record.context != "" && indent > record.context_indent)
                record.context = record.context + "." + key;
            else
                record.context = key;
            record.context_indent = indent;
        }
        return;
    }

    let full_key = key;
    if (record.context != "" && indent > record.context_indent)
        full_key = record.context + "." + key;
    set_record_field(record, full_key, value);
}

function is_clash_proxies_header(line) {
    let text = trim(line);
    return text == "proxies:" || match(text, /^proxies:\s*#/);
}

function clash_yaml_records(input_file) {
    let data = read_file(input_file);
    if (data == null)
        return [];

    let records = [];
    let record = empty_clash_record();
    let in_proxies = false;

    for (let line in split(data, "\n")) {
        line = replace(line, /\r$/g, "");
        let proxies_header = is_clash_proxies_header(line);

        if (in_proxies && match(line, /^[^ \t]/) && !proxies_header && !match(line, /^-[ \t]/)) {
            record = emit_clash_record(records, record);
            in_proxies = false;
        }

        if (proxies_header) {
            record = emit_clash_record(records, record);
            in_proxies = true;
        }
        else if (in_proxies) {
            if (match(line, /^[ \t]*-[ \t]*\{/)) {
                record = emit_clash_record(records, record);
                record = empty_clash_record();
                let map_value = replace(line, /^[ \t]*-[ \t]*/g, "");
                parse_clash_map(record, map_value, "");
                record = emit_clash_record(records, record);
            }
            else if (match(line, /^[ \t]*-[ \t]*/)) {
                record = emit_clash_record(records, record);
                record = empty_clash_record();
                let rest = replace(line, /^[ \t]*-[ \t]*/g, "");
                if (trim(rest) != "")
                    parse_clash_block_line(record, rest);
            }
            else if (clash_record_has_fields(record)) {
                parse_clash_block_line(record, line);
            }
        }
    }

    emit_clash_record(records, record);
    return records;
}

function normalize_packet_encoding(value) {
    value = as_string(value);
    return value == "xudp" || value == "packetaddr" ? value : "";
}

function clash_vless_flow_supported(flow) {
    return flow == null || flow == "" || flow == "xtls-rprx-vision";
}

function normalized_clash_alpn(value) {
    return replace(replace(replace(as_string(value), /^\[/g, ""), /\]$/g, ""), /\s+/g, "");
}

function add_clash_tls(outbound, options) {
    let enabled = options.always || is_true(options.tls) || options.sni != "" ||
        options.alpn != "" || options.fingerprint != "" || options.reality_public_key != "";
    if (!enabled)
        return;

    let tls = { enabled: true };
    if (options.sni != "")
        tls.server_name = options.sni;
    if (is_true(options.skip_verify))
        tls.insecure = true;
    if (options.alpn != "")
        tls.alpn = split_csv(options.alpn);

    if (options.reality_public_key != "") {
        tls.utls = {
            enabled: true,
            fingerprint: options.fingerprint != "" ? options.fingerprint : "chrome"
        };
        tls.reality = { enabled: true, public_key: options.reality_public_key };
        if (options.reality_short_id != "")
            tls.reality.short_id = options.reality_short_id;
    }
    else if (options.fingerprint != "") {
        tls.utls = { enabled: true, fingerprint: options.fingerprint };
    }

    outbound.tls = tls;
}

function add_clash_transport(outbound, options) {
    if (options.network == "ws") {
        outbound.transport = {
            type: "ws",
            path: options.ws_path != "" ? options.ws_path : "/"
        };
        if (options.ws_host != "")
            outbound.transport.headers = { Host: options.ws_host };
    }
    else if (options.network == "grpc") {
        outbound.transport = { type: "grpc" };
        if (options.grpc_service_name != "")
            outbound.transport.service_name = options.grpc_service_name;
    }
}

function parse_clash_record(record) {
    let proxy_type = lc(as_string(record.type));
    let name = as_string(record.name);
    let server = as_string(record.server);
    let port = int(record.port || 0);
    if (name == "")
        name = server + ":" + as_string(record.port);
    if (proxy_type == "" || server == "" || !valid_port(port))
        return null;

    let options = {
        tls: as_string(record.tls),
        skip_verify: as_string(record["skip-cert-verify"]),
        sni: as_string(record.sni || record.servername),
        network: lc(as_string(record.network)),
        ws_path: as_string(record["ws-opts.path"]),
        ws_host: as_string(record["ws-opts.headers.Host"]),
        grpc_service_name: as_string(record["grpc-opts.grpc-service-name"]),
        reality_public_key: as_string(record["reality-opts.public-key"]),
        reality_short_id: as_string(record["reality-opts.short-id"]),
        alpn: normalized_clash_alpn(record.alpn || ""),
        fingerprint: normalize_utls_fingerprint(as_string(record["client-fingerprint"] || record.fingerprint))
    };

    if (proxy_type == "ss" || proxy_type == "shadowsocks") {
        let method = as_string(record.cipher);
        let password = as_string(record.password);
        if (method == "" || method == "ss" || password == "")
            return null;
        return { type: "shadowsocks", tag: name, server: server, server_port: port, method: method, password: password };
    }
    if (proxy_type == "vmess") {
        let uuid = as_string(record.uuid);
        if (uuid == "")
            return null;
        let outbound = {
            type: "vmess",
            tag: name,
            server: server,
            server_port: port,
            uuid: uuid,
            security: as_string(record.cipher) != "" ? as_string(record.cipher) : "auto"
        };
        if (as_string(record.alterId || record["alter-id"]) != "")
            outbound.alter_id = int(record.alterId || record["alter-id"]);
        add_clash_tls(outbound, options);
        add_clash_transport(outbound, options);
        return outbound;
    }
    if (proxy_type == "vless") {
        let uuid = as_string(record.uuid);
        let flow = as_string(record.flow);
        let packet_encoding = normalize_packet_encoding(record["packet-encoding"] || record.packetEncoding || "");
        if (uuid == "" || !clash_vless_flow_supported(flow))
            return null;
        let outbound = { type: "vless", tag: name, server: server, server_port: port, uuid: uuid };
        if (flow != "")
            outbound.flow = flow;
        if (packet_encoding != "")
            outbound.packet_encoding = packet_encoding;
        add_clash_tls(outbound, options);
        add_clash_transport(outbound, options);
        return outbound;
    }
    if (proxy_type == "trojan") {
        let password = as_string(record.password);
        if (password == "")
            return null;
        let outbound = { type: "trojan", tag: name, server: server, server_port: port, password: password };
        options.always = true;
        add_clash_tls(outbound, options);
        add_clash_transport(outbound, options);
        return outbound;
    }
    if (proxy_type == "hysteria2" || proxy_type == "hy2") {
        let password = as_string(record.password);
        if (password == "")
            return null;
        let outbound = { type: "hysteria2", tag: name, server: server, server_port: port, password: password, tls: { enabled: true } };
        if (options.sni != "")
            outbound.tls.server_name = options.sni;
        if (is_true(options.skip_verify))
            outbound.tls.insecure = true;
        if (options.alpn != "")
            outbound.tls.alpn = split_csv(options.alpn);
        let obfs = as_string(record.obfs);
        let obfs_password = as_string(record["obfs-password"] || record["obfs-opts.password"]);
        if (obfs != "" && obfs != "none") {
            outbound.obfs = { type: obfs };
            if (obfs_password != "")
                outbound.obfs.password = obfs_password;
        }
        return outbound;
    }
    if (proxy_type == "socks5" || proxy_type == "socks") {
        let outbound = { type: "socks", tag: name, server: server, server_port: port, version: "5" };
        if (as_string(record.username) != "")
            outbound.username = as_string(record.username);
        if (as_string(record.password) != "")
            outbound.password = as_string(record.password);
        return outbound;
    }

    return null;
}

function normalize_clash_yaml(input_file, output_file) {
    let outbounds = [];
    let skipped = 0;

    for (let record in clash_yaml_records(input_file)) {
        let outbound = parse_clash_record(record);
        if (outbound)
            push(outbounds, outbound);
        else
            skipped++;
    }

    if (length(outbounds) == 0) {
        fs.unlink(output_file);
        return false;
    }

    return write_json_file(output_file, {
        version: 1,
        format: "clash-yaml",
        skipped: skipped,
        outbounds: outbounds
    });
}

function normalize_uri_list_data(data, output_file) {
    data = as_string(data);
    if (index(data, "\r") >= 0)
        data = replace(data, /\r/g, "");

    let output = fs.open(output_file, "w");
    if (!output)
        return false;

    let added = 0;
    let skipped = 0;
    output.write("{\"version\":1,\"format\":\"uri-list\",\"outbounds\":[");

    for (let line in split(data, "\n")) {
        if (index(line, "\r") >= 0)
            line = replace(line, /\r/g, "");
        line = trim(line);
        if (line != "" && !starts_with(line, "#")) {
            let outbound = parse_share_link(line);
            if (outbound) {
                if (added > 0)
                    output.write(",");
                output.write(sprintf("%J", outbound));
                added++;
            }
            else {
                skipped++;
            }
        }
    }

    output.write("],\"skipped\":" + skipped + "}\n");
    output.close();

    if (added == 0) {
        fs.unlink(output_file);
        return false;
    }
    return true;
}

function normalize_uri_list(input_file, output_file) {
    return normalize_uri_list_file(input_file, output_file, false);
}

let metadata_allowed_keys = {
    "profile-title": true,
    "subscription-userinfo": true,
    "profile-web-page-url": true,
    "support-url": true,
    "announce": true,
    "announce-url": true,
    "subscription-refill-date": true,
    "content-disposition": true
};

function is_metadata_preamble_line(line) {
    let trimmed = trim(line);
    let m = match(trimmed, /^(#|\/\/)[ \t]*([A-Za-z0-9][A-Za-z0-9_-]*)[ \t]*:/);
    return m && metadata_allowed_keys[lc(m[2])];
}

function normalize_uri_list_stream(input, output_file, strip_metadata) {
    let output = fs.open(output_file, "w");
    if (!output)
        return false;

    let added = 0;
    let skipped = 0;
    let line_no = 0;
    output.write("{\"version\":1,\"format\":\"uri-list\",\"outbounds\":[");

    while (true) {
        let line = input.read("line");
        if (line == null)
            break;
        line_no++;
        line = trim(line);
        if (strip_metadata && line_no <= 20 && is_metadata_preamble_line(line))
            continue;
        if (line != "" && !starts_with(line, "#")) {
            let outbound = parse_share_link(line);
            if (outbound) {
                if (added > 0)
                    output.write(",");
                output.write(sprintf("%J", outbound));
                added++;
            }
            else {
                skipped++;
            }
        }
    }

    output.write("],\"skipped\":" + skipped + "}\n");
    output.close();

    if (added == 0) {
        fs.unlink(output_file);
        return false;
    }
    return true;
}

function file_looks_like_uri_list(input_file) {
    let input = fs.open(input_file, "r");
    if (!input)
        return false;

    let line_no = 0;
    while (line_no < 200) {
        let line = input.read("line");
        if (line == null)
            break;
        line_no++;
        line = trim(line);
        if (line == "" || starts_with(line, "#") || is_metadata_preamble_line(line))
            continue;
        if (is_supported_share_link(line)) {
            input.close();
            return true;
        }
        if (substr(line, 0, 1) == "{" || substr(line, 0, 1) == "[" || index(line, "proxies:") >= 0) {
            input.close();
            return false;
        }
    }

    input.close();
    return false;
}

function normalize_uri_list_file(input_file, output_file, strip_metadata) {
    let input = fs.open(input_file, "r");
    if (!input)
        return false;
    let ok = normalize_uri_list_stream(input, output_file, strip_metadata);
    input.close();
    return ok;
}

function strip_metadata_preamble_data(data) {
    data = as_string(data);
    let offset = 0;
    let changed = false;

    for (let line_no = 1; line_no <= 20 && offset <= length(data); line_no++) {
        let rest = substr(data, offset);
        let newline_pos = index(rest, "\n");
        let line = newline_pos >= 0 ? substr(rest, 0, newline_pos) : rest;
        if (is_metadata_preamble_line(line)) {
            changed = true;
            break;
        }
        if (newline_pos < 0)
            break;
        offset += newline_pos + 1;
    }

    if (!changed)
        return data;

    let result = [];
    let line_no = 0;

    for (let line in split(data, "\n")) {
        line_no++;
        let text = replace(line, /\r$/g, "");
        if (line_no <= 20) {
            if (is_metadata_preamble_line(text))
                continue;
        }
        push(result, text);
    }

    return join("\n", result);
}

function content_has_share_links(data) {
    for (let line in split(data, "\n")) {
        if (match(line, /^[ \t]*(ss|vmess|vless|trojan|hysteria2|hy2|socks|socks4|socks4a|socks5):\/\//))
            return true;
    }
    return false;
}

function content_is_clash_yaml(data) {
    for (let line in split(data, "\n")) {
        if (match(line, /^[ \t]*proxies:[ \t]*(#.*)?$/))
            return true;
    }
    return false;
}

function normalize_sing_box_json_value(value, output_file) {
    let candidates = [];
    if (type(value) == "object" && type(value.outbounds) == "array")
        candidates = value.outbounds;
    else if (type(value) == "array")
        candidates = value;
    else if (type(value) == "object" && type(value.type) == "string")
        candidates = [value];

    let outbounds = [];
    for (let outbound in candidates) {
        if (type(outbound) == "object")
            push(outbounds, outbound);
    }

    if (length(outbounds) == 0) {
        fs.unlink(output_file);
        return false;
    }

    return write_json_file(output_file, {
        version: 1,
        format: "sing-box-json",
        outbounds: outbounds
    });
}

function temp_path(prefix) {
    let stamp = clock();
    return sprintf("/tmp/%s.%d.%d", prefix, stamp[0], stamp[1]);
}

function normalize_content_data(data, output_file, depth) {
    data = as_string(data);
    if (index(data, "\r") >= 0)
        data = replace(data, /\r/g, "");
    data = strip_metadata_preamble_data(data);

    let first = first_non_ws_char(data);
    if (first == "{" || first == "[") {
        let decoded_json = json_decode_text(data);
        if (decoded_json != null)
            return normalize_sing_box_json_value(decoded_json, output_file);
    }

    if (index(data, "proxies:") >= 0 && content_is_clash_yaml(data)) {
        let tmp = temp_path("podkop-subscription-clash");
        if (!fs.writefile(tmp, data))
            return false;
        let ok = normalize_clash_yaml(tmp, output_file);
        fs.unlink(tmp);
        return ok;
    }

    if (index(data, "://") >= 0) {
        if (normalize_uri_list_data(data, output_file))
            return true;
    }

    if (depth < 1) {
        let compact = replace(data, /[\r\n\t ]/g, "");
        let decoded = base64_decode(compact);
        if (decoded != null && decoded != "")
            return normalize_content_data(decoded, output_file, depth + 1);
    }

    return false;
}

function normalize_content_file(input_file, output_file) {
    if (file_looks_like_uri_list(input_file))
        return normalize_uri_list_file(input_file, output_file, true);

    let data = read_file(input_file);
    return data == null ? false : normalize_content_data(data, output_file, 0);
}

let mode = ARGV[0];
let ok = false;

if (mode == "normalize-uri-list")
    ok = normalize_uri_list(ARGV[1], ARGV[2]);
else if (mode == "normalize-clash-yaml")
    ok = normalize_clash_yaml(ARGV[1], ARGV[2]);
else if (mode == "normalize-content")
    ok = normalize_content_file(ARGV[1], ARGV[2]);
else if (ARGV[0] && ARGV[1])
    ok = normalize_uri_list(ARGV[0], ARGV[1]);
else {
    warn("Usage: subscription_parser.uc normalize-uri-list <input> <output>\n");
    warn("       subscription_parser.uc normalize-clash-yaml <input> <output>\n");
    warn("       subscription_parser.uc normalize-content <input> <output>\n");
    exit(2);
}

if (!ok)
    exit(1);
