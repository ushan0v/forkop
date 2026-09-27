#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;

const COUNTRY_IS_URL = getenv("FORKOP_COUNTRY_IS_URL") || "https://api.country.is/";
const COUNTRY_IS_BATCH_SIZE = 100;

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_output_from_args(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return as_string(data);
}

function remove_file(path) {
    if (as_string(path) != "")
        fs.unlink(as_string(path));
}

function valid_ipv4(value) {
    let parts = split(as_string(value), ".");
    if (length(parts) != 4)
        return false;
    for (let part in parts) {
        if (match(part, /^[0-9]+$/) == null || int(part, 10) < 0 || int(part, 10) > 255)
            return false;
    }
    return true;
}

function valid_ipv6(value) {
    value = as_string(value);
    return index(value, ":") >= 0 && match(value, /^[0-9A-Fa-f:.]+$/) != null;
}

function public_ipv4(value) {
    if (!valid_ipv4(value))
        return false;

    let parts = split(value, ".");
    let a = int(parts[0], 10);
    let b = int(parts[1], 10);
    let c = int(parts[2], 10);

    if (a == 0 || a == 10 || a == 127 || a >= 224)
        return false;
    if (a == 100 && b >= 64 && b <= 127)
        return false;
    if (a == 169 && b == 254)
        return false;
    if (a == 172 && b >= 16 && b <= 31)
        return false;
    if (a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2))))
        return false;
    if (a == 198 && ((b == 18 || b == 19) || (b == 51 && c == 100)))
        return false;
    if (a == 203 && b == 0 && c == 113)
        return false;
    return true;
}

function public_ipv6(value) {
    if (!valid_ipv6(value))
        return false;

    value = lc(value);
    let first = split(value, ":")[0];
    let first_value = int(first, 16);
    if (first_value < 0x2000 || first_value > 0x3fff)
        return false;
    return match(value, /^2001:0?db8:/) == null;
}

function public_ip(value) {
    return public_ipv4(value) || public_ipv6(value);
}

function first_ipv4_line(value) {
    for (let line in split(as_string(value), "\n")) {
        line = trim(as_string(line));
        if (valid_ipv4(line))
            return line;
    }
    return "";
}

function first_ipv6_line(value) {
    for (let line in split(as_string(value), "\n")) {
        line = trim(as_string(line));
        if (valid_ipv6(line))
            return line;
    }
    return "";
}

function first_nslookup_address(value) {
    for (let line in split(as_string(value), "\n")) {
        line = trim(as_string(line));
        let matched = match(line, /^Address[ \t]*[0-9]*:[ \t]*([^ \t]+)$/);
        if (!matched)
            continue;

        let address = as_string(matched[1]);
        if (valid_ipv4(address) || valid_ipv6(address))
            return address;
    }
    return "";
}

function normalized_server(value) {
    value = lc(trim(as_string(value)));
    if (value != "" && substr(value, 0, 1) == "[" && substr(value, length(value) - 1) == "]")
        value = substr(value, 1, length(value) - 2);
    return value;
}

