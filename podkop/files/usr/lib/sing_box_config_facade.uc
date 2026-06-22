#!/usr/bin/env ucode

let fs = require("fs");

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

function json_decode_text(text) {
    try {
        return json(as_string(text));
    }
    catch (e) {
        return null;
    }
}

function read_stdin_json() {
    return json_decode_text(read_stdin());
}

function read_json_file(path) {
    let data = fs.readfile(path);
    return data == null ? null : json_decode_text(data);
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function write_compact_string_array(values) {
    print("[");
    for (let i = 0; i < length(values); i++) {
        if (i > 0)
            print(",");
        print(sprintf("%J", as_string(values[i])));
    }
    print("]\n");
}

function csv_to_json_array(value) {
    value = as_string(value);
    write_compact_string_array(value == "" ? [] : split(value, ","));
}

function hex_digit_value(value) {
    value = ord(lc(as_string(value)));
    if (value >= 48 && value <= 57)
        return value - 48;
    if (value >= 97 && value <= 102)
        return value - 87;
    return -1;
}

function url_decode(value) {
    value = as_string(value);

    let result = "";
    for (let i = 0; i < length(value); i++) {
        let c = substr(value, i, 1);
        if (c == "+") {
            result += " ";
            continue;
        }

        if (c == "%") {
            let high = i + 1 < length(value) ? hex_digit_value(substr(value, i + 1, 1)) : -1;
            let low = i + 2 < length(value) ? hex_digit_value(substr(value, i + 2, 1)) : -1;
            if (high >= 0 && low >= 0) {
                result += chr(high * 16 + low);
                i += 2;
            }
            else {
                result += "\\x";
            }
            continue;
        }

        result += c;
    }

    return result;
}

function write_file(path, text) {
    let result = fs.writefile(path, as_string(text));
    if (result == null)
        return false;
    if (type(result) == "boolean" && !result)
        return false;
    return true;
}

function write_file_json(path, value) {
    return write_file(path, sprintf("%J", value) + "\n");
}

function write_text_file(path, value) {
    return write_file(path, as_string(value));
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function xhttp_value_present(value) {
    return value != null && as_string(value) != "";
}

function xhttp_is_integer_string(value) {
    if (type(value) != "string" || value == "")
        return false;
    for (let i = 0; i < length(value); i++) {
        let code = ord(substr(value, i, 1));
        if (code < 48 || code > 57)
            return false;
    }
    return true;
}

function xhttp_object_arg(value) {
    if (type(value) == "object")
        return value;

    let parsed = json_decode_text(value);
    return type(parsed) == "object" ? parsed : {};
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

function xhttp_query_params(url) {
    let result = {};
    url = as_string(url);
    let question = index(url, "?");
    if (question < 0)
        return result;

    let query = substr(url, question + 1);
    let hash = index(query, "#");
    if (hash >= 0)
        query = substr(query, 0, hash);

    for (let pair in split(query, "&")) {
        if (pair == "")
            continue;
        let equals = index(pair, "=");
        let key = url_decode(equals >= 0 ? substr(pair, 0, equals) : pair);
        let value = equals >= 0 ? url_decode(substr(pair, equals + 1)) : "";
        if (key != "")
            result[key] = value;
    }

    return result;
}

function xhttp_extra_settings(query) {
    let result = {};
    query = object_or_empty(query);
    xhttp_merge_extra_settings(result, query.extra);
    return result;
}

function xhttp_setting_value(query, extra_settings, camel_key, snake_key) {
    query = object_or_empty(query);
    extra_settings = object_or_empty(extra_settings);
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
    if (!xhttp_is_integer_string(value))
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

function xhttp_positive_range_or_default(value, default_value) {
    let normalized = xhttp_range_value(value, true);
    return normalized != null ? normalized : default_value;
}

function xhttp_arg_value(value) {
    if (value == null)
        return "";
    if (type(value) == "object" || type(value) == "array")
        return sprintf("%J", value);
    return as_string(value);
}

function xhttp_bool_arg(value) {
    if (!xhttp_value_present(value))
        return "";

    let normalized = lc(as_string(value));
    return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on" ? "1" : "0";
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

function xhttp_transport_extra(url) {
    let query = xhttp_query_params(url);
    let extra_settings = xhttp_extra_settings(query);
    let xmux = xhttp_normalize_xmux(xhttp_setting_value(query, extra_settings, "xmux", "xmux"));
    let values = [
        xhttp_arg_value(xhttp_range_value(xhttp_setting_value(query, extra_settings, "xPaddingBytes", "x_padding_bytes"), true)),
        xhttp_bool_arg(xhttp_setting_value(query, extra_settings, "noGRPCHeader", "no_grpc_header")),
        xhttp_arg_value(xhttp_range_value(xhttp_setting_value(query, extra_settings, "scMaxEachPostBytes", "sc_max_each_post_bytes"), true)),
        xhttp_arg_value(xhttp_range_value(xhttp_setting_value(query, extra_settings, "scMinPostsIntervalMs", "sc_min_posts_interval_ms"), false)),
        xhttp_arg_value(xhttp_range_value(xhttp_setting_value(query, extra_settings, "scStreamUpServerSecs", "sc_stream_up_server_secs"), false)),
        xhttp_arg_value(xmux)
    ];

    print(join("\t", values), "\n");
}

function sort_strings(values) {
    sort(values, function(first, second) {
        return first == second ? 0 : (first < second ? -1 : 1);
    });
    return values;
}

function clone(value) {
    return json_decode_text(sprintf("%J", value));
}

function non_empty_string(value) {
    return type(value) == "string" && value != "";
}

function strip_ansi_sgr(value) {
    return replace(as_string(value), /\x1b\[[0-9;]*m/g, "");
}

function validation_error_summary() {
    for (let line in split(read_stdin(), "\n")) {
        line = trim(strip_ansi_sgr(replace(as_string(line), /\r/g, "")));
        if (line != "") {
            print(line, "\n");
            return;
        }
    }

    print("sing-box check failed\n");
}

function valid_server_port(value) {
    return type(value) == "int" && value >= 1 && value <= 65535;
}

function valid_server_port_text(value) {
    value = as_string(value);
    if (!match(value, /^\d+$/))
        return false;

    return valid_server_port(int(value, 10));
}

function shadowsocks_userinfo_format_valid(value) {
    return match(as_string(value), /^[^:]+:[^:]+(:[^:]+)?$/) != null;
}

function valid_hysteria2_server_ports(value) {
    if (type(value) != "array" || length(value) == 0)
        return false;

    for (let item in value) {
        let parts = split(as_string(item), ":");
        if (length(parts) != 2)
            return false;
        if (!valid_server_port_text(parts[0]) || !valid_server_port_text(parts[1]))
            return false;
        if (int(parts[0], 10) > int(parts[1], 10))
            return false;
    }

    return true;
}

function type_requires_server(proxy_type) {
    return proxy_type == "vless" || proxy_type == "vmess" || proxy_type == "trojan" ||
        proxy_type == "shadowsocks" || proxy_type == "socks" || proxy_type == "http" || proxy_type == "hysteria2";
}

function supported_flow(flow) {
    return flow == null || flow == "" || flow == "xtls-rprx-vision";
}

function supported_transport_type(transport) {
    return transport == "http" || transport == "ws" || transport == "quic" || transport == "grpc" ||
        transport == "httpupgrade" || transport == "xhttp" || transport == "kcp";
}

function internal_flag(value) {
    if (value === true)
        return true;
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function outbound_is_hidden(outbound) {
    return type(outbound) == "object" && internal_flag(outbound.__podkop_hidden);
}

function outbound_allows_group_type(outbound) {
    return type(outbound) == "object" && internal_flag(outbound.__podkop_allow_group);
}

let supported_shadowsocks_methods = {
    "none": true,
    "aes-128-gcm": true,
    "aes-192-gcm": true,
    "aes-256-gcm": true,
    "chacha20-ietf-poly1305": true,
    "xchacha20-ietf-poly1305": true,
    "2022-blake3-aes-128-gcm": true,
    "2022-blake3-aes-256-gcm": true,
    "2022-blake3-chacha20-poly1305": true,
    "aes-128-cfb": true,
    "aes-192-cfb": true,
    "aes-256-cfb": true,
    "aes-128-ctr": true,
    "aes-192-ctr": true,
    "aes-256-ctr": true,
    "chacha20": true,
    "chacha20-ietf": true,
    "xchacha20": true,
    "salsa20": true,
    "rc4-md5": true
};

function plugin_name(plugin) {
    let m = match(as_string(plugin), /^([^;]*)/);
    return m ? m[1] : "";
}

function reality_enabled(outbound) {
    return type(outbound.tls) == "object" && type(outbound.tls.reality) == "object" &&
        (outbound.tls.reality.enabled == null || outbound.tls.reality.enabled === true);
}

function prefilter_skip_reason(outbound, supports_xhttp, plugin_supports) {
    if (type(outbound) != "object")
        return "not an object";

    let proxy_type = as_string(outbound.type || "");
    if (proxy_type == "")
        return "missing type";
    if ((proxy_type == "selector" || proxy_type == "urltest") && outbound_allows_group_type(outbound))
        return "";
    if (proxy_type == "direct" || proxy_type == "selector" || proxy_type == "urltest" ||
        proxy_type == "dns" || proxy_type == "block")
        return "non-proxy outbound type: " + proxy_type;
    if (proxy_type != "vless" && proxy_type != "vmess" && proxy_type != "trojan" &&
        proxy_type != "shadowsocks" && proxy_type != "socks" && proxy_type != "http" && proxy_type != "hysteria2")
        return "unsupported type: " + proxy_type;
    if (type_requires_server(proxy_type) && !non_empty_string(outbound.server))
        return "missing or empty server";
    if (proxy_type == "hysteria2" && !valid_server_port(outbound.server_port) &&
        !valid_hysteria2_server_ports(outbound.server_ports))
        return "missing or invalid server_port";
    if (proxy_type != "hysteria2" && type_requires_server(proxy_type) && !valid_server_port(outbound.server_port))
        return "missing or invalid server_port";
    if ((proxy_type == "vless" || proxy_type == "vmess") && !non_empty_string(outbound.uuid))
        return "missing uuid";
    if ((proxy_type == "trojan" || proxy_type == "hysteria2") && !non_empty_string(outbound.password))
        return "missing password";
    if (proxy_type == "shadowsocks" && !non_empty_string(outbound.method))
        return "missing shadowsocks method";
    if (proxy_type == "shadowsocks" && !non_empty_string(outbound.password))
        return "missing shadowsocks password";
    if (proxy_type == "shadowsocks" && !supported_shadowsocks_methods[outbound.method])
        return "unsupported shadowsocks method: " + as_string(outbound.method);
    if (proxy_type == "shadowsocks" && non_empty_string(outbound.plugin) && !plugin_supports[plugin_name(outbound.plugin)])
        return "shadowsocks plugin is not installed: " + plugin_name(outbound.plugin);
    if (reality_enabled(outbound) && !non_empty_string(outbound.tls.reality.public_key))
        return "reality public_key is missing";
    if (proxy_type == "vless" && !supported_flow(outbound.flow || ""))
        return "unsupported vless flow: " + as_string(outbound.flow);
    if (type(outbound.transport) == "object" && as_string(outbound.transport.type || "") == "")
        return "missing transport type";
    if (type(outbound.transport) == "object" && !supported_transport_type(as_string(outbound.transport.type || "")))
        return "unknown transport type: " + as_string(outbound.transport.type);
    if (type(outbound.transport) == "object" && as_string(outbound.transport.type || "") == "xhttp" && !supports_xhttp)
        return "transport xhttp requires sing-box-extended";
    if (proxy_type == "shadowsocks" && type(outbound.tls) == "object" && outbound.tls.enabled === true)
        return "shadowsocks with TLS is not supported";

    return "";
}

function safe_string(value, fallback) {
    let result = value == null ? fallback : as_string(value);
    return result == "" || result == "null" ? fallback : result;
}

function unique_tag(base, taken) {
    if (!taken[base])
        return base;

    for (let suffix = 1; suffix < 100000; suffix++) {
        let candidate = base + "-" + suffix;
        if (!taken[candidate])
            return candidate;
    }

    return base + "-overflow";
}

function normalize_outbound(outbound) {
    if (type(outbound) != "object" || type(outbound.transport) != "object")
        return;
    if (outbound.transport.type != "xhttp")
        return;

    if (xhttp_value_present(outbound.transport.sc_max_each_post_bytes)) {
        outbound.transport = clone(outbound.transport);
        outbound.transport.sc_max_each_post_bytes = xhttp_positive_range_or_default(outbound.transport.sc_max_each_post_bytes, 1000000);
    }
}

function copy_outbound(outbound) {
    let copy = {};
    for (let key, value in outbound) {
        if (key != "tag" && key != "remark" && key != "share_link" &&
            key != "__podkop_hidden" && key != "__podkop_allow_group")
            copy[key] = value;
    }
    normalize_outbound(copy);
    return copy;
}

function rewrite_prepared_outbound_references(outbounds, tag_map) {
    for (let outbound in outbounds) {
        if (type(outbound) != "object")
            continue;

        let detour = as_string(outbound.detour || "");
        if (detour != "" && tag_map[detour])
            outbound.detour = tag_map[detour];

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag in outbound.outbounds) {
                tag = as_string(tag);
                push(rewritten, tag_map[tag] || tag);
            }
            outbound.outbounds = rewritten;
        }
    }
}

function candidate_outbounds(path) {
    let subscription = object_or_empty(read_json_file(path));
    let result = [];
    let skipped_types = {
        selector: true,
        urltest: true,
        direct: true,
        dns: true,
        block: true
    };

    for (let outbound in array_or_empty(subscription.outbounds)) {
        if (type(outbound) != "object")
            continue;
        if ((outbound.type == "selector" || outbound.type == "urltest") && outbound_allows_group_type(outbound))
            push(result, outbound);
        else if (!skipped_types[outbound.type])
            push(result, outbound);
    }

    write_json(result);
}

function prepare_subscription(config_path, outbounds_path, output_path, supports_xhttp_arg, plugin_supports_path) {
    let config = read_json_file(config_path);
    let outbounds = read_json_file(outbounds_path);
    let plugin_supports = object_or_empty(read_json_file(plugin_supports_path));

    if (type(config) != "object" || type(outbounds) != "array")
        exit(1);

    let supports_xhttp = supports_xhttp_arg == "true" || supports_xhttp_arg == "1";
    let taken = {};
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) == "object" && non_empty_string(outbound.tag))
            taken[outbound.tag] = true;
    }

    let tags = [];
    let names = [];
    let servers = [];
    let links = [];
    let source_indices = [];
    let visible = [];
    let skipped = 0;
    let skipped_reason_counts = {};
    let prepared = [];
    let tag_map = {};

    for (let i = 0; i < length(outbounds); i++) {
        let outbound = outbounds[i];
        let index = length(prepared) + 1;
        let display_name = safe_string(outbound && (outbound.remark || outbound.tag), "server-" + index);
        let skip_reason = prefilter_skip_reason(outbound, supports_xhttp, plugin_supports);

        if (skip_reason != "") {
            skipped++;
            skipped_reason_counts[skip_reason] = (skipped_reason_counts[skip_reason] || 0) + 1;
            continue;
        }

        let base_tag = safe_string(outbound.tag || outbound.remark, "server-" + index);
        let tag = unique_tag(base_tag, taken);
        let outbound_copy = copy_outbound(outbound);
        outbound_copy.tag = tag;
        let is_hidden = outbound_is_hidden(outbound);
        tag_map[base_tag] = tag;

        push(prepared, outbound_copy);
        push(tags, tag);
        push(names, display_name);
        push(servers, outbound.server || "");
        push(links, outbound.share_link || "");
        push(source_indices, i + 1);
        push(visible, !is_hidden);
        taken[tag] = true;
    }

    rewrite_prepared_outbound_references(prepared, tag_map);

    if (!write_file_json(output_path, {
        outbounds: prepared,
        links,
        source_indices,
        names,
        servers,
        skipped,
        skipped_reason_counts: length(keys(skipped_reason_counts)) > 0 ? skipped_reason_counts : [],
        tags,
        visible
    }))
        exit(1);
}

function skip_count() {
    let prepared = object_or_empty(read_stdin_json());
    print(as_string(prepared.skipped || 0), "\n");
}

function skip_summary() {
    let prepared = object_or_empty(read_stdin_json());
    let counts = object_or_empty(prepared.skipped_reason_counts);
    let entries = [];

    for (let reason, count in counts) {
        push(entries, { reason, count: int(count || 0) });
    }

    sort(entries, function(first, second) {
        if (first.count != second.count)
            return second.count - first.count;
        return first.reason == second.reason ? 0 : (first.reason < second.reason ? -1 : 1);
    });

    let parts = [];
    for (let entry in entries)
        push(parts, entry.count + "x " + entry.reason);
    print(join("; ", parts), "\n");
}

function plugin_names() {
    let outbounds = array_or_empty(read_stdin_json());
    let seen = {};
    for (let outbound in outbounds) {
        if (type(outbound) != "object" || outbound.type != "shadowsocks")
            continue;
        let plugin = as_string(outbound.plugin);
        let semicolon = index(plugin, ";");
        if (semicolon >= 0)
            plugin = substr(plugin, 0, semicolon);
        if (plugin != "")
            seen[plugin] = true;
    }

    for (let name in sort_strings(keys(seen)))
        print(name, "\n");
}

function plugin_supports_from_records(path) {
    let result = {};
    let data = fs.readfile(path);
    if (data != null) {
        for (let line in split(data, "\n")) {
            if (line == "")
                continue;
            let parts = split(line, "\t");
            if (length(parts) >= 2 && parts[0] != "")
                result[parts[0]] = parts[1] == "true";
        }
    }
    write_json(result);
}

function first_direct_tag(config) {
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) == "object" && outbound.type == "direct" && as_string(outbound.tag) != "")
            return outbound.tag;
    }
    return "direct-out";
}

