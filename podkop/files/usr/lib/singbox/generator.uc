#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let runtime_constants = require("singbox.constants");
let runtime_country = require("singbox.country");
let runtime_dns = require("singbox.dns");
let runtime_route = require("singbox.route");
let runtime_rulesets = require("singbox.rulesets");
let runtime_servers = require("singbox.servers");
let runtime_subscription = require("singbox.subscription");
let runtime_url = require("core.url");
let runtime_urltest = require("singbox.urltest");
let source_rulesets = require("routing.rulesets");
let rule_config = require("config.rule");
let connections = require("config.connections");
let uci = null;
let fixture_uci_data = null;
let runtime_settings_cache = null;
let runtime_ruleset_folder = runtime_constants.TMP_RULESET_FOLDER;

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let read_stdin = common.read_stdin;
let read_stdin_json = common.read_stdin_json;
let write_json = common.write_json;
let write_compact_string_array = common.write_compact_string_array;
let csv_to_json_array = common.csv_to_json_array;
let write_file_json = common.write_json_file;
let write_json_file = common.write_json_file;
let strip_internal_fields = common.strip_internal_fields;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let int_option = common.int_option;
let url_decode = runtime_url.decode;
let url_scheme = runtime_url.scheme;
let url_fragment = runtime_url.fragment;
let url_strip_fragment_value = runtime_url.strip_fragment;
let url_host = runtime_url.host;
let url_port = runtime_url.port;
let url_userinfo = runtime_url.userinfo;
let url_path = runtime_url.path;
let url_query_params = runtime_url.query_params;

const CONFIG_NAME = "podkop-plus";

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash <= 0 ? "" : substr(path, 0, slash);
}

function ensure_dir(path) {
    path = as_string(path);
    if (path == "" || path == "/")
        return true;
    if (fs.stat(path) != null)
        return true;

    let parent = parent_dir(path);
    if (parent != "" && !ensure_dir(parent))
        return false;

    return fs.mkdir(path, 0755) || fs.stat(path) != null;
}

function ensure_parent_dir(path) {
    return ensure_dir(parent_dir(path));
}

function atomic_write_json_file(path, value) {
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);

    if (!ensure_parent_dir(path))
        return false;
    if (!write_json_file(tmp_path, value))
        return false;
    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        return false;
    }
    return true;
}

function fixture_section_list(type_name) {
    let value = object_or_empty(fixture_uci_data)[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = object_or_empty(fixture_uci_data)[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function fixture_get_section(section_name) {
    let fixture = object_or_empty(fixture_uci_data);
    if (section_name == "settings" && type(fixture.settings) == "object")
        return fixture.settings;

    for (let type_name in [ "settings", "server", "section", "subscription_url", "urltest", "priority_group", "priority_level" ]) {
        for (let section in fixture_section_list(type_name)) {
            if (as_string(section[".name"]) == section_name)
                return section;
        }
    }

    return {};
}

function fixture_cursor(path) {
    fixture_uci_data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(fixture_uci_data);
    return {
        load: function(_config_name) {
            return true;
        },
        get_all: function(_config_name, section_name) {
            return fixture_get_section(section_name);
        },
        foreach: function(_config_name, type_name, callback) {
            for (let section in fixture_section_list(type_name))
                callback(section);
        }
    };
}

function use_fixture_cursor(path) {
    uci = fixture_cursor(path);
    runtime_settings_cache = null;
}

function runtime_uci_cursor() {
    return {
        load: function(package_name) {
            return uci_core.load(package_name);
        },
        get_all: function(package_name, section_name) {
            return uci_core.get_all(package_name, section_name);
        },
        foreach: function(package_name, type_name, callback) {
            for (let section in uci_core.section_objects(package_name, type_name))
                callback(section);
        }
    };
}

function uci_cursor() {
    if (uci == null)
        uci = runtime_uci_cursor();
    return uci;
}

function runtime_generate_unsupported(reason) {
    warn(reason, "\n");
    exit(2);
}

function valid_section_name(name) {
    return match(name, /^[A-Za-z0-9_]+$/);
}

function section_enabled(section) {
    return bool_option(section, "enabled", true);
}

function runtime_settings() {
    if (runtime_settings_cache == null)
        runtime_settings_cache = object_or_empty(uci_cursor().get_all(CONFIG_NAME, "settings"));
    return runtime_settings_cache;
}

function settings_update_interval() {
    let settings = runtime_settings();
    if (!bool_option(settings, "list_update_enabled", true))
        return "";

    let update_interval = option(settings, "update_interval", "1d");
    return update_interval != "" ? update_interval : "1d";
}

function remote_ruleset_update_interval() {
    let update_interval = settings_update_interval();
    return update_interval != "" ? update_interval : runtime_constants.DISABLED_UPDATE_INTERVAL;
}

function internal_flag(value) {
    return value === true || value == 1 || value == "1" || value == "true" || value == "yes";
}

function subscription_group_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    let t = as_string(outbound.type);
    return (t == "selector" || t == "urltest") && internal_flag(outbound.__podkop_allow_group);
}

function subscription_urltest_group_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    return as_string(outbound.type || "") == "urltest" && internal_flag(outbound.__podkop_allow_group);
}

function subscription_outbound_tag(outbound) {
    return type(outbound) == "object" ? as_string(outbound.tag || "") : "";
}

function subscription_visibility_refs(outbounds) {
    let refs = {
        urltest: {},
        detour: {}
    };

    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        if (subscription_urltest_group_outbound(outbound)) {
            for (let tag_name in array_or_empty(outbound.outbounds)) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    refs.urltest[tag_name] = true;
            }
        }

        let detour = as_string(outbound.detour || "");
        if (detour != "")
            refs.detour[detour] = true;
    }

    return refs;
}

function subscription_hidden_outbound(outbound, refs, hide_urltest_group_outbounds, hide_detour_outbounds) {
    if (type(outbound) != "object")
        return false;

    let tag_name = subscription_outbound_tag(outbound);
    let urltest_refs = object_or_empty(object_or_empty(refs).urltest);
    let detour_refs = object_or_empty(object_or_empty(refs).detour);
    let hidden_by_urltest = tag_name != "" && urltest_refs[tag_name];
    let hidden_by_detour = tag_name != "" && detour_refs[tag_name];

    if (hidden_by_urltest && hide_urltest_group_outbounds !== false)
        return true;
    if (hidden_by_detour && hide_detour_outbounds !== false)
        return true;
    return internal_flag(outbound.__podkop_hidden) && !hidden_by_urltest && !hidden_by_detour;
}

function tag(base, postfix) {
    return runtime_constants.tag(base, postfix);
}

function outbound_tag(section_name) {
    return runtime_constants.outbound_tag(section_name);
}

function download_via_proxy_section_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy_section";
    if (purpose == "components")
        return "download_components_via_proxy_section";
    return "";
}

function download_via_proxy_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy";
    if (purpose == "components")
        return "download_components_via_proxy";
    return "";
}

function download_via_proxy_section(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    if (enabled_option == "" || !bool_option(settings, enabled_option, false))
        return "";

    let section_option = download_via_proxy_section_option_for_purpose(purpose);
    let configured = section_option != "" ? option(settings, section_option, "") : "";
    if (configured != "")
        return configured;

    return option(settings, "download_lists_via_proxy_section", "");
}

function download_via_proxy_enabled(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    return enabled_option != "" && bool_option(settings, enabled_option, false);
}

function download_via_proxy_any_enabled(settings, sections) {
    return download_via_proxy_enabled(settings, "lists") ||
        download_via_proxy_enabled(settings, "components") ||
        length(connections.subscription_download_targets(sections || [])) > 0;
}

function download_detour_tag(settings, purpose) {
    let section_name = download_via_proxy_section(settings, purpose);
    return section_name == "" ? "" : outbound_tag(section_name);
}

function ruleset_tag(section_name, name, kind) {
    kind = as_string(kind);
    return kind == ""
        ? section_name + "-" + name + "-ruleset"
        : section_name + "-" + name + "-" + kind + "-ruleset";
}

function ruleset_registered(config, tag_name) {
    for (let rule_set in array_or_empty(config.route && config.route.rule_set)) {
        if (type(rule_set) == "object" && rule_set.tag == tag_name)
            return true;
    }
    return false;
}

function ensure_custom_ruleset(config, reference) {
    let tag_name;
    let kind = runtime_rulesets.kind_from_reference_hint(reference);

    if (runtime_rulesets.is_community(reference)) {
        tag_name = "builtin-" + reference + "-ruleset";
        kind = "domains";
        if (!ruleset_registered(config, tag_name)) {
            let rule_set = {
                type: "remote",
                tag: tag_name,
                format: "binary",
                url: runtime_rulesets.community_url(reference)
            };
            let detour = download_detour_tag(runtime_settings());
            if (detour != "")
                rule_set.download_detour = detour;
            rule_set.update_interval = remote_ruleset_update_interval();
            push(config.route.rule_set, rule_set);
        }
        return { tag: tag_name, kind };
    }

    tag_name = "inline-custom-" + runtime_rulesets.hash12(reference) + "-ruleset";
    if (kind == "unknown")
        kind = "domains";
    if (ruleset_registered(config, tag_name))
        return { tag: tag_name, kind };

    let extension = runtime_rulesets.file_extension(reference);
    if (substr(reference, 0, 1) == "/") {
        if (extension != "srs" && extension != "json")
            runtime_generate_unsupported("local rule_set extension is not supported by sing-box config generation");
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: extension == "json" ? "source" : "binary",
            path: reference
        });
    }
    else if (substr(reference, 0, 7) == "http://" || substr(reference, 0, 8) == "https://") {
        let rule_set = {
            type: "remote",
            tag: tag_name,
            format: runtime_rulesets.remote_format(reference),
            url: reference
        };
        let detour = download_detour_tag(runtime_settings());
        if (detour != "")
            rule_set.download_detour = detour;
        rule_set.update_interval = remote_ruleset_update_interval();
        push(config.route.rule_set, rule_set);
    }
    else {
        runtime_generate_unsupported("rule_set reference is not supported by sing-box config generation");
    }

    return { tag: tag_name, kind };
}

function clash_api_config(settings, service_address) {
    let controller = as_string(service_address || "");
    if (bool_option(settings, "enable_yacd", false) && bool_option(settings, "enable_yacd_wan_access", false))
        controller = "0.0.0.0";
    else if (controller == "")
        controller = "127.0.0.1";

    let result = {
        external_controller: controller + ":9090"
    };
    if (bool_option(settings, "enable_yacd", false)) {
        result.external_ui = "ui";
        let secret = option(settings, "yacd_secret_key", "");
        if (secret != "")
            result.secret = secret;
    }
    return result;
}

function cli_bool(value) {
    return value === true || value == "1" || value == "true" || value == "yes" || value == "on";
}

function tproxy_inbound_matcher() {
    return [ runtime_constants.TPROXY_INBOUND_TAG, runtime_constants.TPROXY_INBOUND6_TAG ];
}

