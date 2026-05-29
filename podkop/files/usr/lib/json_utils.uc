#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
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
    let data = read_stdin();
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function write_json_file(path, value) {
    return fs.writefile(path, sprintf("%J", value) + "\n");
}

function str_contains(haystack, needle) {
    return index(as_string(haystack), as_string(needle)) >= 0;
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

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function validate_subscription(path) {
    let value = read_json_file(path);
    return type(value) == "object" && type(value.outbounds) == "array" && length(value.outbounds) > 0;
}

function object_has_extra_keys(path) {
    let value = read_json_file(path);
    return type(value) == "object" && length(keys(value)) > 1;
}

function value_length(path) {
    let value = read_json_file(path);
    if (type(value) == "array" || type(value) == "object")
        print(length(value), "\n");
    else
        print("0\n");
}

function response_success() {
    let value = read_stdin_json();
    return type(value) == "object" && value.success === true;
}

function valid_outbound() {
    let value = read_stdin_json();
    return type(value) == "object" && type(value.type) == "string";
}

function stdin_length() {
    let value = read_stdin_json();
    if (type(value) == "array" || type(value) == "object")
        print(length(value), "\n");
    else
        print("0\n");
}

function array_item(index) {
    let value = read_stdin_json();
    index = int(index || 0);
    if (type(value) == "array" && index >= 0 && index < length(value) && value[index] != null)
        print(as_string(value[index]), "\n");
}

function object_get(key) {
    let value = read_stdin_json();
    if (type(value) == "object" && value[key] != null)
        print(as_string(value[key]), "\n");
}

function object_get_default(key, fallback) {
    let value = read_stdin_json();
    if (type(value) == "object" && value[key] != null)
        print(as_string(value[key]), "\n");
    else
        print(as_string(fallback), "\n");
}

function parse_json_or_null(value) {
    try {
        return json(value);
    }
    catch (e) {
        return null;
    }
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

function arg_optional_number(value) {
    value = as_string(value);
    if (value == "" || value == "null" || match(value, /[^0-9-]/))
        return null;
    return int(value);
}

function object_json(start) {
    let result = {};

    for (let i = start; i + 2 < length(ARGV); i += 3) {
        let key = as_string(ARGV[i]);
        let kind = as_string(ARGV[i + 1]);
        let value = ARGV[i + 2];

        if (kind == "n")
            result[key] = arg_number(value);
        else if (kind == "b")
            result[key] = arg_bool(value);
        else if (kind == "j")
            result[key] = parse_json_or_null(value);
        else if (kind == "a") {
            let parsed = parse_json_or_null(value);
            result[key] = parsed != null ? parsed : as_string(value);
        }
        else
            result[key] = as_string(value);
    }

    write_json(result);
}

function subscription_ui_metadata() {
    let title = as_string(ARGV[1]);
    let web_page_url = as_string(ARGV[2]);
    let support_url = as_string(ARGV[3]);
    let announce = as_string(ARGV[4]);
    let announce_url = as_string(ARGV[5]);
    let file_name = as_string(ARGV[6]);
    let has_traffic = arg_bool(ARGV[7]);
    let upload = arg_optional_number(ARGV[8]);
    let download = arg_optional_number(ARGV[9]);
    let used = arg_number(ARGV[10]);
    let total = arg_optional_number(ARGV[11]);
    let remaining = arg_optional_number(ARGV[12]);
    let is_unlimited = arg_bool(ARGV[13]);
    let expire = arg_optional_number(ARGV[14]);
    let refill_date = arg_optional_number(ARGV[15]);

    let result = { version: 1 };
    if (title != "")
        result.title = title;
    if (has_traffic) {
        let traffic = {
            used: used,
            isUnlimited: is_unlimited
        };
        if (upload != null)
            traffic.upload = upload;
        if (download != null)
            traffic.download = download;
        if (total != null && total > 0) {
            traffic.total = total;
            traffic.remaining = remaining != null ? remaining : 0;
        }
        result.traffic = traffic;
    }
    if (expire != null && expire > 0)
        result.expire = expire;
    if (refill_date != null && refill_date > 0)
        result.refillDate = refill_date;
    if (web_page_url != "")
        result.webPageUrl = web_page_url;
    if (support_url != "")
        result.supportUrl = support_url;
    if (announce != "")
        result.announce = announce;
    if (announce_url != "")
        result.announceUrl = announce_url;
    if (file_name != "")
        result.fileName = file_name;

    if (length(keys(result)) > 1)
        write_json(result);
}

function stdin_json() {
    let value = read_stdin_json();
    if (value == null)
        exit(1);
    write_json(value);
}

function file_json_valid(path) {
    return read_json_file(path) != null;
}

function json_file_field(path, key, fallback) {
    let value = read_json_file(path);
    if (type(value) == "object" && value[key] != null)
        print(as_string(value[key]), "\n");
    else
        print(as_string(fallback), "\n");
}

function github_release_tags(path) {
    for (let release in array_or_empty(read_json_file(path))) {
        if (type(release) != "object")
            continue;
        if (release.draft === true || release.prerelease === true)
            continue;
        let tag = as_string(release.tag_name || "");
        if (tag != "")
            print(tag, "\n");
    }
}

function github_response_ok() {
    let response = read_stdin_json();
    if (response == null)
        return false;

    if (type(response) == "object") {
        let message = as_string(response.message || "");
        if (match(message, /API rate limit/) || match(message, /rate limit exceeded/) || message == "Not Found")
            return false;
    }

    return true;
}

function release_by_tag(tag) {
    for (let release in array_or_empty(read_stdin_json())) {
        if (type(release) != "object")
            continue;
        if (release.draft === true || release.prerelease === true)
            continue;
        if (as_string(release.tag_name || "") == tag) {
            write_json(release);
            return;
        }
    }
}

function release_asset_name(prefix, ext) {
    let release = object_or_empty(read_stdin_json());
    for (let asset in array_or_empty(release.assets)) {
        if (type(asset) != "object")
            continue;
        let name = as_string(asset.name || "");
        if ((str_startswith(name, prefix + "_") || str_startswith(name, prefix + "-")) &&
            str_endswith(name, "." + ext)) {
            print(name, "\n");
            return;
        }
    }
}

function release_asset_url(name) {
    let release = object_or_empty(read_stdin_json());
    for (let asset in array_or_empty(release.assets)) {
        if (type(asset) == "object" && as_string(asset.name || "") == name) {
            print(as_string(asset.browser_download_url || ""), "\n");
            return;
        }
    }
}

function release_asset_name_by_suffix(suffix) {
    let release = object_or_empty(read_stdin_json());
    for (let asset in array_or_empty(release.assets)) {
        let name = type(asset) == "object" ? as_string(asset.name || "") : "";
        if (str_endswith(name, suffix)) {
            print(name, "\n");
            return;
        }
    }
}

function release_asset_url_by_suffix(suffix) {
    let release = object_or_empty(read_stdin_json());
    for (let asset in array_or_empty(release.assets)) {
        if (type(asset) != "object")
            continue;
        let name = as_string(asset.name || "");
        if (str_endswith(name, suffix)) {
            print(as_string(asset.browser_download_url || ""), "\n");
            return;
        }
    }
}

function byedpi_asset_matches(name, arch, ext) {
    return (str_startswith(name, "byedpi_") || str_startswith(name, "byedpi-")) &&
        str_endswith(name, "." + ext) &&
        (str_contains(name, "_" + arch + "." + ext) || str_contains(name, "-" + arch + "." + ext));
}

function select_byedpi_asset_from_release(release, asset_ext, arch_candidates) {
    for (let arch in split(as_string(arch_candidates), " ")) {
        if (arch == "")
            continue;
        for (let asset in array_or_empty(release.assets)) {
            if (type(asset) != "object")
                continue;
            let name = as_string(asset.name || "");
            let url = as_string(asset.browser_download_url || "");
            if (url != "" && byedpi_asset_matches(name, arch, asset_ext)) {
                print(arch, "\t", name, "\t", url, "\n");
                return true;
            }
        }
    }

    return false;
}

function byedpi_select_asset(series, asset_ext, arch_candidates) {
    let releases = array_or_empty(read_stdin_json());

    for (let pass = 0; pass < 2; pass++) {
        if (pass == 0 && as_string(series) == "")
            continue;

        for (let release in releases) {
            if (type(release) != "object")
                continue;
            if (release.draft === true || release.prerelease === true)
                continue;
            if (pass == 0) {
                let tag = as_string(release.tag_name || "");
                let name = as_string(release.name || "");
                if (!str_contains(tag, series) && !str_contains(name, series))
                    continue;
            }
            if (select_byedpi_asset_from_release(release, asset_ext, arch_candidates))
                return;
        }
    }
}

function sing_box_extended_release_tag() {
    for (let release in array_or_empty(read_stdin_json())) {
        if (type(release) != "object")
            continue;
        if (release.draft === true || release.prerelease === true)
            continue;
        let tag = as_string(release.tag_name || "");
        let lowered = lc(tag);
        if (tag != "" && !str_contains(lowered, "alpha") && !str_contains(lowered, "beta") && !str_contains(lowered, "rc")) {
            print(tag, "\n");
            return;
        }
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
        byedpi_version: as_string(ARGV[8]),
        byedpi_installed: arg_number(ARGV[9]),
        openwrt_version: as_string(ARGV[10]),
        device_model: as_string(ARGV[11]),
        generated_at: arg_number(ARGV[12])
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

function job_running_is(path, expected) {
    let value = read_json_file(path);
    let running = type(value) == "object" && value.running === true;
    return running == arg_bool(expected);
}

function updates_set_running_job_pid(path, pid) {
    let value = object_or_empty(read_json_file(path));
    if (value.running === true)
        value.pid = as_string(pid);
    write_json(value);
}

function updates_mark_stale_job_state(path) {
    let value = object_or_empty(read_json_file(path));
    if (value.running === true) {
        value.success = false;
        value.running = false;
        value.message = "Component action job is stale or the worker process exited unexpectedly";
        value.changed = 0;
        value.status = "";
        value.exit_code = null;
    }
    write_json(value);
}

function updates_finish_job_state(path, exit_code, updated_at) {
    let value = read_json_file(path);
    if (value == null)
        exit(1);

    value.running = false;
    value.exit_code = arg_number(exit_code);
    value.updated_at = arg_number(updated_at);
    write_json(value);
}

function updates_fallback_job_state(component, action, message, exit_code, updated_at) {
    write_json({
        success: false,
        running: false,
        component: as_string(component),
        action: as_string(action),
        message: as_string(message),
        current_version: "",
        latest_version: "",
        changed: 0,
        status: "",
        exit_code: arg_number(exit_code),
        updated_at: arg_number(updated_at)
    });
}

function sing_box_service_pid() {
    let value = read_stdin_json();
    let service = type(value) == "object" ? value["sing-box"] : null;
    let instances = service && type(service.instances) == "object" ? service.instances : {};

    for (let _, instance in instances) {
        if (type(instance) == "object" && instance.running === true && int(instance.pid || 0) > 0) {
            print(instance.pid, "\n");
            return;
        }
    }
}

function array_append_string(path, value) {
    let result = array_or_empty(read_json_file(path));
    push(result, as_string(value));
    write_json(result);
}

function arrays_concat(first_path, second_path) {
    let result = array_or_empty(read_json_file(first_path));
    for (let value in array_or_empty(read_json_file(second_path)))
        push(result, value);
    write_json(result);
}

function object_set_string(path, key, value) {
    let result = object_or_empty(read_json_file(path));
    result[as_string(key)] = as_string(value);
    write_json(result);
}

function objects_merge(first_path, second_path) {
    let result = object_or_empty(read_json_file(first_path));
    for (let key, value in object_or_empty(read_json_file(second_path)))
        result[key] = value;
    write_json(result);
}

function normalized_country_list() {
    let result = [];
    for (let value in array_or_empty(read_stdin_json())) {
        value = uc(as_string(value));
        if (length(value) == 2)
            push(result, value);
    }
    write_json(result);
}

function contains(values, needle) {
    for (let value in values) {
        if (value == needle)
            return true;
    }
    return false;
}

function urltest_filter(mode, tags_path, names_path, countries_path, names_filter_path, regex_tags_path, countries_filter_path) {
    let tags = array_or_empty(read_json_file(tags_path));
    let names = object_or_empty(read_json_file(names_path));
    let countries = object_or_empty(read_json_file(countries_path));
    let name_filter = array_or_empty(read_json_file(names_filter_path));
    let regex_tags = array_or_empty(read_json_file(regex_tags_path));
    let country_filter = array_or_empty(read_json_file(countries_filter_path));
    let result = [];

    for (let tag in tags) {
        let name = as_string(names[tag] || tag);
        let country = uc(as_string(countries[tag] || ""));
        let matched = contains(name_filter, name) ||
            contains(name_filter, tag) ||
            (country != "" && contains(country_filter, country)) ||
            contains(regex_tags, tag);

        if ((mode == "include" && matched) || (mode == "exclude" && !matched))
            push(result, tag);
    }

    write_json(result);
}

function section_countries(path) {
    let cache = object_or_empty(read_json_file(path));
    write_json(object_or_empty(cache.outboundMetadata && cache.outboundMetadata.countries));
}

function cached_countries_for_servers(servers_path, cache_path) {
    let servers = object_or_empty(read_json_file(servers_path));
    let cache = object_or_empty(read_json_file(cache_path));
    let result = {};

    for (let tag, _ in servers) {
        let country = as_string(cache[tag] || "");
        if (country != "")
            result[tag] = country;
    }

    write_json(result);
}

function missing_servers_tsv(servers_path, cache_path) {
    let servers = object_or_empty(read_json_file(servers_path));
    let cache = object_or_empty(read_json_file(cache_path));

    for (let tag, server in servers) {
        server = as_string(server);
        if (server != "" && as_string(cache[tag] || "") == "")
            print(tag, "\t", server, "\n");
    }
}

function body_error(path) {
    let body = read_json_file(path);
    let result = "";

    if (type(body) == "object")
        result = as_string((body.error && body.error.code) || body.code || body.error || "");

    print(result, "\n");
}

function ip_country_tsv(path) {
    for (let item in array_or_empty(read_json_file(path))) {
        if (type(item) != "object")
            continue;
        let ip = as_string(item.ip || "");
        let country = as_string(item.country || "");
        if (ip != "" && country != "")
            print(ip, "\t", country, "\n");
    }
}

function tsv_to_object(path) {
    let result = {};
    let data = fs.readfile(path);
    if (data != null) {
        for (let line in split(data, "\n")) {
            if (line == "")
                continue;
            let parts = split(line, "\t");
            if (length(parts) >= 2)
                result[parts[0]] = parts[1];
        }
    }
    write_json(result);
}

function tsv_second_column_array(path) {
    let seen = {};
    let result = [];
    let data = fs.readfile(path);

    if (data != null) {
        for (let line in split(data, "\n")) {
            if (line == "")
                continue;
            let parts = split(line, "\t");
            if (length(parts) >= 2 && parts[1] != "" && !seen[parts[1]]) {
                seen[parts[1]] = true;
                push(result, parts[1]);
            }
        }
    }

    sort(result, function(first, second) {
        return first == second ? 0 : (first < second ? -1 : 1);
    });
    write_json(result);
}

function array_slice_file(path, start, end) {
    write_json(slice(array_or_empty(read_json_file(path)), int(start || 0), int(end || 0)));
}

function object_nonempty_stdin() {
    let value = read_stdin_json();
    return (type(value) == "array" || type(value) == "object") && length(value) > 0;
}

function resolved_countries_from_tsv(resolved_path, ip_country_path) {
    let ip_country = object_or_empty(read_json_file(ip_country_path));
    let result = {};
    let data = fs.readfile(resolved_path);

    if (data != null) {
        for (let line in split(data, "\n")) {
            if (line == "")
                continue;
            let parts = split(line, "\t");
            if (length(parts) < 2)
                continue;
            let country = as_string(ip_country[parts[1]] || "");
            if (country != "")
                result[parts[0]] = country;
        }
    }

    write_json(result);
}

function outbound_server_by_tag(tag) {
    let config = object_or_empty(read_stdin_json());
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) == "object" && outbound.tag == tag) {
            print(as_string(outbound.server || ""), "\n");
            return;
        }
    }
}

function server_users_from_tsv(protocol, path) {
    let result = [];
    let data = fs.readfile(path);

    if (data != null) {
        for (let line in split(data, "\n")) {
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
            print(as_string(rule.outbound || ""), "\n");
            return;
        }
    }
}

function dns_route_rule_exists(service_tag, tag) {
    let config = object_or_empty(read_stdin_json());
    for (let rule in array_or_empty(config.dns && config.dns.rules)) {
        if (type(rule) == "object" && rule[service_tag] == tag)
            return true;
    }
    return false;
}

function route_rule_has_resolve_matchers(service_tag, tag) {
    let config = object_or_empty(read_stdin_json());
    for (let rule in array_or_empty(config.route && config.route.rules)) {
        if (type(rule) != "object" || rule[service_tag] != tag)
            continue;
        if (rule.domain != null || rule.domain_suffix != null || rule.domain_keyword != null ||
            rule.domain_regex != null || rule.rule_set != null)
            return true;
    }
    return false;
}

let mode = ARGV[0] || "";

if (mode == "validate-subscription")
    exit(validate_subscription(ARGV[1]) ? 0 : 1);
else if (mode == "object-has-extra-keys")
    exit(object_has_extra_keys(ARGV[1]) ? 0 : 1);
else if (mode == "length")
    value_length(ARGV[1]);
else if (mode == "response-success")
    exit(response_success() ? 0 : 1);
else if (mode == "valid-outbound")
    exit(valid_outbound() ? 0 : 1);
else if (mode == "stdin-length")
    stdin_length();
else if (mode == "array-item")
    array_item(ARGV[1]);
else if (mode == "object-get")
    object_get(ARGV[1]);
else if (mode == "object-get-default")
    object_get_default(ARGV[1], ARGV[2]);
else if (mode == "object-json")
    object_json(1);
else if (mode == "subscription-ui-metadata")
    subscription_ui_metadata();
else if (mode == "stdin-json")
    stdin_json();
else if (mode == "file-json-valid")
    exit(file_json_valid(ARGV[1]) ? 0 : 1);
else if (mode == "json-file-field")
    json_file_field(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "github-release-tags")
    github_release_tags(ARGV[1]);
else if (mode == "github-response-ok")
    exit(github_response_ok() ? 0 : 1);
else if (mode == "release-by-tag")
    release_by_tag(ARGV[1]);
else if (mode == "release-asset-name")
    release_asset_name(ARGV[1], ARGV[2]);
else if (mode == "release-asset-url")
    release_asset_url(ARGV[1]);
else if (mode == "release-asset-name-by-suffix")
    release_asset_name_by_suffix(ARGV[1]);
else if (mode == "release-asset-url-by-suffix")
    release_asset_url_by_suffix(ARGV[1]);
else if (mode == "byedpi-select-asset")
    byedpi_select_asset(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "sing-box-extended-release-tag")
    sing_box_extended_release_tag();
else if (mode == "system-info-cache-valid")
    exit(system_info_cache_valid(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]) ? 0 : 1);