function strip_runtime_fields(config) {
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) == "object") {
            delete outbound.share_link;
            delete outbound.remark;
        }
    }
}

function prepare_validation(new_outbounds_path, updated_path, validation_path) {
    let config = object_or_empty(read_stdin_json());
    let new_outbounds = array_or_empty(read_json_file(new_outbounds_path));
    if (type(config.outbounds) != "array")
        config.outbounds = [];

    for (let outbound in new_outbounds)
        push(config.outbounds, outbound);
    strip_runtime_fields(config);

    let validation = clone(config);
    validation.inbounds = [];
    let route = type(validation.route) == "object" ? validation.route : {};
    route.rules = [];
    route.rule_set = [];
    route.final = first_direct_tag(config);
    validation.route = route;

    if (!write_file_json(updated_path, config))
        exit(1);
    if (!write_file_json(validation_path, validation))
        exit(1);
}

function prepared_entry_visible(prepared, index) {
    let visible = array_or_empty(prepared.visible);
    return index >= length(visible) || visible[index] !== false;
}

function prepared_visible_tags(prepared) {
    let tags = array_or_empty(prepared.tags);
    let result = [];
    for (let i = 0; i < length(tags); i++) {
        if (prepared_entry_visible(prepared, i))
            push(result, tags[i]);
    }
    return result;
}