function base_config(settings, service_address, runtime_context) {
    let log_level = option(settings, "log_level", "warn");
    let bootstrap_dns_server = option(settings, "bootstrap_dns_server", "77.88.8.8");
    let rewrite_ttl = int_option(settings, "dns_rewrite_ttl", "60");
    let cache_path = option(settings, "cache_path", "/tmp/sing-box/cache.db");
    let dns_server = runtime_dns.server_config(settings);
    if (dns_server.unsupported)
        runtime_generate_unsupported(dns_server.unsupported);

    return {
        log: {
            disabled: false,
            level: log_level,
            timestamp: false
        },
        dns: {
            servers: [
                { type: "udp", tag: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG, server: bootstrap_dns_server, server_port: 53 },
                dns_server,
                {
                    type: "fakeip",
                    tag: runtime_constants.FAKEIP_DNS_SERVER_TAG,
                    inet4_range: runtime_constants.FAKEIP_INET4_RANGE,
                    inet6_range: runtime_constants.FAKEIP_INET6_RANGE
                }
            ],
            rules: [
                { action: "reject", query_type: "HTTPS" },
                { action: "reject", domain_suffix: "use-application-dns.net" },
                {
                    action: "route",
                    server: runtime_constants.FAKEIP_DNS_SERVER_TAG,
                    rewrite_ttl,
                    domain: [ runtime_constants.FAKEIP_TEST_DOMAIN, runtime_constants.CHECK_PROXY_IP_DOMAIN ]
                }
            ],
            final: runtime_constants.DNS_SERVER_TAG,
            strategy: "prefer_ipv4",
            independent_cache: true
        },
        ntp: {},
        certificate: {},
        endpoints: [],
        inbounds: [
            { type: "tproxy", tag: runtime_constants.TPROXY_INBOUND_TAG, listen: runtime_constants.TPROXY_INBOUND_ADDRESS, listen_port: runtime_constants.TPROXY_INBOUND_PORT, tcp_fast_open: true, udp_fragment: true },
            { type: "tproxy", tag: runtime_constants.TPROXY_INBOUND6_TAG, listen: runtime_constants.TPROXY_INBOUND6_ADDRESS, listen_port: runtime_constants.TPROXY_INBOUND_PORT, tcp_fast_open: true, udp_fragment: true },
            { type: "direct", tag: runtime_constants.DNS_INBOUND_TAG, listen: runtime_constants.DNS_INBOUND_ADDRESS, listen_port: runtime_constants.DNS_INBOUND_PORT }
        ],
        outbounds: [
            { type: "direct", tag: runtime_constants.DIRECT_OUTBOUND_TAG },
            { type: "direct", tag: runtime_constants.BYPASS_OUTBOUND_TAG }
        ],
        route: runtime_route.config(settings, runtime_context),
        services: [],
        experimental: {
            cache_file: {
                enabled: true,
                path: cache_path,
                store_fakeip: true
            },
            clash_api: clash_api_config(settings, service_address)
        }
    };
}

function unsupported_setting(settings, key) {
    let value = option(settings, key, "");
    return value != "" && value != "0";
}

function check_supported_settings(settings) {
}

function supported_subscription_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    let t = as_string(outbound.type);
    if (subscription_group_outbound(outbound))
        return true;
    if (t == "direct" || t == "selector" || t == "urltest" || t == "dns" || t == "block")
        return false;
    return t == "vless" || t == "vmess" || t == "trojan" || t == "shadowsocks" ||
        t == "socks" || t == "http" || t == "hysteria2";
}

function copy_subscription_outbound(outbound, new_tag) {
    let copy = {};
    for (let key, value in outbound) {
        if (key != "tag" && key != "remark" && key != "share_link" &&
            key != "__podkop_hidden" && key != "__podkop_allow_group")
            copy[key] = value;
    }
    if (as_string(copy.type || "") == "hysteria2" &&
        type(copy.tls) == "object" &&
        copy.tls.utls != null) {
        let tls = {};
        for (let key, value in copy.tls) {
            if (key != "utls")
                tls[key] = value;
        }
        copy.tls = tls;
    }
    copy.tag = new_tag;
    return copy;
}

function rewrite_subscription_outbound_references(outbounds, tag_map) {
    for (let outbound in outbounds) {
        if (type(outbound) != "object")
            continue;

        for (let key in [ "detour", "default" ]) {
            let reference = as_string(outbound[key] || "");
            if (reference != "" && tag_map[reference])
                outbound[key] = tag_map[reference];
        }

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag_name in outbound.outbounds) {
                tag_name = as_string(tag_name);
                if (tag_map[tag_name])
                    push(rewritten, tag_map[tag_name]);
            }
            outbound.outbounds = rewritten;
        }
    }
}

function subscription_skip_summary(skipped) {
    let parts = [];
    for (let t in sort(keys(skipped)))
        push(parts, skipped[t] + "x " + t);
    return join("; ", parts);
}

function reportable_skipped_subscription_type(t) {
    return t != "direct" && t != "selector" && t != "urltest" && t != "dns" && t != "block";
}

function urltest_leaf_candidate_outbound(outbound) {
    if (type(outbound) != "object")
        return false;

    let t = lc(as_string(outbound.type || ""));
    return t != "selector" && t != "urltest" && t != "dns" && t != "block";
}

function unique_tag(base, taken) {
    base = as_string(base);
    if (base == "")
        base = "server";
    if (!taken[base])
        return base;
    for (let i = 1; i < 100000; i++) {
        let candidate = base + "-" + i;
        if (!taken[candidate])
            return candidate;
    }
    return base + "-overflow";
}

function reserved_runtime_tag_set(outbounds) {
    let result = {};
    for (let tag_name in keys(object_or_empty(runtime_constants.RESERVED_TAGS)))
        result[tag_name] = true;

    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        let tag_name = as_string(outbound.tag || "");
        if (tag_name != "")
            result[tag_name] = true;
    }
    return result;
}

function assert_unique_outbound_tags(config) {
    let seen = {};
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            runtime_generate_unsupported("generated sing-box outbound is not an object");

        let tag_name = as_string(outbound.tag || "");
        if (tag_name == "")
            runtime_generate_unsupported("generated sing-box outbound has an empty tag");
        if (seen[tag_name])
            runtime_generate_unsupported("generated sing-box config has duplicate outbound tag '" + tag_name + "'");
        seen[tag_name] = true;
    }
}

function add_subscription_source_with_state(config, section, source_index, source_entry, taken, selector_tags, urltest_candidate_tags, state, show_metadata, include_urltest_groups, hide_urltest_group_outbounds, hide_detour_outbounds, node_prefix) {
    let section_name = section[".name"];
    let source_section = runtime_subscription.source_id(section_name, source_index);
    if (!runtime_subscription.source_cache_is_current(
        source_section,
        source_entry,
        connections.subscription_user_agent(section, source_entry),
        connections.subscription_hwid(section, source_entry)
    ))
        return 0;

    let outbounds = runtime_subscription.read_source_outbounds(source_section);
    if (length(outbounds) == 0)
        return 0;

    if (show_metadata !== false)
        runtime_subscription.merge_source_metadata(state, section_name, source_section, source_index, source_entry);
    let visibility_refs = subscription_visibility_refs(outbounds);
    if (include_urltest_groups === false)
        hide_urltest_group_outbounds = false;
    node_prefix = trim(as_string(node_prefix));
    let prepared = [];
    let source_indices = [];
    let display_names = [];
    let source_links = [];
    let group_flags = [];
    let hidden_flags = [];
    let tag_map = {};
    let skipped = {};
    for (let i = 0; i < length(outbounds); i++) {
        let outbound = outbounds[i];
        if (!supported_subscription_outbound(outbound)) {
            let t = type(outbound) == "object" ? as_string(outbound.type || "missing-type") : "non-object";
            if (reportable_skipped_subscription_type(t))
                skipped[t] = (skipped[t] || 0) + 1;
            continue;
        }
        if (include_urltest_groups === false && subscription_urltest_group_outbound(outbound))
            continue;
        let display_name = as_string(outbound.remark || outbound.tag || ("server-" + (i + 1)));
        let base = as_string(outbound.tag || outbound.remark || ("server-" + (i + 1)));
        if (node_prefix != "") {
            display_name = node_prefix + " " + display_name;
            base = display_name;
        }
        let new_tag = unique_tag(base, taken);
        taken[new_tag] = true;
        tag_map[base] = new_tag;
        if (as_string(outbound.tag || "") != "")
            tag_map[as_string(outbound.tag)] = new_tag;
        if (as_string(outbound.remark || "") != "")
            tag_map[as_string(outbound.remark)] = new_tag;
        push(prepared, copy_subscription_outbound(outbound, new_tag));
        push(source_indices, i + 1);
        push(display_names, display_name);
        push(source_links, as_string(outbound.share_link || ""));
        push(group_flags, subscription_group_outbound(outbound));
        push(hidden_flags, subscription_hidden_outbound(outbound, visibility_refs, hide_urltest_group_outbounds, hide_detour_outbounds));
    }

    if (length(keys(skipped)) > 0)
        warn("skipped unsupported subscription outbounds for rule '", section_name, "': ", subscription_skip_summary(skipped), "\n");

    rewrite_subscription_outbound_references(prepared, tag_map);
    let added = 0;
    for (let i = 0; i < length(prepared); i++) {
        let outbound = prepared[i];
        let is_group = group_flags[i] === true;
        if (is_group && length(array_or_empty(outbound.outbounds)) == 0) {
            warn("skipped empty subscription group for rule '", section_name, "': ", as_string(display_names[i] || outbound.tag || "unknown"), "\n");
            continue;
        }

        push(config.outbounds, outbound);
        added++;
        if (!is_group)
            push(urltest_candidate_tags, outbound.tag);
        if (source_links[i] != "")
            outbound.source_link = source_links[i];
        runtime_subscription.remember_source_outbound(state, outbound.tag, source_section, source_index, source_indices[i], display_names[i], outbound);
        delete outbound.source_link;
        if (hidden_flags[i] !== true) {
            push(selector_tags, outbound.tag);
            runtime_subscription.remember_urltest_group(state, outbound.tag, display_names[i], outbound);
        }
    }
    return added;
}

function duration_to_seconds(value) {
    value = as_string(value);
    if (value == "")
        return null;
    if (match(value, /^[0-9]+$/) != null)
        return int(value, 10);

    let suffix = substr(value, length(value) - 1);
    let number = substr(value, 0, length(value) - 1);
    if (match(number, /^[0-9]+$/) == null)
        return null;

    let multiplier = null;
    if (suffix == "s")
        multiplier = 1;
    else if (suffix == "m")
        multiplier = 60;
    else if (suffix == "h")
        multiplier = 3600;
    else if (suffix == "d")
        multiplier = 86400;

    return multiplier == null ? null : int(number, 10) * multiplier;
}

function urltest_check_interval(section, urltest_id) {
    let interval = connections.urltest_check_interval(section, urltest_id);
    return interval != "" ? interval : "3m";
}

function legacy_urltest_idle_timeout(section, urltest_id) {
    if (urltest_id != "urltest")
        return "";

    let settings = connections.urltest_settings(section, urltest_id);
    if (type(settings) == "object" && as_string(settings[".type"] || "") == "urltest")
        return "";

    let interval = urltest_check_interval(section, urltest_id);
    let interval_seconds = duration_to_seconds(interval);
    let default_idle_seconds = duration_to_seconds(runtime_constants.URLTEST_DEFAULT_IDLE_TIMEOUT);
    return interval_seconds != null && interval_seconds > default_idle_seconds ? interval : "";
}

function urltest_idle_timeout(section, urltest_id) {
    let configured = connections.urltest_idle_timeout(section, urltest_id);
    return configured != "" ? configured : legacy_urltest_idle_timeout(section, urltest_id);
}

function supported_urltest_filter_mode(mode) {
    return mode == "include" || mode == "exclude" || mode == "mixed";
}

