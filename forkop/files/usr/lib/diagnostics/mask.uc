// Diagnostics are pasted into issue reports, so every value identifying a subscriber or a
// credential is masked here.

let core_ip = require("core.ip");
let core_url = require("core.url");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function ends_with(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

function is_space_char(value) {
    return value == " " || value == "\t" || value == "\r" || value == "\n";
}

// Replaces the whole remainder of the line, quotes included.
function mask_after_token(line, token) {
    let pos = index(line, token);
    return pos < 0 ? line : substr(line, 0, pos) + token + " 'MASKED'";
}

// Only before a separator, so "option port" does not match "option portal".
function mask_after_token_space(line, token) {
    let pos = index(line, token);
    if (pos < 0)
        return line;

    let space_pos = pos + length(token);
    if (space_pos >= length(line) || !is_space_char(substr(line, space_pos, 1)))
        return line;

    return substr(line, 0, space_pos + 1) + "'MASKED'";
}

function delete_token_space(line, token) {
    let pos = index(line, token);
    if (pos < 0)
        return false;

    let space_pos = pos + length(token);
    return space_pos < length(line) && is_space_char(substr(line, space_pos, 1));
}

const MULTILINE_OPTIONS = [ "option destinations", "option outbound_json", "list outbound_jsons", "option endpoint_json", "option inbound_json",
    "option openvpn_certificate", "option openvpn_key", "option openvpn_tls_crypt_key",
    "option tls_certificate", "option tls_key", "option tls_self_signed_certificate", "option tls_self_signed_key" ];

function forkop_config_line(line) {
    line = mask_after_token(line, "option proxy_string");
    line = mask_after_token(line, "option hwid");
    line = mask_after_token(line, "list header");
    line = mask_after_token(line, "option subscription_url");
    line = mask_after_token(line, "list subscription_urls");
    line = mask_after_token(line, "list urltest_proxy_links");
    line = mask_after_token(line, "list selector_proxy_links");
    line = mask_after_token_space(line, "option uri");
    for (let token in MULTILINE_OPTIONS)
        line = mask_after_token_space(line, token);
    line = mask_after_token_space(line, "list domain");
    line = mask_after_token_space(line, "list domain_suffix");
    line = mask_after_token_space(line, "list domain_keyword");
    line = mask_after_token_space(line, "list domain_regex");
    line = mask_after_token_space(line, "list ip_cidr");
    line = mask_after_token_space(line, "list source_ip_cidr");
    line = mask_after_token_space(line, "list fully_routed_ips");
    line = mask_after_token_space(line, "option dns_server");
    line = mask_after_token_space(line, "option bootstrap_dns_server");
    line = mask_after_token_space(line, "list dns_server");
    line = mask_after_token_space(line, "list bootstrap_dns_server");
    line = mask_after_token_space(line, "option listen");
    line = mask_after_token_space(line, "option listen_port");
    line = mask_after_token_space(line, "option public_host");
    line = mask_after_token(line, "option server_uuid");
    line = mask_after_token(line, "option server_username");
    line = mask_after_token(line, "option server_password");
    line = mask_after_token(line, "option mtproto_secret");
    line = mask_after_token(line, "option shadowsocks_psk");
    // Credentials of a server client section.
    line = mask_after_token(line, "option uuid");
    line = mask_after_token(line, "option password");
    line = mask_after_token_space(line, "option mtproto_faketls");
    line = mask_after_token_space(line, "option mtproto_domain_fronting_ip");
    line = mask_after_token_space(line, "option tls_server_name");
    line = mask_after_token_space(line, "option reality_handshake_server");
    line = mask_after_token_space(line, "option reality_handshake_server_port");
    line = mask_after_token_space(line, "option transport_host");
    line = mask_after_token_space(line, "list transport_hosts");
    line = mask_after_token_space(line, "option tailscale_auth_key");
    line = mask_after_token_space(line, "option tailscale_control_url");
    line = mask_after_token_space(line, "option tailscale_hostname");
    line = mask_after_token_space(line, "option warp_profile_id");
    line = mask_after_token_space(line, "option warp_profile_auth_token");
    line = mask_after_token_space(line, "option warp_profile_private_key");
    line = mask_after_token_space(line, "option warp_profile_license_key");
    line = mask_after_token_space(line, "option pre_shared_key");
    line = mask_after_token_space(line, "option amnezia_header_protection_key");
    line = mask_after_token_space(line, "option wireguard_private_key");
    line = mask_after_token_space(line, "option wireguard_public_key");
    line = mask_after_token_space(line, "option wireguard_pre_shared_key");
    line = mask_after_token_space(line, "option public_key");
    line = mask_after_token_space(line, "option address");
    line = mask_after_token_space(line, "list address");
    line = mask_after_token_space(line, "option port");
    line = mask_after_token_space(line, "list allowed_ips");
    line = mask_after_token_space(line, "list tailscale_advertise_routes");
    line = mask_after_token(line, "option hysteria2_obfs_password");
    line = mask_after_token(line, "option reality_private_key");
    line = mask_after_token(line, "option reality_public_key");
    line = mask_after_token(line, "option reality_short_id");
    line = mask_after_token(line, "list reality_short_id");
    line = mask_after_token(line, "option vless_encryption_private_key");
    line = mask_after_token(line, "option vless_encryption_public_key");
    line = mask_after_token_space(line, "option mixed_proxy_username");
    line = mask_after_token_space(line, "option mixed_proxy_password");
    line = mask_after_token_space(line, "option private_key");
    line = mask_after_token_space(line, "option url");
    line = mask_after_token(line, "option yacd_secret_key");

    return line;
}

// A trailing newline adds no empty line.
function config_lines(data) {
    data = as_string(data);
    let lines = split(data, "\n");
    if (length(lines) > 0 && lines[length(lines) - 1] == "" && substr(data, length(data) - 1) == "\n")
        lines = slice(lines, 0, length(lines) - 1);
    return lines;
}

function lines_text(lines) {
    return length(lines) == 0 ? "" : join("\n", lines) + "\n";
}

function forkop_config(data) {
    let result = [];
    let in_masked_multiline = false;

    for (let line in config_lines(data)) {
        line = as_string(line);

        if (in_masked_multiline) {
            if (index(line, "'") >= 0)
                in_masked_multiline = false;
            continue;
        }

        if (delete_token_space(line, "option tailscale_ephemeral") ||
            delete_token_space(line, "option tailscale_exit_node") ||
            delete_token_space(line, "option tailscale_exit_node_allow_lan_access"))
            continue;

        push(result, forkop_config_line(line));
        if (length(filter(MULTILINE_OPTIONS, (token) => delete_token_space(line, token))) > 0) {
            let first_quote = index(line, "'");
            if (first_quote >= 0 && index(substr(line, first_quote + 1), "'") < 0)
                in_masked_multiline = true;
        }
    }

    return lines_text(result);
}

const SING_BOX_MASKED_KEYS = {
    auth_key: true,
    control_url: true,
    exit_node: true,
    hostname: true,
    listen: true,
    listen_port: true,
    username: true,
    uuid: true,
    server: true,
    server_name: true,
    secret: true,
    password: true,
    private_key: true,
    // VLESS Encryption: the server's private key and the clients' setting with its public one
    decryption: true,
    encryption: true,
    psk: true,
    userkey: true,
    static_key: true,
    key: true,
    client_key: true,
    client_key_password: true,
    certificate: true,
    client_certificate: true,
    mca_certificate: true,
    mca_key: true,
    mca_key_password: true,
    form_entries: true,
    local_hostname: true,
    device_unique_id: true,
    peer_fingerprint: true,
    cookie: true,
    token: true,
    address: true,
    port: true,
    allowed_ips: true,
    pre_shared_key: true,
    header_protection_key: true,
    reserved: true,
    id: true,
    auth_token: true,
    license_key: true,
    link: true,
    public_key: true,
    short_id: true,
    fingerprint: true,
    server_port: true,
    server_ports: true,
    advertise_routes: true,
    domain: true,
    domain_suffix: true,
    domain_keyword: true,
    domain_regex: true,
    ip_cidr: true,
    source_ip_cidr: true,
    headers: true
};

// A DoH path can carry the account: AdGuard's /dns-query/<id>, ControlD's /<id>.
function doh_path(path) {
    path = as_string(path);
    if (path == "" || path == "/" || path == "/dns-query" || path == "/resolve")
        return path;
    return substr(path, 0, 11) == "/dns-query/" ? "/dns-query/MASKED" : "/MASKED";
}

function mask_sing_box_value(value) {
    if (type(value) == "array")
        return map(value, mask_sing_box_value);
    if (type(value) != "object")
        return value;
    let result = {};
    for (let key, item in value)
        result[key] = SING_BOX_MASKED_KEYS[key] ? "MASKED" : mask_sing_box_value(item);
    return result;
}

// A subscription URL carries the subscriber's token; rule-set and latency-test URLs are public.
function sing_box_config(value) {
    let result = mask_sing_box_value(value);
    if (type(result) != "object")
        return result;
    for (let provider in (type(result.providers) == "array" ? result.providers : []))
        if (type(provider) == "object" && provider.url != null)
            provider.url = "MASKED";
    for (let server in (type(result.dns?.servers) == "array" ? result.dns.servers : []))
        if (type(server) == "object" && server.path != null)
            server.path = doh_path(server.path);
    return result;
}

function repeat_char(char, count) {
    let result = "";
    for (let i = 0; i < count; i++)
        result += char;
    return result;
}

function first_field(value, separator) {
    let marker = index(value, separator);
    return marker < 0 ? value : substr(value, 0, marker);
}

// Resolvers that name the account in the leftmost label of their host for DNS
// over TLS or QUIC.
const ACCOUNT_HOST_SUFFIXES = [ ".dns.nextdns.io", ".d.adguard-dns.com", ".dns.controld.com" ];

function dns_server(value) {
    value = as_string(value);
    let scheme = core_url.scheme(value);
    let prefix = scheme == "" ? "" : scheme + "://";
    let host = core_url.host(value);
    let port = core_url.port(value);
    let suffix = port == "" ? "" : ":" + port;
    let path = core_url.path(value);

    for (let ending in ACCOUNT_HOST_SUFFIXES)
        if (ends_with(host, ending))
            host = repeat_char("*", length(first_field(host, "."))) + ending;
    let masked_path = host == "dns.nextdns.io" && length(path) > 1 ? "/" + repeat_char("*", length(path) - 1) : doh_path(path);
    return host == core_url.host(value) && masked_path == path ? value : prefix + host + suffix + masked_path;
}

// The first three hextets: the provider's allocation, not the subscriber.
function masked_ipv6(address) {
    let bytes = iptoarr(address);
    if (bytes == null || length(bytes) != 16)
        return null;
    return sprintf("%x:%x:%x:XXXX:XXXX:XXXX:XXXX:XXXX", bytes[0] << 8 | bytes[1], bytes[2] << 8 | bytes[3], bytes[4] << 8 | bytes[5]);
}

// Enough to tell two addresses apart, not to find either; local and FakeIP addresses stay.
function address(value) {
    if (!core_ip.valid_public_ip(value))
        return value;
    return core_ip.valid_ipv4(value) ? "X.X.X." + split(value, ".")[3] : masked_ipv6(value);
}

// A share-link outbound carries its server inside the link.
const HOST_KEYS = { server: true, server_name: true, address: true, host: true, hostname: true };

function add_host(result, value) {
    if (type(value) == "array") {
        for (let item in value)
            add_host(result, item);
        return;
    }
    value = lc(trim(as_string(value)));
    if (match(value, /^[a-z0-9-]+(\.[a-z0-9-]+)+$/) != null && match(value, /[a-z]/) != null && !core_ip.valid_ip(value))
        result[value] = true;
}

function collect_hosts(value, result) {
    if (type(value) == "array") {
        for (let item in value)
            collect_hosts(item, result);
        return;
    }
    if (type(value) != "object")
        return;
    for (let key, item in value) {
        if (HOST_KEYS[key])
            add_host(result, item);
        else if (key == "link")
            add_host(result, core_url.host(item));
        else
            collect_hosts(item, result);
    }
}

function hosts(config) {
    let result = {};
    if (type(config) != "object")
        return [];
    for (let key in [ "outbounds", "endpoints", "inbounds", "providers" ])
        collect_hosts(config[key], result);
    collect_hosts(config.dns?.servers, result);
    for (let provider in (type(config.providers) == "array" ? config.providers : []))
        add_host(result, core_url.host(provider?.url));
    return sort(keys(result), (a, b) => length(b) - length(a));
}

// Subdomains included, never the middle of a longer word.
function names(value, host_names) {
    value = as_string(value);
    for (let host in host_names ?? [])
        value = replace(value, regexp("(^|[^A-Za-z0-9-])" + replace(host, /\./g, "\\.") + "([^A-Za-z0-9-]|$)", "g"),
            (all, before, after) => before + "MASKED" + after);
    return value;
}

function text(value, host_names, kept) {
    let mask_address = (token) => index(kept ?? [], token) >= 0 ? token : address(token);
    value = replace(as_string(value), /([a-z][a-z0-9+.-]*):\/\/([^\/?# \t\r\n'"<>]+)([^ \t\r\n'"<>]*)/g, (all, scheme, authority, rest) => {
        let at = rindex(authority, "@");
        return scheme + "://" + (at >= 0 ? "MASKED@" + substr(authority, at + 1) : authority) + (rest == "" || rest == "/" ? rest : "/MASKED");
    });
    value = names(value, host_names);
    value = replace(value, /[0-9][0-9.]*[0-9]/g, mask_address);
    return replace(value, /[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*/g, mask_address);
}

return {
    forkop_config,
    sing_box_config,
    dns_server,
    address,
    hosts,
    names,
    text
};
