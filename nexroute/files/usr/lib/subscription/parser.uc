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

function tls_alpn_for_transport(alpn, transport) {
    transport = lc(as_string(transport));
    if (transport == "xhttp" && length(alpn) == 0)
        return ["h2", "http/1.1"];
    if ((transport == "ws" || transport == "httpupgrade") && length(alpn) > 0)
        return ["http/1.1"];
    return alpn;
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

function xhttp_value_present(value) {
    return value != null && as_string(value) != "";
}

function xhttp_object_arg(value) {
    if (type(value) == "object")
        return value;

    try {
        let parsed = json(as_string(value));
        return type(parsed) == "object" ? parsed : {};
    }
    catch (e) {
        return {};
    }
}

function xhttp_copy_known_settings(target, source) {
    if (type(source) != "object")
        return;

    for (let key in [
        "xPaddingBytes",
        "x_padding_bytes",
        "noGRPCHeader",
        "no_grpc_header",
        "scMaxEachPostBytes",
        "sc_max_each_post_bytes",
        "scMinPostsIntervalMs",
        "sc_min_posts_interval_ms",
        "scStreamUpServerSecs",
        "sc_stream_up_server_secs",
        "xmux"
    ]) {
        if (xhttp_value_present(source[key]))
            target[key] = source[key];
    }
}

function xhttp_merge_extra_settings(target, value) {
    let extra = xhttp_object_arg(value);
    if (type(extra) != "object")
        return;

    xhttp_copy_known_settings(target, extra);

    let xhttp_settings = xhttp_object_arg(extra.xhttpSettings);
    xhttp_copy_known_settings(target, xhttp_settings);
    xhttp_copy_known_settings(target, xhttp_object_arg(xhttp_settings.extra));

    let download_settings = xhttp_object_arg(extra.downloadSettings);
    let download_xhttp_settings = xhttp_object_arg(download_settings.xhttpSettings);
    xhttp_copy_known_settings(target, download_xhttp_settings);
    xhttp_copy_known_settings(target, xhttp_object_arg(download_xhttp_settings.extra));
}

function xhttp_extra_settings(query) {
    let result = {};
    query = type(query) == "object" ? query : {};
    xhttp_merge_extra_settings(result, query.extra);
    return result;
}

function xhttp_setting_value(query, extra_settings, camel_key, snake_key) {
    query = type(query) == "object" ? query : {};
    extra_settings = type(extra_settings) == "object" ? extra_settings : {};
    for (let value in [query[camel_key], query[snake_key], extra_settings[camel_key], extra_settings[snake_key]]) {
        if (xhttp_value_present(value))
            return value;
    }
    return null;
}

function xhttp_non_negative_integer_value(value) {
    if (type(value) == "int" || type(value) == "double") {
        let number = int(value);
        return number == value && number >= 0 ? number : null;
    }

    value = trim(as_string(value));
    if (!is_integer_string(value))
        return null;

    return int(value, 10);
}

function xhttp_positive_integer_value(value) {
    let number = xhttp_non_negative_integer_value(value);
    return number != null && number > 0 ? number : null;
}

function xhttp_range_value(value, positive) {
    if (!xhttp_value_present(value))
        return null;

    if (type(value) == "object") {
        let from = positive ? xhttp_positive_integer_value(value.from) : xhttp_non_negative_integer_value(value.from);
        let to = positive ? xhttp_positive_integer_value(value.to) : xhttp_non_negative_integer_value(value.to);
        return from != null && to != null && from <= to ? { from, to } : null;
    }

    let number = positive ? xhttp_positive_integer_value(value) : xhttp_non_negative_integer_value(value);
    if (number != null)
        return number;

    value = trim(as_string(value));
    let dash = index(value, "-");
    if (dash < 0 || index(substr(value, dash + 1), "-") >= 0)
        return null;

    let from = positive ? xhttp_positive_integer_value(substr(value, 0, dash)) : xhttp_non_negative_integer_value(substr(value, 0, dash));
    let to = positive ? xhttp_positive_integer_value(substr(value, dash + 1)) : xhttp_non_negative_integer_value(substr(value, dash + 1));
    return from != null && to != null && from <= to ? from + "-" + to : null;
}

function xhttp_optional_range(object, key, value) {
    let normalized = xhttp_range_value(value, false);
    if (normalized != null)
        object[key] = normalized;
}

function xhttp_optional_positive_range(object, key, value) {
    let normalized = xhttp_range_value(value, true);
    if (normalized != null)
        object[key] = normalized;
}

function xhttp_positive_range_or_default(value, default_value) {
    let normalized = xhttp_range_value(value, true);
    return normalized != null ? normalized : default_value;
}

function xhttp_present_positive_range_or_default(value, default_value) {
    if (!xhttp_value_present(value))
        return null;

    return xhttp_positive_range_or_default(value, default_value);
}

function xhttp_optional_bool(object, key, value) {
    if (xhttp_value_present(value))
        object[key] = is_true(value);
}

function xhttp_object_setting_value(source, camel_key, snake_key) {
    source = type(source) == "object" ? source : {};
    for (let value in [source[camel_key], source[snake_key]]) {
        if (xhttp_value_present(value))
            return value;
    }
    return null;
}

function xhttp_optional_xmux_range(object, key, value) {
    let normalized = xhttp_range_value(value, false);
    if (normalized != null)
        object[key] = normalized;
}

function xhttp_optional_xmux_integer(object, key, value) {
    let normalized = xhttp_non_negative_integer_value(value);
    if (normalized != null)
        object[key] = normalized;
}

function xhttp_normalize_xmux(value) {
    let source = xhttp_object_arg(value);
    if (type(source) != "object")
        return null;

    let result = {};
    xhttp_optional_xmux_range(result, "max_concurrency", xhttp_object_setting_value(source, "maxConcurrency", "max_concurrency"));
    xhttp_optional_xmux_range(result, "max_connections", xhttp_object_setting_value(source, "maxConnections", "max_connections"));
    xhttp_optional_xmux_range(result, "c_max_reuse_times", xhttp_object_setting_value(source, "cMaxReuseTimes", "c_max_reuse_times"));
    xhttp_optional_xmux_range(result, "h_max_request_times", xhttp_object_setting_value(source, "hMaxRequestTimes", "h_max_request_times"));
    xhttp_optional_xmux_range(result, "h_max_reusable_secs", xhttp_object_setting_value(source, "hMaxReusableSecs", "h_max_reusable_secs"));
    xhttp_optional_xmux_integer(result, "h_keep_alive_period", xhttp_object_setting_value(source, "hKeepAlivePeriod", "h_keep_alive_period"));

    return length(keys(result)) > 0 ? result : null;
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

function reality_public_key_valid(value) {
    return match(as_string(value), /^[A-Za-z0-9_-]{43}$/) != null;
}

function validate_subscription(path) {
    let value = read_json_file(path);
    if (type(value) != "object" || type(value.outbounds) != "array" || length(value.outbounds) == 0)
        return false;

    for (let outbound in value.outbounds) {
        let tls = type(outbound) == "object" && type(outbound.tls) == "object" ? outbound.tls : {};
        let reality = tls.reality;
        if (type(reality) == "object" && reality.enabled !== false && !reality_public_key_valid(reality.public_key))
            return false;
    }

    return true;
}

function write_json_file(path, value) {
    return fs.writefile(path, sprintf("%J", value) + "\n");
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function canonical_runtime_value(value) {
    if (type(value) == "array") {
        let result = [];
        for (let item in value)
            push(result, canonical_runtime_value(item));
        return result;
    }

    if (type(value) == "object") {
        let result = {};
        let names = keys(value);
        sort(names, function(a, b) {
            return a < b ? -1 : (a > b ? 1 : 0);
        });

        for (let name in names) {
            if (name == "share_link")
                continue;
            result[name] = canonical_runtime_value(value[name]);
        }

        return result;
    }

    return value;
}

function runtime_outbounds_signature(path) {
    let subscription = read_json_file(path);
    if (type(subscription) != "object" || type(subscription.outbounds) != "array")
        return null;

    return canonical_runtime_value(subscription.outbounds);
}

function runtime_outbounds_equal(left_path, right_path) {
    let left = runtime_outbounds_signature(left_path);
    let right = runtime_outbounds_signature(right_path);

    if (left == null || right == null)
        return false;

    return sprintf("%J", left) == sprintf("%J", right);
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

function subscription_url_fragment(url) {
    url = as_string(url);
    let marker = index(url, "#");
    if (marker < 0) {
        print("\n");
        return true;
    }

    let fragment = substr(url, marker + 1);
    if (index(fragment, "%") >= 0 || index(fragment, "+") >= 0)
        print(urldecode_fragment(fragment));
    else
        print(fragment, "\n");
    return true;
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

function parse_port_value(value) {
    value = as_string(value);
    return is_integer_string(value) ? int(value, 10) : value;
}

function parse_host_port(value) {
    value = as_string(value);
    if (length(value) > 0 && substr(value, length(value) - 1) == "/")
        value = substr(value, 0, length(value) - 1);
    if (starts_with(value, "[")) {
        let m = match(value, /^\[([^\]]+)\]:(.+)$/);
        return m ? [m[1], parse_port_value(m[2])] : ["", null];
    }

    let colon = rindex(value, ":");
    if (colon < 0)
        return ["", null];

    let host = substr(value, 0, colon);
    let port = substr(value, colon + 1);
    return [host, parse_port_value(port)];
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
    if (value == "randomizedalpn" || value == "randomizednoalpn")
        return "randomized";

    return allowed[value] ? value : "chrome";
}

function add_tls(url, security, default_tls) {
    let query = object_or_empty(url.query);
    let sni = query.sni || query.peer || "";
    let insecure = query.allowInsecure || query.insecure || "";
    let transport = query.type || "";
    let alpn = tls_alpn_for_transport(split_csv(query.alpn || ""), transport);

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
        tls_enabled = default_tls || sni != "" || length(alpn) > 0 || fingerprint != "" || public_key != "";

    if (!tls_enabled)
        return [null, true];

    let tls = { enabled: true };
    if (sni != "")
        tls.server_name = sni;
    if (is_true(insecure))
        tls.insecure = true;
    if (length(alpn) > 0)
        tls.alpn = alpn;
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

        let extra_settings = xhttp_extra_settings(query);
        xhttp_optional_positive_range(result, "x_padding_bytes", xhttp_setting_value(query, extra_settings, "xPaddingBytes", "x_padding_bytes"));
        xhttp_optional_bool(result, "no_grpc_header", xhttp_setting_value(query, extra_settings, "noGRPCHeader", "no_grpc_header"));
        xhttp_optional_positive_range(result, "sc_max_each_post_bytes", xhttp_setting_value(query, extra_settings, "scMaxEachPostBytes", "sc_max_each_post_bytes"));
        xhttp_optional_range(result, "sc_min_posts_interval_ms", xhttp_setting_value(query, extra_settings, "scMinPostsIntervalMs", "sc_min_posts_interval_ms"));
        xhttp_optional_range(result, "sc_stream_up_server_secs", xhttp_setting_value(query, extra_settings, "scStreamUpServerSecs", "sc_stream_up_server_secs"));
        let xmux = xhttp_normalize_xmux(xhttp_setting_value(query, extra_settings, "xmux", "xmux"));
        if (xmux)
            result.xmux = xmux;
        return result;
    }

    return null;
}

function valid_port(port) {
    let port_type = type(port);
    return (port_type == "int" || port_type == "double") && port >= 1 && port <= 65535 && int(port) == port;
}

function normalize_port_number(value) {
    value = trim(value);
    if (!is_integer_string(value))
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
        entry = trim(entry);
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

function normalize_vless_encryption(value) {
    value = as_string(value);
    return value != "" && value != "none" ? value : "";
}

function vless_flow_supported(flow) {
    return flow == null || flow == "" || flow == "xtls-rprx-vision";
}

function process_vless(raw, url) {
    if (url.host == "" || !valid_port(url.port) || url.userinfo == "")
        return null;

    let flow = url.query.flow || "";
    if (!vless_flow_supported(flow))
        return null;

    let packet_encoding = url.query.packetEncoding || "";
    if (packet_encoding != "xudp" && packet_encoding != "packetaddr")
        packet_encoding = "";
    let encryption = normalize_vless_encryption(url.query.encryption || "");

    let outbound = {
        type: "vless",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + url.port),
        share_link: raw,
        server: url.host,
        server_port: url.port,
        uuid: url.userinfo
    };
    if (encryption != "")
        outbound.encryption = encryption;
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
    let mport = trim(as_string(url.query.mport || ""));
    let port_value = mport != "" ? mport : url.port;
    let server_ports = parse_hysteria2_server_ports(port_value);
    let server_port = normalize_port_number(as_string(port_value));
    if (url.host == "" || (server_ports == null && server_port == "") || url.userinfo == "")
        return null;

    let password = url.userinfo;
    if (password == "")
        return null;

    let tls = { enabled: true };
    if ((url.query.sni || "") != "")
        tls.server_name = url.query.sni;
    if (is_true(url.query.allowInsecure || url.query.insecure))
        tls.insecure = true;
    if ((url.query.alpn || "") != "")
        tls.alpn = split_csv(url.query.alpn);

    let outbound = {
        type: "hysteria2",
        tag: url.fragment != "" ? url.fragment : (url.host + ":" + as_string(port_value)),
        share_link: raw,
        server: url.host,
        password: password,
        tls: tls
    };
    if (server_ports != null)
        outbound.server_ports = server_ports;
    else
        outbound.server_port = int(server_port, 10);

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

    let network = string_value(vmess.net);
    if (vmess.tls === true || vmess.tls == "tls" || vmess.tls == "true") {
        let fingerprint = normalize_utls_fingerprint(string_value(vmess.fp));
        let tls = { enabled: true };
        if (string_value(vmess.sni) != "")
            tls.server_name = string_value(vmess.sni);
        let alpn = tls_alpn_for_transport(split_csv(string_value(vmess.alpn)), network);
        if (length(alpn) > 0)
            tls.alpn = alpn;
        if (fingerprint != "")
            tls.utls = { enabled: true, fingerprint: fingerprint };
        outbound.tls = tls;
    }

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

function share_link_outbound(raw, tag) {
    let outbound = parse_share_link(raw);
    if (type(outbound) != "object")
        return false;

    outbound.tag = as_string(tag);
    delete outbound.share_link;
    delete outbound.remark;
    write_json(outbound);
    return true;
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

let parse_clash_map;

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

parse_clash_map = function(record, value, prefix) {
    value = trim(value);
    if (substr(value, 0, 1) == "{")
        value = substr(value, 1);
    if (substr(value, length(value) - 1) == "}")
        value = substr(value, 0, length(value) - 1);

    for (let part in split_top_level(value, ","))
        parse_clash_pair(record, part, prefix);
};

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

function normalized_clash_alpn(value) {
    return replace(replace(replace(as_string(value), /^\[/g, ""), /\]$/g, ""), /\s+/g, "");
}

function add_clash_tls(outbound, options) {
    let enabled = options.always || is_true(options.tls) || options.sni != "" ||
        length(tls_alpn_for_transport(split_csv(options.alpn), options.network)) > 0 ||
        options.fingerprint != "" || options.reality_public_key != "";
    if (!enabled)
        return;

    let tls = { enabled: true };
    if (options.sni != "")
        tls.server_name = options.sni;
    if (is_true(options.skip_verify))
        tls.insecure = true;
    let alpn = tls_alpn_for_transport(split_csv(options.alpn), options.network);
    if (length(alpn) > 0)
        tls.alpn = alpn;

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
        let encryption = normalize_vless_encryption(record.encryption || "");
        if (uuid == "" || !vless_flow_supported(flow))
            return null;
        let outbound = { type: "vless", tag: name, server: server, server_port: port, uuid: uuid };
        if (encryption != "")
            outbound.encryption = encryption;
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

function metadata_new_store() {
    return {
        values: {},
        seen: {},
        order: []
    };
}

function write_metadata_compact_json(store) {
    print("{");
    for (let i = 0; i < length(store.order); i++) {
        let key = store.order[i];
        if (i > 0)
            print(",");
        print(sprintf("%J", key), ":", sprintf("%J", store.values[key]));
    }
    print("}\n");
}

function add_metadata_entry(store, key, value) {
    key = lc(trim(key));
    value = replace(trim(value), /\r/g, "");
    if (!metadata_allowed_keys[key] || value == "")
        return;

    if (!store.seen[key]) {
        push(store.order, key);
        store.seen[key] = true;
    }
    store.values[key] = value;
}

function parse_metadata_line(store, line) {
    line = trim(line);
    let colon = index(line, ":");
    if (colon <= 0)
        return;

    add_metadata_entry(store, substr(line, 0, colon), substr(line, colon + 1));
}

function metadata_headers_store(input_file) {
    let data = read_file(input_file);
    let store = metadata_new_store();

    if (data != null) {
        for (let line in split(data, "\n"))
            parse_metadata_line(store, line);
    }

    return store;
}

function metadata_headers_json(input_file) {
    write_metadata_compact_json(metadata_headers_store(input_file));
    return true;
}

function metadata_body_store_from_data(data) {
    let store = metadata_new_store();
    let line_no = 0;

    if (data != null) {
        for (let line in split(data, "\n")) {
            line_no++;
            if (line_no > 20)
                break;

            line = trim(line);
            if (starts_with(line, "#"))
                line = replace(line, /^#[ \t]*/g, "");
            else if (starts_with(line, "//"))
                line = replace(line, /^\/\/[ \t]*/g, "");
            else
                continue;

            parse_metadata_line(store, line);
        }
    }

    return store;
}

function metadata_body_store(input_file) {
    return metadata_body_store_from_data(read_file(input_file));
}

function metadata_body_store_with_base64_fallback(input_file) {
    let store = metadata_body_store(input_file);
    if (length(store.order) > 0)
        return store;

    let data = read_file(input_file);
    if (data == null)
        return store;

    let decoded = base64_decode(replace(as_string(data), /[\r\n\t ]/g, ""));
    if (decoded == null || decoded == "")
        return store;

    return metadata_body_store_from_data(decoded);
}

function metadata_body_json(input_file) {
    write_metadata_compact_json(metadata_body_store(input_file));
    return true;
}

function metadata_trim_text(value) {
    return trim(as_string(value));
}

function metadata_clean_text(value, max, decode_base64) {
    value = as_string(value);
    if (decode_base64 && lc(substr(value, 0, 7)) == "base64:") {
        let decoded = base64_decode(substr(value, 7));
        value = decoded == null ? "" : decoded;
    }

    let cleaned = "";
    let last_space = false;
    for (let i = 0; i < length(value); i++) {
        let char = substr(value, i, 1);
        let code = ord(char);
        if (code < 32 || code == 127)
            char = " ";

        if (char == " ") {
            if (!last_space)
                cleaned += " ";
            last_space = true;
        }
        else {
            cleaned += char;
            last_space = false;
        }
    }

    cleaned = trim(cleaned);
    if (cleaned == "")
        return null;
    return length(cleaned) > max ? substr(cleaned, 0, max) : cleaned;
}

function metadata_has_control_or_space(value) {
    value = as_string(value);
    for (let i = 0; i < length(value); i++) {
        let code = ord(substr(value, i, 1));
        if (code <= 32 || code == 127)
            return true;
    }
    return false;
}

function metadata_clean_url(value) {
    let cleaned = metadata_trim_text(value);
    if (cleaned == "" || length(cleaned) > 2048)
        return null;
    if (!starts_with(cleaned, "http://") && !starts_with(cleaned, "https://"))
        return null;
    return metadata_has_control_or_space(cleaned) ? null : cleaned;
}

function metadata_clean_number(value) {
    value = metadata_trim_text(value);
    if (value == "")
        return null;
    for (let i = 0; i < length(value); i++) {
        let code = ord(substr(value, i, 1));
        if (code < 48 || code > 57)
            return null;
    }
    return value;
}

function metadata_replace_path_separators(value) {
    let result = "";
    for (let i = 0; i < length(value); i++) {
        let char = substr(value, i, 1);
        result += (char == "/" || char == "\\") ? "_" : char;
    }
    return result;
}

function metadata_content_disposition_filename(value) {
    value = as_string(value);
    let filename = null;
    let quoted_marker = "filename=\"";
    let quoted_pos = index(value, quoted_marker);
    if (quoted_pos >= 0) {
        let rest = substr(value, quoted_pos + length(quoted_marker));
        let quote_end = index(rest, "\"");
        filename = quote_end >= 0 ? substr(rest, 0, quote_end) : rest;
    }
    else {
        let marker = "filename=";
        let pos = index(value, marker);
        if (pos < 0)
            return null;

        let rest = substr(value, pos + length(marker));
        let semicolon = index(rest, ";");
        filename = semicolon >= 0 ? substr(rest, 0, semicolon) : rest;
        if (length(filename) > 0 && substr(filename, 0, 1) == "\"")
            filename = substr(filename, 1);
        if (length(filename) > 0 && substr(filename, length(filename) - 1) == "\"")
            filename = substr(filename, 0, length(filename) - 1);
    }

    filename = metadata_clean_text(filename, 120, false);
    if (filename == null)
        return null;

    filename = metadata_replace_path_separators(filename);
    return filename == "" ? null : filename;
}

function metadata_number_value(value) {
    return value == null ? 0 : int(value, 10);
}

function metadata_parse_userinfo(value) {
    let result = {};

    for (let item in split(as_string(value), ";")) {
        item = trim(item);
        let equals = index(item, "=");
        if (equals < 0)
            continue;

        let key = lc(trim(substr(item, 0, equals)));
        let number = metadata_clean_number(substr(item, equals + 1));
        if (number == null)
            continue;

        if (key == "upload" || key == "download" || key == "total" || key == "expire")
            result[key] = number;
    }

    return result;
}

function metadata_ui_object(raw) {
    raw = object_or_empty(raw);

    let title = metadata_clean_text(raw["profile-title"], 120, true);
    let web_page_url = metadata_clean_url(raw["profile-web-page-url"]);
    let support_url = metadata_clean_url(raw["support-url"]);
    let announce = metadata_clean_text(raw["announce"], 500, true);
    let announce_url = metadata_clean_url(raw["announce-url"]);
    let refill_date = metadata_clean_number(raw["subscription-refill-date"]);
    let file_name = metadata_content_disposition_filename(raw["content-disposition"]);
    let userinfo = metadata_parse_userinfo(raw["subscription-userinfo"]);

    let upload = userinfo.upload;
    let download = userinfo.download;
    let total = userinfo.total;
    let expire = userinfo.expire;
    let has_traffic = upload != null || download != null || total != null || expire != null;
    let used = metadata_number_value(upload) + metadata_number_value(download);
    let total_value = metadata_number_value(total);

    let result = { version: 1 };
    if (title != null)
        result.title = title;
    if (has_traffic) {
        let traffic = {
            used: used,
            isUnlimited: !(total != null && total_value > 0)
        };
        if (upload != null)
            traffic.upload = metadata_number_value(upload);
        if (download != null)
            traffic.download = metadata_number_value(download);
        if (total != null && total_value > 0) {
            traffic.total = total_value;
            let remaining = total_value - used;
            traffic.remaining = remaining < 0 ? 0 : remaining;
        }
        result.traffic = traffic;
    }
    if (expire != null && metadata_number_value(expire) > 0)
        result.expire = metadata_number_value(expire);
    if (refill_date != null && metadata_number_value(refill_date) > 0)
        result.refillDate = metadata_number_value(refill_date);
    if (web_page_url != null)
        result.webPageUrl = web_page_url;
    if (support_url != null)
        result.supportUrl = support_url;
    if (announce != null)
        result.announce = announce;
    if (announce_url != null)
        result.announceUrl = announce_url;
    if (file_name != null)
        result.fileName = file_name;

    return result;
}

function metadata_ui_json(raw_path) {
    let result = metadata_ui_object(read_json_file(raw_path));
    if (length(keys(result)) > 1)
        write_json(result);
    return true;
}

function metadata_extract_ui_json(headers_file, body_file) {
    let raw = metadata_body_store_with_base64_fallback(body_file).values;
    let headers = metadata_headers_store(headers_file).values;
    for (let key, value in headers)
        raw[key] = value;

    let result = metadata_ui_object(raw);
    if (length(keys(result)) > 1)
        write_json(result);
    return true;
}

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

function normalize_uri_list(input_file, output_file) {
    return normalize_uri_list_file(input_file, output_file, false);
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

function content_is_clash_yaml(data) {
    for (let line in split(data, "\n")) {
        if (match(line, /^[ \t]*proxies:[ \t]*(#.*)?$/))
            return true;
    }
    return false;
}

function xray_first_array_object(value) {
    value = array_or_empty(value);
    return length(value) > 0 && type(value[0]) == "object" ? value[0] : {};
}

function xray_first_string(values) {
    for (let value in values) {
        value = as_string(value);
        if (value != "")
            return value;
    }
    return "";
}

function xray_valid_port_value(value) {
    let value_type = type(value);
    if (value_type == "int" || value_type == "double")
        return valid_port(value) ? int(value) : null;

    value = as_string(value);
    if (!is_integer_string(value))
        return null;

    let port = int(value, 10);
    return valid_port(port) ? port : null;
}

function xray_alpn(value) {
    if (type(value) == "array")
        return value;

    let text = as_string(value);
    return text != "" ? split_csv(text) : [];
}

function xray_add_utls(tls, fingerprint) {
    fingerprint = normalize_utls_fingerprint(fingerprint);
    if (fingerprint != "")
        tls.utls = { enabled: true, fingerprint: fingerprint };
}

function xray_tls_from_stream(stream, network) {
    stream = object_or_empty(stream);
    let security = lc(as_string(stream.security || ""));
    let reality = object_or_empty(stream.realitySettings);
    let tls_settings = object_or_empty(stream.tlsSettings);
    let settings = security == "reality" ? reality : tls_settings;

    if (security != "tls" && security != "xtls" && security != "reality" && length(keys(settings)) == 0)
        return null;

    let tls = { enabled: true };
    let server_name = xray_first_string([settings.serverName, settings.server_name, settings.sni]);
    let alpn = tls_alpn_for_transport(xray_alpn(settings.alpn), network);
    if (server_name != "")
        tls.server_name = server_name;
    if (is_true(settings.allowInsecure) || is_true(settings.insecure))
        tls.insecure = true;
    if (length(alpn) > 0)
        tls.alpn = alpn;

    xray_add_utls(tls, settings.fingerprint || settings.fp || "");

    if (security == "reality" || length(keys(reality)) > 0) {
        tls.reality = { enabled: true };
        let public_key = xray_first_string([reality.publicKey, reality.public_key, settings.publicKey, settings.public_key]);
        let short_id = xray_first_string([reality.shortId, reality.short_id, settings.shortId, settings.short_id]);
        if (public_key != "")
            tls.reality.public_key = public_key;
        if (short_id != "")
            tls.reality.short_id = short_id;
        if (!tls.utls)
            tls.utls = { enabled: true, fingerprint: "chrome" };
    }

    return tls;
}

function xray_transport_from_stream(stream) {
    stream = object_or_empty(stream);
    let network = lc(as_string(stream.network || ""));
    if (network == "" || network == "tcp")
        return null;

    if (network == "ws") {
        let settings = object_or_empty(stream.wsSettings);
        let headers = object_or_empty(settings.headers);
        let result = { type: "ws", path: as_string(settings.path || "/") };
        let host = as_string(headers.Host || headers.host || "");
        if (host != "")
            result.headers = { Host: host };
        return result;
    }

    if (network == "grpc") {
        let settings = object_or_empty(stream.grpcSettings);
        let result = { type: "grpc" };
        if (as_string(settings.serviceName || settings.service_name || "") != "")
            result.service_name = as_string(settings.serviceName || settings.service_name);
        return result;
    }

    if (network == "http" || network == "h2") {
        let settings = object_or_empty(stream.httpSettings);
        let result = { type: "http" };
        if (type(settings.path) == "array" && length(settings.path) > 0)
            result.path = as_string(settings.path[0]);
        else if (as_string(settings.path || "") != "")
            result.path = as_string(settings.path);
        if (type(settings.host) == "array")
            result.host = settings.host;
        else if (as_string(settings.host || "") != "")
            result.host = split_csv(settings.host);
        return result;
    }

    if (network == "httpupgrade") {
        let settings = object_or_empty(stream.httpupgradeSettings);
        let result = { type: "httpupgrade" };
        if (as_string(settings.path || "") != "")
            result.path = as_string(settings.path);
        if (as_string(settings.host || "") != "")
            result.host = as_string(settings.host);
        return result;
    }

    if (network == "xhttp") {
        let settings = object_or_empty(stream.xhttpSettings);
        let result = {
            type: "xhttp",
            mode: as_string(settings.mode || "auto"),
            path: as_string(settings.path || "/"),
            x_padding_bytes: "100-1000",
            no_grpc_header: false,
            sc_max_each_post_bytes: 1000000,
            sc_min_posts_interval_ms: 30
        };
        if (result.mode != "auto" && result.mode != "packet-up" && result.mode != "stream-up" && result.mode != "stream-one")
            result.mode = "auto";
        if (as_string(settings.host || "") != "")
            result.host = as_string(settings.host);
        xhttp_optional_positive_range(result, "x_padding_bytes", xhttp_setting_value(settings, settings, "xPaddingBytes", "x_padding_bytes"));
        xhttp_optional_bool(result, "no_grpc_header", xhttp_setting_value(settings, settings, "noGRPCHeader", "no_grpc_header"));
        xhttp_optional_positive_range(result, "sc_max_each_post_bytes", xhttp_setting_value(settings, settings, "scMaxEachPostBytes", "sc_max_each_post_bytes"));
        xhttp_optional_range(result, "sc_min_posts_interval_ms", xhttp_setting_value(settings, settings, "scMinPostsIntervalMs", "sc_min_posts_interval_ms"));
        xhttp_optional_range(result, "sc_stream_up_server_secs", xhttp_setting_value(settings, settings, "scStreamUpServerSecs", "sc_stream_up_server_secs"));
        let xmux = xhttp_normalize_xmux(settings.xmux);
        if (xmux)
            result.xmux = xmux;
        return result;
    }

    return null;
}

function xray_display_name(original_tag) {
    original_tag = as_string(original_tag);
    return original_tag;
}

function xray_config_display_name(config, fallback) {
    let name = xray_first_string([config.remarks, config.remark, config.name, config.ps]);
    return name != "" ? name : fallback;
}

function xray_source_tag(outbound, fallback) {
    let tag = as_string(outbound.tag || "");
    return tag != "" ? tag : fallback;
}

function xray_unique_tag(base, taken) {
    base = as_string(base);
    if (base == "")
        base = "server";
    if (!taken[base])
        return base;

    for (let suffix = 1; suffix < 100000; suffix++) {
        let candidate = base + "-" + suffix;
        if (!taken[candidate])
            return candidate;
    }

    return base + "-overflow";
}

function xray_tag_base(original_tag, config_index, config_count) {
    original_tag = as_string(original_tag);
    if (original_tag == "")
        original_tag = "server";
    return original_tag;
}

function convert_xray_vless(outbound, tag) {
    let vnext = xray_first_array_object(object_or_empty(outbound.settings).vnext);
    let user = xray_first_array_object(vnext.users);
    let server = as_string(vnext.address || "");
    let port = xray_valid_port_value(vnext.port);
    let uuid = as_string(user.id || "");
    if (server == "" || port == null || uuid == "")
        return null;

    let result = {
        type: "vless",
        tag: tag,
        server: server,
        server_port: port,
        uuid: uuid
    };

    let flow = as_string(user.flow || "");
    if (!vless_flow_supported(flow))
        return null;
    if (flow != "")
        result.flow = flow;
    let encryption = normalize_vless_encryption(user.encryption || "");
    if (encryption != "")
        result.encryption = encryption;

    let stream = object_or_empty(outbound.streamSettings);
    let transport = xray_transport_from_stream(stream);
    let tls = xray_tls_from_stream(stream, lc(as_string(stream.network || "")));
    if (tls)
        result.tls = tls;
    if (transport)
        result.transport = transport;

    return result;
}

function convert_xray_socks(outbound, tag) {
    let server_config = xray_first_array_object(object_or_empty(outbound.settings).servers);
    let server = as_string(server_config.address || "");
    let port = xray_valid_port_value(server_config.port);
    if (server == "" || port == null)
        return null;

    let result = {
        type: "socks",
        tag: tag,
        server: server,
        server_port: port,
        version: "5"
    };

    let user = xray_first_array_object(server_config.users);
    if (as_string(user.user || "") != "")
        result.username = as_string(user.user);
    if (as_string(user.pass || user.password || "") != "")
        result.password = as_string(user.pass || user.password);

    return result;
}

function convert_xray_hysteria2(outbound, tag) {
    let settings = object_or_empty(outbound.settings);
    let stream = object_or_empty(outbound.streamSettings);
    let hysteria_settings = object_or_empty(stream.hysteriaSettings);
    let version = int(settings.version || hysteria_settings.version || 0);
    if (version != 2)
        return null;

    let server = as_string(settings.address || settings.server || "");
    let port = xray_valid_port_value(settings.port);
    let password = as_string(hysteria_settings.auth || settings.auth || settings.password || "");
    if (server == "" || port == null || password == "")
        return null;

    let result = {
        type: "hysteria2",
        tag: tag,
        server: server,
        server_port: port,
        password: password,
        tls: { enabled: true }
    };

    let tls_settings = object_or_empty(stream.tlsSettings);
    let server_name = xray_first_string([tls_settings.serverName, tls_settings.server_name, tls_settings.sni]);
    if (server_name != "")
        result.tls.server_name = server_name;
    if (is_true(tls_settings.allowInsecure) || is_true(tls_settings.insecure))
        result.tls.insecure = true;
    let alpn = xray_alpn(tls_settings.alpn);
    if (length(alpn) > 0)
        result.tls.alpn = alpn;

    return result;
}

function convert_xray_outbound(outbound, tag) {
    let protocol = lc(as_string(outbound.protocol || ""));
    if (protocol == "vless")
        return convert_xray_vless(outbound, tag);
    if (protocol == "socks")
        return convert_xray_socks(outbound, tag);
    if (protocol == "hysteria")
        return convert_xray_hysteria2(outbound, tag);
    return null;
}

function xray_outbound_supported(outbound) {
    return convert_xray_outbound(outbound, "probe") != null;
}

function xray_outbound_detour(outbound) {
    let stream = object_or_empty(outbound.streamSettings);
    let sockopt = object_or_empty(stream.sockopt);
    if (as_string(sockopt.dialerProxy || "") != "")
        return as_string(sockopt.dialerProxy);

    sockopt = object_or_empty(outbound.sockopt);
    return as_string(sockopt.dialerProxy || "");
}

function xray_supported_source_tags(source_outbounds) {
    let result = {};
    for (let i = 0; i < length(source_outbounds); i++) {
        let outbound = source_outbounds[i];
        if (type(outbound) != "object" || !xray_outbound_supported(outbound))
            continue;

        let tag = xray_source_tag(outbound, lc(as_string(outbound.protocol || "server")) + "-" + (i + 1));
        result[tag] = true;
    }
    return result;
}

function xray_primary_source_tag(config, source_outbounds) {
    let supported_tags = xray_supported_source_tags(source_outbounds);

    for (let rule in array_or_empty(object_or_empty(config.routing).rules)) {
        let outbound_tag = as_string(object_or_empty(rule).outboundTag || "");
        if (supported_tags[outbound_tag])
            return outbound_tag;
    }

    if (supported_tags["proxy"])
        return "proxy";

    for (let i = 0; i < length(source_outbounds); i++) {
        let outbound = source_outbounds[i];
        if (type(outbound) != "object" || !xray_outbound_supported(outbound))
            continue;

        let tag = xray_source_tag(outbound, lc(as_string(outbound.protocol || "server")) + "-" + (i + 1));
        if (xray_outbound_detour(outbound) == "")
            return tag;
    }

    for (let tag in keys(supported_tags))
        return tag;

    return "";
}

function xray_balancer_selector_matches(selector, tag) {
    selector = as_string(selector);
    tag = as_string(tag);
    if (selector == "" || tag == "")
        return false;
    return tag == selector || starts_with(tag, selector + "-") || starts_with(tag, selector);
}

function xray_urltest_option_string(value) {
    value = as_string(value);
    return value != "" ? value : "";
}

function xray_config_urltest_options(config) {
    let observatory = object_or_empty(config.observatory);
    let burst_observatory = object_or_empty(config.burstObservatory || config.burst_observatory);
    let ping_config = object_or_empty(burst_observatory.pingConfig || burst_observatory.ping_config);
    let result = {};

    let url = xray_first_string([
        ping_config.destination,
        ping_config.url,
        observatory.probeURL,
        observatory.probeUrl,
        observatory.probe_url
    ]);
    if (url != "")
        result.url = url;

    let interval = xray_first_string([
        ping_config.interval,
        observatory.probeInterval,
        observatory.probe_interval
    ]);
    if (interval != "")
        result.interval = interval;

    return result;
}

function xray_apply_urltest_options(group, options) {
    options = object_or_empty(options);
    for (let key in [ "url", "interval" ]) {
        let value = xray_urltest_option_string(options[key]);
        if (value != "")
            group[key] = value;
    }
}

function xray_balancer_plans(config, source_outbounds) {
    let supported_tags = xray_supported_source_tags(source_outbounds);
    let result = [];
    let urltest_options = xray_config_urltest_options(config);

    for (let balancer in array_or_empty(object_or_empty(config.routing).balancers)) {
        let selectors = array_or_empty(object_or_empty(balancer).selector);
        let selected = {};
        let tags = [];
        for (let tag in keys(supported_tags)) {
            for (let selector in selectors) {
                if (xray_balancer_selector_matches(selector, tag) && !selected[tag]) {
                    selected[tag] = true;
                    push(tags, tag);
                    break;
                }
            }
        }
        if (length(tags) > 0) {
            push(result, {
                tag: as_string(object_or_empty(balancer).tag || ""),
                source_tags: tags,
                urltest_options
            });
        }
    }

    return result;
}

function xray_balancer_group_base(plan, display_name, config_index, config_count, plan_index, plan_count) {
    let balancer_tag = as_string(object_or_empty(plan).tag || "");
    display_name = as_string(display_name);
    if (plan_count == 1 && display_name != "")
        return display_name;
    if (balancer_tag != "")
        return balancer_tag;
    if (display_name != "")
        return display_name + "-" + (plan_index + 1);
    return xray_tag_base("urltest", config_index, config_count);
}

function xray_plan_config_outbounds(config, config_index, config_count, taken) {
    let source_outbounds = array_or_empty(config.outbounds);
    let planned = [];
    let tag_map = {};

    for (let i = 0; i < length(source_outbounds); i++) {
        let outbound = source_outbounds[i];
        if (type(outbound) != "object" || !xray_outbound_supported(outbound))
            continue;

        let original_tag = xray_source_tag(outbound, lc(as_string(outbound.protocol || "server")) + "-" + (i + 1));
        let tag = xray_unique_tag(xray_tag_base(original_tag, config_index, config_count), taken);
        taken[tag] = true;
        tag_map[original_tag] = tag;
        push(planned, { outbound, original_tag, tag });
    }

    return { planned, tag_map };
}

function xray_retag_planned_outbound(planned, tag_map, source_tag, new_base, config_index, config_count, taken) {
    source_tag = as_string(source_tag);
    new_base = as_string(new_base);
    if (source_tag == "" || new_base == "")
        return;

    for (let item in planned) {
        if (item.original_tag != source_tag)
            continue;

        let old_tag = as_string(item.tag || "");
        let new_tag = xray_unique_tag(new_base, taken);
        if (new_tag == old_tag)
            return;

        if (old_tag != "")
            delete taken[old_tag];
        taken[new_tag] = true;
        item.tag = new_tag;
        tag_map[source_tag] = new_tag;
        return;
    }
}

function xray_add_converted_outbound(result, item, tag_map, visible, display_name) {
    let converted = convert_xray_outbound(item.outbound, item.tag);
    if (!converted)
        return;

    if (visible && display_name != "")
        converted.remark = display_name;
    if (!visible)
        converted.__forkop_hidden = true;

    let detour = xray_outbound_detour(item.outbound);
    if (detour != "" && tag_map[detour])
        converted.detour = tag_map[detour];

    push(result, converted);
}

function xray_config_outbounds(config, config_index, config_count, taken) {
    let source_outbounds = array_or_empty(config.outbounds);
    let plan = xray_plan_config_outbounds(config, config_index, config_count, taken);
    let planned = array_or_empty(plan.planned);
    let tag_map = object_or_empty(plan.tag_map);
    let display_name = xray_config_display_name(config, "");
    let balancer_plans = xray_balancer_plans(config, source_outbounds);
    let visible_source_tags = {};
    let dependency_tags = {};
    let result = [];

    if (length(balancer_plans) > 0) {
        for (let plan_index = 0; plan_index < length(balancer_plans); plan_index++) {
            let plan = balancer_plans[plan_index];
            let urltest_outbounds = [];
            for (let source_tag in array_or_empty(plan.source_tags)) {
                if (tag_map[source_tag]) {
                    visible_source_tags[source_tag] = false;
                    push(urltest_outbounds, tag_map[source_tag]);
                }
            }

            if (length(urltest_outbounds) > 0) {
                let group_base = xray_balancer_group_base(plan, display_name, config_index, config_count, plan_index, length(balancer_plans));
                let group_tag = xray_unique_tag(group_base, taken);
                taken[group_tag] = true;
                let group = {
                    type: "urltest",
                    tag: group_tag,
                    outbounds: urltest_outbounds,
                    remark: group_base != "" ? group_base : group_tag,
                    __forkop_allow_group: true
                };
                xray_apply_urltest_options(group, plan.urltest_options);
                push(result, group);
            }
        }
    } else {
        let primary_tag = xray_primary_source_tag(config, source_outbounds);
        if (primary_tag != "") {
            xray_retag_planned_outbound(planned, tag_map, primary_tag, display_name, config_index, config_count, taken);
            visible_source_tags[primary_tag] = true;
        }
    }

    for (let item in planned) {
        let detour = xray_outbound_detour(item.outbound);
        if (detour != "" && tag_map[detour])
            dependency_tags[detour] = true;
    }

    for (let item in planned) {
        let visible = visible_source_tags[item.original_tag] === true;
        let hidden = !visible;
        if (visible || dependency_tags[item.original_tag] || visible_source_tags[item.original_tag] === false) {
            let item_display_name = visible && display_name != ""
                ? display_name
                : xray_display_name(item.original_tag);
            xray_add_converted_outbound(result, item, tag_map, !hidden, item_display_name);
        }
    }

    return result;
}

function is_xray_config(value) {
    if (type(value) != "object" || type(value.outbounds) != "array")
        return false;

    for (let outbound in value.outbounds) {
        if (type(outbound) == "object" && type(outbound.protocol) == "string")
            return true;
    }

    return false;
}

function normalize_xray_configs(configs) {
    configs = array_or_empty(configs);
    let taken = {};
    let outbounds = [];

    for (let i = 0; i < length(configs); i++) {
        let config = configs[i];
        if (!is_xray_config(config))
            continue;

        for (let outbound in xray_config_outbounds(config, i, length(configs), taken))
            push(outbounds, outbound);
    }

    return outbounds;
}

function normalize_sing_box_xhttp_transport(outbound) {
    if (type(outbound) != "object" || type(outbound.transport) != "object")
        return outbound;
    if (outbound.transport.type != "xhttp")
        return outbound;

    outbound.transport.x_padding_bytes = xhttp_positive_range_or_default(outbound.transport.x_padding_bytes, "100-1000");
    let sc_max_each_post_bytes = xhttp_present_positive_range_or_default(outbound.transport.sc_max_each_post_bytes, 1000000);
    if (sc_max_each_post_bytes != null)
        outbound.transport.sc_max_each_post_bytes = sc_max_each_post_bytes;
    return outbound;
}

function normalize_sing_box_hysteria2_outbound(outbound) {
    if (type(outbound) == "object" && lc(as_string(outbound.type || "")) == "hysteria2") {
        if (type(outbound.tls) != "object")
            outbound.tls = { enabled: true };
        else
            outbound.tls.enabled = true;
        if (outbound.tls.utls != null)
            delete outbound.tls.utls;
    }
    return outbound;
}

function sing_box_urltest_group(outbound) {
    return type(outbound) == "object" && lc(as_string(outbound.type || "")) == "urltest";
}

function sing_box_outbound_tag(outbound) {
    return type(outbound) == "object" ? as_string(outbound.tag || "") : "";
}

function normalize_sing_box_json_outbounds(candidates) {
    let outbounds = [];
    let urltest_refs = {};
    let detour_refs = {};

    for (let outbound in candidates) {
        if (type(outbound) != "object")
            continue;
        outbound = normalize_sing_box_hysteria2_outbound(outbound);
        push(outbounds, normalize_sing_box_xhttp_transport(outbound));
    }

    for (let outbound in outbounds) {
        if (sing_box_urltest_group(outbound)) {
            for (let tag_name in array_or_empty(outbound.outbounds)) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    urltest_refs[tag_name] = true;
            }
        }

        let detour = as_string(outbound.detour || "");
        if (detour != "")
            detour_refs[detour] = true;
    }

    for (let outbound in outbounds) {
        let tag_name = sing_box_outbound_tag(outbound);
        if (sing_box_urltest_group(outbound)) {
            outbound.__forkop_allow_group = true;
            continue;
        }
        if (tag_name != "" && (urltest_refs[tag_name] || detour_refs[tag_name]))
            outbound.__forkop_hidden = true;
    }

    return outbounds;
}

function normalize_sing_box_json_value(value, output_file) {
    let candidates = [];
    let outbounds = [];

    if (is_xray_config(value))
        outbounds = normalize_xray_configs([value]);
    else if (type(value) == "array" && length(value) > 0 && is_xray_config(value[0]))
        outbounds = normalize_xray_configs(value);

    if (length(outbounds) > 0) {
        return write_json_file(output_file, {
            version: 1,
            format: "sing-box-json",
            outbounds: outbounds
        });
    }

    if (type(value) == "object" && type(value.outbounds) == "array")
        candidates = value.outbounds;
    else if (type(value) == "array")
        candidates = value;
    else if (type(value) == "object" && type(value.type) == "string")
        candidates = [value];

    outbounds = normalize_sing_box_json_outbounds(candidates);

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

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function gzip_decode_file(input_file, output_file) {
    if (as_string(input_file) == "" || as_string(output_file) == "" || !fs.stat(input_file))
        return false;

    for (let command in [ "gzip -dc", "gunzip -c", "zcat" ]) {
        let pipe = fs.popen(command + " " + shell_quote(input_file) + " 2>/dev/null", "r");
        if (!pipe)
            continue;

        let data = pipe.read("all");
        let status = pipe.close();
        if (status == 0 && data != null && data != "") {
            if (fs.writefile(output_file, data))
                return true;
            fs.unlink(output_file);
            return false;
        }
        fs.unlink(output_file);
    }

    return false;
}

function try_decode_gzip_content_file(input_file) {
    let tmp = temp_path("forkop-subscription-gzip");
    if (!gzip_decode_file(input_file, tmp)) {
        fs.unlink(tmp);
        return false;
    }

    if (!fs.rename(tmp, input_file)) {
        fs.unlink(tmp);
        return false;
    }

    return true;
}

function normalized_skipped_message(path) {
    let value = read_json_file(path);
    if (type(value) != "object")
        return "";

    let skipped = as_string(value.skipped != null ? value.skipped : "0");
    if (match(skipped, /^[0-9]+$/) == null || int(skipped) <= 0)
        return "";

    if (as_string(value.format != null ? value.format : "") == "clash-yaml")
        return "Skipped " + skipped + " invalid or unsupported Clash proxy entries";

    return "Skipped " + skipped + " invalid or unsupported subscription links";
}

function extract_ui_metadata_file(headers_file, body_file, output_file) {
    let tmp = temp_path("forkop-subscription-metadata");
    let raw = metadata_body_store_with_base64_fallback(body_file).values;
    let headers = metadata_headers_store(headers_file).values;
    for (let key, value in headers)
        raw[key] = value;

    let result = metadata_ui_object(raw);
    if (length(keys(result)) <= 1) {
        fs.unlink(output_file);
        return false;
    }

    if (!fs.writefile(tmp, sprintf("%J\n", result))) {
        fs.unlink(tmp);
        return false;
    }
    if (!fs.rename(tmp, output_file)) {
        fs.unlink(tmp);
        return false;
    }
    return true;
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
        let tmp = temp_path("forkop-subscription-clash");
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

function normalize_content_validated(input_file, output_file) {
    let normalize_input = input_file;
    let decoded_tmp = temp_path("forkop-subscription-gzip");
    let decoded = gzip_decode_file(input_file, decoded_tmp);
    if (decoded)
        normalize_input = decoded_tmp;
    else
        fs.unlink(decoded_tmp);

    let ok = normalize_content_file(normalize_input, output_file);
    if (decoded)
        fs.unlink(decoded_tmp);
    if (!ok)
        return false;

    return validate_subscription(output_file);
}

function normalized_skipped_warning(path) {
    let message = normalized_skipped_message(path);
    if (message != "")
        print(message, "\n");

    return true;
}

function subscription_source_entry_result(valid, url, user_agent, error) {
    return {
        valid,
        url: as_string(url),
        user_agent: as_string(user_agent),
        error: as_string(error)
    };
}

function write_subscription_source_entry_tsv_result(result) {
    result = type(result) == "object" ? result : subscription_source_entry_result(false, "", "", "Subscription URL cannot be empty");

    if (!result.valid) {
        print(result.error, "\n");
        return false;
    }

    print(result.url, "\t", result.user_agent, "\n");
    return true;
}

function parse_subscription_source_entry(entry) {
    entry = trim(entry);
    if (entry == "")
        return subscription_source_entry_result(false, "", "", "Subscription URL cannot be empty");

    if (index(entry, "|") >= 0)
        return subscription_source_entry_result(false, "", "", "Configure User-Agent in the subscription item settings");

    if (!(substr(entry, 0, 7) == "http://" || substr(entry, 0, 8) == "https://"))
        return subscription_source_entry_result(false, "", "", "Subscription URL must start with http:// or https://");

    return subscription_source_entry_result(true, entry, "", "");
}

function parse_subscription_source_entry_tsv(entry) {
    return write_subscription_source_entry_tsv_result(parse_subscription_source_entry(entry));
}

function module_exports() {
    return {
        parse_subscription_source_entry,
        validate_subscription,
        normalize_content_validated,
        normalized_skipped_message,
        try_decode_gzip_content_file,
        extract_ui_metadata_file,
        runtime_outbounds_equal
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

let mode = ARGV[0];
let ok = false;

if (mode == "validate-subscription")
    ok = validate_subscription(ARGV[1]);
else if (mode == "url-fragment")
    ok = subscription_url_fragment(ARGV[1]);
else if (mode == "share-link-outbound")
    ok = share_link_outbound(ARGV[1], ARGV[2]);
else if (mode == "normalize-uri-list")
    ok = normalize_uri_list(ARGV[1], ARGV[2]);
else if (mode == "normalize-clash-yaml")
    ok = normalize_clash_yaml(ARGV[1], ARGV[2]);
else if (mode == "normalize-content")
    ok = normalize_content_file(ARGV[1], ARGV[2]);
else if (mode == "normalize-content-validated")
    ok = normalize_content_validated(ARGV[1], ARGV[2]);
else if (mode == "try-decode-gzip-content")
    ok = try_decode_gzip_content_file(ARGV[1]);
else if (mode == "runtime-outbounds-equal")
    ok = runtime_outbounds_equal(ARGV[1], ARGV[2]);
else if (mode == "normalized-skipped-warning")
    ok = normalized_skipped_warning(ARGV[1]);
else if (mode == "metadata-headers-json")
    ok = metadata_headers_json(ARGV[1]);
else if (mode == "metadata-body-json")
    ok = metadata_body_json(ARGV[1]);
else if (mode == "metadata-ui-json")
    ok = metadata_ui_json(ARGV[1]);
else if (mode == "metadata-extract-ui-json")
    ok = metadata_extract_ui_json(ARGV[1], ARGV[2]);
else if (mode == "metadata-extract-ui-file")
    ok = extract_ui_metadata_file(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "parse-source-entry-tsv")
    ok = parse_subscription_source_entry_tsv(ARGV[1]);
else if (ARGV[0] && ARGV[1])
    ok = normalize_uri_list(ARGV[0], ARGV[1]);
else {
    warn("Usage: subscription/parser.uc validate-subscription <normalized-json>\n");
    warn("       subscription/parser.uc url-fragment <url>\n");
    warn("       subscription/parser.uc share-link-outbound <url> <tag>\n");
    warn("       subscription/parser.uc normalize-uri-list <input> <output>\n");
    warn("       subscription/parser.uc normalize-clash-yaml <input> <output>\n");
    warn("       subscription/parser.uc normalize-content <input> <output>\n");
    warn("       subscription/parser.uc normalize-content-validated <input> <output>\n");
    warn("       subscription/parser.uc try-decode-gzip-content <input>\n");
    warn("       subscription/parser.uc runtime-outbounds-equal <left> <right>\n");
    warn("       subscription/parser.uc normalized-skipped-warning <normalized-json>\n");
    warn("       subscription/parser.uc metadata-headers-json <input>\n");
    warn("       subscription/parser.uc metadata-body-json <input>\n");
    warn("       subscription/parser.uc metadata-ui-json <raw-json>\n");
    warn("       subscription/parser.uc metadata-extract-ui-json <headers> <body>\n");
    warn("       subscription/parser.uc metadata-extract-ui-file <headers> <body> <output>\n");
    warn("       subscription/parser.uc parse-source-entry-tsv <entry>\n");
    exit(2);
}

if (!ok)
    exit(1);