function filter_mode_uses_include(mode) {
    return mode == "include" || mode == "mixed";
}

function filter_mode_uses_exclude(mode) {
    return mode == "exclude" || mode == "mixed";
}

function configured_country_filter(mode, include_countries, exclude_countries) {
    return (filter_mode_uses_include(mode) && length(array_or_empty(include_countries)) > 0) ||
        (filter_mode_uses_exclude(mode) && length(array_or_empty(exclude_countries)) > 0);
}

function section_needs_country_is(section) {
    for (let urltest_id in connections.urltests(section)) {
        let mode = connections.urltest_filter_mode(section, urltest_id);
        if (connections.urltest_detect_server_country(section, urltest_id) == "country_is" &&
            configured_country_filter(
                mode,
                connections.urltest_include_countries(section, urltest_id),
                connections.urltest_exclude_countries(section, urltest_id)
            ))
            return true;
    }

    for (let group_id in connections.priority_groups(section)) {
        for (let level_id in connections.priority_levels(group_id)) {
            if (connections.priority_level_direct(group_id, level_id))
                continue;
            let mode = connections.priority_level_filter_mode(group_id, level_id);
            if (connections.priority_level_detect_server_country(group_id, level_id) == "country_is" &&
                configured_country_filter(
                    mode,
                    connections.priority_level_include_countries(group_id, level_id),
                    connections.priority_level_exclude_countries(group_id, level_id)
                ))
                return true;
        }
    }
    return false;
}

function section_has_direct_priority_level(section) {
    for (let group_id in connections.priority_groups(section))
        for (let level_id in connections.priority_levels(group_id))
            if (connections.priority_level_direct(group_id, level_id))
                return true;
    return false;
}

function urltest_country_metadata(section, urltest_id, state) {
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    let detect_method = connections.urltest_detect_server_country(section, urltest_id);
    if (detect_method == "flag_emoji")
        return runtime_urltest.countries_from_flag_names(object_or_empty(object_or_empty(state.outboundMetadata).names));
    return metadata;
}

function array_contains(values, needle) {
    for (let value in array_or_empty(values)) {
        if (value == needle)
            return true;
    }
    return false;
}

function unique_string_array(values) {
    let result = [];
    let seen = {};
    for (let value in array_or_empty(values)) {
        value = as_string(value);
        if (value == "" || seen[value])
            continue;
        seen[value] = true;
        push(result, value);
    }
    return result;
}

function object_keys_set(values) {
    let result = {};
    for (let value in array_or_empty(values))
        result[value] = true;
    return result;
}

function tag_display_name(tag, names) {
    let name = as_string(object_or_empty(names)[tag] || "");
    return name != "" ? name : tag;
}

function regex_match_set(tags, names, regexes) {
    return object_keys_set(runtime_urltest.regex_matching_tag_array(tags, names, regexes));
}

function tag_name_filter_matches(tag, names, name_filter, regex_set) {
    let name = tag_display_name(tag, names);
    return array_contains(name_filter, name) || regex_set[tag];
}

function tag_country_filter_matches(tag, countries, country_filter) {
    let country = uc(as_string(object_or_empty(countries)[tag] || ""));
    return country != "" && array_contains(country_filter, country);
}

function urltest_all_candidate_outbounds(urltest_candidate_tags) {
    return unique_string_array(urltest_candidate_tags);
}

function urltest_matching_candidate_outbounds(urltest_candidate_tags, names, countries, name_filter, regexes, country_filter) {
    names = object_or_empty(names);
    countries = object_or_empty(countries);
    country_filter = runtime_urltest.normalized_country_list(country_filter);

    let regex_set = regex_match_set(urltest_candidate_tags, names, regexes);
    let result = [];

    for (let tag in array_or_empty(urltest_candidate_tags)) {
        if (tag_name_filter_matches(tag, names, name_filter, regex_set) ||
            tag_country_filter_matches(tag, countries, country_filter))
            push(result, tag);
    }

    return unique_string_array(result);
}

function urltest_exclude_outbounds(all_outbounds, excluded_outbounds) {
    let excluded = object_keys_set(excluded_outbounds);
    let result = [];
    for (let tag in array_or_empty(all_outbounds)) {
        if (!excluded[tag])
            push(result, tag);
    }
    return result;
}

function filter_candidate_outbounds(filter_mode, urltest_candidate_tags, names, countries,
    include_names, include_regex, include_countries, exclude_names, exclude_regex, exclude_countries) {
    let all_outbounds = urltest_all_candidate_outbounds(urltest_candidate_tags);
    if (filter_mode == "" || filter_mode == "disabled")
        return all_outbounds;
    if (!supported_urltest_filter_mode(filter_mode))
        return all_outbounds;

    let include_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        names,
        countries,
        include_names,
        include_regex,
        include_countries
    );
    let exclude_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        names,
        countries,
        exclude_names,
        exclude_regex,
        exclude_countries
    );

    if (filter_mode == "include")
        return include_outbounds;
    if (filter_mode == "exclude")
        return urltest_exclude_outbounds(all_outbounds, exclude_outbounds);
    if (filter_mode == "mixed")
        return urltest_exclude_outbounds(include_outbounds, exclude_outbounds);
    return all_outbounds;
}

function urltest_filtered_outbounds(section, urltest_id, urltest_candidate_tags, state) {
    return filter_candidate_outbounds(
        connections.urltest_filter_mode(section, urltest_id),
        urltest_candidate_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        urltest_country_metadata(section, urltest_id, state),
        connections.urltest_include_outbounds(section, urltest_id),
        connections.urltest_include_regex(section, urltest_id),
        connections.urltest_include_countries(section, urltest_id),
        connections.urltest_exclude_outbounds(section, urltest_id),
        connections.urltest_exclude_regex(section, urltest_id),
        connections.urltest_exclude_countries(section, urltest_id)
    );
}

function priority_level_country_metadata(group_id, level_id, state) {
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    let detect_method = connections.priority_level_detect_server_country(group_id, level_id);
    if (detect_method == "flag_emoji")
        return runtime_urltest.countries_from_flag_names(object_or_empty(object_or_empty(state.outboundMetadata).names));
    return metadata;
}

function priority_level_filtered_outbounds(group_id, level_id, urltest_candidate_tags, state) {
    if (connections.priority_level_direct(group_id, level_id))
        return [ runtime_constants.DIRECT_OUTBOUND_TAG ];

    return filter_candidate_outbounds(
        connections.priority_level_filter_mode(group_id, level_id),
        urltest_candidate_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        priority_level_country_metadata(group_id, level_id, state),
        connections.priority_level_include_outbounds(group_id, level_id),
        connections.priority_level_include_regex(group_id, level_id),
        connections.priority_level_include_countries(group_id, level_id),
        connections.priority_level_exclude_outbounds(group_id, level_id),
        connections.priority_level_exclude_regex(group_id, level_id),
        connections.priority_level_exclude_countries(group_id, level_id)
    );
}

function priority_levels_with_outbounds(group_id, urltest_candidate_tags, state) {
    let result = [];
    let assigned = {};

    for (let level_id in connections.priority_levels(group_id)) {
        let outbounds = [];
        for (let tag_name in priority_level_filtered_outbounds(group_id, level_id, urltest_candidate_tags, state)) {
            if (!assigned[tag_name]) {
                assigned[tag_name] = true;
                push(outbounds, tag_name);
            }
        }

        push(result, {
            id: level_id,
            displayName: connections.priority_level_display_name(group_id, level_id),
            order: int(connections.priority_level_order(group_id, level_id), 10),
            direct: connections.priority_level_direct(group_id, level_id),
            filter_mode: connections.priority_level_filter_mode(group_id, level_id),
            detect_server_country: connections.priority_level_detect_server_country(group_id, level_id),
            outbounds
        });
    }

    return result;
}

function priority_group_outbounds(levels) {
    let result = [];
    let seen = {};
    for (let level in array_or_empty(levels)) {
        for (let tag_name in array_or_empty(level.outbounds)) {
            tag_name = as_string(tag_name);
            if (tag_name != "" && !seen[tag_name]) {
                seen[tag_name] = true;
                push(result, tag_name);
            }
        }
    }
    return result;
}

function urltest_outbound_tag(section_name, urltest_id) {
    urltest_id = as_string(urltest_id);
    return urltest_id == "urltest"
        ? outbound_tag(section_name + "-urltest")
        : outbound_tag(section_name + "-urltest-" + urltest_id);
}

function priority_outbound_tag(section_name, group_id) {
    return outbound_tag(section_name + "-priority-" + as_string(group_id));
}

function add_urltest_outbound(config, section, urltest_id, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let urltest_outbounds = urltest_filtered_outbounds(section, urltest_id, urltest_candidate_tags, state);
    let urltest_tag = urltest_outbound_tag(section_name, urltest_id);
    let display_name = connections.urltest_display_name(section, urltest_id);
    let urltest_outbound = {
        type: "urltest",
        tag: urltest_tag,
        outbounds: urltest_outbounds,
        url: connections.urltest_testing_url(section, urltest_id),
        interval: urltest_check_interval(section, urltest_id),
        tolerance: int(connections.urltest_tolerance(section, urltest_id), 10),
        interrupt_exist_connections: connections.urltest_interrupt_exist_connections(section, urltest_id)
    };
    let idle_timeout = urltest_idle_timeout(section, urltest_id);
    if (idle_timeout != "")
        urltest_outbound.idle_timeout = idle_timeout;

    runtime_subscription.remember_outbound_metadata(state, urltest_tag, display_name, urltest_outbound);
    runtime_subscription.remember_urltest_group_config(state, urltest_tag, {
        displayName: display_name,
        outbounds: urltest_outbounds,
        url: urltest_outbound.url,
        interval: urltest_outbound.interval,
        tolerance: urltest_outbound.tolerance,
        idle_timeout: urltest_outbound.idle_timeout,
        interrupt_exist_connections: urltest_outbound.interrupt_exist_connections
    });

    if (length(urltest_outbounds) == 0)
        return {
            tag: "",
            outbounds: []
        };

    push(config.outbounds, urltest_outbound);
    return {
        tag: urltest_tag,
        outbounds: urltest_outbounds
    };
}

function add_priority_group_outbound(config, section, group_id, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let levels = priority_levels_with_outbounds(group_id, urltest_candidate_tags, state);
    let outbounds = priority_group_outbounds(levels);
    let priority_tag = priority_outbound_tag(section_name, group_id);
    let display_name = connections.priority_group_display_name(section, group_id);
    let outbound = {
        type: "selector",
        tag: priority_tag,
        outbounds,
        default: outbounds[0],
        interrupt_exist_connections: connections.priority_group_interrupt_exist_connections(section, group_id)
    };

    runtime_subscription.remember_outbound_metadata(state, priority_tag, display_name, outbound);
    runtime_subscription.remember_priority_group(state, priority_tag, {
        id: group_id,
        tag: priority_tag,
        section: section_name,
        displayName: display_name,
        health_url: connections.priority_group_health_url(section, group_id),
        active_check_interval: connections.priority_group_active_check_interval(section, group_id),
        check_timeout: connections.priority_group_check_timeout(section, group_id),
        recovery_check_interval: connections.priority_group_recovery_check_interval(section, group_id),
        pick_fastest: connections.priority_group_pick_fastest(section, group_id),
        switch_to_faster_same_priority: connections.priority_group_switch_to_faster_same_priority(section, group_id),
        fastest_check_interval: connections.priority_group_fastest_check_interval(section, group_id),
        interrupt_exist_connections: connections.priority_group_interrupt_exist_connections(section, group_id),
        pin_dashboard: connections.priority_group_pin_dashboard(section, group_id),
        hide_added_outbounds: connections.priority_group_hide_added_outbounds(section, group_id),
        outbounds,
        levels
    });

    if (length(outbounds) == 0)
        return {
            tag: "",
            outbounds: []
        };

    push(config.outbounds, outbound);
    return {
        tag: priority_tag,
        outbounds
    };
}

