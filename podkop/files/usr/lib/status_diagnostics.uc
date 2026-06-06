#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function url_encode(value) {
    value = as_string(value);
    for (let i = 0; i < length(value); i++) {
        let c = substr(value, i, 1);
        let code = ord(c);
        if ((code >= 48 && code <= 57) ||
            (code >= 65 && code <= 90) ||
            (code >= 97 && code <= 122) ||
            c == "-" || c == "_" || c == "." || c == "~")
            print(c);
        else
            print(sprintf("%%%02X", code));
    }
    print("\n");
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

function proxy_response_is_retryable_error() {
    let response = read_stdin();
    return index(response, "<html") == 0 || index(response, "403 Forbidden") >= 0;
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

function write_json_file(path, value) {
    return fs.writefile(path, sprintf("%J", value) + "\n");
}

function parse_json_object(value) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        return {};
    }

    return type(value) == "object" ? value : {};
}

function parse_json_or_null(value) {
    try {
        return json(as_string(value));
    }
    catch (e) {
        return null;
    }
}

function number_value(value) {
    value = as_string(value);
    return value == "" ? 0 : int(value);
}

function stdin_first_line_last_field() {
    let input = read_stdin();
    if (input == "")
        return;

    let newline = index(input, "\n");
    let line = newline >= 0 ? substr(input, 0, newline) : input;
    let trimmed = trim(line);
    if (trimmed == "") {
        print(line, "\n");
        return;
    }

    let fields = split(trimmed, /[ \t\r\n]+/);
    if (length(fields) > 0 && fields[0] != "")
        print(fields[length(fields) - 1], "\n");
    else
        print("\n");
}

function stdin_first_line() {
    let input = read_stdin();
    if (input == "")
        return;

    let newline = index(input, "\n");
    print(newline >= 0 ? substr(input, 0, newline + 1) : input);
}

function stdin_first_ipv4_line() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^[0-9]+\./) != null) {
            print(line, "\n");
            return;
        }
    }
}

function stdin_contains(needle) {
    exit(index(read_stdin(), as_string(needle)) >= 0 ? 0 : 1);
}

function strip_leading_v(value) {
    value = as_string(value);
    print(substr(value, 0, 1) == "v" ? substr(value, 1) : value, "\n");
}

