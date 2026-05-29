#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_json(path) {
    if (path == null || path == "" || path == "-")
        return null;

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

function write_file(path, value) {
    return fs.writefile(path, value);
}

function write_json(path, value) {
    return write_file(path, sprintf("%J", value) + "\n");
}

function write_stdout_json(value) {
    print(sprintf("%J", value), "\n");
}

function is_array(value) {
    return type(value) == "array";
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function object_key_count(value) {
    return type(value) == "object" ? length(keys(value)) : 0;
}

function valid_metadata_object(value) {
    return type(value) == "object" && object_key_count(value) > 1;
}

function safe_section(section) {
    return type(section) == "string" && match(section, /^[A-Za-z0-9_-]+$/);
}

function cache_path(cache_dir, section) {
    return cache_dir + "/" + section + ".json";
}

function load_cache(cache_dir, section) {
    return object_or_empty(read_json(cache_path(cache_dir, section)));
}

function normalize_cache(cache, section, format_version) {
    cache.version = int(format_version || 0);
    cache.section = as_string(section);
    cache.links = object_or_empty(cache.links);
    cache.linkRefs = object_or_empty(cache.linkRefs);
    cache.outboundMetadata = object_or_empty(cache.outboundMetadata);
    cache.outboundMetadata.names = object_or_empty(cache.outboundMetadata.names);
    cache.outboundMetadata.countries = object_or_empty(cache.outboundMetadata.countries);
    cache.servers = object_or_empty(cache.servers);
    cache.subscriptionMetadata = array_or_empty(cache.subscriptionMetadata);
    return cache;
}

function save_cache(cache_dir, section, format_version, cache) {
    cache = normalize_cache(cache, section, format_version);
    let path = cache_path(cache_dir, section);
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);

    if (!write_json(tmp_path, cache))
        exit(1);
    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        exit(1);
    }
}

function write_link_cache(cache_dir, format_version, section, links_path, link_refs_path) {
    let cache = load_cache(cache_dir, section);
    cache.links = object_or_empty(read_json(links_path));
    cache.linkRefs = object_or_empty(read_json(link_refs_path));
    save_cache(cache_dir, section, format_version, cache);
}

function write_outbound_metadata(cache_dir, format_version, section, names_path, countries_path, servers_path) {
    let cache = load_cache(cache_dir, section);
    cache.outboundMetadata = {
        names: object_or_empty(read_json(names_path)),
        countries: object_or_empty(read_json(countries_path))
    };
    cache.servers = object_or_empty(read_json(servers_path));
    save_cache(cache_dir, section, format_version, cache);
}

function metadata_array_from_file(metadata_path) {
    let metadata = read_json(metadata_path);
    let result = [];

    if (is_array(metadata)) {
        for (let item in metadata) {
            if (valid_metadata_object(item))
                push(result, item);
        }
    }
    else if (valid_metadata_object(metadata)) {
        push(result, metadata);
    }

    return result;
}

function write_subscription_metadata(cache_dir, format_version, section, metadata_path) {
    let cache = load_cache(cache_dir, section);
    cache.subscriptionMetadata = metadata_array_from_file(metadata_path);
    save_cache(cache_dir, section, format_version, cache);
}

function read_metadata_items_from_cache(cache_dir, section, legacy_path) {
    let cache = load_cache(cache_dir, section);
    let metadata = cache.subscriptionMetadata;

    if (type(metadata) != "array")
        metadata = read_json(legacy_path);

    let result = [];
    if (is_array(metadata)) {
        for (let item in metadata) {
            if (valid_metadata_object(item))
                push(result, item);
        }
    }
    else if (valid_metadata_object(metadata)) {
        push(result, metadata);
    }

    return result;
}

function metadata_source_index(item) {
    if (type(item) != "object")
        return null;
    let value = item.sourceIndex != null ? item.sourceIndex : item.source_index;
    if (value == null || as_string(value) == "")
        return null;
    return int(value);
}

function metadata_source_section(item) {
    if (type(item) != "object")
        return "";
    return as_string(item.sourceSection != null ? item.sourceSection : item.source_section);
}