function add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let selector_tag = outbound_tag(section_name);
    let selector_outbounds = selector_tags;
    let selector_default = selector_tags[0];
    let urltest_tags = [];
    let priority_tags = [];
    let hidden_selector_tags = {};

    for (let urltest_id in connections.urltests(section)) {
        let urltest = add_urltest_outbound(config, section, urltest_id, urltest_candidate_tags, state);
        if (urltest.tag == "")
            continue;

        push(urltest_tags, urltest.tag);

        if (connections.urltest_hide_added_outbounds(section, urltest_id)) {
            for (let tag in array_or_empty(urltest.outbounds))
                hidden_selector_tags[tag] = true;
        }
    }

    for (let group_id in connections.priority_groups(section)) {
        let priority = add_priority_group_outbound(config, section, group_id, urltest_candidate_tags, state);
        if (priority.tag == "")
            continue;

        push(priority_tags, priority.tag);

        if (connections.priority_group_hide_added_outbounds(section, group_id)) {
            for (let tag in array_or_empty(priority.outbounds))
                hidden_selector_tags[tag] = true;
        }
    }

    if (length(urltest_tags) > 0 || length(priority_tags) > 0) {
        selector_outbounds = [];
        for (let tag in selector_tags) {
            if (!hidden_selector_tags[tag])
                push(selector_outbounds, tag);
        }
        for (let tag in urltest_tags)
            push(selector_outbounds, tag);
        for (let tag in priority_tags)
            push(selector_outbounds, tag);
        selector_default = length(urltest_tags) > 0 ? urltest_tags[0] : priority_tags[0];
    }

    push(config.outbounds, {
        type: "selector",
        tag: selector_tag,
        outbounds: selector_outbounds,
        default: selector_default,
        interrupt_exist_connections: true
    });
}

function outbound_detour_tag_for_section(section) {
    if (!bool_option(section, "outbound_detour_enabled", false))
        return "";

    let detour_section = option(section, "outbound_detour_section", "");
    return detour_section == "" ? "" : outbound_tag(detour_section);
}

function apply_section_detour_to_connection_outbounds(config, start_index, detour_tag) {
    if (detour_tag == "")
        return;

    let outbounds = array_or_empty(config.outbounds);
    for (let i = int(start_index || 0); i < length(outbounds); i++) {
        let outbound = outbounds[i];
        if (type(outbound) != "object")
            continue;

        let outbound_type = lc(as_string(outbound.type || ""));
        if (outbound_type == "" ||
            outbound_type == "selector" ||
            outbound_type == "urltest" || outbound_type == "dns" ||
            outbound_type == "block")
            continue;

        // Preserve subscription chains: only their terminal dial outbound receives the section detour.
        if (as_string(outbound.detour || "") == "")
            outbound.detour = detour_tag;
    }
}

function mixed_proxy_enabled_action(action) {
    return action == "connection" || action == "proxy" || action == "outbound" || action == "vpn" ||
        action == "byedpi" || action == "zapret" || action == "zapret2";
}

function add_mixed_proxy_for_section(config, section, service_address) {
    if (!bool_option(section, "mixed_proxy_enabled", false))
        return;

    let action = option(section, "action", "");
    if (!mixed_proxy_enabled_action(action))
        runtime_generate_unsupported("mixed proxy inbound is not supported for action " + action);

    let listen_port_value = option(section, "mixed_proxy_port", "");
    if (match(listen_port_value, /^[0-9]+$/) == null)
        runtime_generate_unsupported("mixed proxy port is invalid");
    let listen_port = int(listen_port_value, 10);
    if (listen_port < 1 || listen_port > 65535)
        runtime_generate_unsupported("mixed proxy port is invalid");

    let listen = as_string(service_address || "");
    if (listen == "")
        runtime_generate_unsupported("mixed proxy listen address is not set");

    let inbound = {
        type: "mixed",
        tag: runtime_constants.inbound_tag(section[".name"] + "-mixed"),
        listen,
        listen_port
    };

    if (bool_option(section, "mixed_proxy_auth_enabled", false)) {
        let username = option(section, "mixed_proxy_username", "");
        let password = option(section, "mixed_proxy_password", "");
        if (username == "" || password == "")
            runtime_generate_unsupported("mixed proxy authentication is enabled but username or password is empty");
        inbound.users = [{ username, password }];
    }
    push(config.inbounds, inbound);
    push(config.route.rules, {
        action: "route",
        inbound: inbound.tag,
        outbound: runtime_constants.outbound_tag(section[".name"])
    });
}

function add_service_mixed_proxy_inbound(config, tag_name, listen_port, outbound) {
    push(config.inbounds, {
        type: "mixed",
        tag: tag_name,
        listen: runtime_constants.SERVICE_MIXED_INBOUND_ADDRESS,
        listen_port
    });
    push(config.route.rules, {
        action: "route",
        inbound: tag_name,
        outbound
    });
}

function service_mixed_proxy_inbound_tag_for_purpose(purpose) {
    return as_string(purpose || "lists") == "components"
        ? runtime_constants.inbound_tag("service-components")
        : runtime_constants.SERVICE_MIXED_INBOUND_TAG;
}

function service_mixed_proxy_port_for_purpose(purpose) {
    return runtime_constants.SERVICE_MIXED_INBOUND_PORT +
        (as_string(purpose || "lists") == "components" ? 1 : 0);
}

function add_global_download_service_mixed_proxy(config, settings, purpose) {
    let outbound = download_detour_tag(settings, purpose);
    if (outbound == "")
        return;

    add_service_mixed_proxy_inbound(
        config,
        service_mixed_proxy_inbound_tag_for_purpose(purpose),
        service_mixed_proxy_port_for_purpose(purpose),
        outbound
    );
}

function add_subscription_download_service_mixed_proxies(config, sections) {
    for (let target in connections.subscription_download_targets(sections)) {
        let port = connections.subscription_download_target_port(sections, target, runtime_constants.SERVICE_MIXED_INBOUND_PORT);
        if (port <= 0)
            runtime_generate_unsupported("subscription download proxy port could not be resolved");

        add_service_mixed_proxy_inbound(
            config,
            runtime_constants.inbound_tag("service-subscription-" + target),
            port,
            outbound_tag(target)
        );
    }
}

function add_service_mixed_proxy(config, settings, sections) {
    if (!download_via_proxy_any_enabled(settings, sections))
        return;

    add_global_download_service_mixed_proxy(config, settings, "lists");
    add_global_download_service_mixed_proxy(config, settings, "components");
    add_subscription_download_service_mixed_proxies(config, sections);

    if (download_via_proxy_enabled(settings, "lists") && download_detour_tag(settings, "lists") == "")
        runtime_generate_unsupported("download lists via proxy section is not set");
    if (download_via_proxy_enabled(settings, "components") && download_detour_tag(settings, "components") == "")
        runtime_generate_unsupported("download components via proxy section is not set");
}

function parse_port(value) {
    value = as_string(value);
    if (match(value, /^[0-9]+$/) == null)
        return null;
    let port = int(value, 10);
    return port >= 1 && port <= 65535 ? port : null;
}

function bool_query(value) {
    return value == "1" || value == "true";
}

function base64_decode_value(value) {
    value = replace(as_string(value), /[\r\n\t ]/g, "");
    value = replace(replace(value, /-/g, "+"), /_/g, "/");
    while (length(value) % 4 != 0)
        value += "=";
    try {
        return b64dec(value);
    }
    catch (e) {
        return null;
    }
}

function shadowsocks_userinfo_valid(value) {
    value = as_string(value);
    let first = index(value, ":");
    if (first <= 0 || first >= length(value) - 1)
        return false;
    let rest = substr(value, first + 1);
    let second = index(rest, ":");
    return second < 0 || index(substr(rest, second + 1), ":") < 0;
}

function split_host_port(value) {
    value = as_string(value);
    if (substr(value, 0, 1) == "[") {
        let close = index(value, "]");
        if (close > 0 && substr(value, close + 1, 1) == ":")
            return [ substr(value, 1, close - 1), substr(value, close + 2) ];
    }

    let colon = rindex(value, ":");
    if (colon < 0)
        return [ "", "" ];
    return [ substr(value, 0, colon), substr(value, colon + 1) ];
}

function tls_alpn_array(value, transport) {
    value = as_string(value);
    transport = lc(as_string(transport));
    if (value == "" && transport == "xhttp")
        return [ "h2", "http/1.1" ];
    if (value != "" && (transport == "ws" || transport == "httpupgrade"))
        return [ "http/1.1" ];
    return value == "" ? [] : split(value, ",");
}

function apply_link_tls(outbound, scheme, query) {
    query = object_or_empty(query);
    let security = as_string(query.security || "");
    if (security == "" && (scheme == "hysteria2" || scheme == "hy2"))
        security = "tls";

    if (security == "" || security == "none")
        return;
    if (security != "tls" && security != "reality") {
        warn("unknown manual proxy link security '", security, "' ignored\n");
        return;
    }

    let tls = { enabled: true };
    if (as_string(query.sni || "") != "")
        tls.server_name = as_string(query.sni);
    if (bool_query(query.allowInsecure || query.insecure || ""))
        tls.insecure = true;

    let alpn = tls_alpn_array(query.alpn, query.type);
    if (length(alpn) > 0)
        tls.alpn = alpn;

    if (scheme != "hysteria2" && scheme != "hy2" && as_string(query.fp || "") != "") {
        tls.utls = {
            enabled: true,
            fingerprint: as_string(query.fp)
        };
    }
    if (security == "reality") {
        tls.reality = {
            enabled: true,
            public_key: as_string(query.pbk || ""),
            short_id: as_string(query.sid || "")
        };
    }
    outbound.tls = tls;
}

function csv_array(value) {
    value = as_string(value);
    if (value == "")
        return [];
    let result = [];
    for (let item in split(value, ",")) {
        item = trim(as_string(item));
        if (item != "")
            push(result, item);
    }
    return result;
}

function optional_query_string(object, key, value) {
    value = as_string(value);
    if (value != "")
        object[key] = value;
}

function optional_query_number(object, key, value) {
    value = as_string(value);
    if (value != "" && match(value, /^[0-9]+$/) != null)
        object[key] = int(value, 10);
}