function prepared_link_refs(prepared, source_section) {
    let tags = array_or_empty(prepared.tags);
    let source_indices = array_or_empty(prepared.source_indices);
    let outbounds = array_or_empty(prepared.outbounds);
    let result = {};

    if (source_section == "")
        return result;

    for (let i = 0; i < length(tags); i++) {
        if (!prepared_entry_visible(prepared, i))
            continue;
        let outbound = type(outbounds[i]) == "object" ? outbounds[i] : {};
        if (outbound.type == "selector" || outbound.type == "urltest")
            continue;
        result[tags[i]] = {
            sourceSection: source_section,
            sourceIndex: int(source_indices[i] || (i + 1))
        };
    }
    return result;
}

function prepared_names(prepared) {
    let tags = array_or_empty(prepared.tags);
    let names = array_or_empty(prepared.names);
    let result = {};
    for (let i = 0; i < length(tags); i++) {
        if (!prepared_entry_visible(prepared, i))
            continue;
        result[tags[i]] = as_string(names[i] || tags[i]);
    }
    return result;
}

function prepared_servers(prepared) {
    let tags = array_or_empty(prepared.tags);
    let servers = array_or_empty(prepared.servers);
    let result = {};
    for (let i = 0; i < length(tags); i++) {
        if (!prepared_entry_visible(prepared, i))
            continue;
        let server = as_string(servers[i]);
        if (server != "")
            result[tags[i]] = server;
    }
    return result;
}