function metadata_items_have_source_markers(items) {
    for (let item in items) {
        if (metadata_source_index(item) != null || metadata_source_section(item) != "")
            return true;
    }
    return false;
}

function metadata_matches_source(item, source_index, source_section, has_source_markers) {
    if (!has_source_markers)
        return false;

    let item_section = metadata_source_section(item);
    let item_index = metadata_source_index(item);
    return (item_section != "" && item_section == source_section) ||
        (item_section == "" && item_index == source_index);
}

function attach_source_metadata(item, source_index, source_section) {
    if (type(item) != "object")
        item = {};
    item.sourceIndex = source_index;
    item.sourceSection = as_string(source_section);
    return item;
}

function append_metadata_file(array_path, metadata_path, source_index, source_section) {
    if (array_path == null || array_path == "")
        return;

    let array = array_or_empty(read_json(array_path));
    let metadata = read_json(metadata_path);
    source_index = int(source_index || 0);
    source_section = as_string(source_section);

    if (valid_metadata_object(metadata)) {
        push(array, attach_source_metadata(metadata, source_index, source_section));
        write_json(array_path, array);
    }
}

function append_cached_metadata(array_path, cache_dir, section, legacy_path, source_index, source_section) {
    if (array_path == null || array_path == "")
        return;

    let array = array_or_empty(read_json(array_path));
    let items = read_metadata_items_from_cache(cache_dir, section, legacy_path);
    source_index = int(source_index || 0);
    source_section = as_string(source_section);

    let has_source_markers = metadata_items_have_source_markers(items);
    let selected = null;
    if (has_source_markers) {
        for (let item in items) {
            if (metadata_matches_source(item, source_index, source_section, true)) {
                selected = item;
                break;
            }
        }
    }
    else if (source_index > 0 && source_index <= length(items)) {
        selected = items[source_index - 1];
    }

    if (valid_metadata_object(selected)) {
        push(array, attach_source_metadata(selected, source_index, source_section));
        write_json(array_path, array);
    }
}

function write_source_metadata(cache_dir, format_version, section, source_index, source_section, metadata_path, legacy_path) {
    let cache = load_cache(cache_dir, section);
    let items = read_metadata_items_from_cache(cache_dir, section, legacy_path);
    let kept = [];
    let has_source_markers = metadata_items_have_source_markers(items);
    source_index = int(source_index || 0);
    source_section = as_string(source_section);

    for (let index, item in items) {
        let keep = has_source_markers ?
            !metadata_matches_source(item, source_index, source_section, true) :
            (index + 1) != source_index;
        if (keep && valid_metadata_object(item))
            push(kept, item);
    }

    let metadata = read_json(metadata_path);
    if (valid_metadata_object(metadata))
        push(kept, attach_source_metadata(metadata, source_index, source_section));

    sort(kept, function(first, second) {
        let first_index = metadata_source_index(first) || 999999;
        let second_index = metadata_source_index(second) || 999999;
        return first_index == second_index ? 0 : (first_index < second_index ? -1 : 1);
    });

    cache.subscriptionMetadata = kept;
    save_cache(cache_dir, section, format_version, cache);
}

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

