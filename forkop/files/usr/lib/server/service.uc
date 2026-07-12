#!/usr/bin/env ucode

let fs = require("fs");
let core_ip = require("core.ip");
let core_url = require("core.url");
let uci = require("core.uci");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function run(command) {
    return system(command) == 0;
}

function output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return replace(as_string(data), /[\r\n]+$/g, "");
}

function log(message, level) {
    level = as_string(level || "info");
    run("logger -t " + shell_quote("forkop") + " " + shell_quote("[" + level + "] " + as_string(message)));
}

function fatal(message) {
    log(message, "fatal");
    exit(1);
}

function uci_get(path) {
    return uci.get(path);
}

function uci_set(path, value) {
    return uci.set(path, value);
}

function uci_commit(package_name) {
    return uci.commit(package_name);
}

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function uci_sections(type_name) {
    return uci.sections(CONFIG_NAME, type_name);
}

function config_path(section, option) {
    return CONFIG_NAME + "." + as_string(section) + "." + as_string(option);
}

function config_get(section, option, fallback) {
    let value = uci_get(config_path(section, option));
    return value == "" ? as_string(fallback || "") : value;
}

let SERVER_DEFAULTS_CHANGED = false;

function server_default_set_option(section, option, value) {
    value = as_string(value);
    if (value == "")
        return;
    if (uci_get(config_path(section, option)) != "")
        return;
    if (uci_set(config_path(section, option), value))
        SERVER_DEFAULTS_CHANGED = true;
}