function prepared_names_text(prepared) {
    let lines = [];
    let names = array_or_empty(prepared.names);
    for (let i = 0; i < length(names); i++) {
        if (prepared_entry_visible(prepared, i))
            push(lines, as_string(names[i]));
    }
    return length(lines) > 0 ? join("\n", lines) + "\n" : "";
}

function trim_trailing_newlines(value) {
    value = as_string(value);
    while (length(value) > 0) {
        let last = substr(value, length(value) - 1, 1);
        if (last != "\n" && last != "\r")
            break;
        value = substr(value, 0, length(value) - 1);
    }
    return value;
}

function merge_object_values(target, source) {
    target = object_or_empty(target);
    for (let key, value in object_or_empty(source))
        target[key] = value;
    return target;
}

function prepared_slice(start, end) {
    let prepared = object_or_empty(read_stdin_json());
    start = int(start || 0);
    end = int(end || start);
    prepared.outbounds = slice(array_or_empty(prepared.outbounds), start, end);
    prepared.tags = slice(array_or_empty(prepared.tags), start, end);
    prepared.names = slice(array_or_empty(prepared.names), start, end);
    prepared.servers = slice(array_or_empty(prepared.servers), start, end);
    prepared.links = slice(array_or_empty(prepared.links), start, end);
    prepared.source_indices = slice(array_or_empty(prepared.source_indices), start, end);
    prepared.visible = slice(array_or_empty(prepared.visible), start, end);
    prepared.skipped = 0;
    prepared.skipped_reason_counts = {};
    write_json(prepared);
}