function apply_link_transport(outbound, query) {
    let transport = lc(as_string(object_or_empty(query).type || ""));
    if (transport == "" || transport == "tcp" || transport == "raw")
        return;

    if (transport == "h2")
        transport = "http";

    let result = { type: transport };
    if (transport == "http") {
        optional_query_string(result, "path", query.path);
        let hosts = csv_array(query.host);
        if (length(hosts) > 0)
            result.host = hosts;
    }
    else if (transport == "ws") {
        result.path = as_string(query.path || "");
        if (as_string(query.host || "") != "")
            result.headers = { Host: as_string(query.host) };
        optional_query_number(result, "max_early_data", query.ed);
    }
    else if (transport == "grpc") {
        optional_query_string(result, "service_name", query.serviceName);
    }
    else if (transport == "httpupgrade") {
        optional_query_string(result, "path", query.path);
        optional_query_string(result, "host", query.host);
    }
    else if (transport == "xhttp") {
        let mode = as_string(query.mode || "auto");
        if (mode != "auto" && mode != "packet-up" && mode != "stream-up" && mode != "stream-one")
            mode = "auto";
        result.mode = mode;
        result.path = as_string(query.path || "") != "" ? as_string(query.path) : "/";
        result.x_padding_bytes = "100-1000";
        result.no_grpc_header = false;
        result.sc_max_each_post_bytes = 1000000;
        result.sc_min_posts_interval_ms = 30;
        optional_query_string(result, "host", as_string(query.host || "") != "" ? query.host : query.sni);
    }
    else {
        warn("unknown manual proxy link transport '", transport, "' ignored\n");
        return;
    }

    outbound.transport = result;
}

function manual_http_outbound(link, tag_name) {
    let scheme = url_scheme(link);
    let host = url_host(link);
    let port = parse_port(url_port(link));
    let path = url_path(link);
    if (host == "" || port == null || (path != "" && path != "/") || index(link, "?") >= 0)
        runtime_generate_unsupported("manual HTTP proxy link is invalid");

    let outbound = {
        type: "http",
        tag: tag_name,
        server: host,
        server_port: port
    };
    let userinfo = url_userinfo(link);
    if (userinfo != "") {
        let colon = index(userinfo, ":");
        outbound.username = colon >= 0 ? substr(userinfo, 0, colon) : userinfo;
        if (colon >= 0)
            outbound.password = substr(userinfo, colon + 1);
    }
    if (scheme == "https")
        outbound.tls = { enabled: true };
    return outbound;
}

function manual_socks_outbound(link, tag_name) {
    let scheme = url_scheme(link);
    let host = url_host(link);
    let port = parse_port(url_port(link));
    if (host == "" || port == null)
        runtime_generate_unsupported("manual SOCKS proxy link is invalid");

    let outbound = {
        type: "socks",
        tag: tag_name,
        server: host,
        server_port: port,
        version: scheme == "socks4" || scheme == "socks4a" ? "4" : "5"
    };
    if (scheme == "socks5") {
        let userinfo = url_userinfo(link);
        if (userinfo != "") {
            let colon = index(userinfo, ":");
            outbound.username = colon >= 0 ? substr(userinfo, 0, colon) : userinfo;
            if (colon >= 0)
                outbound.password = substr(userinfo, colon + 1);
        }
    }
    return outbound;
}

function manual_shadowsocks_outbound(link, tag_name) {
    let raw = url_strip_fragment_value(url_decode(link));
    let body = substr(raw, 5);
    let question = index(body, "?");
    let query_string = "";
    if (question >= 0) {
        query_string = substr(body, question + 1);
        body = substr(body, 0, question);
    }

    let at = rindex(body, "@");
    let userinfo = "";
    let hostport = "";
    if (at >= 0) {
        userinfo = substr(body, 0, at);
        hostport = substr(body, at + 1);
    }
    else {
        let decoded = base64_decode_value(body);
        if (decoded == null)
            runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");
        at = rindex(decoded, "@");
        if (at < 0)
            runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");
        userinfo = substr(decoded, 0, at);
        hostport = substr(decoded, at + 1);
    }

    userinfo = url_decode(userinfo);
    if (!shadowsocks_userinfo_valid(userinfo)) {
        let decoded = base64_decode_value(userinfo);
        if (decoded == null)
            runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");
        userinfo = decoded;
    }

    let cred_colon = index(userinfo, ":");
    let host_port = split_host_port(hostport);
    let port = parse_port(host_port[1]);
    if (cred_colon <= 0 || host_port[0] == "" || port == null)
        runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");

    let outbound = {
        type: "shadowsocks",
        tag: tag_name,
        server: host_port[0],
        server_port: port,
        method: substr(userinfo, 0, cred_colon),
        password: substr(userinfo, cred_colon + 1)
    };
    let query = url_query_params("ss://placeholder/?" + query_string);
    if (as_string(query.plugin || "") != "")
        outbound.plugin = as_string(query.plugin);
    if (as_string(query["plugin-opts"] || "") != "")
        outbound.plugin_opts = as_string(query["plugin-opts"]);
    return outbound;
}

function manual_vless_outbound(link, tag_name) {
    let query = url_query_params(link);

    let host = url_host(link);
    let port = parse_port(url_port(link));
    let uuid = url_userinfo(link);
    if (host == "" || port == null || uuid == "")
        runtime_generate_unsupported("manual VLESS proxy link is invalid");

    let outbound = {
        type: "vless",
        tag: tag_name,
        server: host,
        server_port: port,
        uuid
    };
    let flow = as_string(query.flow || "");
    if (flow != "")
        outbound.flow = flow;
    let encryption = as_string(query.encryption || "");
    if (encryption != "" && encryption != "none")
        outbound.encryption = encryption;
    let packet_encoding = as_string(query.packetEncoding || "");
    if (packet_encoding == "xudp" || packet_encoding == "packetaddr")
        outbound.packet_encoding = packet_encoding;
    apply_link_tls(outbound, "vless", query);
    apply_link_transport(outbound, query);
    return outbound;
}

function vmess_json_value(value) {
    return value == null ? "" : as_string(value);
}

function manual_vmess_outbound(link, tag_name) {
    let encoded = substr(url_strip_fragment_value(link), 8);
    let decoded = base64_decode_value(encoded);
    if (decoded == null)
        runtime_generate_unsupported("manual VMess proxy link is invalid");

    if (index(decoded, "\r") >= 0 || index(decoded, "\n") >= 0)
        decoded = replace(decoded, /[\r\n]/g, "");
    decoded = trim(decoded);

    let vmess;
    try {
        vmess = json(decoded);
    }
    catch (e) {
        runtime_generate_unsupported("manual VMess proxy link is invalid");
    }
    if (type(vmess) != "object")
        runtime_generate_unsupported("manual VMess proxy link is invalid");

    let host = vmess_json_value(vmess.add);
    let port = parse_port(vmess_json_value(vmess.port));
    let uuid = vmess_json_value(vmess.id);
    if (host == "" || port == null || uuid == "")
        runtime_generate_unsupported("manual VMess proxy link is invalid");

    let outbound = {
        type: "vmess",
        tag: tag_name,
        server: host,
        server_port: port,
        uuid,
        security: vmess_json_value(vmess.scy) != "" ? vmess_json_value(vmess.scy) : "auto"
    };

    if (vmess_json_value(vmess.aid) != "")
        outbound.alter_id = int(vmess.aid || 0);

    let network = lc(vmess_json_value(vmess.net));
    if (vmess.tls === true || vmess.tls == "tls" || vmess.tls == "true") {
        let tls = { enabled: true };
        optional_query_string(tls, "server_name", vmess_json_value(vmess.sni));
        let alpn = tls_alpn_array(vmess_json_value(vmess.alpn), network);
        if (length(alpn) > 0)
            tls.alpn = alpn;
        if (vmess_json_value(vmess.fp) != "") {
            tls.utls = {
                enabled: true,
                fingerprint: vmess_json_value(vmess.fp)
            };
        }
        outbound.tls = tls;
    }

    if (network == "ws") {
        outbound.transport = {
            type: "ws",
            path: vmess_json_value(vmess.path) != "" ? vmess_json_value(vmess.path) : "/"
        };
        if (vmess_json_value(vmess.host) != "")
            outbound.transport.headers = { Host: vmess_json_value(vmess.host) };
    }
    else if (network == "grpc") {
        outbound.transport = { type: "grpc" };
        optional_query_string(outbound.transport, "service_name", vmess_json_value(vmess.path));
    }
    else if (network == "http" || network == "h2") {
        outbound.transport = { type: "http" };
        optional_query_string(outbound.transport, "path", vmess_json_value(vmess.path));
        let hosts = csv_array(vmess_json_value(vmess.host));
        if (length(hosts) > 0)
            outbound.transport.host = hosts;
    }

    return outbound;
}

function manual_trojan_outbound(link, tag_name) {
    let query = url_query_params(link);

    let host = url_host(link);
    let port = parse_port(url_port(link));
    let password = url_userinfo(link);
    if (host == "" || port == null || password == "")
        runtime_generate_unsupported("manual Trojan proxy link is invalid");

    let outbound = {
        type: "trojan",
        tag: tag_name,
        server: host,
        server_port: port,
        password
    };
    apply_link_tls(outbound, "trojan", query);
    apply_link_transport(outbound, query);
    return outbound;
}

function manual_hysteria2_outbound(link, tag_name) {
    let query = url_query_params(link);
    let host = url_host(link);
    let port = parse_port(as_string(query.mport || "") != "" ? query.mport : url_port(link));
    let password = url_userinfo(link);
    if (host == "" || port == null || password == "")
        runtime_generate_unsupported("manual Hysteria2 proxy link is invalid");

    let outbound = {
        type: "hysteria2",
        tag: tag_name,
        server: host,
        server_port: port,
        password
    };
    if (as_string(query.obfs || "") != "")
        outbound.obfs = { type: as_string(query.obfs), password: as_string(query["obfs-password"] || "") };
    if (as_string(query.upmbps || "") != "")
        outbound.up_mbps = int(query.upmbps, 10);
    if (as_string(query.downmbps || "") != "")
        outbound.down_mbps = int(query.downmbps, 10);
    apply_link_tls(outbound, url_scheme(link), query);
    return outbound;
}

function manual_link_outbound(link, tag_name) {
    let scheme = url_scheme(link);
    if (scheme == "vmess")
        return manual_vmess_outbound(link, tag_name);

    link = url_strip_fragment_value(url_decode(link));
    scheme = url_scheme(link);
    if (scheme == "http" || scheme == "https")
        return manual_http_outbound(link, tag_name);
    if (scheme == "socks4" || scheme == "socks4a" || scheme == "socks5")
        return manual_socks_outbound(link, tag_name);
    if (scheme == "ss")
        return manual_shadowsocks_outbound(link, tag_name);
    if (scheme == "vless")
        return manual_vless_outbound(link, tag_name);
    if (scheme == "trojan")
        return manual_trojan_outbound(link, tag_name);
    if (scheme == "hysteria2" || scheme == "hy2")
        return manual_hysteria2_outbound(link, tag_name);
    runtime_generate_unsupported("manual proxy link scheme is not supported by sing-box config generation yet");
}

function add_manual_proxy_link(config, state, section_name, manual_index, link, taken, selector_tags, urltest_candidate_tags) {
    let tag_name = outbound_tag(section_name + "-" + manual_index);
    if (taken[tag_name])
        tag_name = unique_tag(tag_name, taken);
    taken[tag_name] = true;

    let outbound = manual_link_outbound(link, tag_name);
    push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    push(urltest_candidate_tags, tag_name);

    let display_name = url_fragment(link);
    if (display_name == "")
        display_name = tag_name;
    state.links[tag_name] = as_string(link);
    state.outboundMetadata.names[tag_name] = display_name;
    if (as_string(outbound.server || "") != "")
        state.servers[tag_name] = as_string(outbound.server);
    return tag_name;
}

function connection_item_tag(section_name, kind, item_index) {
    return outbound_tag(section_name + "-" + as_string(kind) + "-" + item_index);
}