function add_query(params, key, value) {
    value = as_string(value);
    if (value != "")
        push(params, uri_encode(key) + "=" + uri_encode(value));
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
    if (as_string(outbound.password) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
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
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
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

function get_source_link(subscription_dir, ref) {
    if (type(ref) != "object")
        return "";

    let source_section = as_string(ref.sourceSection || ref.source_section);
    let source_index = int(ref.sourceIndex || ref.source_index || 0);
    if (!safe_section(source_section) || source_index < 1)
        return "";

    let source = read_json(subscription_dir + "/" + source_section + ".json");
    if (type(source) != "object" || type(source.outbounds) != "array")
        return "";

    let outbound = source.outbounds[source_index - 1];
    if (type(outbound) != "object")
        return "";

    let link = as_string(outbound.share_link);
    if (link == "")
        link = serialize_outbound_link(outbound);
    return is_copyable_link(link) ? link : "";
}

function get_link(cache_dir, subscription_dir, section, tag, legacy_links_dir) {
    let cache = load_cache(cache_dir, section);
    let links = object_or_empty(cache.links);
    let link_refs = object_or_empty(cache.linkRefs);
    let link = as_string(links[tag]);

    if (!is_copyable_link(link))
        link = get_source_link(subscription_dir, link_refs[tag]);

    if (!is_copyable_link(link) && legacy_links_dir != null && legacy_links_dir != "") {
        let legacy = object_or_empty(read_json(legacy_links_dir + "/" + section + ".json"));
        link = as_string(legacy[tag]);
    }

    if (!is_copyable_link(link))
        link = "";

    write_stdout_json({ link: link });
}

function get_link_states(cache_dir, section, legacy_links_dir) {
    let cache = load_cache(cache_dir, section);
    let result = {};

    for (let tag, link in object_or_empty(cache.links))
        result[tag] = is_copyable_link(link);
    for (let tag, _ in object_or_empty(cache.linkRefs))
        result[tag] = true;

    if (length(keys(result)) == 0 && legacy_links_dir != null && legacy_links_dir != "") {
        let legacy = object_or_empty(read_json(legacy_links_dir + "/" + section + ".json"));
        for (let tag, link in legacy)
            result[tag] = is_copyable_link(link);
    }

    write_stdout_json(result);
}

function get_outbound_metadata(cache_dir, section, legacy_path) {
    let cache = load_cache(cache_dir, section);
    let metadata = cache.outboundMetadata;
    if (type(metadata) != "object")
        metadata = read_json(legacy_path);
    metadata = object_or_empty(metadata);

    write_stdout_json({
        names: object_or_empty(metadata.names),
        countries: object_or_empty(metadata.countries)
    });
}

function get_subscription_metadata(cache_dir, section, legacy_path) {
    let items = read_metadata_items_from_cache(cache_dir, section, legacy_path);
    if (length(items) > 0)
        write_stdout_json(items);
    else
        print("{}\n");
}

let mode = ARGV[0] || "";

if (mode == "write-link-cache") {
    let cache_dir = ARGV[1], format_version = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        exit(1);
    write_link_cache(cache_dir, format_version, section, ARGV[4], ARGV[5]);
}
else if (mode == "write-outbound-metadata") {
    let cache_dir = ARGV[1], format_version = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        exit(1);
    write_outbound_metadata(cache_dir, format_version, section, ARGV[4], ARGV[5], ARGV[6]);
}
else if (mode == "write-subscription-metadata") {
    let cache_dir = ARGV[1], format_version = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        exit(1);
    write_subscription_metadata(cache_dir, format_version, section, ARGV[4]);
}
else if (mode == "append-metadata-file") {
    append_metadata_file(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
}
else if (mode == "append-cached-metadata") {
    append_cached_metadata(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]);
}
else if (mode == "write-source-metadata") {
    let cache_dir = ARGV[1], format_version = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        exit(1);
    write_source_metadata(cache_dir, format_version, section, ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
}
else if (mode == "get-link") {
    let cache_dir = ARGV[1], subscription_dir = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        print("{\"link\":\"\"}\n");
    else
        get_link(cache_dir, subscription_dir, section, ARGV[4] || "", ARGV[5] || "");
}
else if (mode == "get-link-states") {
    let cache_dir = ARGV[1], section = ARGV[2];
    if (!safe_section(section))
        print("{}\n");
    else
        get_link_states(cache_dir, section, ARGV[3] || "");
}
else if (mode == "get-outbound-metadata") {
    let cache_dir = ARGV[1], section = ARGV[2];
    if (!safe_section(section))
        print("{\"names\":{},\"countries\":{}}\n");
    else
        get_outbound_metadata(cache_dir, section, ARGV[3]);
}
else if (mode == "get-subscription-metadata") {
    let cache_dir = ARGV[1], section = ARGV[2];
    if (!safe_section(section))
        print("{}\n");
    else
        get_subscription_metadata(cache_dir, section, ARGV[3]);
}
else {
    warn("Usage: subscription_cache.uc <mode> ...\n");
    exit(1);
}