function field_json(field) {
    let value = object_or_empty(read_stdin_json())[field];
    if (field == "outbounds" || field == "tags" || field == "names" || field == "servers" || field == "links" || field == "source_indices" || field == "visible")
        value = array_or_empty(value);
    write_json(value == null ? [] : value);
}

function prepared_field_to_file(field, output_path, count_path) {
    let value = object_or_empty(read_stdin_json())[field];
    if (field == "outbounds" || field == "tags" || field == "names" || field == "servers" || field == "links" || field == "source_indices" || field == "visible")
        value = array_or_empty(value);
    if (value == null)
        value = [];

    let count = (type(value) == "array" || type(value) == "object") ? length(value) : 0;
    if (!write_file_json(output_path, value))
        exit(1);
    if (as_string(count_path) != "" && !write_text_file(count_path, count + "\n"))
        exit(1);
}

function field_length(field) {
    let value = object_or_empty(read_stdin_json())[field];
    if (type(value) != "array" && type(value) != "object")
        print("0\n");
    else
        print(length(value), "\n");
}

function visible_length() {
    let prepared = object_or_empty(read_stdin_json());
    print(length(prepared_visible_tags(prepared)), "\n");
}

function stdin_collection_length() {
    let value = read_stdin_json();
    if (type(value) != "array" && type(value) != "object")
        print("0\n");
    else
        print(length(value), "\n");
}

