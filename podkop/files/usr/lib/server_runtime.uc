#!/usr/bin/env ucode

let fs = require("fs");

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
    value = as_string(value);
    if (!regex_matches(value, "^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))
        return false;

    let parts = split(value, ".");
    if (length(parts) != 4)
        return false;

    for (let part in parts) {
        if (part == "" || regex_matches(part, "[^0-9]"))
            return false;
        let octet = int(part);
        if (octet < 0 || octet > 255)
            return false;
    }

    return true;
}

function valid_domain(value) {
    return regex_matches(ascii_lower(value), "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$");
}

function valid_host(value) {
    value = normalize_host(value);
    return value != "" && (valid_ipv4(value) || valid_domain(value));
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
    let slash = index(rest, "/");
    let host_port = slash >= 0 ? substr(rest, 0, slash) : rest;
    let colon = index(host_port, ":");
    let host = colon >= 0 ? substr(host_port, 0, colon) : host_port;

    return valid_host(host);
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

function mtproto_base_secret_from_value(value) {
    value = lc(as_string(value));
    if (regex_matches(value, "^[0-9a-f]{32}$")) {
        print(value, "\n");
        return;
    }

    if (regex_matches(value, "^ee[0-9a-f]{32}([0-9a-f]{2})+$")) {
        print(substr(value, 2, 32), "\n");
        return;
    }

    exit(1);
}

function hex_digit_value(value) {
    value = ord(lc(as_string(value)));
    if (value >= 48 && value <= 57)
        return value - 48;
    if (value >= 97 && value <= 102)
        return value - 87;
    return -1;
}

function hex_to_string(value) {
    value = as_string(value);
    if (length(value) == 0 || length(value) % 2 != 0 || !regex_matches(value, "^([0-9a-fA-F]{2})+$"))
        exit(1);

    for (let i = 0; i < length(value); i += 2) {
        let high = hex_digit_value(substr(value, i, 1));
        let low = hex_digit_value(substr(value, i + 1, 1));
        if (high < 0 || low < 0)
            exit(1);
        print(chr(high * 16 + low));
    }
}

function string_to_hex(value) {
    value = as_string(value);
    for (let i = 0; i < length(value); i++)
        print(sprintf("%02x", ord(substr(value, i, 1))));
}

function mtproto_faketls_from_secret(value) {
    value = lc(as_string(value));
    if (!regex_matches(value, "^ee[0-9a-f]{32}([0-9a-f]{2})+$"))
        exit(1);
    hex_to_string(substr(value, 34));
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
    value = as_string(value);
    return index(value, ":") >= 0 && regex_matches(value, "^[0-9A-Fa-f:.]+$");
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
    warn("Usage: server_runtime.uc <operation> ...\n");
    exit(1);
}