function uci_show_value(line) {
    let equals = index(as_string(line), "=");
    if (equals < 0)
        return "";

    let value = substr(line, equals + 1);
    let next_equals = index(value, "=");
    if (next_equals >= 0)
        value = substr(value, 0, next_equals);

    return replace(value, /['" ]/g, "");
}

function string_starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function uci_show_list_value(value) {
    return trim(replace(as_string(value), /['"]/g, ""));
}

function firewall_rules_from_uci_show(data) {
    let prefix = "firewall.";
    let sections = {};
    let order = [];

    for (let line in split(as_string(data), "\n")) {
        let equals = index(as_string(line), "=");
        if (equals < 0)
            continue;

        let key = substr(line, 0, equals);
        let raw_value = substr(line, equals + 1);
        if (!string_starts_with(key, prefix))
            continue;

        let rest = substr(key, length(prefix));
        if (index(rest, ".") < 0) {
            if (uci_show_list_value(raw_value) == "rule") {
                if (sections[key] == null)
                    sections[key] = {};
                push(order, key);
            }
            continue;
        }

        let option_dot = rindex(key, ".");
        let section = substr(key, 0, option_dot);
        let option = substr(key, option_dot + 1);
        if (sections[section] == null)
            sections[section] = {};
        sections[section][option] = uci_show_list_value(raw_value);
    }

    let rules = [];
    for (let section in order)
        push(rules, sections[section] || {});

    return rules;
}

function first_two_dot_fields(value) {
    let parts = split(as_string(value), ".");
    return length(parts) >= 2 ? parts[0] + "." + parts[1] : as_string(value);
}

function whitespace_values(value) {
    let result = [];
    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function value_in_list(values, needle) {
    for (let value in values)
        if (as_string(value) == as_string(needle))
            return true;
    return false;
}

function network_endpoint_host_warnings(octets) {
    let cloudflare_octets = whitespace_values(octets);

    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (index(line, "endpoint_host") < 0)
            continue;

        let host = uci_show_value(line);
        if (host == "")
            continue;

        if (host == "engage.cloudflareclient.com") {
            print("engage\t", host, "\n");
            continue;
        }

        if (value_in_list(cloudflare_octets, first_two_dot_fields(host)))
            print("prefix\t", host, "\n");
    }
}

function network_wireguard_route_allowed_peers() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (index(line, "wireguard_") < 0 || index(line, ".route_allowed_ips=") < 0)
            continue;
        if (uci_show_value(line) != "1")
            continue;

        let route_option = index(line, ".route_allowed_ips=");
        if (route_option > 0)
            print(substr(line, 0, route_option), "\n");
    }
}

function wan_config_masked(path) {
    let data = fs.readfile(path);
    let in_wan = false;
    let proto = "";

    if (data == null)
        exit(1);

    let lines = split(as_string(data), "\n");
    for (let i = 0; i < length(lines); i++) {
        let line = lines[i];
        if (i == length(lines) - 1 && line == "" && substr(as_string(data), length(data) - 1) == "\n")
            continue;

        let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
        if (length(fields) > 0 && fields[0] == "config") {
            in_wan = length(fields) >= 3 && fields[1] == "interface" && fields[2] == "'wan'";
            proto = "";
        }

        if (!in_wan)
            continue;

        if (length(fields) >= 3 && fields[0] == "option" && fields[1] == "proto") {
            proto = fields[2];
            print(line, "\n");
        }
        else if (proto == "'static'" && length(fields) >= 2 && fields[0] == "option" &&
            (fields[1] == "ipaddr" || fields[1] == "netmask" || fields[1] == "gateway")) {
            print("        option ", fields[1], " '******'\n");
        }
        else if (proto == "'pppoe'" && length(fields) >= 2 && fields[0] == "option" &&
            (fields[1] == "username" || fields[1] == "password")) {
            print("        option ", fields[1], " '******'\n");
        }
        else {
            print(line, "\n");
        }
    }
}

function is_space_char(value) {
    return value == " " || value == "\t" || value == "\r" || value == "\n";
}

function mask_after_token(line, token) {
    let pos = index(line, token);
    return pos < 0 ? line : substr(line, 0, pos) + token + " 'MASKED'";
}

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

function mask_option_path(line, token) {
    let pos = index(line, token);
    if (pos < 0)
        return line;

    let slash = index(substr(line, pos + length(token)), "/");
    if (slash < 0)
        return line;
    slash += pos + length(token);

    let quote = index(substr(line, slash + 1), "'");
    if (quote < 0)
        return line;
    quote += slash + 1;

    return substr(line, 0, slash) + "/MASKED'" + substr(line, quote + 1);
}

function podkop_config_masked_line(line) {
    line = mask_after_token(line, "option proxy_string");
    line = mask_after_token(line, "option subscription_url");
    line = mask_after_token(line, "list subscription_urls");
    line = mask_after_token(line, "list urltest_proxy_links");
    line = mask_after_token(line, "list selector_proxy_links");
    line = mask_after_token_space(line, "list domain");
    line = mask_after_token_space(line, "list domain_suffix");
    line = mask_after_token_space(line, "list domain_keyword");
    line = mask_after_token_space(line, "list domain_regex");
    line = mask_after_token_space(line, "list ip_cidr");
    line = mask_after_token_space(line, "list source_ip_cidr");
    line = mask_after_token_space(line, "list fully_routed_ips");
    line = mask_after_token(line, "list server_users");
    line = mask_after_token_space(line, "option dns_server");
    line = mask_after_token_space(line, "option bootstrap_dns_server");
    line = mask_after_token_space(line, "option domain_resolver_dns_server");
    line = mask_after_token_space(line, "option listen");
    line = mask_after_token_space(line, "option listen_port");
    line = mask_after_token_space(line, "option public_host");
    line = mask_after_token(line, "option server_uuid");
    line = mask_after_token(line, "option server_username");
    line = mask_after_token(line, "option server_password");
    line = mask_after_token(line, "option mtproto_secret");
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
    line = mask_after_token_space(line, "list tailscale_advertise_routes");
    line = mask_after_token(line, "option hysteria2_obfs_password");
    line = mask_after_token(line, "option reality_private_key");
    line = mask_after_token(line, "option reality_public_key");
    line = mask_after_token(line, "option reality_short_id");
    line = mask_after_token(line, "list reality_short_id");
    line = mask_after_token_space(line, "option mixed_proxy_username");
    line = mask_after_token_space(line, "option mixed_proxy_password");
    line = mask_option_path(line, "option dns_server '");
    line = mask_option_path(line, "option domain_resolver_dns_server '");
    line = mask_after_token(line, "option yacd_secret_key");

    return line;
}

function podkop_config_masked(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let lines = split(as_string(data), "\n");
    let skipping_outbound_json = false;

    for (let i = 0; i < length(lines); i++) {
        let line = as_string(lines[i]);
        if (i == length(lines) - 1 && line == "" && substr(as_string(data), length(data) - 1) == "\n")
            continue;

        if (skipping_outbound_json) {
            if (substr(line, 0, 1) == "}")
                skipping_outbound_json = false;
            continue;
        }

        if (index(line, "option outbound_json") >= 0) {
            print("\toption outbound_json 'MASKED'\n");
            skipping_outbound_json = true;
            continue;
        }

        if (delete_token_space(line, "option tailscale_ephemeral") ||
            delete_token_space(line, "option tailscale_exit_node") ||
            delete_token_space(line, "option tailscale_exit_node_allow_lan_access"))
            continue;

        print(podkop_config_masked_line(line), "\n");
    }
}

function dhcp_dnsmasq_config(path) {
    let data = fs.readfile(path);
    let in_dnsmasq = false;

    if (data == null)
        exit(1);

    let lines = split(as_string(data), "\n");
    for (let i = 0; i < length(lines); i++) {
        let line = lines[i];
        if (i == length(lines) - 1 && line == "" && substr(as_string(data), length(data) - 1) == "\n")
            continue;

        if (match(as_string(line), /^config /) != null) {
            let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
            in_dnsmasq = length(fields) >= 2 && fields[1] == "dnsmasq";
        }

        if (in_dnsmasq)
            print(line, "\n");
    }
}

function only_digits(value) {
    value = as_string(value);
    return value != "" && match(value, /^[0-9]+$/) != null;
}

function firewall_port_token_contains(token, port) {
    token = as_string(token);
    port = as_string(port);

    let dash = index(token, "-");
    let colon = index(token, ":");
    if (dash < 0 && colon < 0)
        return token == port;

    let separator = dash >= 0 ? dash : colon;
    let start = substr(token, 0, separator);
    let end = substr(token, separator + 1);
    if (!only_digits(start) || !only_digits(end) || !only_digits(port))
        return false;

    port = int(port);
    return port >= int(start) && port <= int(end);
}

function firewall_port_spec_contains(spec, port) {
    spec = as_string(spec);
    if (spec == "")
        return true;

    for (let token in split(replace(spec, /,/g, " "), /[ \t\r\n]+/))
        if (token != "" && firewall_port_token_contains(token, port))
            return true;

    return false;
}

function firewall_proto_spec_contains(spec, proto) {
    spec = as_string(spec);
    proto = as_string(proto);
    if (spec == "")
        return true;

    for (let token in split(spec, /[ \t\r\n]+/)) {
        if (token == "all" || token == "any" || token == "tcpudp" || token == "tcp/udp" || token == proto)
            return true;
    }

    return false;
}

function firewall_port_open_for_proto(port, proto) {
    for (let rule in firewall_rules_from_uci_show(read_stdin())) {
        let enabled = as_string(rule.enabled);
        if (enabled != "" && enabled != "1")
            continue;

        if (uc(as_string(rule.target)) != "ACCEPT")
            continue;

        let src = as_string(rule.src);
        if (src != "" && src != "wan" && src != "*")
            continue;

        let dest = as_string(rule.dest);
        if (dest != "" && dest != "*")
            continue;

        if (as_string(rule.family) == "ipv6")
            continue;

        if (!firewall_proto_spec_contains(rule.proto, proto))
            continue;

        if (!firewall_port_spec_contains(rule.dest_port, port))
            continue;

        return true;
    }

    return false;
}

function server_required_inbound_proto(protocol) {
    print(as_string(protocol) == "hysteria2" ? "udp" : "tcp", "\n");
}

function server_runtime_type_for_protocol(protocol) {
    protocol = as_string(protocol);
    if (protocol == "mtproto")
        print("mtproxy\n");
    else
        print(protocol, "\n");
}

function arg_bool(value) {
    return value === true || value == "true" || value == "1" || value == 1;
}

function arg_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9-]/))
        return 0;
    return int(value);
}