function country_is_endpoint() {
    let matched = match(COUNTRY_IS_URL, /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^\/:?#]+)(:([0-9]+))?/);
    if (!matched)
        return { host: "", port: "" };

    let scheme = lc(as_string(matched[1]));
    let port = as_string(matched[4] || "");
    if (port == "")
        port = scheme == "https" ? "443" : "80";
    return { host: as_string(matched[2]), port };
}

function normalized_resolver(value) {
    value = trim(as_string(value));
    let separator = index(value, "#");
    if (separator >= 0)
        value = substr(value, 0, separator);
    if (substr(value, 0, 1) == "[" && substr(value, length(value) - 1) == "]")
        value = substr(value, 1, length(value) - 2);
    return valid_ipv4(value) || valid_ipv6(value) ? value : "";
}

function resolve_service_host(host, resolver) {
    resolver = normalized_resolver(resolver);
    if (host == "" || resolver == "")
        return "";

    return first_ipv4_line(command_output_from_args([
        "dig", "+short", "@" + resolver, host, "A", "+time=2", "+tries=1"
    ]));
}

function resolve_server(value) {
    let server = normalized_server(value);
    if (server == "")
        return "";
    if (valid_ipv4(server) || valid_ipv6(server))
        return server;

    let output = command_output_from_args([ "dig", "+short", server, "A", "+time=2", "+tries=1" ]);
    let address = first_ipv4_line(output);
    if (address == "") {
        output = command_output_from_args([ "dig", "+short", server, "AAAA", "+time=2", "+tries=1" ]);
        address = first_ipv6_line(output);
    }
    if (address != "")
        return address;

    return first_nslookup_address(command_output_from_args([ "nslookup", server ]));
}

function lookup_ip_batch(ips, resolver) {
    let body_path = trim(command_output_from_args([ "mktemp" ]));
    if (body_path == "")
        return { countries: {}, stop: true };

    let args = [
        "curl", "-sS", "-m", "10", "-o", body_path, "-w", "%{http_code}",
        "-H", "Content-Type: application/json", "-d", sprintf("%J", ips)
    ];
    let endpoint = country_is_endpoint();
    if (endpoint.host != "" && !valid_ipv4(endpoint.host) && !valid_ipv6(endpoint.host)) {
        let service_ip = resolve_service_host(endpoint.host, resolver);
        if (normalized_resolver(resolver) != "" && !public_ipv4(service_ip)) {
            remove_file(body_path);
            warn("Server country service host resolution failed\n");
            return { countries: {}, stop: true };
        }
        if (public_ipv4(service_ip)) {
            push(args, "--resolve");
            push(args, endpoint.host + ":" + endpoint.port + ":" + service_ip);
        }
    }
    push(args, COUNTRY_IS_URL);

    let http_code = trim(command_output_from_args(args));
    let raw_body = common.read_json_file(body_path);
    remove_file(body_path);
    let body = object_or_empty(raw_body);

    let error_code = "";
    if (type(body.error) == "object")
        error_code = as_string(body.error.code || "");
    else
        error_code = as_string(body.code || body.error || "");

    if (http_code == "429" || error_code == "rate_limit") {
        warn("Server country lookup is rate-limited\n");
        return { countries: {}, stop: true };
    }
    if (http_code != "200" || type(raw_body) != "array") {
        warn("Server country lookup failed\n");
        return { countries: {}, stop: false };
    }

    let countries = {};
    for (let item in raw_body) {
        item = object_or_empty(item);
        let ip = as_string(item.ip || "");
        let country = uc(as_string(item.country || ""));
        if (ip != "" && country != "")
            countries[ip] = country;
    }
    return { countries, stop: false };
}

function lookup_ips(ips, resolver) {
    let result = {};
    for (let start = 0; start < length(ips); start += COUNTRY_IS_BATCH_SIZE) {
        let batch = slice(ips, start, start + COUNTRY_IS_BATCH_SIZE);
        let response = lookup_ip_batch(batch, resolver);
        for (let ip, country in response.countries)
            result[ip] = country;
        if (response.stop)
            break;
        if (start + COUNTRY_IS_BATCH_SIZE < length(ips))
            system("sleep 1");
    }
    return result;
}

function previous_countries_by_server(previous_state) {
    previous_state = object_or_empty(previous_state);
    let servers = object_or_empty(previous_state.servers);
    let countries = object_or_empty(object_or_empty(previous_state.outboundMetadata).countries);
    let result = {};

    for (let tag_name, server in servers) {
        let country = uc(as_string(countries[tag_name] || ""));
        server = normalized_server(server);
        if (server != "" && country != "")
            result[server] = country;
    }
    return result;
}

function detect(servers, previous_state, resolver) {
    servers = object_or_empty(servers);
    let cached = previous_countries_by_server(previous_state);
    let result = {};
    let pending_tags_by_server = {};
    let tags_by_ip = {};
    let ips = [];

    for (let tag_name, server in servers) {
        server = normalized_server(server);
        if (server == "")
            continue;
        if ((valid_ipv4(server) || valid_ipv6(server)) && !public_ip(server))
            continue;

        if (cached[server]) {
            result[tag_name] = cached[server];
            continue;
        }

        if (!pending_tags_by_server[server])
            pending_tags_by_server[server] = [];
        push(pending_tags_by_server[server], tag_name);
    }

    for (let server, tags in pending_tags_by_server) {
        let ip = resolve_server(server);
        if (!public_ip(ip))
            continue;
        if (!tags_by_ip[ip]) {
            tags_by_ip[ip] = [];
            push(ips, ip);
        }
        for (let tag_name in tags)
            push(tags_by_ip[ip], tag_name);
    }

    let countries_by_ip = length(ips) > 0 ? lookup_ips(ips, resolver) : {};
    for (let ip, tags in tags_by_ip) {
        let country = as_string(countries_by_ip[ip] || "");
        if (country == "")
            continue;
        for (let tag_name in tags)
            result[tag_name] = country;
    }

    return result;
}

return {
    detect,
    normalized_server,
    public_ip,
    previous_countries_by_server
};