function print_string_array_csv(values) {
    let tags = [];
    for (let tag in values)
        push(tags, as_string(tag));
    print(join(",", tags), "\n");
}

function tags_csv() {
    let prepared = object_or_empty(read_stdin_json());
    print_string_array_csv(prepared_visible_tags(prepared));
}

function stdin_string_array_csv() {
    print_string_array_csv(array_or_empty(read_stdin_json()));
}

function prepared_state_to_files(source_section, tags_path, tags_csv_path, names_lines_path, link_refs_path, names_path, servers_path) {
    let prepared = object_or_empty(read_stdin_json());
    let tags = prepared_visible_tags(prepared);
    let tag_values = [];
    for (let tag in tags)
        push(tag_values, as_string(tag));

    if (!write_file_json(tags_path, tags) ||
        !write_text_file(tags_csv_path, join(",", tag_values) + "\n") ||
        !write_text_file(names_lines_path, prepared_names_text(prepared)) ||
        !write_file_json(link_refs_path, prepared_link_refs(prepared, source_section)) ||
        !write_file_json(names_path, prepared_names(prepared)) ||
        !write_file_json(servers_path, prepared_servers(prepared)))
        exit(1);
}

function append_prepared_state_to_files(source_section, tags_path, names_lines_path, link_refs_path, names_path, servers_path) {
    let prepared = object_or_empty(read_stdin_json());
    let tags = array_or_empty(read_json_file(tags_path));
    for (let tag in prepared_visible_tags(prepared))
        push(tags, tag);

    let names_lines = trim_trailing_newlines(fs.readfile(names_lines_path));
    let next_names_lines = trim_trailing_newlines(prepared_names_text(prepared));
    if (next_names_lines != "")
        names_lines = names_lines == "" ? next_names_lines : names_lines + "\n" + next_names_lines;

    if (!write_file_json(tags_path, tags) ||
        !write_text_file(names_lines_path, names_lines) ||
        !write_file_json(link_refs_path, merge_object_values(read_json_file(link_refs_path), prepared_link_refs(prepared, source_section))) ||
        !write_file_json(names_path, merge_object_values(read_json_file(names_path), prepared_names(prepared))) ||
        !write_file_json(servers_path, merge_object_values(read_json_file(servers_path), prepared_servers(prepared))))
        exit(1);
}