function flag_is_one(value) {
    return as_string(value) == "1";
}

function flag_is_true(value) {
    return value == true || as_string(value) == "true" || as_string(value) == "1";
}

function object_value(object, key) {
    return type(object) == "object" && object[key] != null ? as_string(object[key]) : "";
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function str_startswith(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
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

function str_last_index(value, needle) {
    value = as_string(value);
    needle = as_string(needle);
    if (needle == "")
        return length(value);

    for (let i = length(value) - length(needle); i >= 0; i--)
        if (substr(value, i, length(needle)) == needle)
            return i;

    return -1;
}

function contains(values, needle) {
    needle = as_string(needle);
    for (let value in array_or_empty(values))
        if (as_string(value) == needle)
            return true;
    return false;
}

function netstat_fields(line) {
    line = trim(as_string(line));
    return line == "" ? [] : split(line, /[ \t\r\n]+/);
}

function netstat_addr_port(addr) {
    addr = as_string(addr);
    let colon = str_last_index(addr, ":");
    return colon >= 0 ? substr(addr, colon + 1) : addr;
}

function netstat_addr_host(addr) {
    addr = as_string(addr);
    let colon = str_last_index(addr, ":");
    return colon >= 0 ? substr(addr, 0, colon) : addr;
}

function ipv4_like(value) {
    return match(as_string(value), /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) != null;
}

function netstat_addr_matches(addr, listen, port) {
    addr = as_string(addr);
    listen = as_string(listen);
    port = as_string(port);

    if (netstat_addr_port(addr) != port)
        return false;

    let host = netstat_addr_host(addr);
    if (host == "0.0.0.0" || host == "::")
        return true;
    if (listen == "0.0.0.0")
        return ipv4_like(host);

    return host == listen;
}

function netstat_server_port_listening(listen, port, proto) {
    listen = as_string(listen);
    port = as_string(port);
    proto = as_string(proto);

    for (let line in split(read_stdin(), "\n")) {
        let fields = netstat_fields(line);
        if (length(fields) < 4 || !str_startswith(fields[0], proto))
            continue;

        let local_addr = as_string(fields[3]);
        if (listen == "0.0.0.0") {
            if (local_addr == "0.0.0.0:" + port || local_addr == ":::" + port)
                return true;
        }
        else if (local_addr == listen + ":" + port) {
            return true;
        }
    }

    return false;
}

function sorted_unique_strings(values) {
    let result = [];
    for (let value in values) {
        value = as_string(value);
        if (value != "" && !contains(result, value))
            push(result, value);
    }

    sort(result, function(a, b) {
        return a < b ? -1 : (a > b ? 1 : 0);
    });
    return result;
}

function sorted_unique_lines(values) {
    let result = [];
    for (let value in values) {
        value = as_string(value);
        if (!contains(result, value))
            push(result, value);
    }

    sort(result, function(a, b) {
        return a < b ? -1 : (a > b ? 1 : 0);
    });
    return result;
}

function stdin_sorted_unique_space_list() {
    let lines = split(read_stdin(), "\n");

    if (length(lines) > 0 && lines[length(lines) - 1] == "")
        lines = slice(lines, 0, length(lines) - 1);

    print(replace(join(" ", sorted_unique_lines(lines)), /[ \t\r\n]+$/, ""), "\n");
}

function netstat_server_port_conflict_owners(listen, port, proto) {
    let owners = [];
    let line_number = 0;
    let owner_supported = false;

    for (let line in split(read_stdin(), "\n")) {
        line_number++;
        if (line_number == 2) {
            owner_supported = index(as_string(line), "PID/Program") >= 0;
            continue;
        }

        if (!owner_supported)
            continue;

        let fields = netstat_fields(line);
        if (length(fields) < 4 || !str_startswith(fields[0], proto) || !netstat_addr_matches(fields[3], listen, port))
            continue;

        let owner = length(fields) > 0 ? as_string(fields[length(fields) - 1]) : "";
        if (owner == "" || owner == "-" || owner == "LISTEN")
            owner = "unknown";
        if (!str_endswith(owner, "/sing-box"))
            push(owners, owner);
    }

    print(join(" ", sorted_unique_strings(owners)), "\n");
}

function nft_line_is_count_element(line) {
    line = trim(as_string(line));
    return line != "" && match(substr(line, 0, 1), /^[0-9]$/) != null;
}

function render_nft_chain_config_blocks() {
    let lines = split(read_stdin(), "\n");

    for (let i = 1; i < length(ARGV); i++) {
        let chain = as_string(ARGV[i]);
        let in_block = false;
        let needle = "chain " + chain + " {";

        for (let line in lines) {
            line = as_string(line);
            if (!in_block && index(line, needle) < 0)
                continue;

            if (!in_block)
                in_block = true;

            if (index(line, "elements") < 0 && !nft_line_is_count_element(line))
                print(line, "\n");

            if (index(line, "}") >= 0)
                in_block = false;
        }
    }
}

function nft_chain_counter_status() {
    let rules_exist = 0;
    let counters = 0;

    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (index(line, "counter") < 0)
            continue;

        rules_exist = 1;
        if (index(line, "packets 0 bytes 0") < 0)
            counters = 1;
    }

    print(rules_exist, " ", counters, "\n");
}

function print_line(value) {
    print(value, "\n");
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function stdin_json() {
    let value = read_stdin_json();
    if (value == null)
        exit(1);
    write_json(value);
}

function json_error(message) {
    write_json({ error: as_string(message) });
}

function mask_ipv6_line(line) {
    let matched = match(line, /([0-9a-fA-F]+:[0-9a-fA-F]+:[0-9a-fA-F]+):.*/);
    return matched ? matched[1] + ":XXXX:XXXX:XXXX" : line;
}

function render_proxy_response_ip_mask() {
    let response = read_stdin();
    let lines = split(response, "\n");
    let ipv4_lines = [];
    let ipv6_like = false;

    for (let line in lines) {
        let matched = match(line, /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
        if (matched)
            push(ipv4_lines, "X.X.X." + matched[4]);

        if (match(line, /^[0-9a-fA-F:]*::[0-9a-fA-F:]*$/) || match(line, /^[0-9a-fA-F:]+$/))
            ipv6_like = true;
    }

    if (length(ipv4_lines) > 0) {
        for (let line in ipv4_lines)
            print_line(line);
        return;
    }

    if (ipv6_like) {
        for (let i = 0; i < length(lines); i++) {
            if (i == length(lines) - 1 && lines[i] == "")
                continue;
            print_line(mask_ipv6_line(lines[i]));
        }
        return;
    }

    exit(1);
}

function render_inbound_item(item, wan_ip) {
    let label = object_value(item, "label");
    let protocol = object_value(item, "protocol");
    let listen = object_value(item, "listen");
    let listen_port = object_value(item, "listen_port");
    let public_host = object_value(item, "public_host");
    let tag = object_value(item, "tag");
    let required_proto = object_value(item, "required_proto");
    let runtime_ok = object_value(item, "runtime_ok");
    let listening = object_value(item, "listening");
    let firewall_required = object_value(item, "firewall_required");
    let firewall_open = object_value(item, "firewall_open");
    let port_conflict = object_value(item, "port_conflict");
    let port_conflict_owners = object_value(item, "port_conflict_owners");
    let routes_configured = object_value(item, "routes_configured");
    let public_host_resolved = object_value(item, "public_host_resolved");
    let public_host_public = object_value(item, "public_host_public");
    let public_host_matches_wan = object_value(item, "public_host_matches_wan");
    let public_host_ips = object_value(item, "public_host_ips");

    if (flag_is_one(runtime_ok))
        print_line("[OK] " + label + ": runtime " + tag + " [" + protocol + "]");
    else
        print_line("[FAIL] " + label + ": generated inbound is missing or differs from UCI");

    if (protocol != "tailscale") {
        if (flag_is_one(listening))
            print_line("[OK] " + label + ": listening on " + listen + ":" + listen_port + " [" + required_proto + "]");
        else
            print_line("[FAIL] " + label + ": not listening on " + listen + ":" + listen_port + " [" + required_proto + "]");

        if (flag_is_one(port_conflict))
            print_line("[FAIL] " + label + ": " + listen + ":" + listen_port + " [" + required_proto + "] is already used by " + port_conflict_owners);
        else
            print_line("[OK] " + label + ": no local port conflict detected");

        if (flag_is_one(firewall_required)) {
            if (flag_is_one(firewall_open))
                print_line("[OK] " + label + ": firewall accepts " + required_proto + "/" + listen_port + " from WAN");
            else
                print_line("[FAIL] " + label + ": firewall does not accept " + required_proto + "/" + listen_port + " from WAN");
        }
        else {
            print_line("[WARN] " + label + ": firewall WAN check skipped for listen address " + listen);
        }
    }
    else {
        print_line("[OK] " + label + ": Tailscale endpoint does not need a public firewall port");
    }

    if (flag_is_one(routes_configured))
        print_line("[OK] " + label + ": route rules for inbound exist");
    else
        print_line("[WARN] " + label + ": route rules for inbound were not found");

    if (protocol != "tailscale") {
        if (public_host != "") {
            if (public_host_resolved == "0")
                print_line("[WARN] " + label + ": public host does not resolve: " + public_host);
            else if (public_host_public == "0")
                print_line("[WARN] " + label + ": public host is not public: " + public_host);
            else if (public_host_matches_wan == "0")
                print_line("[WARN] " + label + ": public host resolves to " + public_host_ips + ", WAN is " + wan_ip);
            else
                print_line("[OK] " + label + ": public host " + public_host);
        }
        else {
            print_line("[WARN] " + label + ": public host is empty");
        }
    }
}

function inbound_runtime_ok(protocol, runtime_exists, runtime_type, runtime_listen, runtime_port_text, expected_type, listen, listen_port) {
    if (!flag_is_one(runtime_exists) || runtime_type != expected_type)
        return 0;

    if (protocol == "tailscale")
        return 1;

    return runtime_listen == listen && runtime_port_text == listen_port ? 1 : 0;
}

function write_inbound_item_json(args) {
    let runtime = parse_json_object(args[0]);
    let section = as_string(args[1]);
    let label = as_string(args[2]);
    let protocol = as_string(args[3]);
    let routing_mode = as_string(args[4]);
    let tag = as_string(args[5]);
    let listen = as_string(args[6]);
    let listen_port = as_string(args[7]);
    let public_host = as_string(args[8]);
    let public_host_ips = as_string(args[9]);
    let expected_type = as_string(args[10]);
    let required_proto = as_string(args[11]);
    let runtime_exists = object_value(runtime, "exists") || "0";
    let runtime_type = object_value(runtime, "type");
    let runtime_listen = object_value(runtime, "listen");
    let runtime_port_text = object_value(runtime, "listen_port") || "0";

    write_json({
        section,
        label,
        protocol,
        routing_mode,
        tag,
        listen,
        listen_port: number_value(listen_port),
        public_host,
        public_host_ips,
        expected_type,
        required_proto,
        runtime_exists: number_value(runtime_exists),
        runtime_type,
        runtime_listen,
        runtime_port: number_value(runtime_port_text),
        runtime_ok: inbound_runtime_ok(protocol, runtime_exists, runtime_type, runtime_listen, runtime_port_text, expected_type, listen, listen_port),
        listening: number_value(args[12]),
        firewall_required: number_value(args[13]),
        firewall_open: number_value(args[14]),
        port_conflict: number_value(args[15]),
        port_conflict_owners: as_string(args[16]),
        routes_configured: number_value(args[17]),
        public_host_resolved: number_value(args[18]),
        public_host_public: number_value(args[19]),
        public_host_matches_wan: number_value(args[20])
    });
}

function write_inbounds_config_json(enabled_count) {
    write_json({
        enabled_count: number_value(enabled_count)
    });
}

function write_inbounds_check_json(enabled_count, config_path, wan_ip, wan_public, items_json) {
    let items = parse_json_or_null(items_json);
    write_json({
        enabled_count: number_value(enabled_count),
        config_path: as_string(config_path),
        wan_ip: as_string(wan_ip),
        wan_public: number_value(wan_public),
        items: items != null ? items : null
    });
}

function write_server_capabilities_json(sing_box_extended) {
    write_json({
        sing_box_extended: arg_number(sing_box_extended)
    });
}

function write_ui_capabilities_json(sing_box_extended, zapret_installed, zapret2_installed, byedpi_installed, server_inbounds_enabled_count) {
    write_json({
        sing_box_extended: arg_number(sing_box_extended),
        zapret_installed: arg_number(zapret_installed),
        zapret2_installed: arg_number(zapret2_installed),
        byedpi_installed: arg_number(byedpi_installed),
        server_inbounds_enabled_count: arg_number(server_inbounds_enabled_count)
    });
}

function write_service_status_json(running, enabled, status, dns_configured) {
    write_json({
        running: arg_number(running),
        enabled: arg_number(enabled),
        status: as_string(status),
        dns_configured: arg_number(dns_configured)
    });
}

function stdin_service_status_running() {
    let value = read_stdin_json();
    if (type(value) != "object")
        exit(1);

    exit(number_value(value.running) == 1 ? 0 : 1);
}

function service_list_instance_running(name) {
    let value = object_or_empty(read_stdin_json());
    let service = object_or_empty(value[as_string(name)]);
    let instances = object_or_empty(service.instances);

    for (let key in instances) {
        let instance = object_or_empty(instances[key]);
        if (flag_is_true(instance.running))
            exit(0);
    }

    exit(1);
}

function write_dns_check_json(dns_type, dns_server, dns_status, dns_on_router, bootstrap_dns_server, bootstrap_dns_status, dhcp_config_status) {
    write_json({
        dns_type: as_string(dns_type),
        dns_server: as_string(dns_server),
        dns_status: arg_number(dns_status),
        dns_on_router: arg_number(dns_on_router),
        bootstrap_dns_server: as_string(bootstrap_dns_server),
        bootstrap_dns_status: arg_number(bootstrap_dns_status),
        dhcp_config_status: arg_number(dhcp_config_status)
    });
}

function write_nft_check_json(table_exist, rules_mangle_exist, rules_mangle_counters, rules_mangle_output_exist, rules_mangle_output_counters, rules_proxy_exist, rules_proxy_counters, rules_other_mark_exist) {
    write_json({
        table_exist: arg_number(table_exist),
        rules_mangle_exist: arg_number(rules_mangle_exist),
        rules_mangle_counters: arg_number(rules_mangle_counters),
        rules_mangle_output_exist: arg_number(rules_mangle_output_exist),
        rules_mangle_output_counters: arg_number(rules_mangle_output_counters),
        rules_proxy_exist: arg_number(rules_proxy_exist),
        rules_proxy_counters: arg_number(rules_proxy_counters),
        rules_other_mark_exist: arg_number(rules_other_mark_exist)
    });
}

function write_sing_box_check_json(sing_box_installed, sing_box_version_ok, sing_box_extended, sing_box_service_exist, sing_box_autostart_disabled, sing_box_process_running, sing_box_ports_listening) {
    write_json({
        sing_box_installed: arg_number(sing_box_installed),
        sing_box_version_ok: arg_number(sing_box_version_ok),
        sing_box_extended: arg_number(sing_box_extended),
        sing_box_service_exist: arg_number(sing_box_service_exist),
        sing_box_autostart_disabled: arg_number(sing_box_autostart_disabled),
        sing_box_process_running: arg_number(sing_box_process_running),
        sing_box_ports_listening: arg_number(sing_box_ports_listening)
    });
}

function write_fakeip_check_json(fakeip_status, fakeip_address) {
    write_json({
        fakeip: arg_bool(fakeip_status),
        IP: as_string(fakeip_address)
    });
}

function fakeip_address_status(address) {
    print(match(as_string(address), /^198\.(18|19)\./) != null ? "true\n" : "false\n");
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

function mask_dns_server(value) {
    value = as_string(value);
    if (str_endswith(value, ".dns.nextdns.io")) {
        let nextdns_id = first_field(value, ".");
        print_line(repeat_char("*", length(nextdns_id)) + ".dns.nextdns.io");
        return;
    }

    if (str_startswith(value, "dns.nextdns.io/")) {
        let path = substr(value, length("dns.nextdns.io/"));
        print_line("dns.nextdns.io/" + repeat_char("*", length(path)));
        return;
    }

    print_line(value);
}

function render_global_inbounds_check() {
    let value = read_stdin_json();
    if (type(value) != "object")
        exit(1);

    let enabled_count = number_value(value.enabled_count);
    let wan_ip = as_string(value.wan_ip || "");
    let wan_public = number_value(value.wan_public);

    if (enabled_count == 0) {
        print_line("[OK] No enabled server inbounds");
        return;
    }

    if (wan_public == 1)
        print_line("[OK] WAN public IP: " + wan_ip);
    else if (wan_ip != "")
        print_line("[WARN] WAN IP is not public: " + wan_ip);
    else
        print_line("[WARN] WAN IP was not detected");

    let items = type(value.items) == "array" ? value.items : [];
    for (let i = 0; i < enabled_count; i++)
        render_inbound_item(type(items[i]) == "object" ? items[i] : {}, wan_ip);
}

function render_flag_line(value, key, ok_message, fail_message) {
    print_line((flag_is_one(value[key]) ? ok_message : fail_message));
}

function render_global_sing_box_check() {
    let value = object_or_empty(read_stdin_json());

    render_flag_line(value, "sing_box_installed", "\u2705 Sing-box installed", "\u274c Sing-box installed");
    render_flag_line(value, "sing_box_version_ok", "\u2705 Sing-box version is compatible (newer than 1.12.4)", "\u274c Sing-box version is not compatible (older than 1.12.4)");

    if (flag_is_one(value.sing_box_extended))
        print_line("Sing-box extended detected");
    else
        print_line("Sing-box regular build detected");

    render_flag_line(value, "sing_box_service_exist", "\u2705 Sing-box service exist", "\u274c Sing-box service exist");
    render_flag_line(value, "sing_box_autostart_disabled", "\u2705 Sing-box autostart disabled", "\u274c Sing-box autostart disabled");
    render_flag_line(value, "sing_box_process_running", "\u2705 Sing-box process running", "\u274c Sing-box process running");
    render_flag_line(value, "sing_box_ports_listening", "\u2705 Sing-box listening ports", "\u274c Sing-box listening ports");
}

function render_global_system_info() {
    let value = object_or_empty(read_stdin_json());
    let podkop_version = object_value(value, "podkop_version") || "unknown";
    let luci_app_version = object_value(value, "luci_app_version") || "unknown";
    let sing_box_version = object_value(value, "sing_box_version") || "unknown";
    let zapret_version = object_value(value, "zapret_version") || "unknown";
    let zapret2_version = object_value(value, "zapret2_version") || "unknown";
    let byedpi_version = object_value(value, "byedpi_version") || "unknown";
    let openwrt_version = object_value(value, "openwrt_version") || "unknown";
    let device_model = object_value(value, "device_model") || "unknown";

    if (flag_is_one(value.sing_box_extended))
        print_line("Sing-box core: extended");
    else
        print_line("Sing-box core: regular");

    print_line("\ud83d\udd73\ufe0f Podkop Plus:   " + podkop_version);
    print_line("\ud83d\udd73\ufe0f LuCI App:      " + luci_app_version);
    print_line("\ud83d\udce6 Sing-box:      " + sing_box_version);
    if (flag_is_one(value.zapret_installed))
        print_line("\ud83e\uddf5 Zapret:        " + zapret_version);
    if (flag_is_one(value.zapret2_installed))
        print_line("\ud83e\uddf5 Zapret2:       " + zapret2_version);
    if (flag_is_one(value.byedpi_installed))
        print_line("\ud83e\uddf5 ByeDPI:        " + byedpi_version);
    print_line("\ud83d\udedc OpenWrt:       " + openwrt_version);
    print_line("\ud83d\udedc Device:        " + device_model);
}

function render_global_fakeip_check() {
    let value = object_or_empty(read_stdin_json());
    let fakeip_address = object_value(value, "IP");

    if (flag_is_true(value.fakeip))
        print_line("\u2705 Sing-box FakeIP DNS works: " + fakeip_address);
    else
        print_line("\u274c Sing-box FakeIP DNS does NOT work");
}

function render_global_dns_check(dont_touch_dhcp) {
    let value = object_or_empty(read_stdin_json());
    let dns_type = object_value(value, "dns_type") || "unknown";
    let dns_server = object_value(value, "dns_server") || "unknown";
    let bootstrap_dns_server = object_value(value, "bootstrap_dns_server");
    let dump_dhcp_config = false;

    if (bootstrap_dns_server != "") {
        print_line((flag_is_one(value.bootstrap_dns_status) ? "\u2705 Bootstrap DNS: " : "\u274c Bootstrap DNS: ") + bootstrap_dns_server);
    }

    print_line((flag_is_one(value.dns_status) ? "\u2705 Main DNS: " : "\u274c Main DNS: ") + dns_server + " [" + dns_type + "]");
    print_line(flag_is_one(value.dns_on_router) ? "\u2705 DNS on router" : "\u274c DNS on router");

    if (as_string(dont_touch_dhcp) == "1") {
        print_line("\u26a0\ufe0f dont_touch_dhcp is enabled. \ud83d\udcc4 DHCP config:");
        dump_dhcp_config = true;
    }
    else if (!flag_is_one(value.dhcp_config_status)) {
        print_line("\u274c DHCP configuration differs from template. \ud83d\udcc4 DHCP config:");
        dump_dhcp_config = true;
    }
    else {
        print_line("\u2705 /etc/config/dhcp");
    }

    exit(dump_dhcp_config ? 10 : 0);
}

function render_global_nft_check() {
    let value = read_stdin_json();
    if (type(value) != "object")
        exit(1);

    render_flag_line(value, "table_exist", "\u2705 Table exist", "\u274c Table exist");
    render_flag_line(value, "rules_mangle_exist", "\u2705 Rules mangle exist", "\u274c Rules mangle exist");
    render_flag_line(value, "rules_mangle_counters", "\u2705 Rules mangle counters", "\u26a0\ufe0f  Rules mangle counters");
    render_flag_line(value, "rules_mangle_output_exist", "\u2705 Rules mangle output exist", "\u274c Rules mangle output exist");
    render_flag_line(value, "rules_mangle_output_counters", "\u2705 Rules mangle output counters", "\u26a0\ufe0f  Rules mangle output counters");
    render_flag_line(value, "rules_proxy_exist", "\u2705 Rules proxy exist", "\u274c Rules proxy exist");
    render_flag_line(value, "rules_proxy_counters", "\u2705 Rules proxy counters", "\u26a0\ufe0f  Rules proxy counters");

    if (flag_is_one(value.rules_other_mark_exist))
        print_line("\u26a0\ufe0f  Additional marking rules found:");
    else
        print_line("\u2705 No other marking rules found");
}

function global_nft_other_mark_exists() {
    let value = read_stdin_json();
    exit(type(value) == "object" && flag_is_one(value.rules_other_mark_exist) ? 0 : 1);
}

function nft_ruleset_other_mark_lines(table_name) {
    table_name = as_string(table_name);
    let in_podkop_table = false;

    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (index(line, "table inet " + table_name) >= 0) {
            in_podkop_table = true;
            continue;
        }

        if (match(line, /^table/) != null)
            in_podkop_table = false;

        if (!in_podkop_table && (index(line, "mark set") >= 0 || index(line, "meta mark") >= 0))
            print_line(line);
    }
}

function nft_set_element_count() {
    let value = object_or_empty(read_stdin_json());

    for (let item in array_or_empty(value.nftables)) {
        if (type(item) != "object" || type(item.set) != "object")
            continue;

        print_line(length(array_or_empty(item.set.elem)));
        return;
    }

    print_line("0");
}

function line_contains(line, needle) {
    return index(as_string(line), as_string(needle)) >= 0;
}

function print_lines(lines, start, end) {
    for (let i = start; i < end; i++)
        print_line(lines[i]);
}

function render_matching_log_tail(needle, max_lines) {
    let lines = split(read_stdin(), "\n");
    let filtered = [];

    for (let line in lines) {
        if (line == "")
            continue;
        if (line_contains(line, needle))
            push(filtered, line);
    }

    if (length(filtered) == 0)
        exit(1);

    max_lines = int(max_lines || "100", 10) || 100;
    let start = length(filtered) > max_lines ? length(filtered) - max_lines : 0;
    print_lines(filtered, start, length(filtered));
}

function render_podkop_logs() {
    let lines = split(read_stdin(), "\n");
    let filtered = [];
    let start = -1;

    for (let line in lines) {
        if (line == "")
            continue;
        if (!line_contains(line, "podkop-plus") && !line_contains(line, "sing-box"))
            continue;

        if (line_contains(line, "podkop-plus") && line_contains(line, "Starting Podkop Plus"))
            start = length(filtered);

        push(filtered, line);
    }

    if (length(filtered) == 0)
        exit(1);

    if (start >= 0) {
        print_lines(filtered, start, length(filtered));
        return;
    }

    print_line("No 'Starting Podkop Plus' message found, showing last 100 lines");
    start = length(filtered) > 100 ? length(filtered) - 100 : 0;
    print_lines(filtered, start, length(filtered));
}

function file_first_line(path, fallback) {
    let data = fs.readfile(path);
    let result = "";

    if (data != null) {
        let lines = split(as_string(data), "\n");
        if (length(lines) > 0)
            result = str_remove_suffix(as_string(lines[0]), "\r");
    }

    if (result == "")
        result = as_string(fallback);

    print_line(result);
}

function js_var_string_value(path, var_name) {
    let data = fs.readfile(path);
    var_name = as_string(var_name);

    if (data == null || var_name == "")
        return;

    for (let line in split(as_string(data), "\n")) {
        let matched = match(line, /^[ \t]*var[ \t]+([^ \t=]+)[ \t]*=[ \t]*"([^"]*)"/);
        if (matched != null && matched[1] == var_name) {
            print_line(matched[2]);
            return;
        }
    }
}

function key_value_file_value(path, key) {
    let data = fs.readfile(path);
    key = as_string(key);

    if (data == null || key == "")
        return;

    let prefix = key + "=";
    for (let line in split(as_string(data), "\n")) {
        line = str_remove_suffix(as_string(line), "\r");
        if (!str_startswith(line, prefix))
            continue;

        let value = substr(line, length(prefix));
        if (length(value) >= 2) {
            let quote = substr(value, 0, 1);
            if ((quote == "\"" || quote == "'") && str_endswith(value, quote))
                value = substr(value, 1, length(value) - 2);
        }
        print_line(value);
        return;
    }
}

function system_info_cache_valid(path, podkop_version, luci_app_version, ttl, now) {
    let cache = read_json_file(path);
    if (type(cache) != "object")
        return false;

    now = arg_number(now);
    ttl = arg_number(ttl);
    let cached_at = arg_number(cache.generated_at || 0);

    if (now > 0 && cached_at > 0 && ttl > 0 && now - cached_at >= ttl)
        return false;

    return cache.podkop_version == podkop_version && cache.luci_app_version == luci_app_version;
}

function system_info_json() {
    write_json({
        podkop_version: as_string(ARGV[1]),
        podkop_latest_version: as_string(ARGV[2]),
        luci_app_version: as_string(ARGV[3]),
        sing_box_version: as_string(ARGV[4]),
        sing_box_extended: arg_number(ARGV[5]),
        zapret_version: as_string(ARGV[6]),
        zapret_installed: arg_number(ARGV[7]),
        zapret2_version: as_string(ARGV[8]),
        zapret2_installed: arg_number(ARGV[9]),
        byedpi_version: as_string(ARGV[10]),
        byedpi_installed: arg_number(ARGV[11]),
        openwrt_version: as_string(ARGV[12]),
        device_model: as_string(ARGV[13]),
        generated_at: arg_number(ARGV[14])
    });
}

function nfqws_strategy_validation(valid, message, needle, needles) {
    let result = [];
    for (let item in split(as_string(needles), "\n")) {
        if (item != "")
            push(result, item);
    }

    write_json({
        valid: arg_bool(valid),
        message: as_string(message),
        needle: as_string(needle),
        needles: result
    });
}

let masked_sing_box_keys = {
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
    source_ip_cidr: true
};

function mask_sing_box_value(value) {
    if (type(value) == "array") {
        let result = [];
        for (let item in value)
            push(result, mask_sing_box_value(item));
        return result;
    }

    if (type(value) == "object") {
        let result = {};
        for (let key, item in value)
            result[key] = masked_sing_box_keys[key] ? "MASKED" : mask_sing_box_value(item);
        return result;
    }

    return value;
}

function mask_sing_box_config(path) {
    write_json(mask_sing_box_value(read_json_file(path)));
}

function prepare_check_proxy_config(input_path, output_path, cache_path) {
    let config = object_or_empty(read_json_file(input_path));
    config.inbounds = [];
    config.services = [];
    if (type(config.experimental) == "object") {
        if (type(config.experimental.cache_file) == "object")
            config.experimental.cache_file.path = as_string(cache_path);
        delete config.experimental.clash_api;
    }

    if (!write_json_file(output_path, config))
        exit(1);
}

function check_proxy_outbound_tag(config_path, domain) {
    let config = object_or_empty(read_json_file(config_path));
    for (let rule in array_or_empty(config.route && config.route.rules)) {
        if (type(rule) != "object")
            continue;
        if (contains(array_or_empty(rule.domain), domain)) {
            print_line(as_string(rule.outbound || ""));
            return;
        }
    }
}

function http_response_with_status() {
    let lines = split(read_stdin(), "\n");
    let status = length(lines) > 0 ? as_string(lines[length(lines) - 1]) : "";
    let body_lines = length(lines) > 0 ? slice(lines, 0, length(lines) - 1) : [];

    return {
        status_text: status,
        status: int(status || "0", 10) || 0,
        body: join("\n", body_lines)
    };
}

function write_clash_api_error(status, body) {
    let result = {
        success: false,
        http_code: status
    };

    if (body != "")
        result.body = body;

    write_json(result);
    exit(1);
}

function clash_set_group_proxy_result(group_tag, proxy_tag) {
    let response = http_response_with_status();

    if (response.status == 204) {
        write_json({ success: true, group: as_string(group_tag), proxy: as_string(proxy_tag) });
        return;
    }

    if (response.status == 404) {
        write_json({ success: false, error: "group_not_found", message: as_string(group_tag) + " does not exist" });
        exit(1);
    }

    if (response.status == 400) {
        if (line_contains(response.body, "not found"))
            write_json({ success: false, error: "proxy_not_found", message: as_string(proxy_tag) + " not found in group " + as_string(group_tag) });
        else
            write_json({ success: false, error: "bad_request", message: "Invalid request" });
        exit(1);
    }

    write_clash_api_error(response.status, response.body);
}

function clash_close_connection_result(connection_id) {
    let response = http_response_with_status();

    if (response.status == 200 || response.status == 204) {
        write_json({ success: true, connection_id: as_string(connection_id) });
        return;
    }

    if (response.status == 404) {
        write_json({ success: false, error: "connection_not_found", connection_id: as_string(connection_id) });
        exit(1);
    }

    write_clash_api_error(response.status, response.body);
}

function clash_close_all_connections_result() {
    let response = http_response_with_status();

    if (response.status == 200 || response.status == 204) {
        write_json({ success: true });
        return;
    }

    write_clash_api_error(response.status, response.body);
}

function clash_set_group_proxy_payload(proxy_tag) {
    write_json({ name: as_string(proxy_tag) });
}

function clash_unknown_action() {
    write_json({
        error: "unknown action",
        available: [
            "get_proxies",
            "get_connections",
            "get_proxy_latency",
            "get_group_latency",
            "set_group_proxy",
            "close_connection",
            "close_all_connections"
        ]
    });
}

let mode = ARGV[0];

if (mode == "proxy-response-ip-mask")
    render_proxy_response_ip_mask();
else if (mode == "url-encode")
    url_encode(ARGV[1]);
else if (mode == "stdin-json")
    stdin_json();
else if (mode == "stdin-first-line-last-field")
    stdin_first_line_last_field();
else if (mode == "stdin-first-line")
    stdin_first_line();
else if (mode == "stdin-sorted-unique-space-list")
    stdin_sorted_unique_space_list();
else if (mode == "stdin-first-ipv4-line")
    stdin_first_ipv4_line();
else if (mode == "stdin-contains")
    stdin_contains(ARGV[1]);
else if (mode == "strip-leading-v")
    strip_leading_v(ARGV[1]);
else if (mode == "network-endpoint-host-warnings")
    network_endpoint_host_warnings(ARGV[1]);
else if (mode == "network-wireguard-route-allowed-peers")
    network_wireguard_route_allowed_peers();
else if (mode == "wan-config-masked")
    wan_config_masked(ARGV[1]);
else if (mode == "podkop-config-masked")
    podkop_config_masked(ARGV[1]);
else if (mode == "dhcp-dnsmasq-config")
    dhcp_dnsmasq_config(ARGV[1]);
else if (mode == "firewall-port-token-contains")
    exit(firewall_port_token_contains(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "firewall-port-spec-contains")
    exit(firewall_port_spec_contains(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "firewall-proto-spec-contains")
    exit(firewall_proto_spec_contains(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "firewall-port-open")
    exit(firewall_port_open_for_proto(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "server-required-inbound-proto")
    server_required_inbound_proto(ARGV[1]);
else if (mode == "server-runtime-type-for-protocol")
    server_runtime_type_for_protocol(ARGV[1]);
else if (mode == "server-port-listening")
    exit(netstat_server_port_listening(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "server-port-conflict-owners")
    netstat_server_port_conflict_owners(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "json-error")
    json_error(ARGV[1]);
else if (mode == "inbound-item-json")
    write_inbound_item_json(slice(ARGV, 1));
else if (mode == "inbounds-config-json")
    write_inbounds_config_json(ARGV[1]);
else if (mode == "inbounds-check-json")
    write_inbounds_check_json(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "server-capabilities-json")
    write_server_capabilities_json(ARGV[1]);
else if (mode == "ui-capabilities-json")
    write_ui_capabilities_json(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "service-status-json")
    write_service_status_json(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "service-status-running")
    stdin_service_status_running();
else if (mode == "service-list-instance-running")
    service_list_instance_running(ARGV[1]);
else if (mode == "dns-check-json")
    write_dns_check_json(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "nft-check-json")
    write_nft_check_json(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]);
else if (mode == "sing-box-check-json")
    write_sing_box_check_json(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "fakeip-check-json")
    write_fakeip_check_json(ARGV[1], ARGV[2]);
else if (mode == "fakeip-address-status")
    fakeip_address_status(ARGV[1]);
else if (mode == "mask-dns-server")
    mask_dns_server(ARGV[1]);
else if (mode == "global-inbounds-check")
    render_global_inbounds_check();
else if (mode == "global-sing-box-check")
    render_global_sing_box_check();
else if (mode == "global-system-info")
    render_global_system_info();
else if (mode == "global-fakeip-check")
    render_global_fakeip_check();
else if (mode == "global-dns-check")
    render_global_dns_check(ARGV[1]);
else if (mode == "global-nft-check")
    render_global_nft_check();
else if (mode == "global-nft-other-mark-exists")
    global_nft_other_mark_exists();
else if (mode == "nft-ruleset-other-mark-lines")
    nft_ruleset_other_mark_lines(ARGV[1]);
else if (mode == "nft-set-element-count")
    nft_set_element_count();
else if (mode == "nft-chain-config-blocks")
    render_nft_chain_config_blocks();
else if (mode == "nft-chain-counter-status")
    nft_chain_counter_status();
else if (mode == "podkop-logs")
    render_podkop_logs();
else if (mode == "matching-log-tail")
    render_matching_log_tail(ARGV[1], ARGV[2]);
else if (mode == "file-first-line")
    file_first_line(ARGV[1], ARGV[2]);
else if (mode == "js-var-string-value")
    js_var_string_value(ARGV[1], ARGV[2]);
else if (mode == "key-value-file-value")
    key_value_file_value(ARGV[1], ARGV[2]);
else if (mode == "system-info-cache-valid")
    exit(system_info_cache_valid(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]) ? 0 : 1);
else if (mode == "system-info-json")
    system_info_json();
else if (mode == "nfqws-strategy-validation")
    nfqws_strategy_validation(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "mask-sing-box-config")
    mask_sing_box_config(ARGV[1]);
else if (mode == "proxy-response-is-retryable-error")
    exit(proxy_response_is_retryable_error() ? 0 : 1);
else if (mode == "prepare-check-proxy-config")
    prepare_check_proxy_config(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "check-proxy-outbound-tag")
    check_proxy_outbound_tag(ARGV[1], ARGV[2]);
else if (mode == "clash-set-group-proxy-result")
    clash_set_group_proxy_result(ARGV[1], ARGV[2]);
else if (mode == "clash-close-connection-result")
    clash_close_connection_result(ARGV[1]);
else if (mode == "clash-close-all-connections-result")
    clash_close_all_connections_result();
else if (mode == "clash-set-group-proxy-payload")
    clash_set_group_proxy_payload(ARGV[1]);
else if (mode == "clash-unknown-action")
    clash_unknown_action();
else {
    warn("Usage: status_diagnostics.uc <operation> ...\n");
    exit(1);
}