function server_set_option(section, option, value) {
    value = as_string(value);
    if (value == "")
        return;
    if (uci_get(config_path(section, option)) == value)
        return;
    if (uci_set(config_path(section, option), value))
        SERVER_DEFAULTS_CHANGED = true;
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

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_stdin_json() {
    try {
        return json(read_stdin());
    }
    catch (e) {
        return null;
    }
}

function stdin_first_nonempty_line() {
    for (let line in split(read_stdin(), "\n")) {
        if (trim(as_string(line)) != "") {
            print(line, "\n");
            return;
        }
    }
}

function stdin_remove_newlines() {
    print(replace(read_stdin(), /\n/g, ""));
}

function shell_single_quote(value) {
    value = as_string(value);
    if (value == "")
        return;
    print("'", replace(value, /'/g, "'\\''"), "'\n");
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function array_append_string(value) {
    let result = array_or_empty(read_stdin_json());
    push(result, as_string(value));
    write_json(result);
}

function regex_matches(value, pattern) {
    pattern = as_string(pattern);
    if (pattern == "")
        return false;

    try {
        return match(as_string(value), regexp(pattern)) != null;
    }
    catch (e) {
        return false;
    }
}

function valid_dotted_ipv4(value) {
    return regex_matches(value, "^([0-9]{1,3}\\.){3}[0-9]{1,3}$");
}

function valid_file_path(value) {
    value = as_string(value);
    return value != "" &&
        value != "/" &&
        substr(value, length(value) - 1) != "/" &&
        regex_matches(value, "^/[A-Za-z0-9_./-]+$");
}

function valid_duration(value) {
    value = as_string(value);
    return value != "" && regex_matches(value, "^([0-9]+(ns|us|ms|s|m|h))+$");
}

function valid_client_value(value) {
    value = as_string(value);
    return value != "" && !regex_matches(value, "[[:cntrl:]]");
}

function valid_port(value) {
    value = as_string(value);
    if (value == "" || regex_matches(value, "[^0-9]"))
        return false;

    value = int(value);
    return value >= 1 && value <= 65535;
}

function normalize_host(value) {
    value = as_string(value);
    if (substr(value, 0, 1) == "[")
        value = substr(value, 1);
    if (substr(value, length(value) - 1) == "]")
        value = substr(value, 0, length(value) - 1);
    return lc(value);
}

function str_endswith(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

function str_remove_suffix(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return str_endswith(value, suffix) ? substr(value, 0, length(value) - length(suffix)) : value;
}

function valid_ipv4(value) {
    return core_ip.valid_ipv4(value, false, false);
}

function valid_domain(value) {
    return regex_matches(ascii_lower(value), "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$");
}

function valid_host(value) {
    value = normalize_host(value);
    return value != "" && (valid_ipv4(value) || core_ip.valid_ipv6(value) || valid_domain(value));
}

function valid_absolute_path(value) {
    return substr(as_string(value), 0, 1) == "/";
}

function valid_http_url(value) {
    value = as_string(value);
    let scheme = index(value, "://");
    if (scheme < 0)
        return false;

    let prefix = substr(value, 0, scheme + 3);
    if (prefix != "http://" && prefix != "https://")
        return false;

    let rest = substr(value, scheme + 3);
    if (rest == "")
        return false;

    return valid_host(core_url.host(value));
}

function valid_uuid(value) {
    return regex_matches(value, "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
}

function valid_nonnegative_integer(value) {
    return regex_matches(value, "^[0-9]+$");
}

function valid_reality_short_id(value) {
    return regex_matches(value, "^[0-9a-fA-F]{1,8}$");
}

function valid_transport_service_name(value) {
    return regex_matches(value, "^[A-Za-z0-9_.-]+$");
}

function mtproto_base_secret_value(value) {
    value = lc(as_string(value));
    if (regex_matches(value, "^[0-9a-f]{32}$"))
        return value;
    if (regex_matches(value, "^ee[0-9a-f]{32}([0-9a-f]{2})+$"))
        return substr(value, 2, 32);
    return "";
}

function mtproto_base_secret_from_value(value) {
    let result = mtproto_base_secret_value(value);
    if (result == "")
        exit(1);
    print(result, "\n");
}

function hex_digit_value(value) {
    value = ord(lc(as_string(value)));
    if (value >= 48 && value <= 57)
        return value - 48;
    if (value >= 97 && value <= 102)
        return value - 87;
    return -1;
}

function hex_to_string_value(value) {
    value = as_string(value);
    if (length(value) == 0 || length(value) % 2 != 0 || !regex_matches(value, "^([0-9a-fA-F]{2})+$"))
        return null;

    let result = "";
    for (let i = 0; i < length(value); i += 2) {
        let high = hex_digit_value(substr(value, i, 1));
        let low = hex_digit_value(substr(value, i + 1, 1));
        if (high < 0 || low < 0)
            return null;
        result += chr(high * 16 + low);
    }
    return result;
}

function string_to_hex(value) {
    value = as_string(value);
    for (let i = 0; i < length(value); i++)
        print(sprintf("%02x", ord(substr(value, i, 1))));
}

function mtproto_faketls_value(value) {
    value = lc(as_string(value));
    if (!regex_matches(value, "^ee[0-9a-f]{32}([0-9a-f]{2})+$"))
        return "";
    let result = hex_to_string_value(substr(value, 34));
    return result == null ? "" : result;
}

function mtproto_faketls_from_secret(value) {
    let result = mtproto_faketls_value(value);
    if (result == "")
        exit(1);
    print(result);
}

function mtproto_build_secret(base, faketls, padding) {
    if (as_string(padding) != "1")
        exit(1);

    print("ee", as_string(base));
    string_to_hex(faketls);
    print("\n");
}

function valid_mtproto_base_secret(value) {
    value = lc(as_string(value));
    return regex_matches(value, "^[0-9a-f]{32}$") && value != "00000000000000000000000000000000";
}

function default_security_for_protocol(protocol) {
    protocol = as_string(protocol);
    if (protocol == "vless")
        print("reality\n");
    else if (protocol == "trojan" || protocol == "hysteria2")
        print("tls\n");
    else
        print("none\n");
}

function safe_filename(value) {
    value = as_string(value);
    for (let i = 0; i < length(value); i++) {
        let chr = substr(value, i, 1);
        print(regex_matches(chr, "^[A-Za-z0-9_.-]$") ? chr : "_");
    }
}

function valid_public_ipv4(value) {
    value = as_string(value);
    if (!valid_ipv4(value))
        return false;

    let parts = split(value, ".");
    let a = int(parts[0]);
    let b = int(parts[1]);

    if (a == 0 || a == 10 || a == 127 || a >= 224)
        return false;
    if (a == 169 && b == 254)
        return false;
    if (a == 192 && (b == 168 || b == 0 || b == 2))
        return false;
    if (a == 198 && (b == 18 || b == 19 || b == 51))
        return false;
    if (a == 203 && b == 0)
        return false;
    if (a == 100 && b >= 64 && b <= 127)
        return false;
    if (a == 172 && b >= 16 && b <= 31)
        return false;

    return true;
}

function valid_ipv6_literal(value) {
    return core_ip.valid_ipv6(value);
}

function valid_cidr(value) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash < 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let address = substr(value, 0, slash);
    let prefix = substr(value, slash + 1);
    if (prefix == "" || regex_matches(prefix, "[^0-9]"))
        return false;

    prefix = int(prefix);
    if (valid_ipv4(address))
        return prefix >= 0 && prefix <= 32;
    if (valid_ipv6_literal(address))
        return prefix >= 0 && prefix <= 128;

    return false;
}

function server_users_from_tsv(protocol, path) {
    let result = [];
    let data = fs.readfile(path);

    if (data != null) {
        for (let line in split(as_string(data), "\n")) {
            if (line == "")
                continue;

            let parts = split(line, "\t");
            let name = as_string(parts[0] || "");
            let credential = as_string(parts[1] || "");
            let flow = as_string(parts[2] || "");

            if (credential == "")
                continue;

            if (protocol == "vless") {
                let user = { uuid: credential };
                if (name != "")
                    user.name = name;
                if (flow != "")
                    user.flow = flow;
                push(result, user);
            }
            else if (protocol == "vmess") {
                let user = { uuid: credential, alterId: int(flow || "0", 10) || 0 };
                if (name != "")
                    user.name = name;
                push(result, user);
            }
            else if (protocol == "trojan") {
                let user = { password: credential };
                if (name != "")
                    user.name = name;
                push(result, user);
            }
            else if (protocol == "hysteria2") {
                let user = { password: credential };
                if (name != "")
                    user.name = name;
                push(result, user);
            }
            else if (protocol == "mtproto") {
                let user = { secret: credential };
                if (name != "")
                    user.name = name;
                push(result, user);
            }
            else if (protocol == "socks") {
                let user = {
                    username: name != "" ? name : "user",
                    password: credential
                };
                push(result, user);
            }
        }
    }

    write_json(result);
}

function json_length(path) {
    let value = read_json_file(path);
    if (type(value) == "array" || type(value) == "object")
        print(length(value), "\n");
    else
        print("0\n");
}

function error_response(message) {
    write_json({
        success: false,
        message: as_string(message)
    });
}

function reality_keypair_response(private_key, public_key) {
    write_json({
        success: true,
        private_key: as_string(private_key),
        public_key: as_string(public_key)
    });
}

function tls_fingerprint_response(fingerprint) {
    write_json({
        success: true,
        sha256: as_string(fingerprint)
    });
}

function first_key_value_line_value(data, prefix) {
    prefix = as_string(prefix);
    for (let line in split(as_string(data), "\n")) {
        line = as_string(line);
        if (!regex_matches(line, "^" + prefix + ":"))
            continue;

        let value = substr(line, length(prefix) + 1);
        return replace(value, /^[ \t\r]*/, "");
    }

    return null;
}

function reality_keypair_tsv() {
    let data = read_stdin();
    let private_key = first_key_value_line_value(data, "PrivateKey");
    let public_key = first_key_value_line_value(data, "PublicKey");

    if (private_key == null || public_key == null || private_key == "" || public_key == "")
        exit(1);

    print(private_key, "\t", public_key, "\n");
}

function pem_block(data, begin_marker, end_marker) {
    let lines = [];
    let in_block = false;

    for (let line in split(as_string(data), "\n")) {
        line = str_remove_suffix(as_string(line), "\r");
        if (!in_block && line != begin_marker)
            continue;

        in_block = true;
        push(lines, line);

        if (line == end_marker)
            return join("\n", lines);
    }

    return "";
}

function write_tls_keypair_files(key_path, certificate_path) {
    let data = read_stdin();
    let key = pem_block(data, "-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----");
    let cert = pem_block(data, "-----BEGIN CERTIFICATE-----", "-----END CERTIFICATE-----");

    if (key == "" || cert == "")
        exit(1);

    if (!fs.writefile(key_path, key + "\n"))
        exit(1);
    if (!fs.writefile(certificate_path, cert + "\n"))
        exit(1);
}

function certificate_base64(path) {
    let data = fs.readfile(path);
    let cert = pem_block(data, "-----BEGIN CERTIFICATE-----", "-----END CERTIFICATE-----");
    let lines = [];

    if (cert == "")
        exit(1);

    for (let line in split(cert, "\n")) {
        line = replace(as_string(line), /\r/g, "");
        if (line == "-----BEGIN CERTIFICATE-----" || line == "-----END CERTIFICATE-----" || line == "")
            continue;

        push(lines, line);
    }

    if (length(lines) == 0)
        exit(1);

    print(join("\n", lines), "\n");
}

function valid_sha256_hex(value) {
    return regex_matches(value, "^[0-9a-f]{64}$");
}

function command_first_nonempty_line(command) {
    for (let line in split(output(command), "\n"))
        if (trim(as_string(line)) != "")
            return line;
    return "";
}

function server_generate_uuid() {
    return command_first_nonempty_line("sing-box generate uuid 2>/dev/null");
}

function server_generate_password() {
    return replace(output("sing-box generate rand --base64 18 2>/dev/null"), /\n/g, "");
}

function server_generate_short_id() {
    return replace(output("sing-box generate rand --hex 4 2>/dev/null"), /\n/g, "");
}

function server_generate_mtproto_secret() {
    let random_hex = replace(output("sing-box generate rand --hex 16 2>/dev/null"), /\n/g, "");
    if (random_hex == "")
        random_hex = replace(output("head -c 16 /dev/urandom | hexdump -ve '1/1 \"%02x\"' 2>/dev/null"), /\n/g, "");
    if (random_hex == "00000000000000000000000000000000")
        random_hex = "11111111111111111111111111111111";
    return random_hex;
}

function default_security_value(protocol) {
    protocol = as_string(protocol);
    if (protocol == "vless")
        return "reality";
    if (protocol == "trojan" || protocol == "hysteria2")
        return "tls";
    return "none";
}

function server_effective_security_value(section, protocol) {
    protocol = as_string(protocol);
    let security = config_get(section, "security", "");
    if (security == "")
        security = default_security_value(protocol);

    if (protocol == "shadowsocks" || protocol == "socks" || protocol == "mtproto" || protocol == "tailscale" || protocol == "json_inbound")
        security = "none";
    else if (protocol == "hysteria2")
        security = "tls";
    else if ((protocol == "vmess" || protocol == "trojan") && security == "reality")
        security = default_security_value(protocol);

    return security;
}

function print_effective_security(section, protocol) {
    print(server_effective_security_value(section, protocol), "\n");
}

function generate_reality_keypair_values() {
    let data = output("sing-box generate reality-keypair 2>/dev/null");
    let private_key = first_key_value_line_value(data, "PrivateKey");
    let public_key = first_key_value_line_value(data, "PublicKey");

    if (private_key == null || public_key == null || private_key == "" || public_key == "")
        return null;

    return {
        private_key: private_key,
        public_key: public_key
    };
}

function generate_reality_keypair_cli() {
    let pair = generate_reality_keypair_values();
    if (pair == null) {
        error_response("Failed to generate Reality key pair");
        exit(1);
    }

    reality_keypair_response(pair.private_key, pair.public_key);
}

function write_tls_keypair_data(data, key_path, certificate_path) {
    let key = pem_block(data, "-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----");
    let cert = pem_block(data, "-----BEGIN CERTIFICATE-----", "-----END CERTIFICATE-----");

    if (key == "" || cert == "")
        return false;

    return fs.writefile(key_path, key + "\n") && fs.writefile(certificate_path, cert + "\n");
}

function server_generate_tls_keypair_files(server_name, certificate_path, key_path) {
    let data = output("sing-box generate tls-keypair " + shell_quote(server_name) + " 2>/dev/null");
    if (data == "")
        return false;

    let key_dir = replace(as_string(key_path), /\/[^\/]*$/, "");
    let cert_dir = replace(as_string(certificate_path), /\/[^\/]*$/, "");
    if (!run("mkdir -p " + shell_quote(key_dir) + " " + shell_quote(cert_dir)))
        return false;

    if (!write_tls_keypair_data(data, key_path, certificate_path))
        return false;

    run("chmod 600 " + shell_quote(key_path) + " >/dev/null 2>&1");
    return true;
}

function certificate_base64_text(path) {
    let data = fs.readfile(path);
    let cert = pem_block(data, "-----BEGIN CERTIFICATE-----", "-----END CERTIFICATE-----");
    let lines = [];

    if (cert == "")
        return "";

    for (let line in split(cert, "\n")) {
        line = replace(as_string(line), /\r/g, "");
        if (line == "-----BEGIN CERTIFICATE-----" || line == "-----END CERTIFICATE-----" || line == "")
            continue;
        push(lines, line);
    }

    return length(lines) == 0 ? "" : join("\n", lines) + "\n";
}

function server_tls_certificate_sha256_from_file(certificate_path) {
    if (!valid_file_path(certificate_path))
        return "";
    let base64_text = certificate_base64_text(certificate_path);
    if (base64_text == "")
        return "";

    let tmp_path = output("mktemp 2>/dev/null");
    if (tmp_path == "")
        return "";

    if (!fs.writefile(tmp_path, base64_text)) {
        fs.unlink(tmp_path);
        return "";
    }

    let fingerprint = output("base64 -d " + shell_quote(tmp_path) + " 2>/dev/null | sha256sum 2>/dev/null");
    fs.unlink(tmp_path);
    fingerprint = substr(fingerprint, 0, index(fingerprint, " ") >= 0 ? index(fingerprint, " ") : length(fingerprint));
    return valid_sha256_hex(fingerprint) ? fingerprint : "";
}

function get_tls_certificate_sha256_cli(section) {
    if (as_string(section) == "") {
        error_response("Missing server section");
        exit(1);
    }

    let protocol = config_get(section, "protocol", "vless");
    let security = server_effective_security_value(section, protocol);
    if (security != "tls") {
        error_response("Server does not use TLS");
        exit(1);
    }

    let certificate_path = config_get(section, "tls_certificate_path", "");
    if (certificate_path == "") {
        error_response("TLS certificate path is empty");
        exit(1);
    }

    let fingerprint = server_tls_certificate_sha256_from_file(certificate_path);
    if (fingerprint == "") {
        error_response("Failed to read TLS certificate fingerprint");
        exit(1);
    }

    tls_fingerprint_response(fingerprint);
}

function network_status_ipv4_address(data) {
    try {
        data = json(as_string(data));
    }
    catch (e) {
        return "";
    }

    let addresses = data["ipv4-address"];
    if (type(addresses) != "array")
        return "";

    for (let item in addresses)
        if (type(item) == "object" && as_string(item.address) != "")
            return as_string(item.address);

    return "";
}

function server_detect_default_public_host() {
    for (let interface in [ "wan", "wwan" ]) {
        let ip = network_status_ipv4_address(output("ubus -S call " + shell_quote("network.interface." + interface) + " status 2>/dev/null"));
        if (valid_public_ipv4(ip))
            return ip;
    }

    let lan_ip = uci_get("network.lan.ipaddr");
    return valid_dotted_ipv4(lan_ip) ? lan_ip : "";
}

function first_server_user(section) {
    let users = words(uci_get(config_path(section, "server_users")));
    return length(users) > 0 ? users[0] : "";
}

function server_prepare_legacy_user_defaults(section, protocol) {
    let entry = first_server_user(section);
    if (entry == "")
        return;

    let parts = split(entry, "|");
    let name = "client";
    let credential = entry;
    let extra = "";
    if (length(parts) > 1) {
        name = as_string(parts[0]);
        credential = as_string(parts[1]);
        extra = as_string(parts[2] || "");
    }

    if (protocol == "vless" || protocol == "vmess")
        server_default_set_option(section, "server_uuid", credential);
    else if (protocol == "shadowsocks" || protocol == "socks" || protocol == "trojan" || protocol == "hysteria2")
        server_default_set_option(section, "server_password", credential);
    else if (protocol == "mtproto") {
        let mtproto_faketls = mtproto_faketls_value(credential);
        let base_secret = mtproto_base_secret_value(credential);
        server_default_set_option(section, "mtproto_secret", base_secret != "" ? base_secret : credential);
        server_default_set_option(section, "mtproto_faketls", mtproto_faketls != "" ? mtproto_faketls : "google.com");
        server_default_set_option(section, "mtproto_padding", "1");
    }

    if (protocol == "socks" && name != "")
        server_default_set_option(section, "server_username", name);
    if (protocol == "vless" && extra != "")
        server_default_set_option(section, "vless_flow", extra);
}

function server_prepare_tls_defaults(section, protocol, security) {
    if (security != "tls")
        return;
    if (config_get(section, "enabled", "1") == "0")
        return;

    let tls_server_name = config_get(section, "tls_server_name", "");
    if (tls_server_name == "")
        tls_server_name = "www.microsoft.com";
    server_default_set_option(section, "tls_server_name", tls_server_name);

    let certificate_path = config_get(section, "tls_certificate_path", "");
    let key_path = config_get(section, "tls_key_path", "");
    if (certificate_path == "" || key_path == "") {
        let safe_name = safe_filename_string(section);
        let default_dir = "/etc/forkop/server-certs";
        if (certificate_path == "")
            certificate_path = default_dir + "/" + safe_name + ".crt";
        if (key_path == "")
            key_path = default_dir + "/" + safe_name + ".key";
        server_set_option(section, "tls_certificate_path", certificate_path);
        server_set_option(section, "tls_key_path", key_path);
    }

    if (!valid_file_path(certificate_path))
        fatal("Server '" + section + "' has invalid TLS certificate path. Specify a file path. Aborted.");
    if (!valid_file_path(key_path))
        fatal("Server '" + section + "' has invalid TLS key path. Specify a file path. Aborted.");
    if (certificate_path == key_path)
        fatal("Server '" + section + "' has the same TLS certificate and key path. Specify different files. Aborted.");

    if (!run("[ -s " + shell_quote(certificate_path) + " ] && [ -s " + shell_quote(key_path) + " ]")) {
        log("Generating self-signed TLS certificate for server '" + section + "'", "info");
        if (!server_generate_tls_keypair_files(tls_server_name, certificate_path, key_path))
            fatal("Failed to generate TLS certificate for server '" + section + "'. Aborted.");
    }
}

function safe_filename_string(value) {
    value = as_string(value);
    let result = [];
    for (let i = 0; i < length(value); i++) {
        let chr = substr(value, i, 1);
        push(result, regex_matches(chr, "^[A-Za-z0-9_.-]$") ? chr : "_");
    }
    return join("", result);
}

function prepare_server_defaults(section) {
    let protocol = config_get(section, "protocol", "vless");
    if (!(protocol == "shadowsocks" || protocol == "socks" || protocol == "vmess" || protocol == "vless" ||
        protocol == "trojan" || protocol == "hysteria2" || protocol == "mtproto" || protocol == "tailscale" ||
        protocol == "json_inbound"))
        fatal("Server '" + section + "' has unsupported protocol '" + protocol + "'. Aborted.");

    server_default_set_option(section, "protocol", protocol);
    server_default_set_option(section, "label", section);
    server_default_set_option(section, "enabled", "1");
    server_default_set_option(section, "routing_mode", "rules");

    if (protocol == "json_inbound") {
        server_set_option(section, "security", "none");
        return;
    }

    server_default_set_option(section, "listen", "0.0.0.0");
    server_default_set_option(section, "listen_port", "443");
    server_default_set_option(section, "public_host", server_detect_default_public_host());

    let security = server_effective_security_value(section, protocol);
    server_set_option(section, "security", security);
    server_prepare_legacy_user_defaults(section, protocol);

    if (protocol == "vless" || protocol == "vmess") {
        if (uci_get(config_path(section, "server_uuid")) == "") {
            let uuid = server_generate_uuid();
            server_default_set_option(section, "server_uuid", uuid);
        }
    }
    else if (protocol == "shadowsocks" || protocol == "socks" || protocol == "trojan" || protocol == "hysteria2") {
        if (uci_get(config_path(section, "server_password")) == "") {
            let password = server_generate_password();
            server_default_set_option(section, "server_password", password);
        }
    }

    if (protocol == "mtproto") {
        let mtproto_secret = uci_get(config_path(section, "mtproto_secret"));
        let mtproto_faketls = "";
        let mtproto_base_secret = "";
        if (mtproto_secret != "") {
            mtproto_faketls = mtproto_faketls_value(mtproto_secret);
            mtproto_base_secret = mtproto_base_secret_value(mtproto_secret);
        }
        if (mtproto_base_secret == "")
            mtproto_base_secret = server_generate_mtproto_secret();
        if (mtproto_secret != mtproto_base_secret)
            server_set_option(section, "mtproto_secret", mtproto_base_secret);
        server_default_set_option(section, "mtproto_faketls", mtproto_faketls != "" ? mtproto_faketls : "google.com");
        server_default_set_option(section, "mtproto_padding", "1");
        server_default_set_option(section, "mtproto_domain_fronting_port", "443");
        server_default_set_option(section, "mtproto_prefer_ip", "prefer-ipv4");
        server_default_set_option(section, "mtproto_tolerate_time_skewness", "3s");
        server_default_set_option(section, "mtproto_idle_timeout", "5m");
        server_default_set_option(section, "mtproto_handshake_timeout", "10s");
    }

    if (protocol == "socks" && uci_get(config_path(section, "server_username")) == "")
        server_default_set_option(section, "server_username", config_get(section, "label", section));
    if (protocol == "vless")
        server_default_set_option(section, "vless_flow", "none");
    if (protocol == "vmess")
        server_default_set_option(section, "vmess_alter_id", "0");
    if (protocol == "shadowsocks")
        server_default_set_option(section, "shadowsocks_method", "aes-128-gcm");
    if (protocol == "tailscale") {
        let safe_name = safe_filename_string(section);
        server_default_set_option(section, "tailscale_control_url", "https://controlplane.tailscale.com");
        server_default_set_option(section, "tailscale_hostname", "forkop-" + safe_name);
        server_default_set_option(section, "tailscale_advertise_exit_node", "1");
    }

    if (security == "reality") {
        server_default_set_option(section, "tls_server_name", "www.microsoft.com");
        server_default_set_option(section, "client_fingerprint", "chrome");
        server_default_set_option(section, "reality_handshake_server", "www.microsoft.com");
        server_default_set_option(section, "reality_handshake_server_port", "443");
        if (uci_get(config_path(section, "reality_short_id")) == "")
            server_default_set_option(section, "reality_short_id", server_generate_short_id());
        server_default_set_option(section, "reality_max_time_difference", "1m");

        let reality_private_key = uci_get(config_path(section, "reality_private_key"));
        let reality_public_key = uci_get(config_path(section, "reality_public_key"));
        if (reality_private_key == "" || reality_public_key == "") {
            log("Generating Reality key pair for server '" + section + "'", "info");
            let pair = generate_reality_keypair_values();
            if (pair == null)
                fatal("Failed to generate Reality key pair for server '" + section + "'. Aborted.");
            server_set_option(section, "reality_private_key", pair.private_key);
            server_set_option(section, "reality_public_key", pair.public_key);
        }
    }

    server_prepare_tls_defaults(section, protocol, security);
}

function prepare_all_server_defaults() {
    SERVER_DEFAULTS_CHANGED = false;
    for (let section in uci_sections("server"))
        prepare_server_defaults(section);
    if (SERVER_DEFAULTS_CHANGED)
        uci_commit(CONFIG_NAME);
}

let mode = ARGV[0] || "";

if (mode == "valid-file-path")
    exit(valid_file_path(ARGV[1]) ? 0 : 1);
else if (mode == "valid-dotted-ipv4")
    exit(valid_dotted_ipv4(ARGV[1]) ? 0 : 1);
else if (mode == "stdin-first-nonempty-line")
    stdin_first_nonempty_line();
else if (mode == "stdin-remove-newlines")
    stdin_remove_newlines();
else if (mode == "shell-single-quote")
    shell_single_quote(ARGV[1]);
else if (mode == "valid-port")
    exit(valid_port(ARGV[1]) ? 0 : 1);
else if (mode == "normalize-host")
    print(normalize_host(ARGV[1]), "\n");
else if (mode == "valid-host")
    exit(valid_host(ARGV[1]) ? 0 : 1);
else if (mode == "valid-absolute-path")
    exit(valid_absolute_path(ARGV[1]) ? 0 : 1);
else if (mode == "valid-http-url")
    exit(valid_http_url(ARGV[1]) ? 0 : 1);
else if (mode == "valid-duration")
    exit(valid_duration(ARGV[1]) ? 0 : 1);
else if (mode == "valid-client-value")
    exit(valid_client_value(ARGV[1]) ? 0 : 1);
else if (mode == "valid-uuid")
    exit(valid_uuid(ARGV[1]) ? 0 : 1);
else if (mode == "valid-nonnegative-integer")
    exit(valid_nonnegative_integer(ARGV[1]) ? 0 : 1);
else if (mode == "valid-reality-short-id")
    exit(valid_reality_short_id(ARGV[1]) ? 0 : 1);
else if (mode == "valid-transport-service-name")
    exit(valid_transport_service_name(ARGV[1]) ? 0 : 1);
else if (mode == "mtproto-base-secret")
    mtproto_base_secret_from_value(ARGV[1]);
else if (mode == "mtproto-faketls-from-secret")
    mtproto_faketls_from_secret(ARGV[1]);
else if (mode == "mtproto-build-secret")
    mtproto_build_secret(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "valid-mtproto-base-secret")
    exit(valid_mtproto_base_secret(ARGV[1]) ? 0 : 1);
else if (mode == "default-security-for-protocol")
    default_security_for_protocol(ARGV[1]);
else if (mode == "effective-security")
    print_effective_security(ARGV[1], ARGV[2]);
else if (mode == "safe-filename")
    safe_filename(ARGV[1]);
else if (mode == "valid-public-ipv4")
    exit(valid_public_ipv4(ARGV[1]) ? 0 : 1);
else if (mode == "valid-cidr")
    exit(valid_cidr(ARGV[1]) ? 0 : 1);
else if (mode == "server-users-from-tsv")
    server_users_from_tsv(ARGV[1], ARGV[2]);
else if (mode == "json-length")
    json_length(ARGV[1]);
else if (mode == "array-append-string")
    array_append_string(ARGV[1]);
else if (mode == "error-response")
    error_response(ARGV[1]);
else if (mode == "prepare-all-defaults")
    prepare_all_server_defaults();
else if (mode == "generate-reality-keypair")
    generate_reality_keypair_cli();
else if (mode == "tls-certificate-sha256")
    get_tls_certificate_sha256_cli(ARGV[1]);
else if (mode == "reality-keypair-response")
    reality_keypair_response(ARGV[1], ARGV[2]);
else if (mode == "reality-keypair-tsv")
    reality_keypair_tsv();
else if (mode == "write-tls-keypair-files")
    write_tls_keypair_files(ARGV[1], ARGV[2]);
else if (mode == "certificate-base64")
    certificate_base64(ARGV[1]);
else if (mode == "valid-sha256-hex")
    exit(valid_sha256_hex(ARGV[1]) ? 0 : 1);
else if (mode == "tls-fingerprint-response")
    tls_fingerprint_response(ARGV[1]);
else {
    warn("Usage: server/service.uc <operation> ...\n");
    exit(1);
}