else if (mode == "system-info-json")
    system_info_json();
else if (mode == "nfqws-strategy-validation")
    nfqws_strategy_validation(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "url-encode")
    url_encode(ARGV[1]);
else if (mode == "job-running-is")
    exit(job_running_is(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "updates-set-running-job-pid")
    updates_set_running_job_pid(ARGV[1], ARGV[2]);
else if (mode == "updates-mark-stale-job-state")
    updates_mark_stale_job_state(ARGV[1]);
else if (mode == "updates-finish-job-state")
    updates_finish_job_state(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "updates-fallback-job-state")
    updates_fallback_job_state(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "sing-box-service-pid")
    sing_box_service_pid();
else if (mode == "array-append-string")
    array_append_string(ARGV[1], ARGV[2]);
else if (mode == "arrays-concat")
    arrays_concat(ARGV[1], ARGV[2]);
else if (mode == "object-set-string")
    object_set_string(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "objects-merge")
    objects_merge(ARGV[1], ARGV[2]);
else if (mode == "normalized-country-list")
    normalized_country_list();
else if (mode == "urltest-filter")
    urltest_filter(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "section-countries")
    section_countries(ARGV[1]);
else if (mode == "cached-countries-for-servers")
    cached_countries_for_servers(ARGV[1], ARGV[2]);
else if (mode == "missing-servers-tsv")
    missing_servers_tsv(ARGV[1], ARGV[2]);
else if (mode == "body-error")
    body_error(ARGV[1]);
else if (mode == "ip-country-tsv")
    ip_country_tsv(ARGV[1]);
else if (mode == "tsv-to-object")
    tsv_to_object(ARGV[1]);
else if (mode == "tsv-second-column-array")
    tsv_second_column_array(ARGV[1]);
else if (mode == "array-slice-file")
    array_slice_file(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "object-nonempty")
    exit(object_nonempty_stdin() ? 0 : 1);
else if (mode == "resolved-countries-from-tsv")
    resolved_countries_from_tsv(ARGV[1], ARGV[2]);
else if (mode == "outbound-server-by-tag")
    outbound_server_by_tag(ARGV[1]);
else if (mode == "server-users-from-tsv")
    server_users_from_tsv(ARGV[1], ARGV[2]);
else if (mode == "mask-sing-box-config")
    mask_sing_box_config(ARGV[1]);
else if (mode == "prepare-check-proxy-config")
    prepare_check_proxy_config(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "check-proxy-outbound-tag")
    check_proxy_outbound_tag(ARGV[1], ARGV[2]);
else if (mode == "dns-route-rule-exists")
    exit(dns_route_rule_exists(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "route-rule-has-resolve-matchers")
    exit(route_rule_has_resolve_matchers(ARGV[1], ARGV[2]) ? 0 : 1);
else {
    warn("Usage: json_utils.uc <operation> ...\n");
    exit(1);
}