function display_name() {
    let prepared = object_or_empty(read_stdin_json());
    let names = array_or_empty(prepared.names);
    let outbounds = array_or_empty(prepared.outbounds);
    let result = "";
    let first_visible = -1;
    for (let i = 0; i < length(outbounds); i++) {
        if (prepared_entry_visible(prepared, i)) {
            first_visible = i;
            break;
        }
    }
    if (first_visible >= 0)
        result = as_string(names[first_visible]);
    if (result == "" && first_visible >= 0 && type(outbounds[first_visible]) == "object")
        result = as_string(outbounds[first_visible].tag);
    if (result == "")
        result = "unknown";
    result = replace(result, /[\r\n\t]/g, " ");
    result = replace(result, /[ ]+/g, " ");
    result = trim(result);
    print(result != "" ? result : "unknown", "\n");
}

let mode = ARGV[0] || "";

if (mode == "candidate-outbounds")
    candidate_outbounds(ARGV[1]);
else if (mode == "csv-to-json-array")
    csv_to_json_array(ARGV[1]);
else if (mode == "url-decode")
    print(url_decode(ARGV[1]));
else if (mode == "xhttp-transport-extra")
    xhttp_transport_extra(ARGV[1]);
else if (mode == "shadowsocks-userinfo-format-valid")
    exit(shadowsocks_userinfo_format_valid(ARGV[1]) ? 0 : 1);
else if (mode == "skip-count")
    skip_count();
else if (mode == "skip-summary")
    skip_summary();
else if (mode == "plugin-names")
    plugin_names();
else if (mode == "plugin-supports-from-records")
    plugin_supports_from_records(ARGV[1]);
else if (mode == "prepare-subscription")
    prepare_subscription(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "prepare-validation")
    prepare_validation(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "prepared-slice")
    prepared_slice(ARGV[1], ARGV[2]);
else if (mode == "prepared-field")
    field_json(ARGV[1]);
else if (mode == "prepared-field-to-file")
    prepared_field_to_file(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "prepared-length")
    field_length(ARGV[1]);
else if (mode == "prepared-visible-count")
    visible_length();
else if (mode == "prepared-tags-csv")
    tags_csv();
else if (mode == "stdin-collection-length")
    stdin_collection_length();
else if (mode == "stdin-string-array-csv")
    stdin_string_array_csv();
else if (mode == "validation-error-summary")
    validation_error_summary();
else if (mode == "prepared-state-to-files")
    prepared_state_to_files(as_string(ARGV[1]), ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "append-prepared-state-to-files")
    append_prepared_state_to_files(as_string(ARGV[1]), ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]);
else if (mode == "prepared-display-name")
    display_name();
else {
    warn("Usage: sing_box_config_facade.uc <operation> [args...]\n");
    exit(1);
}
