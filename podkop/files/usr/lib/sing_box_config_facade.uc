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

function write_file_json(path, value) {
    return fs.writefile(path, sprintf("%J", value) + "\n");
}

function write_text_file(path, value) {
    return fs.writefile(path, as_string(value));
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
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

function valid_server_port(value) {
    return type(value) == "int" && value >= 1 && value <= 65535;
}

function valid_server_port_text(value) {
    value = as_string(value);
    if (!match(value, /^\d+$/))
        return false;

    return valid_server_port(int(value, 10));
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
        proxy_type == "shadowsocks" || proxy_type == "socks" || proxy_type == "hysteria2";
}

function supported_flow(flow) {
    return flow == null || flow == "" || flow == "xtls-rprx-vision";
}

function supported_transport_type(transport) {
    return transport == "http" || transport == "ws" || transport == "quic" || transport == "grpc" ||
        transport == "httpupgrade" || transport == "xhttp" || transport == "kcp";
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
    if (proxy_type == "direct" || proxy_type == "selector" || proxy_type == "urltest" ||
        proxy_type == "dns" || proxy_type == "block")
        return "non-proxy outbound type: " + proxy_type;
    if (proxy_type != "vless" && proxy_type != "vmess" && proxy_type != "trojan" &&
        proxy_type != "shadowsocks" && proxy_type != "socks" && proxy_type != "hysteria2")
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

function copy_outbound(outbound) {
    let copy = {};
    for (let key, value in outbound) {
        if (key != "tag" && key != "remark" && key != "share_link")
            copy[key] = value;
    }
    return copy;
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
        if (type(outbound) == "object" && !skipped_types[outbound.type])
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
    let skipped = 0;
    let skipped_reason_counts = {};
    let prepared = [];

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

        push(prepared, outbound_copy);
        push(tags, tag);
        push(names, display_name);
        push(servers, outbound.server || "");
        push(links, outbound.share_link || "");
        push(source_indices, i + 1);
        taken[tag] = true;
    }

    if (!write_file_json(output_path, {
        outbounds: prepared,
        links,
        source_indices,
        names,
        servers,
        skipped,
        skipped_reason_counts: length(keys(skipped_reason_counts)) > 0 ? skipped_reason_counts : [],
        tags
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

function prepared_link_refs(prepared, source_section) {
    let tags = array_or_empty(prepared.tags);
    let source_indices = array_or_empty(prepared.source_indices);
    let result = {};

    if (source_section == "")
        return result;

    for (let i = 0; i < length(tags); i++) {
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
    for (let i = 0; i < length(tags); i++)
        result[tags[i]] = as_string(names[i] || tags[i]);
    return result;
}

function prepared_servers(prepared) {
    let tags = array_or_empty(prepared.tags);
    let servers = array_or_empty(prepared.servers);
    let result = {};
    for (let i = 0; i < length(tags); i++) {
        let server = as_string(servers[i]);
        if (server != "")
            result[tags[i]] = server;
    }
    return result;
}

function prepared_names_lines(prepared) {
    for (let name in array_or_empty(prepared.names))
        print(as_string(name), "\n");
}

function prepared_names_text(prepared) {
    let lines = [];
    for (let name in array_or_empty(prepared.names))
        push(lines, as_string(name));
    return length(lines) > 0 ? join("\n", lines) + "\n" : "";
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
    prepared.skipped = 0;
    prepared.skipped_reason_counts = {};
    write_json(prepared);
}

function field_json(field) {
    let value = object_or_empty(read_stdin_json())[field];
    if (field == "outbounds" || field == "tags" || field == "names" || field == "servers" || field == "links" || field == "source_indices")
        value = array_or_empty(value);
    write_json(value == null ? [] : value);
}

function prepared_field_to_file(field, output_path, count_path) {
    let value = object_or_empty(read_stdin_json())[field];
    if (field == "outbounds" || field == "tags" || field == "names" || field == "servers" || field == "links" || field == "source_indices")
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

function tags_csv() {
    let prepared = object_or_empty(read_stdin_json());
    let tags = [];
    for (let tag in array_or_empty(prepared.tags))
        push(tags, as_string(tag));
    print(join(",", tags), "\n");
}

function metadata_command(kind, source_section) {
    let prepared = object_or_empty(read_stdin_json());
    if (kind == "link-refs")
        write_json(prepared_link_refs(prepared, source_section));
    else if (kind == "names")
        write_json(prepared_names(prepared));
    else if (kind == "servers")
        write_json(prepared_servers(prepared));
    else if (kind == "names-lines")
        prepared_names_lines(prepared);
}

function prepared_state_to_files(source_section, tags_path, tags_csv_path, names_lines_path, link_refs_path, names_path, servers_path) {
    let prepared = object_or_empty(read_stdin_json());
    let tags = array_or_empty(prepared.tags);
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

function display_name() {
    let prepared = object_or_empty(read_stdin_json());
    let names = array_or_empty(prepared.names);
    let outbounds = array_or_empty(prepared.outbounds);
    let result = as_string(names[0]);
    if (result == "" && length(outbounds) > 0 && type(outbounds[0]) == "object")
        result = as_string(outbounds[0].tag);
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
else if (mode == "prepared-link-refs")
    metadata_command("link-refs", as_string(ARGV[1]));
else if (mode == "prepared-names")
    metadata_command("names", "");
else if (mode == "prepared-servers")
    metadata_command("servers", "");
else if (mode == "prepared-names-lines")
    metadata_command("names-lines", "");
else if (mode == "prepared-slice")
    prepared_slice(ARGV[1], ARGV[2]);
else if (mode == "prepared-field")
    field_json(ARGV[1]);
else if (mode == "prepared-field-to-file")
    prepared_field_to_file(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "prepared-length")
    field_length(ARGV[1]);
else if (mode == "prepared-tags-csv")
    tags_csv();
else if (mode == "prepared-state-to-files")
    prepared_state_to_files(as_string(ARGV[1]), ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "prepared-display-name")
    display_name();
else {
    warn("Usage: sing_box_config_facade.uc <operation> [args...]\n");
    exit(1);
}