function add_connection_manual_links(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let section_name = section[".name"];
    let manual_links = connections.connection_urls(section);
    for (let i = 0; i < length(manual_links); i++) {
        let link = manual_links[i];
        add_manual_proxy_link(
            config,
            state,
            section_name,
            i + 1,
            link,
            taken,
            selector_tags,
            urltest_candidate_tags
        );
    }
}

function add_connection_subscriptions(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let subscription_urls = connections.subscription_urls(section);

    for (let i = 0; i < length(subscription_urls); i++)
        add_subscription_source_with_state(
            config,
            section,
            i + 1,
            subscription_urls[i],
            taken,
            selector_tags,
            urltest_candidate_tags,
            state,
            connections.subscription_dashboard_metadata_enabled(section, subscription_urls[i]),
            connections.subscription_include_urltest_groups(section, subscription_urls[i]),
            connections.subscription_hide_urltest_group_outbounds(section, subscription_urls[i]),
            connections.subscription_hide_detour_outbounds(section, subscription_urls[i]),
            connections.subscription_node_prefix(section, subscription_urls[i])
        );
}

function add_interface_connection_outbound(config, state, section, interface_index, interface_name, taken, selector_tags, urltest_candidate_tags) {
    let section_name = section[".name"];
    let tag_name = connection_item_tag(section_name, "interface", interface_index);
    if (taken[tag_name])
        tag_name = unique_tag(tag_name, taken);
    taken[tag_name] = true;

    let outbound = {
        type: "direct",
        tag: tag_name,
        bind_interface: interface_name,
        routing_mark: runtime_constants.OUTBOUND_MARK
    };

    push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    push(urltest_candidate_tags, tag_name);
    runtime_subscription.remember_outbound_metadata(state, tag_name, interface_name, outbound);
}

function add_connection_interfaces(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let items = connections.interfaces(section);
    for (let i = 0; i < length(items); i++)
        add_interface_connection_outbound(config, state, section, i + 1, items[i], taken, selector_tags, urltest_candidate_tags);
}

function parse_outbound_json(value) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        return null;
    }

    return type(value) == "object" ? value : null;
}

function rewrite_json_outbound_references(outbounds, tag_map) {
    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        for (let key in [ "detour", "default" ]) {
            let reference = as_string(outbound[key] || "");
            if (reference != "" && tag_map[reference])
                outbound[key] = tag_map[reference];
        }

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag_name in outbound.outbounds) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    push(rewritten, as_string(tag_map[tag_name] || tag_name));
            }
            outbound.outbounds = rewritten;
        }
    }
}

function prepare_json_connection_outbounds(section, taken) {
    let items = connections.outbound_jsons(section);
    let prepared = [];
    let outbounds = [];
    let tag_map = {};
    let legacy_tags = [];

    for (let i = 0; i < length(items); i++) {
        let outbound = parse_outbound_json(items[i]);
        if (outbound == null)
            runtime_generate_unsupported("JSON outbound is invalid");

        let display_name = trim(as_string(outbound.tag || ""));
        let legacy_tag = connection_item_tag(section[".name"], "json", i + 1);
        let base = display_name != "" ? display_name : legacy_tag;
        let tag_name = unique_tag(base, taken);
        taken[tag_name] = true;
        if (display_name != "" && !tag_map[display_name])
            tag_map[display_name] = tag_name;
        push(legacy_tags, [ legacy_tag, tag_name ]);

        outbound.tag = tag_name;
        push(outbounds, outbound);
        push(prepared, {
            outbound,
            displayName: display_name != "" ? display_name : "JSON outbound " + (i + 1)
        });
    }

    for (let entry in legacy_tags)
        if (!tag_map[entry[0]])
            tag_map[entry[0]] = entry[1];

    rewrite_json_outbound_references(outbounds, tag_map);
    return prepared;
}

function add_connection_json_outbounds(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    for (let item in prepare_json_connection_outbounds(section, taken)) {
        let outbound = item.outbound;
        let tag_name = outbound.tag;
        push(config.outbounds, outbound);
        push(selector_tags, tag_name);
        if (urltest_leaf_candidate_outbound(outbound))
            push(urltest_candidate_tags, tag_name);
        runtime_subscription.remember_outbound_metadata(state, tag_name, item.displayName, outbound);
        runtime_subscription.remember_urltest_group(state, tag_name, item.displayName, outbound);
    }
}

function add_connections_outbound(config, section, taken) {
    let section_name = section[".name"];
    let selector_tags = [];
    let urltest_candidate_tags = [];
    let state = runtime_subscription.new_section_state(section_name);
    let cascade_start = length(array_or_empty(config.outbounds));

    add_connection_manual_links(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_connection_subscriptions(config, state, section, taken, selector_tags, urltest_candidate_tags);
    // Apply before interface and JSON items are added: those source kinds are intentionally excluded.
    apply_section_detour_to_connection_outbounds(
        config,
        cascade_start,
        outbound_detour_tag_for_section(section)
    );
    add_connection_interfaces(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_connection_json_outbounds(config, state, section, taken, selector_tags, urltest_candidate_tags);

    if (length(selector_tags) == 0)
        runtime_generate_unsupported("connection section has no usable outbounds");

    if (section_needs_country_is(section)) {
        let previous_state = read_json_file(runtime_subscription.section_cache_path(section_name));
        state.outboundMetadata.countries = runtime_country.detect(
            state.servers,
            previous_state,
            option(runtime_settings(), "bootstrap_dns_server", "77.88.8.8")
        );
    }
    if (section_has_direct_priority_level(section))
        state.outboundMetadata.names[runtime_constants.DIRECT_OUTBOUND_TAG] = "Direct";

    state.urltestCandidateTags = unique_string_array(urltest_candidate_tags);
    add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state);
    if (!atomic_write_json_file(runtime_subscription.section_cache_path(section_name), state))
        runtime_generate_unsupported("failed to write section cache for " + section_name);
}

function add_proxy_outbound(config, section, taken) {
    add_connections_outbound(config, section, taken);
}

function add_json_outbound(config, section) {
    let outbound_json = option(section, "outbound_json", "");
    if (outbound_json == "")
        runtime_generate_unsupported("JSON outbound is not set");

    let outbound;
    try {
        outbound = json(outbound_json);
    }
    catch (e) {
        runtime_generate_unsupported("JSON outbound is invalid");
    }

    if (type(outbound) != "object")
        runtime_generate_unsupported("JSON outbound is not an object");

    outbound.tag = outbound_tag(section[".name"]);
    push(config.outbounds, outbound);
}

function add_vpn_outbound(config, section) {
    let interface_name = option(section, "interface", "");
    if (interface_name == "")
        runtime_generate_unsupported("VPN interface is not set");

    push(config.outbounds, {
        type: "direct",
        tag: outbound_tag(section[".name"]),
        bind_interface: interface_name,
        routing_mark: runtime_constants.OUTBOUND_MARK
    });
}

function enabled_action_index(sections, target_section, action_name) {
    let index = 0;
    for (let section in sections) {
        if (option(section, "action", "") != action_name)
            continue;
        index++;
        if (section[".name"] == target_section[".name"])
            return index;
    }
    return 0;
}

function add_zapret_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "zapret");
    if (index <= 0)
        runtime_generate_unsupported("unable to resolve Zapret index for " + section[".name"]);
    push(config.outbounds, {
        type: "direct",
        tag: outbound_tag(section[".name"]),
        routing_mark: runtime_constants.ZAPRET_ROUTE_MARK_BASE + index
    });
}

function add_zapret2_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "zapret2");
    if (index <= 0)
        runtime_generate_unsupported("unable to resolve Zapret2 index for " + section[".name"]);
    push(config.outbounds, {
        type: "direct",
        tag: outbound_tag(section[".name"]),
        routing_mark: runtime_constants.ZAPRET2_ROUTE_MARK_BASE + index
    });
}

function add_byedpi_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "byedpi");
    if (index <= 0)
        runtime_generate_unsupported("unable to resolve ByeDPI index for " + section[".name"]);
    push(config.outbounds, {
        type: "socks",
        tag: outbound_tag(section[".name"]),
        server: runtime_constants.BYEDPI_LISTEN_ADDRESS,
        server_port: runtime_constants.BYEDPI_PORT_BASE + index - 1,
        version: "5"
    });
}

function ensure_community_ruleset(config, section_name, community) {
    if (!runtime_rulesets.is_community(community))
        runtime_generate_unsupported("unknown community list " + community);

    let tag_name = ruleset_tag(section_name, community, "community");
    if (!ruleset_registered(config, tag_name)) {
        push(config.route.rule_set, {
            type: "remote",
            tag: tag_name,
            format: "binary",
            url: runtime_rulesets.community_url(community),
            update_interval: remote_ruleset_update_interval()
        });
    }
    return {
        tag: tag_name,
        kind: "domains"
    };
}

function domain_ip_list_ruleset_tag(section_name) {
    return ruleset_tag(section_name, "lists", "");
}

function domain_ip_list_ruleset_path(section_name) {
    return runtime_ruleset_folder + "/" + domain_ip_list_ruleset_tag(section_name) + ".json";
}

function reference_is_remote(reference) {
    reference = as_string(reference);
    return substr(reference, 0, 7) == "http://" || substr(reference, 0, 8) == "https://";
}

function reference_is_local(reference) {
    return substr(as_string(reference), 0, 1) == "/";
}

function source_file_exists(path) {
    return fs.readfile(path) != null;
}

function rebuild_local_domain_ip_list_ruleset(section_name, references) {
    let ruleset_path = domain_ip_list_ruleset_path(section_name);
    let has_local = false;

    for (let reference in references) {
        if (reference_is_local(reference)) {
            has_local = true;
            break;
        }
    }

    if (!has_local)
        return;

    fs.unlink(ruleset_path);
    source_rulesets.create_source(ruleset_path);

    for (let reference in references) {
        reference = as_string(reference);
        if (!reference_is_local(reference))
            continue;
        if (!source_file_exists(reference)) {
            warn("local domain/IP list not found: ", reference, "\n");
            continue;
        }

        source_rulesets.import_plain_list(reference, ruleset_path, "domain_suffix", "domains", "5000");
        source_rulesets.import_plain_list(reference, ruleset_path, "ip_cidr", "subnets", "5000");
    }
}

function add_domain_ip_list_ruleset(config, section_name, rule_set_tags, dns_rule_set_tags, references) {
    if (length(references) == 0)
        return;

    rebuild_local_domain_ip_list_ruleset(section_name, references);

    let ruleset_path = domain_ip_list_ruleset_path(section_name);
    if (!source_rulesets.has_rules(ruleset_path))
        return;

    let tag_name = domain_ip_list_ruleset_tag(section_name);
    if (!ruleset_registered(config, tag_name)) {
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: "source",
            path: ruleset_path
        });
    }

    push(rule_set_tags, tag_name);
    if (source_rulesets.has_domain_matchers(ruleset_path))
        push(dns_rule_set_tags, tag_name);
}

function split_condition_text(value) {
    value = replace(as_string(value), /[\t\r\n,]+/g, " ");
    value = replace(value, / +/g, " ");
    value = trim(value);
    return value == "" ? [] : split(value, " ");
}

function legacy_condition_values(section, key) {
    let raw_values = object_or_empty(section)[key];
    let list_values = type(raw_values) == "array"
        ? raw_values
        : [];
    let option_text_values = type(raw_values) == "array"
        ? []
        : split_condition_text(raw_values);
    let text_values = split_condition_text(option(section, key + "_text", ""));

    if (bool_option(section, key + "_text_mode", false) || bool_option(section, "conditions_text_mode", false))
        return text_values;
    if (length(list_values) > 0)
        return list_values;
    if (length(option_text_values) > 0)
        return option_text_values;
    return text_values;
}

function combined_domain_source_values(section) {
    let values = [];
    if (type(object_or_empty(section)["domain"]) != "array") {
        for (let value in split_condition_text(option(section, "domain", "")))
            if (as_string(value) != "")
                push(values, as_string(value));
    }
    for (let value in split_condition_text(option(section, "domain_suffix_text", "")))
        if (as_string(value) != "")
            push(values, as_string(value));
    for (let value in list_option(section, "domain_suffix"))
        if (as_string(value) != "")
            push(values, as_string(value));
    return values;
}

function domain_suffix_condition_value_kind(value) {
    return rule_config.prefixed_domain_kind_value(value);
}

function domain_condition_values(section, key) {
    let result = [];

    if (key == "domain_suffix") {
        for (let value in combined_domain_source_values(section)) {
            let normalized = domain_suffix_condition_value_kind(value);
            if (normalized != null && normalized.kind == "domain_suffix")
                push(result, normalized.value);
        }
        return result;
    }

    for (let value in legacy_condition_values(section, key)) {
        let normalized = rule_config.domain_value_for_key(value, key);
        if (normalized != null)
            push(result, normalized);
    }

    for (let value in combined_domain_source_values(section)) {
        let normalized = domain_suffix_condition_value_kind(value);
        if (normalized != null && normalized.kind == key)
            push(result, normalized.value);
    }

    return result;
}

function add_domain_array(rule, key, values) {
    if (length(values) > 0)
        rule[key] = values;
}

function push_dns_matcher_rule(config, rule) {
    push(config.dns.rules, rule);
}

function section_dns_server(section) {
    return option(section, "action", "") == "bypass"
        ? runtime_constants.DNS_SERVER_TAG
        : runtime_constants.FAKEIP_DNS_SERVER_TAG;
}

function single_or_array(values) {
    return length(values) == 1 ? values[0] : values;
}

function normalize_port_number_value(value) {
    return rule_config.normalize_port_number_value(value);
}

function add_port_matchers(rule, section) {
    let values = [];
    for (let value in list_option(section, "ports"))
        push(values, value);
    for (let value in split_condition_text(option(section, "ports_text", "")))
        push(values, value);

    let ports = [];
    let port_ranges = [];
    let seen = {};
    for (let value in values) {
        value = trim(as_string(value));
        if (value == "" || seen[value])
            continue;
        seen[value] = true;

        let dash = index(value, "-");
        if (dash < 0) {
            let port = normalize_port_number_value(value);
            if (port != null)
                push(ports, port);
            continue;
        }

        let start = normalize_port_number_value(substr(value, 0, dash));
        let end = normalize_port_number_value(substr(value, dash + 1));
        if (start != null && end != null && start <= end)
            push(port_ranges, start == end ? as_string(start) : sprintf("%d:%d", start, end));
    }

    if (length(ports) > 0)
        rule.port = ports;
    if (length(port_ranges) > 0)
        rule.port_range = port_ranges;
}

function add_fully_routed_ips_rule(config, section) {
    let source_ip_cidr = list_option(section, "fully_routed_ips");
    if (length(source_ip_cidr) == 0)
        return;

    let target = runtime_route.target(section, outbound_tag(section[".name"]));
    if (target.unsupported)
        runtime_generate_unsupported(target.unsupported);

    let route_rule = {
        action: target.action,
        inbound: tproxy_inbound_matcher()
    };
    if (target.outbound)
        route_rule.outbound = target.outbound;
    route_rule.source_ip_cidr = single_or_array(source_ip_cidr);
    push(config.route.rules, route_rule);
}

function add_combined_route_for_section(config, section) {
    let domain = domain_condition_values(section, "domain");
    let domain_suffix = domain_condition_values(section, "domain_suffix");
    let domain_keyword = domain_condition_values(section, "domain_keyword");
    let domain_regex = domain_condition_values(section, "domain_regex");
    let ip_cidr = legacy_condition_values(section, "ip_cidr");
    let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr");
    let rule_set_tags = [];
    let dns_rule_set_tags = [];
    let section_name = section[".name"];

    add_fully_routed_ips_rule(config, section);

    for (let community in connections.community_lists(section)) {
        let ensured = ensure_community_ruleset(config, section_name, as_string(community));
        push(rule_set_tags, ensured.tag);
        push(dns_rule_set_tags, ensured.tag);
    }
    for (let reference in connections.rule_sets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        push(rule_set_tags, ensured.tag);
        if (ensured.kind == "domains")
            push(dns_rule_set_tags, ensured.tag);
    }
    for (let reference in connections.rule_sets_with_subnets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        push(rule_set_tags, ensured.tag);
        if (ensured.kind == "domains")
            push(dns_rule_set_tags, ensured.tag);
    }
    add_domain_ip_list_ruleset(
        config,
        section_name,
        rule_set_tags,
        dns_rule_set_tags,
        list_option(section, "domain_ip_lists")
    );

    let target = runtime_route.target(section, outbound_tag(section_name));
    if (target.unsupported)
        runtime_generate_unsupported(target.unsupported);
    let route_rule = {
        action: target.action,
        inbound: tproxy_inbound_matcher()
    };
    if (target.outbound)
        route_rule.outbound = target.outbound;
    add_domain_array(route_rule, "domain", domain);
    add_domain_array(route_rule, "domain_suffix", domain_suffix);
    add_domain_array(route_rule, "domain_keyword", domain_keyword);
    add_domain_array(route_rule, "domain_regex", domain_regex);
    if (length(ip_cidr) > 0)
        route_rule.ip_cidr = ip_cidr;
    if (length(source_ip_cidr) > 0)
        route_rule.source_ip_cidr = source_ip_cidr;
    add_port_matchers(route_rule, section);
    if (length(rule_set_tags) > 0)
        route_rule.rule_set = single_or_array(rule_set_tags);

    let has_route_matchers = route_rule.domain != null || route_rule.domain_suffix != null ||
        route_rule.domain_keyword != null || route_rule.domain_regex != null ||
        route_rule.ip_cidr != null || route_rule.port != null || route_rule.port_range != null ||
        route_rule.rule_set != null;
    if (has_route_matchers) {
        let resolve = runtime_route.resolve_rule_for_section(section, route_rule);
        if (type(resolve) == "object" && resolve.warning)
            warn(resolve.warning, "\n");
        else if (type(resolve) == "object" && resolve.rule)
            push(config.route.rules, resolve.rule);
        push(config.route.rules, route_rule);
    }

    let rewrite_ttl = int_option(runtime_settings(), "dns_rewrite_ttl", "60");
    if (length(domain) > 0 || length(domain_suffix) > 0 || length(domain_keyword) > 0 || length(domain_regex) > 0) {
        let dns_rule = {
            action: "route",
            server: section_dns_server(section),
            rewrite_ttl
        };
        add_domain_array(dns_rule, "domain", domain);
        add_domain_array(dns_rule, "domain_suffix", domain_suffix);
        add_domain_array(dns_rule, "domain_keyword", domain_keyword);
        add_domain_array(dns_rule, "domain_regex", domain_regex);
        push_dns_matcher_rule(config, dns_rule);
    }
    if (length(dns_rule_set_tags) > 0) {
        push_dns_matcher_rule(config, {
            action: "route",
            server: section_dns_server(section),
            rewrite_ttl,
            rule_set: single_or_array(dns_rule_set_tags)
        });
    }
}

function unsupported_matcher_key(section) {
    let unsupported_options = [
        "subnet", "subnet_text",
        "local_domain_lists", "local_subnet_lists",
        "remote_domain_lists", "remote_subnet_lists"
    ];
    for (let key in unsupported_options) {
        if (length(list_option(section, key)) > 0 || option(section, key, "") != "")
            return key;
    }
    return "";
}

function add_outbound_for_section(config, section, taken, sections) {
    let action = option(section, "action", "");
    let section_name = section[".name"];
    if (!valid_section_name(section_name))
        runtime_generate_unsupported("section name is not safe for sing-box config generation");
    let unsupported_matcher = unsupported_matcher_key(section);
    if (unsupported_matcher != "")
        runtime_generate_unsupported("section has unsupported matcher " + unsupported_matcher);

    if (connections.is_connections_action(action))
        add_connections_outbound(config, section, taken);
    else if (action == "zapret")
        add_zapret_outbound(config, section, sections);
    else if (action == "zapret2")
        add_zapret2_outbound(config, section, sections);
    else if (action == "byedpi")
        add_byedpi_outbound(config, section, sections);
    else if (action == "bypass") {
        /* route-only action */
    }
    else if (action == "block") {
        /* route-only action */
    }
    else {
        runtime_generate_unsupported("unsupported action " + action);
    }
}

function reserve_section_outbound_tags(sections, taken) {
    for (let section in sections) {
        let action = option(section, "action", "");
        if (connections.is_connections_action(action) ||
            action == "byedpi" || action == "zapret" || action == "zapret2")
            taken[outbound_tag(section[".name"])] = true;

        if (!connections.is_connections_action(action))
            continue;

        for (let urltest_id in connections.urltests(section))
            taken[urltest_outbound_tag(section[".name"], urltest_id)] = true;
        for (let group_id in connections.priority_groups(section))
            taken[priority_outbound_tag(section[".name"], group_id)] = true;
    }
}

function add_route_for_section(config, section) {
    add_combined_route_for_section(config, section);
}

function add_service_route_rules(config, sections) {
    let first = null;
    for (let section in sections) {
        let action = option(section, "action", "");
        if (connections.is_connections_action(action) ||
            action == "byedpi" || action == "zapret" || action == "zapret2") {
            first = section;
            break;
        }
    }
    if (first != null) {
        push(config.route.rules, {
            action: "route",
            inbound: tproxy_inbound_matcher(),
            outbound: outbound_tag(first[".name"]),
            domain: runtime_constants.CHECK_PROXY_IP_DOMAIN
        });
    }
    push(config.route.rules, {
        action: "route-options",
        domain: runtime_constants.FAKEIP_TEST_DOMAIN,
        override_port: 8443
    });
}

function enabled_sections() {
    let result = [];
    uci_cursor().foreach(CONFIG_NAME, "section", function(section) {
        if (section_enabled(section))
            push(result, section);
    });
    return result;
}

function enabled_servers() {
    let result = [];
    uci_cursor().foreach(CONFIG_NAME, "server", function(section) {
        if (section_enabled(section))
            push(result, section);
    });
    return result;
}

function section_by_name(sections, name) {
    name = as_string(name);
    for (let section in sections)
        if (as_string(section[".name"]) == name)
            return section;
    return null;
}

function add_server_routes(config, servers, sections) {
    for (let server in servers) {
        runtime_servers.add_sniff_rule(config, server);

        let inbound = runtime_constants.server_inbound_tag(server[".name"]);
        let routing_mode = option(server, "routing_mode", "rules");
        if (routing_mode == "rules") {
            runtime_servers.clone_rules_for_inbound(
                config,
                runtime_constants.TPROXY_INBOUND_TAG,
                inbound,
                runtime_constants.CHECK_PROXY_IP_DOMAIN
            );
        }
        else if (routing_mode == "direct") {
            push(config.route.rules, {
                action: "route",
                inbound,
                outbound: runtime_constants.DIRECT_OUTBOUND_TAG
            });
        }
        else if (routing_mode == "section") {
            let routing_section_name = option(server, "routing_section", "");
            let routing_section = section_by_name(sections, routing_section_name);
            if (routing_section == null)
                runtime_generate_unsupported("server references missing routing section " + routing_section_name);
            let action = option(routing_section, "action", "");
            if (action == "bypass" || action == "block")
                runtime_generate_unsupported("server routing section " + routing_section_name + " cannot use action " + action);
            let target = runtime_route.target(routing_section, outbound_tag(routing_section[".name"]));
            if (target.unsupported)
                runtime_generate_unsupported(target.unsupported);
            let rule = {
                action: target.action,
                inbound
            };
            if (target.outbound)
                rule.outbound = target.outbound;
            push(config.route.rules, rule);
        }
        else {
            runtime_generate_unsupported("unsupported server routing_mode " + routing_mode);
        }
    }
}

function generate_config(output_path, service_address, mwan3_active) {
    let cursor = uci_cursor();
    cursor.load(CONFIG_NAME);
    runtime_settings_cache = object_or_empty(cursor.get_all(CONFIG_NAME, "settings"));
    let settings = runtime_settings_cache;
    check_supported_settings(settings);

    let sections = enabled_sections();
    let servers = enabled_servers();
    if (length(sections) == 0 && length(servers) == 0)
        runtime_generate_unsupported("no enabled sections");

    let config = base_config(settings, service_address, { mwan3_active: cli_bool(mwan3_active) });
    let taken = reserved_runtime_tag_set(config.outbounds);
    reserve_section_outbound_tags(sections, taken);
    for (let server in servers)
        runtime_servers.add_server(config, server);
    for (let section in sections)
        add_outbound_for_section(config, section, taken, sections);
    add_service_route_rules(config, sections);
    for (let section in sections)
        add_route_for_section(config, section);
    add_server_routes(config, servers, sections);
    add_service_mixed_proxy(config, settings, sections);
    for (let section in sections)
        add_mixed_proxy_for_section(config, section, service_address);

    assert_unique_outbound_tags(config);
    strip_internal_fields(config);
    if (!write_json_file(output_path, config)) {
        warn("failed to write ", output_path, "\n");
        exit(1);
    }
}

function generate_config_fixture(fixture_path, output_path, service_address, mwan3_active) {
    use_fixture_cursor(fixture_path);
    runtime_subscription.set_section_cache_dir(output_path + ".section-cache");
    runtime_ruleset_folder = output_path + ".rulesets";
    generate_config(output_path, service_address, mwan3_active);
}

function merge_object_values(target, source) {
    target = object_or_empty(target);
    for (let key, value in object_or_empty(source))
        target[key] = value;
    return target;
}

function stdin_length() {
    let value = read_stdin_json();
    if (type(value) == "array" || type(value) == "object")
        print(length(value), "\n");
    else
        print("0\n");
}

function stdin_contains(needle) {
    return index(read_stdin(), as_string(needle)) >= 0;
}

function stdin_regex_matches(pattern) {
    pattern = as_string(pattern);
    if (pattern == "")
        return false;

    try {
        return match(read_stdin(), regexp(pattern)) != null;
    }
    catch (e) {
        return false;
    }
}

function file_line_count(path) {
    let data = fs.readfile(path);
    let count = 0;

    if (data == null) {
        print("0\n");
        return;
    }

    for (let i = 0; i < length(data); i++)
        if (substr(data, i, 1) == "\n")
            count++;

    print(count, "\n");
}

function ip_addr_first_inet4() {
    for (let line in split(read_stdin(), "\n")) {
        let fields = split(trim(as_string(line)), /[ \t]+/);
        if (length(fields) < 2 || fields[0] != "inet")
            continue;

        let slash = index(fields[1], "/");
        print(slash >= 0 ? substr(fields[1], 0, slash) : fields[1], "\n");
        return;
    }
}

function stdin_first_dns_a_address() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) != null) {
            print(line, "\n");
            return;
        }
    }
}

function stdin_first_dns_aaaa_address() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^[0-9A-Fa-f:]+$/) != null) {
            print(line, "\n");
            return;
        }
    }
}

function stdin_first_nslookup_address() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^Address[ \t]*[0-9]*:[ \t]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) == null &&
            match(line, /^Address[ \t]*[0-9]*:[ \t]*[0-9A-Fa-f:]+$/) == null)
            continue;

        let fields = split(trim(line), /[ \t]+/);
        if (length(fields) > 0)
            print(fields[length(fields) - 1], "\n");
        return;
    }
}

function valid_ipv6_literal(value) {
    value = as_string(value);
    return index(value, ":") >= 0 && match(value, /^[0-9A-Fa-f:.]+$/) != null;
}

function stdin_first_field() {
    let data = read_stdin();
    let newline = index(data, "\n");
    let line = newline >= 0 ? substr(data, 0, newline) : data;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);

    if (length(fields) > 0 && fields[0] != "")
        print(fields[0], "\n");
}

function normalize_country_server_key(value) {
    print(lc(trim(as_string(value))), "\n");
}

function array_item(index) {
    let value = read_stdin_json();
    index = int(index || 0);
    if (type(value) == "array" && index >= 0 && index < length(value) && value[index] != null)
        print(as_string(value[index]), "\n");
}

function array_append_string(value) {
    let result = array_or_empty(read_stdin_json());
    push(result, as_string(value));
    write_json(result);
}

function merge_proxy_group_subscription_state(tags_path, link_refs_path, names_path, servers_path,
    subscription_tags_path, subscription_link_refs_path, subscription_names_path, subscription_servers_path) {
    let tags = array_or_empty(read_json_file(tags_path));
    for (let tag in array_or_empty(read_json_file(subscription_tags_path)))
        push(tags, tag);

    if (!write_file_json(tags_path, tags) ||
        !write_file_json(link_refs_path, merge_object_values(read_json_file(link_refs_path), read_json_file(subscription_link_refs_path))) ||
        !write_file_json(names_path, merge_object_values(read_json_file(names_path), read_json_file(subscription_names_path))) ||
        !write_file_json(servers_path, merge_object_values(read_json_file(servers_path), read_json_file(subscription_servers_path))))
        exit(1);
}

function append_proxy_group_outbound_state(tags_path, links_path, names_path, servers_path, tag, link, display_name, server) {
    tag = as_string(tag);
    link = as_string(link);
    display_name = as_string(display_name);
    server = as_string(server);

    let tags = array_or_empty(read_json_file(tags_path));
    let links = object_or_empty(read_json_file(links_path));
    let names = object_or_empty(read_json_file(names_path));
    let servers = object_or_empty(read_json_file(servers_path));

    push(tags, tag);
    names[tag] = display_name;
    if (link != "")
        links[tag] = link;
    if (server != "")
        servers[tag] = server;

    if (!write_file_json(tags_path, tags) ||
        !write_file_json(links_path, links) ||
        !write_file_json(names_path, names) ||
        !write_file_json(servers_path, servers))
        exit(1);
}

function normalized_country_list() {
    write_json(runtime_urltest.normalized_country_list(read_stdin_json()));
}

function countries_from_flag_names(path) {
    write_json(runtime_urltest.countries_from_flag_names(read_json_file(path)));
}

function urltest_regex_matching_tags(tags_path, names_path, regex_path) {
    write_json(runtime_urltest.regex_matching_tag_array(
        read_json_file(tags_path),
        read_json_file(names_path),
        read_json_file(regex_path)
    ));
}

function urltest_filter(mode, tags_path, names_path, countries_path, names_filter_path, regex_tags_path, countries_filter_path) {
    write_json(runtime_urltest.filter_array(
        mode,
        read_json_file(tags_path),
        read_json_file(names_path),
        read_json_file(countries_path),
        read_json_file(names_filter_path),
        read_json_file(regex_tags_path),
        read_json_file(countries_filter_path)
    ));
}

function urltest_filter_mode(mode, tags_path, names_path, countries_path, include_names_path, include_regex_path, include_countries_path, exclude_names_path, exclude_regex_path, exclude_countries_path) {
    write_json(runtime_urltest.filter_mode(
        mode,
        read_json_file(tags_path),
        read_json_file(names_path),
        read_json_file(countries_path),
        read_json_file(include_names_path),
        read_json_file(include_regex_path),
        read_json_file(include_countries_path),
        read_json_file(exclude_names_path),
        read_json_file(exclude_regex_path),
        read_json_file(exclude_countries_path)
    ));
}

function final_urltest_outbounds(config_path, tags_path) {
    let config = object_or_empty(read_json_file(config_path));
    let tags = array_or_empty(read_json_file(tags_path));
    let outbounds_by_tag = {};
    let skipped_types = {
        selector: true,
        urltest: true,
        direct: true,
        dns: true,
        block: true
    };
    let result = [];

    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            continue;

        let tag = as_string(outbound.tag || "");
        if (tag != "")
            outbounds_by_tag[tag] = outbound;
    }

    for (let tag in tags) {
        tag = as_string(tag);
        let outbound = outbounds_by_tag[tag];
        if (type(outbound) != "object")
            continue;

        let proxy_type = lc(as_string(outbound.type || ""));
        if (skipped_types[proxy_type])
            continue;

        push(result, tag);
    }

    write_json(result);
}

function section_countries(path) {
    let cache = object_or_empty(read_json_file(path));
    write_json(object_or_empty(cache.outboundMetadata && cache.outboundMetadata.countries));
}

function cached_country_object_for_servers(servers_path, cache_path) {
    let servers = object_or_empty(read_json_file(servers_path));
    let cache = object_or_empty(read_json_file(cache_path));
    let result = {};

    for (let tag, _ in servers) {
        let country = as_string(cache[tag] || "");
        if (country != "")
            result[tag] = country;
    }

    return result;
}

function cached_countries_for_servers(servers_path, cache_path) {
    write_json(cached_country_object_for_servers(servers_path, cache_path));
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

function resolved_country_object_from_tsv(resolved_path, ip_country_path) {
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

    return result;
}

function server_countries_result(servers_path, cache_path, resolved_path, ip_country_path) {
    let result = cached_country_object_for_servers(servers_path, cache_path);

    for (let tag, country in resolved_country_object_from_tsv(resolved_path, ip_country_path))
        result[tag] = country;

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

if (mode == "generate-config")
    generate_config(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "generate-config-fixture")
    generate_config_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "stdin-length")
    stdin_length();
else if (mode == "stdin-contains")
    exit(stdin_contains(ARGV[1]) ? 0 : 1);
else if (mode == "stdin-regex-matches")
    exit(stdin_regex_matches(ARGV[1]) ? 0 : 1);
else if (mode == "csv-to-json-array")
    csv_to_json_array(ARGV[1]);
else if (mode == "ip-addr-first-inet4")
    ip_addr_first_inet4();
else if (mode == "stdin-first-dns-a-address")
    stdin_first_dns_a_address();
else if (mode == "stdin-first-dns-aaaa-address")
    stdin_first_dns_aaaa_address();
else if (mode == "stdin-first-nslookup-address")
    stdin_first_nslookup_address();
else if (mode == "stdin-first-field")
    stdin_first_field();
else if (mode == "array-append-string")
    array_append_string(ARGV[1]);
else if (mode == "normalized-country-list")
    normalized_country_list();
else if (mode == "urltest-filter")
    urltest_filter(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "object-nonempty")
    exit(object_nonempty_stdin() ? 0 : 1);
else {
    warn("Usage: singbox/generator.uc <operation> ...\n");
    exit(1);
}
