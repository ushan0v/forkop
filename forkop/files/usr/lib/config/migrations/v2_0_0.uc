// 1.0.5 → 2.0.0. Every step reads a released option the way the 1.0.5 backend did and writes
// the form 2.0.0 reads; an option with no counterpart is removed, with a warning where what the
// router routes, serves or opens changes. Forms only older releases wrote, which 1.0.5 still
// read, are read here too, so the backend reads none of them.

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let core_url = require("core.url");
let core_ip = require("core.ip");
let headers = require("singbox.subscription_headers");
let singbox_constants = require("singbox.constants");
let urltest = require("singbox.urltest");
let rule = require("config.rule");
let model = require("config.migrations.model");
let url = require("config.migrations.url_1_0_5");

let as_string = common.as_string;
let parse_json = common.parse_json;

let paths = {
    // Where the released page put the self-signed certificate it issued for a server.
    certificates: "/etc/forkop/server-certs/",
    // Where the 1.0.x runtime kept the last good download of each subscription.
    subscription_cache: "/etc/forkop/subscription-cache/",
    dnsmasq_init: "/etc/init.d/dnsmasq",
    // What the 1.0.x runtime kept and 2.0.0 does not read, the directories of its retired
    // features included.
    leftovers: [
        "/var/run/forkop/server-country-cache.json", "/var/run/forkop/subscription-update",
        "/var/run/forkop/subscription-links", "/var/run/forkop/subscription-metadata", "/var/run/forkop/outbound-metadata",
        "/var/run/forkop/section-cache", "/var/run/forkop/runtime-manifest.json", "/var/run/forkop/subscription-update.lock",
        "/var/run/forkop/subscription-update-jobs", "/var/run/forkop/subscription-bootstrap-retry.pid",
        "/var/run/forkop/cache-format", "/var/run/forkop/dns-failover.json", "/var/run/forkop/dns-failover.pid",
        "/var/run/forkop/priority.pid", "/var/run/forkop/list-update.timestamp", "/var/run/forkop_list_update.pid",
        "/tmp/sing-box/subscriptions", "/tmp/sing-box/rulesets", "/etc/forkop/subscription-cache",
        "/var/run/forkop/system-info.json", "/tmp/forkop/system-info.json", "/var/run/forkop/component-update-check.timestamp",
        "/var/run/forkop/component-update-checks", "/var/run/forkop/component-actions", "/var/run/forkop/component-action.lock",
        "/tmp/forkop.latest-version.cache", "/var/run/forkop/zapret", "/var/run/forkop/zapret2", "/var/run/forkop/byedpi",
        "/var/run/forkop/zapret-runtime", "/usr/lib/forkop/components", "/usr/lib/forkop/dns", "/usr/lib/forkop/providers",
        "/usr/lib/forkop/routing", "/usr/lib/forkop/subscription"
    ]
};

function label_of(section) {
    return trim(model.value(section, "label")) || model.name(section);
}

function section_owned(config, type_name, section) {
    return model.children(config, type_name, "section", model.name(section));
}

function json_map(section, key) {
    let parsed = parse_json(model.value(section, key));
    return type(parsed) == "object" ? parsed : {};
}

// ---------------------------------------------------------------- forms 1.0.5 still read

// proxy, outbound and vpn were names of connection; the single outbound_json counted only
// while outbound_jsons was empty.
function connection_aliases(config) {
    for (let section in model.of_type(config, "section")) {
        if (model.value(section, "action") in [ "proxy", "outbound", "vpn" ])
            section.action = "connection";
        if (model.present(section, "outbound_json")) {
            let single = trim(model.value(section, "outbound_json"));
            if (length(model.list(section, "outbound_jsons")) == 0 && single != "")
                section.outbound_jsons = [ single ];
            delete section.outbound_json;
        }
    }
}

const SUBSCRIPTION_ITEM_KEYS = [
    "subscription_update_enabled", "subscription_update_interval", "download_via_proxy_enabled",
    "download_via_proxy_section", "auto_user_agent", "user_agent", "auto_hwid", "hwid",
    "show_dashboard_metadata", "prefix_nodes", "node_prefix", "include_urltest_groups",
    "hide_urltest_group_outbounds", "hide_detour_outbounds"
];

const URLTEST_SECTION_KEYS = {
    check_interval: "urltest_check_interval",
    tolerance: "urltest_tolerance",
    testing_url: "urltest_testing_url",
    filter_mode: "urltest_filter_mode",
    include_countries: "urltest_include_countries",
    include_outbounds: "urltest_include_outbounds",
    include_regex: "urltest_include_regex",
    exclude_countries: "urltest_exclude_countries",
    exclude_outbounds: "urltest_exclude_outbounds",
    exclude_regex: "urltest_exclude_regex"
};

// A section without children of a kind fell back to the options older releases kept on the
// section itself, with per-item settings in a JSON map keyed by the item.
function section_items_become_children(config) {
    for (let section in model.of_type(config, "section")) {
        let owner = model.name(section);

        if (length(section_owned(config, "subscription_url", section)) == 0) {
            let settings = json_map(section, "subscription_url_settings");
            for (let address in model.words(section, "subscription_urls")) {
                let child = model.add(config, "subscription_url", { section: owner, url: address });
                let item = type(settings[address]) == "object" ? settings[address] : {};
                for (let key in SUBSCRIPTION_ITEM_KEYS)
                    if (item[key] != null)
                        child[key] = as_string(item[key]);
                for (let key in [ "subscription_update_enabled", "subscription_update_interval" ])
                    if (child[key] == null && model.value(section, key) != "")
                        child[key] = model.value(section, key);
            }
        }

        if (length(section_owned(config, "section_interface", section)) == 0) {
            let names = model.list(section, "interfaces");
            if (length(names) == 0 && model.value(section, "interface") != "")
                names = [ model.value(section, "interface") ];
            let settings = json_map(section, "interface_settings");
            for (let interface_name in names) {
                let item = type(settings[interface_name]) == "object" ? settings[interface_name] : {};
                model.add(config, "section_interface", {
                    section: owner,
                    name: interface_name,
                    domain_resolver_enabled: common.bool_value(item.domain_resolver_enabled,
                        model.flag(section, "domain_resolver_enabled", false)) ? "1" : "0",
                    domain_resolver_dns_type: as_string(item.domain_resolver_dns_type ??
                        (model.value(section, "domain_resolver_dns_type") || "udp")),
                    domain_resolver_dns_server: as_string(item.domain_resolver_dns_server ??
                        (model.value(section, "domain_resolver_dns_server") || "8.8.8.8"))
                });
            }
        }

        if (length(section_owned(config, "urltest", section)) == 0 && model.flag(section, "urltest_enabled", false)) {
            let item = json_map(section, "urltest_settings").urltest;
            item = type(item) == "object" ? item : {};
            let child = model.add(config, "urltest", { section: owner, name: as_string(item.display_name ?? "Fastest") });
            for (let key, legacy in URLTEST_SECTION_KEYS) {
                let value = item[legacy] ?? section[legacy];
                if (value != null)
                    child[key] = type(value) == "array" ? value : as_string(value);
            }
            for (let key in [ "idle_timeout", "interrupt_exist_connections", "pin_dashboard" ])
                if (item[key] != null)
                    child[key] = as_string(item[key]);
            let detect = item.detect_server_country ?? section.detect_server_country;
            if (detect != null)
                child.detect_server_country = as_string(detect);
        }

        model.unset(section, [
            "subscription_urls", "subscription_url_settings", "subscription_update_enabled",
            "subscription_update_interval", "interfaces", "interface", "interface_settings",
            "domain_resolver_enabled", "domain_resolver_dns_type", "domain_resolver_dns_server",
            "urltest_enabled", "urltest_settings", ...values(URLTEST_SECTION_KEYS)
        ]);
    }
}

// A URLTest read each option under its older name too, the newer one first.
function urltest_aliases(config) {
    for (let group in model.of_type(config, "urltest")) {
        for (let key, legacy in { ...URLTEST_SECTION_KEYS, name: "display_name" }) {
            if (group[key] == null && group[legacy] != null)
                group[key] = group[legacy];
            delete group[legacy];
        }
    }
}

// ------------------------------------------------------------------- Zapret, Zapret2, ByeDPI

const DPI_ACTIONS = { zapret: "Zapret", zapret2: "Zapret2", byedpi: "ByeDPI" };

// Each option naming a section, with the switch that makes it count.
const SECTION_REFERENCES = [
    [ "dns_detour_section", "dns_detour_enabled" ],
    [ "outbound_detour_section", "outbound_detour_enabled" ],
    [ "download_via_proxy_section", "download_via_proxy_enabled" ],
    [ "download_lists_via_proxy_section", "download_lists_via_proxy" ],
    [ "download_components_via_proxy_section", "download_components_via_proxy" ]
];

// 2.0.0 runs no DPI bypass: such a section goes with what it owns, and whatever pointed at it is
// switched off. What those engines installed on the router is left alone.
function remove_dpi_sections(config, ctx) {
    let removed = {};
    for (let section in model.of_type(config, "section")) {
        let engine = DPI_ACTIONS[model.value(section, "action")];
        if (engine == null)
            continue;
        removed[model.name(section)] = true;
        model.remove(config, section);
        push(ctx.warnings, "Removed the " + engine + " section '" + label_of(section) +
            "': Forkop no longer runs DPI bypass");
    }

    for (let section in [ ...config.sections ]) {
        if (removed[model.value(section, "section")]) {
            if (section[".type"] == "priority_group")
                for (let level in model.children(config, "priority_level", "group", model.name(section)))
                    model.remove(config, level);
            model.remove(config, section);
            continue;
        }
        for (let reference in SECTION_REFERENCES)
            if (removed[model.value(section, reference[0])]) {
                delete section[reference[0]];
                section[reference[1]] = "0";
            }
        if (section[".type"] == "server" && removed[model.value(section, "routing_section")]) {
            section.routing_mode = "direct";
            delete section.routing_section;
            push(ctx.warnings, "Server '" + label_of(section) + "' was routed through a removed DPI section and now goes direct");
        }
    }
    for (let section in model.of_type(config, "section"))
        model.unset(section, [ "nfqws_opt", "nfqws2_opt", "byedpi_cmd_opts" ]);
}

// -------------------------------------------------------------------------------- settings

// As 1.0.5 built a DNS server from a host[:port][/path] and the protocol set beside it.
function dns_uri(dns_type, value) {
    value = trim(as_string(value));
    let scheme = { udp: "", dot: "tls://", doh: "https://" }[dns_type];
    if (scheme == null)
        return value;
    let host = url.host(value);
    let authority = index(host, ":") >= 0 ? "[" + host + "]" : host;
    if (url.port(value) != "")
        authority += ":" + url.port(value);
    return scheme + authority + (dns_type == "doh" ? url.path(value) : "");
}

function dns_uris(dns_type, values) {
    return filter(map(values, (value) => dns_uri(dns_type, value)), (value) => value != "");
}

function migrate_settings(config, ctx) {
    let settings = model.settings(config);
    if (model.present(settings, "dns_type")) {
        let servers = dns_uris(model.value(settings, "dns_type") || "udp", model.words(settings, "dns_server"));
        if (length(servers) > 0)
            settings.dns_server = servers;
        else
            delete settings.dns_server;
        delete settings.dns_type;
    }
    if (model.flag(settings, "dont_touch_dhcp", false))
        settings.unmatched_dns_mode = "router";
    model.unset(settings, [
        "applied_migrations", "dont_touch_dhcp", "shutdown_correctly", "exclude_ntp",
        "dns_check_interval", "dns_recovery_check_interval", "dns_check_timeout",
        "component_update_check_enabled", "component_update_check_interval",
        "download_components_via_proxy", "download_components_via_proxy_section"
    ]);
}

// ------------------------------------------------------------------------- built-in lists

// 1.0.x took its built-in lists from itdog and a few other repositories, 2.0.0 from
// forkop-lists. A list 2.0.0 carries on under another name is renamed; one it dropped becomes
// the file 1.0.x downloaded, a rule set of the section, with the subnets 1.0.x applied of it.
const KEPT_LISTS = {
    geoblock: "ru_blocked_geo", ukraine_inside: "ua_blocked", google_ai: "gemini", twitter: "x",
    ads_hagezi_pro: "ads", telegram: "telegram", youtube: "youtube", discord: "discord", tiktok: "tiktok",
    github: "github", google_play: "google_play", roblox: "roblox", supercell: "supercell", cloudflare: "cloudflare",
    hetzner: "hetzner", ovh: "ovh", digitalocean: "digitalocean"
};
// Whether 1.0.x applied the subnets of a dropped list.
const DROPPED_LISTS = {
    russia_inside: false, russia_outside: false, block: false, porn: false, news: false, anime: false,
    hdrezka: false, hodca: false, meta: true, cloudfront: true
};
const DROPPED_LISTS_URL = "https://github.com/itdoginfo/allow-domains/releases/latest/download/";

function push_unique(values, value) {
    if (!(value in values))
        push(values, value);
}

function migrate_builtin_lists(config) {
    for (let section in model.of_type(config, "section")) {
        let dns = model.value(section, "action") == "dns";
        let lists = [];
        let named = [];
        let sets = { rule_set: [], rule_set_with_subnets: [] };

        // 1.0.x also took a built-in list's name as a rule set; 2.0.0 keeps lists in their own option.
        for (let key in keys(sets))
            for (let value in model.list(section, key)) {
                if (KEPT_LISTS[value] != null)
                    push_unique(named, KEPT_LISTS[value]);
                else
                    push_unique(sets[key], DROPPED_LISTS[value] != null ? DROPPED_LISTS_URL + value + ".srs" : value);
            }
        for (let name in model.list(section, "community_lists")) {
            if (DROPPED_LISTS[name] != null)
                push_unique(sets[DROPPED_LISTS[name] && !dns ? "rule_set_with_subnets" : "rule_set"],
                    DROPPED_LISTS_URL + name + ".srs");
            else
                push_unique(lists, KEPT_LISTS[name] ?? name);
        }
        for (let name in named)
            push_unique(lists, name);

        sets.community_lists = lists;
        for (let key in keys(sets)) {
            if (length(sets[key]) > 0)
                section[key] = sets[key];
            else
                delete section[key];
        }
    }
}

// -------------------------------------------------------------------------------- sections

const SUBNET_LIST_OPTIONS = [ "local_domain_lists", "local_subnet_lists", "remote_domain_lists", "remote_subnet_lists", "subnet", "subnet_text" ];

// 1.0.5 skipped a list file it could not read or that held no entry; the core refuses to start
// with one.
function list_file_holds_entries(path) {
    for (let line in split(fs.readfile(path) ?? "", "\n"))
        if (trim(split(split(line, "#")[0], "//")[0]) != "")
            return true;
    return false;
}

function migrate_section_options(config, ctx) {
    for (let section in model.of_type(config, "section")) {
        let dns = model.value(section, "action") == "dns";

        if (dns && model.present(section, "dns_type")) {
            let servers = dns_uris(model.value(section, "dns_type") || "udp", model.list(section, "dns_server"));
            if (length(servers) > 0)
                section.dns_server = servers;
            else
                delete section.dns_server;
            delete section.dns_type;
        }

        // 1.0.5 split a single option of these on whitespace.
        for (let key in [ "community_lists", "rule_set", "rule_set_with_subnets" ])
            if (model.present(section, key) && type(section[key]) != "array") {
                let values = model.words(section, key);
                if (length(values) > 0)
                    section[key] = values;
                else
                    delete section[key];
            }

        // Plain lists of domains and addresses; a DNS section matched only their domains.
        let lists = model.list(section, "domain_ip_lists");
        if (length(lists) > 0) {
            let key = dns ? "rule_set" : "rule_set_with_subnets";
            let merged = model.list(section, key);
            for (let value in lists) {
                if (substr(value, 0, 1) == "/" && !list_file_holds_entries(value)) {
                    push(ctx.warnings, "Section '" + label_of(section) + "' no longer lists '" + value + "': the file is " +
                        "missing or holds no entry, which Forkop no longer starts with. Add it again once it holds the list");
                    continue;
                }
                if (!(value in merged))
                    push(merged, value);
            }
            if (length(merged) > 0)
                section[key] = merged;
        }
        delete section.domain_ip_lists;

        for (let key in SUBNET_LIST_OPTIONS)
            if (model.present(section, key)) {
                push(ctx.warnings, "Removed '" + key + "' from section '" + label_of(section) +
                    "': no Forkop release ever applied it; add those lists as rule sets");
                delete section[key];
            }

        if (model.value(section, "dashboard_filter_mode") in [ "include", "exclude", "mixed" ])
            push(ctx.warnings, "Section '" + label_of(section) + "' offers all its servers now: the Dashboard server " +
                "filter is gone, so the server it uses by default may change. A URLTest or fallback group with " +
                "the same filter keeps to those servers");
        for (let key in keys(section))
            if (substr(key, 0, 10) == "dashboard_")
                delete section[key];
        model.unset(section, [ "sort_by_latency", "resolve_real_ip_for_routing", "detect_server_country" ]);
    }
}

// ------------------------------------------------------------- conditions, as 1.0.5 matched them

const DOMAIN_FORMS = [
    "domain_suffix", "domain_suffix_text", "domain_suffix_text_mode", "domain_keyword", "domain_keyword_text",
    "domain_keyword_text_mode", "domain_regex", "domain_regex_text", "domain_regex_text_mode", "domain_text",
    "domain_text_mode", "ip_cidr_text", "ip_cidr_text_mode", "conditions_text_mode"
];

function strip_comment(line) {
    return replace(replace(line, /[[:space:]]*\/\/.*$/, ""), /[[:space:]]*#.*$/, "");
}

// The text fields: a value per line or between spaces and commas, comments after # or //.
function text_values(text) {
    let result = [];
    for (let line in split(as_string(text), "\n"))
        for (let item in split(replace(strip_comment(line), /[ ,]/g, "\n"), "\n")) {
            item = trim(replace(item, /\r/g, ""));
            if (item != "")
                push(result, item);
        }
    return result;
}

function text_mode(section, key) {
    return model.flag(section, key + "_text_mode", false) || model.flag(section, "conditions_text_mode", false);
}

// What 1.0.5 matched for an option that older releases kept as a list, a plain option or text.
function legacy_values(section, key) {
    if (text_mode(section, key))
        return text_values(model.value(section, key + "_text"));
    let raw = section[key];
    if (type(raw) == "array" && length(raw) > 0)
        return raw;
    if (type(raw) != "array" && key != "domain" && length(text_values(raw)) > 0)
        return text_values(raw);
    return text_values(model.value(section, key + "_text"));
}

// The domains and addresses of a section as one text, the user's own lines kept as written. A
// DNS section never matched addresses, so they are left out there. A listed value the text
// would split or cut, at a space, a comma or a comment mark, cannot be carried over.
function destination_text(section, dns, unwritable) {
    let parts = [];
    let add = (value) => {
        value = trim(as_string(value));
        if (value != "")
            push(parts, value);
    };

    if (type(section.domain) != "array")
        add(section.domain);
    add(section.domain_suffix_text);
    for (let value in model.words(section, "domain_suffix"))
        add(value);
    for (let entry in [ [ "domain", "full:" ], [ "domain_keyword", "keyword:" ], [ "domain_regex", "regex:" ] ])
        for (let value in legacy_values(section, entry[0])) {
            if (match(value, /[ \t,#]|\/\//) != null)
                push(unwritable, entry[1] + value);
            else
                add(entry[1] + value);
        }

    if (!dns) {
        if (text_mode(section, "ip_cidr"))
            add(section.ip_cidr_text);
        else if (type(section.ip_cidr) == "array" && length(section.ip_cidr) > 0)
            add(join("\n", section.ip_cidr));
        else if (trim(model.value(section, "ip_cidr")) != "")
            add(section.ip_cidr);
        else
            add(section.ip_cidr_text);
    }
    return join("\n", parts);
}

function port_values(section) {
    let result = [];
    for (let value in [ ...model.words(section, "ports"), ...text_values(model.value(section, "ports_text")) ]) {
        let dash = index(value, "-");
        let start = dash < 0 ? value : substr(value, 0, dash);
        let end = dash < 0 ? value : substr(value, dash + 1);
        if (match(start, /^[0-9]+$/) == null || match(end, /^[0-9]+$/) == null)
            continue;
        start = int(start);
        end = int(end);
        if (start < 1 || end > 65535 || start > end)
            continue;
        let normalized = start == end ? as_string(start) : start + "-" + end;
        if (!(normalized in result))
            push(result, normalized);
    }
    return result;
}

function regex_valid(pattern) {
    try {
        urltest.compile(pattern);
        return true;
    }
    catch (e) {
        return false;
    }
}

// What 2.0.0 refuses was never matched by 1.0.5 either: it skipped a value it could not read,
// and a DNS section matched no address. A line keeps its comment.
function readable_destinations(text, dns, dropped) {
    let lines = [];
    for (let line in split(text, "\n")) {
        let start = length(line);
        for (let marker in [ "#", "//" ])
            if (index(line, marker) >= 0 && index(line, marker) < start)
                start = index(line, marker);
        let comment = trim(substr(line, start));
        let kept = [];
        let changed = false;
        for (let item in split(replace(substr(line, 0, start), /[ ,]/g, "\n"), "\n")) {
            item = trim(replace(item, /\r/g, ""));
            if (item == "")
                continue;
            let parsed = rule.destination_kind_value(item);
            if (parsed == null || (dns && parsed.kind == "ip_cidr") ||
                (parsed.kind == "domain_regex" && !regex_valid(parsed.value))) {
                push(dropped, item);
                changed = true;
                continue;
            }
            push(kept, item);
        }
        if (!changed)
            push(lines, line);
        else if (length(kept) > 0 || comment != "")
            push(lines, join(" ", length(kept) > 0 && comment != "" ? [ ...kept, comment ] : length(kept) > 0 ? kept : [ comment ]));
    }
    return trim(join("\n", lines));
}

function migrate_conditions(config, ctx) {
    for (let section in model.of_type(config, "section")) {
        let dns = model.value(section, "action") == "dns";
        let unwritable = [];
        let dropped = [];
        let text = readable_destinations(destination_text(section, dns, unwritable), dns, dropped);
        if (text != "")
            section.destinations = text;
        for (let value in unwritable)
            push(ctx.warnings, "Section '" + label_of(section) + "' no longer matches '" + value +
                "': a value with a space, a comma, '#' or '//' cannot be written in its destinations");
        if (length(dropped) > 0)
            push(ctx.warnings, "Section '" + label_of(section) + "' dropped from its destinations what Forkop cannot read there: " +
                join(", ", dropped));

        if (model.present(section, "ports") || model.present(section, "ports_text")) {
            let ports = port_values(section);
            if (length(ports) > 0)
                section.ports = ports;
            else
                delete section.ports;
        }

        let devices = legacy_values(section, "source_ip_cidr");
        if (length(devices) > 0)
            section.source_ip_cidr = devices;
        // 1.0.5 showed the older text in this field and saved it as the list.
        let fully_routed = model.words(section, "fully_routed_ips");
        if (length(fully_routed) == 0)
            fully_routed = text_values(model.value(section, "fully_routed_ips_text"));
        if (length(fully_routed) > 0)
            section.fully_routed_ips = fully_routed;

        model.unset(section, [
            "domain", "ip_cidr", ...DOMAIN_FORMS, "ports_text", "ports_text_mode",
            "source_ip_cidr_text", "source_ip_cidr_text_mode", "fully_routed_ips_text", "fully_routed_ips_text_mode"
        ]);
    }
}

// ------------------------------------------------------------------------------ JSON outbounds

function main_dns_tag(config) {
    return model.flag(model.settings(config), "dns_detour_enabled", false)
        ? singbox_constants.BOOTSTRAP_DNS_SERVER_TAG
        : singbox_constants.DNS_SERVER_TAG;
}

// sing-box 1.12 deprecated the dial domain_strategy for a domain_resolver naming a server; 1.0.5
// resolved such an outbound's server through the same DNS server 2.0.0 names here.
function domain_resolver(config, outbound) {
    if (outbound.domain_strategy == null)
        return;
    let resolver = outbound.domain_resolver;
    if (type(resolver) == "string")
        resolver = { server: resolver };
    resolver = type(resolver) == "object" ? resolver : { server: main_dns_tag(config) };
    if (resolver.strategy == null && as_string(outbound.domain_strategy) != "")
        resolver.strategy = outbound.domain_strategy;
    outbound.domain_resolver = resolver;
    delete outbound.domain_strategy;
}

function openvpn_endpoint(outbound, name) {
    let endpoint = { ...outbound, type: "openvpn-client" };
    // The system interface put allowed_ips into the router's routing table; the native client
    // routes inside sing-box, so neither can be carried over.
    if (endpoint.system || (endpoint.reconnect_delay != null && endpoint.reconnect_delay != ""))
        die(name + " uses OpenVPN system routes or reconnect_delay, which the native OpenVPN client has not");
    let proto = lc(as_string(endpoint.proto ?? "udp"));
    if (!(proto in [ "udp", "udp4", "tcp", "tcp-client", "tcp4", "tcp4-client" ]))
        die(name + " uses the OpenVPN protocol '" + proto + "', which the native client has not");
    endpoint.network = proto in [ "tcp", "tcp-client", "tcp4", "tcp4-client" ] ? "tcp" : "udp";
    endpoint.auth = as_string(endpoint.auth ?? "SHA1");
    if (endpoint.cipher)
        endpoint.data_ciphers_fallback = endpoint.cipher;

    let old_tls = type(endpoint.tls) == "object" ? endpoint.tls : {};
    if (old_tls.kernel_tx || old_tls.kernel_rx || old_tls.cipher_suites != null || old_tls.verify_x509_name_mode == "name-suffix")
        die(name + " uses OpenVPN tls.kernel_tx, tls.kernel_rx, tls.cipher_suites or a name-suffix check, which the native client has not");
    let renamed = {
        ca: "certificate", ca_path: "certificate_path", certificate: "client_certificate",
        certificate_path: "client_certificate_path", key: "client_key", key_path: "client_key_path",
        verify_x509_name: "server_name"
    };
    let tls = {};
    for (let key, value in old_tls) {
        if (renamed[key] != null)
            tls[renamed[key]] = value;
        else if (!(key in [ "kernel_tx", "kernel_rx", "verify_x509_name_mode" ]))
            die(name + " has the OpenVPN TLS field '" + key + "', which the native client has not");
    }
    if (tls.server_name != null)
        tls.server_name_type = old_tls.verify_x509_name_mode == "name-prefix" ? "name-prefix" : "name";

    let auth_key = endpoint.tls_auth || endpoint.tls_auth_path;
    let crypt_key = endpoint.tls_crypt || endpoint.tls_crypt_path;
    if (auth_key || crypt_key) {
        let prefix = auth_key ? "tls_auth" : "tls_crypt";
        let wrap = { type: auth_key ? "tls_auth" : endpoint.tls_crypt_v2 ? "tls_crypt_v2" : "tls_crypt" };
        if (endpoint[prefix])
            wrap.key = endpoint[prefix];
        else
            wrap.key_path = endpoint[prefix + "_path"];
        if (auth_key) {
            let direction = int(endpoint.key_direction ?? 0);
            if (direction != 0 && direction != 1)
                die(name + " has the OpenVPN key_direction '" + endpoint.key_direction + "', which is neither 0 nor 1");
            wrap.direction = direction == 1 ? "client" : "server";
        }
        tls.control_wrap = wrap;
    }
    for (let key in [ "cipher", "proto", "allowed_ips", "reconnect_delay", "tls_auth", "tls_auth_path", "tls_crypt",
        "tls_crypt_path", "tls_crypt_v2", "key_direction" ])
        delete endpoint[key];
    endpoint.tls = tls;
    return endpoint;
}

// sing-box 1.11 replaced the WireGuard outbound with the endpoint; its documented mapping.
function wireguard_endpoint(outbound) {
    let endpoint = { ...outbound };
    let peers = type(outbound.peers) == "array" ? outbound.peers : [ {
        server: outbound.server, server_port: outbound.server_port, public_key: outbound.peer_public_key,
        pre_shared_key: outbound.pre_shared_key, reserved: outbound.reserved
    } ];
    endpoint.peers = map(peers, (peer) => {
        let result = { address: peer.server, port: peer.server_port, public_key: peer.public_key,
            allowed_ips: peer.allowed_ips ?? [ "0.0.0.0/0", "::/0" ] };
        for (let key in [ "pre_shared_key", "reserved", "persistent_keepalive_interval" ])
            if (peer[key] != null)
                result[key] = peer[key];
        return result;
    });
    if (outbound.local_address != null)
        endpoint.address = outbound.local_address;
    if (outbound.system_interface != null)
        endpoint.system = outbound.system_interface;
    if (outbound.interface_name != null)
        endpoint.name = outbound.interface_name;
    for (let key in [ "server", "server_port", "peer_public_key", "pre_shared_key", "reserved", "local_address",
        "system_interface", "interface_name", "gso" ])
        delete endpoint[key];
    return endpoint;
}

function legacy_wireguard(outbound) {
    return outbound.type == "wireguard" && (outbound.server != null || outbound.local_address != null ||
        outbound.peer_public_key != null || type(outbound.peers) == "array" && outbound.peers[0]?.server != null);
}

// Each JSON outbound takes the name 1.0.5 showed for it, and what sing-box 1.14 no longer reads
// becomes what it reads instead: OpenVPN and WireGuard become tunnels of the section.
function migrate_json_outbounds(config, ctx) {
    for (let section in model.of_type(config, "section")) {
        let values = model.list(section, "outbound_jsons");
        if (length(values) == 0)
            continue;

        let kept = [];
        let tunnels = 0;
        for (let i = 0; i < length(values); i++) {
            let outbound = parse_json(values[i]);
            if (type(outbound) != "object") {
                push(kept, values[i]);
                continue;
            }
            let released = sprintf("%J", outbound);
            if (trim(as_string(outbound.tag)) == "")
                outbound.tag = "JSON outbound " + (i + 1);
            let name = "JSON outbound '" + outbound.tag + "' of section '" + label_of(section) + "'";
            domain_resolver(config, outbound);

            if (outbound.type == "dns") {
                push(ctx.warnings, "Removed the " + name + ": sing-box has no DNS outbound any more");
                continue;
            }
            if (outbound.type == "openvpn" || legacy_wireguard(outbound)) {
                let endpoint = outbound.type == "openvpn" ? openvpn_endpoint(outbound, name) : wireguard_endpoint(outbound);
                model.add(config, "tunnel", {
                    section: model.name(section),
                    kind: outbound.type == "openvpn" ? "openvpn-client" : "json",
                    name: outbound.tag,
                    order: as_string(tunnels++),
                    endpoint_json: sprintf("%J", endpoint)
                });
                continue;
            }
            if (outbound.type == "snell") {
                if (!(outbound.version in [ 4, 5, 6 ]))
                    die(name + " is Snell " + outbound.version + ", which sing-box no longer speaks; upgrade the server to Snell 4 or 6 first");
                if (outbound.version == 5)
                    outbound.version = 4;
                if (type(outbound.obfs) == "object") {
                    if (outbound.version != 4 || outbound.obfs_mode != null || outbound.obfs_host != null)
                        die(name + " sets Snell obfuscation twice");
                    if (outbound.obfs.mode != null)
                        outbound.obfs_mode = outbound.obfs.mode;
                    if (outbound.obfs.host != null)
                        outbound.obfs_host = outbound.obfs.host;
                    delete outbound.obfs;
                }
            }
            push(kept, sprintf("%J", outbound) == released ? values[i] : sprintf("%J", outbound));
        }

        if (length(kept) > 0)
            section.outbound_jsons = kept;
        else
            delete section.outbound_jsons;
    }
}

// -------------------------------------------------------------------------- links and cascades

// Each link of selector_proxy_links becomes a link of its own, named as 1.0.5 named its server:
// the decoded fragment, where 2.0.0 names an unnamed one.
function migrate_links(config) {
    for (let section in model.of_type(config, "section")) {
        let links = model.words(section, "selector_proxy_links");
        for (let i = 0; i < length(links); i++) {
            let name = trim(url.fragment(links[i])) || trim(core_url.link_name(links[i])) || "Node #" + (i + 1);
            model.add(config, "connection_link", {
                section: model.name(section), uri: links[i], name, order: as_string(i)
            });
        }
        delete section.selector_proxy_links;
    }
}

// The cascade went to the section's links and subscriptions, never to its interfaces or JSON
// outbounds.
function migrate_cascades(config) {
    for (let section in model.of_type(config, "section")) {
        let target = model.flag(section, "outbound_detour_enabled", false) ? trim(model.value(section, "outbound_detour_section")) : "";
        if (target != "")
            for (let type_name in [ "connection_link", "subscription_url" ])
                for (let child in section_owned(config, type_name, section))
                    child.detour_section = target;
        model.unset(section, [ "outbound_detour_enabled", "outbound_detour_section" ]);
    }
}

// ------------------------------------------------------------------------- servers

// Account names go on the wire: what fits stays as typed, anything else becomes "-".
function login_name(value, fallback) {
    value = as_string(value);
    if (match(value, /^[A-Za-z0-9._-]+$/))
        return value;
    let result = replace(replace(value, /[^A-Za-z0-9._-]/g, "-"), /^-+|-+$/g, "");
    return result == "" ? fallback : result;
}

function claim(taken, name, separator) {
    let candidate = name;
    for (let n = 2; taken[candidate]; n++)
        candidate = name + separator + n;
    taken[candidate] = true;
    return candidate;
}

function taken_names(config) {
    let result = {};
    for (let section in config.sections)
        result[model.name(section)] = true;
    return result;
}

function taken_labels(config) {
    let result = {};
    for (let type_name in [ "section", "server" ])
        for (let section in model.of_type(config, type_name))
            result[label_of(section)] = true;
    return result;
}

function mixed_client(config, ctx, server, username, password, what) {
    let name = login_name(username, "client");
    if (name != trim(as_string(username)) && trim(as_string(username)) != "")
        push(ctx.warnings, what + " accepts the account '" + name + "' instead of '" + username +
            "', since an account name holds only letters, digits, '.', '_' and '-': use it in its clients");
    model.add(config, "server_client", { server: model.name(server), name, password });
}

// A section's own mixed proxy becomes a mixed server routed to the section. It listened on the
// LAN address; :: with the port closed in the firewall answers on the LAN alone.
function migrate_section_proxies(config, ctx) {
    let names = null;
    let labels = null;
    for (let section in model.of_type(config, "section")) {
        let port = model.value(section, "mixed_proxy_port");
        let auth = model.flag(section, "mixed_proxy_auth_enabled", false);
        let username = model.value(section, "mixed_proxy_username");
        let password = model.value(section, "mixed_proxy_password");
        // Only what 1.0.5 accepted reached a listener.
        let served = model.flag(section, "mixed_proxy_enabled", false) && model.value(section, "action") == "connection" &&
            match(port, /^[0-9]+$/) != null && int(port) >= 1 && int(port) <= 65535 && (!auth || (username != "" && password != ""));
        model.unset(section, [ "mixed_proxy_enabled", "mixed_proxy_port", "mixed_proxy_auth_enabled", "mixed_proxy_username", "mixed_proxy_password" ]);
        if (!served)
            continue;

        if (names == null) {
            names = taken_names(config);
            labels = taken_labels(config);
        }
        let server = model.add_named(config, "server", claim(names, "server_" + model.name(section) + "_mixed", "_"), {
            label: claim(labels, label_of(section) + " - Mixed proxy", " "),
            enabled: model.flag(section, "enabled", true) ? "1" : "0",
            protocol: "mixed",
            listen: "::",
            listen_port: port,
            open_firewall: "0",
            routing_mode: "section",
            routing_section: model.name(section),
            mixed_auth_enabled: auth ? "1" : "0"
        });
        if (auth)
            mixed_client(config, ctx, server, username, password, "The mixed proxy of section '" + label_of(section) + "'");
    }
}

// Frozen with 1.0.5: the key sizes of the Shadowsocks 2022 methods.
const SHADOWSOCKS_2022_KEY_BYTES = {
    "2022-blake3-aes-128-gcm": 16,
    "2022-blake3-aes-256-gcm": 32,
    "2022-blake3-chacha20-poly1305": 32
};

// The protocols 1.0.5 served and the fields their accounts became in 2.0.0.
const CLIENT_FIELDS = {
    vless: [ [ "uuid", "server_uuid" ], [ "flow", "vless_flow" ] ],
    vmess: [ [ "uuid", "server_uuid" ] ],
    trojan: [ [ "password", "server_password" ] ],
    shadowsocks: [ [ "password", "server_password" ] ],
    hysteria2: [ [ "password", "server_password" ] ]
};

const REMOVED_SERVER_OPTIONS = [
    "server_users", "server_uuid", "server_username", "server_password", "vless_flow", "vmess_alter_id",
    "socks_auth_enabled", "reality_max_time_difference", "reality_handshake_server", "reality_handshake_server_port",
    "tailscale_advertise_exit_node", "tailscale_accept_routes", "tls_certificate_path", "tls_key_path", "transport_hosts"
];

// 1.0.x kept an account as "credential" or "name|credential|extra" before it had fields for it,
// and 1.0.5 filled the fields from it; the name went on the wire for SOCKS alone. Returns the
// name the entry gave.
function legacy_account(server, protocol) {
    let entry = as_string(model.list(server, "server_users")[0] ?? "");
    if (entry == "")
        return "";
    let parts = split(entry, "|");
    let fill = (key, value) => {
        if (model.value(server, key) == "" && value != "")
            server[key] = value;
    };
    let credential = length(parts) > 1 ? parts[1] : entry;
    if (protocol in [ "vless", "vmess" ])
        fill("server_uuid", credential);
    else if (protocol in [ "shadowsocks", "socks", "trojan", "hysteria2" ])
        fill("server_password", credential);
    if (protocol == "socks")
        fill("server_username", length(parts) > 1 ? parts[0] : "client");
    if (protocol == "vless" && length(parts) > 2)
        fill("vless_flow", parts[2]);
    return length(parts) > 1 ? trim(parts[0]) : "";
}

function pem_block(path, label) {
    let text = as_string(fs.readfile(path) ?? "");
    let end_line = "-----END " + label + "-----";
    let begin = index(text, "-----BEGIN " + label + "-----");
    let end = index(text, end_line);
    return begin < 0 || end < begin ? "" : substr(text, begin, end + length(end_line) - begin);
}

// A certificate Forkop issued moves into the server's options, keeping a pinned Hysteria2
// fingerprint; any other path is the user's and stays a path.
function migrate_certificate(server, security) {
    let certificate = model.value(server, "tls_certificate_path");
    let key = model.value(server, "tls_key_path");
    if (security != "tls" || certificate == "" || key == "")
        return;
    let own = substr(certificate, 0, length(paths.certificates)) == paths.certificates &&
        substr(key, 0, length(paths.certificates)) == paths.certificates;
    if (!own) {
        server.tls_certificate_source = "custom";
        server.tls_certificate = certificate;
        server.tls_key = key;
        return;
    }
    let issued_certificate = pem_block(certificate, "CERTIFICATE");
    let issued_key = pem_block(key, "PRIVATE KEY");
    if (issued_certificate != "" && issued_key != "") {
        server.tls_self_signed_certificate = issued_certificate;
        server.tls_self_signed_key = issued_key;
    }
}

// The security 1.0.5 served a protocol with, whatever the option said.
function released_security(server, protocol) {
    let security = model.value(server, "security") ||
        { vless: "reality", trojan: "tls", hysteria2: "tls" }[protocol] || "none";
    if (protocol in [ "shadowsocks", "socks", "mtproto", "tailscale", "json_inbound" ])
        return "none";
    if (protocol == "hysteria2")
        return "tls";
    if (protocol in [ "vmess", "trojan" ] && security == "reality")
        return protocol == "trojan" ? "tls" : "none";
    return security;
}

const LEGACY_INBOUND_FIELDS = [ "sniff", "sniff_override_destination", "sniff_timeout", "domain_strategy", "udp_disable_domain_unmapping" ];

function migrate_json_inbound(server, ctx) {
    let inbound = parse_json(model.value(server, "inbound_json"));
    if (type(inbound) != "object")
        return;
    let dropped = filter(LEGACY_INBOUND_FIELDS, (key) => inbound[key] != null);
    if (length(dropped) == 0)
        return;
    for (let key in dropped)
        delete inbound[key];
    server.inbound_json = sprintf("%J", inbound);
    // Forkop sniffs every server itself, so only the rest changed what the server did.
    let changed = filter(dropped, (key) => key != "sniff" && key != "sniff_timeout");
    if (length(changed) > 0)
        push(ctx.warnings, "Removed " + join(", ", changed) + " from the inbound JSON of server '" + label_of(server) +
            "': sing-box no longer reads them there");
}

function migrate_servers(config, ctx) {
    for (let server in model.of_type(config, "server")) {
        let protocol = model.value(server, "protocol") || "vless";
        let what = "Server '" + label_of(server) + "'";

        if (protocol == "mtproto") {
            for (let client in model.children(config, "server_client", "server", model.name(server)))
                model.remove(config, client);
            model.remove(config, server);
            push(ctx.warnings, "Removed the MTProto server '" + label_of(server) + "': Forkop no longer serves MTProto");
            continue;
        }

        // 1.0.5 counted a server without the switch as on, and listened on IPv4 unless told.
        if (!model.present(server, "enabled"))
            server.enabled = "1";
        if (!(protocol in [ "json_inbound", "tailscale" ])) {
            if (model.value(server, "listen") == "")
                server.listen = "0.0.0.0";
            // 1.0.5 never opened a server's port; one reachable from outside had a rule of its owner.
            server.open_firewall = "0";
        }

        let security = released_security(server, protocol);
        migrate_certificate(server, security);
        if (protocol == "trojan" && security == "none") {
            security = "tls";
            push(ctx.warnings, what + " serves Trojan over TLS now, which every Trojan client needs: hand its clients the new link");
        }
        if (!(protocol in [ "socks", "tailscale", "json_inbound" ]))
            server.security = security;

        let legacy_name = legacy_account(server, protocol);
        if (protocol == "socks") {
            server.protocol = "mixed";
            let auth = model.present(server, "socks_auth_enabled") ? model.flag(server, "socks_auth_enabled", true) : true;
            server.mixed_auth_enabled = auth ? "1" : "0";
            let existing = model.children(config, "server_client", "server", model.name(server));
            if (auth && length(existing) == 0)
                mixed_client(config, ctx, server, model.value(server, "server_username") || label_of(server),
                    model.value(server, "server_password"), what);
        }
        else if (CLIENT_FIELDS[protocol] != null && length(model.children(config, "server_client", "server", model.name(server))) == 0) {
            let client = model.add(config, "server_client", {
                server: model.name(server),
                name: trim(model.value(server, "server_username")) || legacy_name || label_of(server)
            });
            for (let field in CLIENT_FIELDS[protocol]) {
                let value = model.value(server, field[1]);
                if (value != "" && !(field[0] == "flow" && value == "none"))
                    client[field[0]] = value;
            }
        }

        if (protocol == "shadowsocks") {
            if (model.value(server, "shadowsocks_method") == "")
                server.shadowsocks_method = "aes-128-gcm";
            // A 2022 method kept its key in the password: it becomes the listener key, and the
            // client keeps it too. The core then wants both keys from a client, as 1.0.5's link
            // never gave them.
            if (SHADOWSOCKS_2022_KEY_BYTES[server.shadowsocks_method] != null && model.value(server, "server_password") != "" &&
                model.value(server, "shadowsocks_psk") == "") {
                server.shadowsocks_psk = model.value(server, "server_password");
                push(ctx.warnings, what + " gives each Shadowsocks 2022 client a key of its own now, which a link holds " +
                    "next to the server key: hand its clients the new link");
            }
        }

        // The SNI is in every link a client holds, so it wins; the handshake target fills one only
        // where none was stored, and 2.0.0 hands unknown clients to the SNI's port 443.
        if (security == "reality") {
            let handshake = model.value(server, "reality_handshake_server");
            let handshake_port = model.value(server, "reality_handshake_server_port");
            if (model.value(server, "tls_server_name") == "" && handshake != "")
                server.tls_server_name = handshake;
            if ((handshake != "" && handshake != server.tls_server_name) || (handshake_port != "" && handshake_port != "443"))
                push(ctx.warnings, what + " hands unknown clients to " + server.tls_server_name + ":443 instead of " +
                    (handshake || server.tls_server_name) + ":" + (handshake_port || "443"));
        }

        // A link carries one host.
        let hosts = model.list(server, "transport_hosts");
        if (length(hosts) > 0 && model.value(server, "transport") == "http" && model.value(server, "transport_host") == "")
            server.transport_host = hosts[0];

        // The released dialog listened on 0.0.0.0 yet handed out IPv6 links; :: serves both.
        let public_host = replace(trim(model.value(server, "public_host")), /^\[|\]$/g, "");
        if (model.value(server, "listen") == "0.0.0.0" && core_ip.valid_ipv6(public_host))
            server.listen = "::";

        if (protocol == "json_inbound")
            migrate_json_inbound(server, ctx);

        for (let key in keys(server))
            if (substr(key, 0, 8) == "mtproto_")
                delete server[key];
        model.unset(server, REMOVED_SERVER_OPTIONS);
    }
    // The certificates it issued now live in the servers' options.
    push(ctx.after_commit, paths.certificates);
}

// ---------------------------------------------------------------------------- subscriptions

function remote_source(subscription) {
    return match(lc(trim(model.value(subscription, "url"))), /^https?:\/\//) != null;
}

// The clients 1.0.x went on to when a panel refused its own User-Agent, and the headers it sent
// besides those a new subscription starts with.
const FALLBACK_USER_AGENTS = [ "Happ", "v2rayN", "v2rayNG", "Mihomo", "Clash.Meta" ];
const RELEASED_EXTRA_HEADERS = [ "Accept-Language: ru-RU,en,*", "X-Device-Locale: EN" ];

// 1.0.x kept the User-Agent that worked beside its last good download, by section and position.
function working_user_agent(owner, position, address) {
    let base = paths.subscription_cache + owner + "-subscription-" + position;
    if (trim(fs.readfile(base + ".url") ?? "") != address)
        return "";
    let agent = trim(fs.readfile(base + ".user_agent") ?? "");
    return agent in FALLBACK_USER_AGENTS ? agent : "";
}

// 1.0.5 sent the User-Agent of the installed core first when it chose one itself, unless a panel
// had needed another, and an HWID unless told one; with what else it sent, they become the
// headers. Its server names carried the prefix, which the provider now adds.
function migrate_subscriptions(config) {
    let counters = {};
    let positions = {};
    for (let subscription in model.of_type(config, "subscription_url")) {
        let owner = model.value(subscription, "section");
        let address = trim(model.value(subscription, "url"));
        if (address != "")
            positions[owner] = (positions[owner] ?? 0) + 1;

        if (remote_source(subscription)) {
            let auto_agent = model.present(subscription, "auto_user_agent")
                ? model.flag(subscription, "auto_user_agent", true)
                : model.value(subscription, "user_agent") == "";
            let auto_hwid = model.present(subscription, "auto_hwid")
                ? model.flag(subscription, "auto_hwid", true)
                : model.value(subscription, "hwid") == "";
            let hwid = trim(model.value(subscription, "hwid"));
            let lines = headers.default_header_lines(auto_hwid || hwid == "" ? null : hwid);
            let agent = auto_agent
                ? working_user_agent(owner, positions[owner], address)
                : trim(model.value(subscription, "user_agent")) || "sing-box";
            if (agent != "")
                lines = map(lines, (line) => lc(substr(line, 0, 11)) == "user-agent:" ? "User-Agent: " + agent : line);
            subscription.header = [ ...lines, ...RELEASED_EXTRA_HEADERS ];
        }

        counters[owner] = (counters[owner] ?? 0) + 1;
        let prefix = trim(model.value(subscription, "node_prefix"));
        if (model.flag(subscription, "prefix_nodes", false) && prefix != "")
            subscription.override_prefix = prefix + " ";
        if (trim(model.value(subscription, "tag")) == "")
            subscription.tag = prefix || "sub" + counters[owner];

        model.unset(subscription, [
            "auto_user_agent", "user_agent", "auto_hwid", "hwid", "prefix_nodes", "node_prefix",
            "include_urltest_groups", "hide_urltest_group_outbounds", "hide_detour_outbounds"
        ]);
    }
}

// ------------------------------------------------------------------------------ interfaces

// The dialog asks for a display name, which was the interface's own.
function migrate_interfaces(config) {
    for (let item in model.of_type(config, "section_interface")) {
        if (trim(model.value(item, "display_name")) == "")
            item.display_name = model.value(item, "name");
        if (model.present(item, "domain_resolver_dns_type") || model.present(item, "domain_resolver_dns_server")) {
            let server = trim(model.value(item, "domain_resolver_dns_server")) || "8.8.8.8";
            item.domain_resolver_dns_server = [ dns_uri(model.value(item, "domain_resolver_dns_type") || "udp", server) ];
        }
        delete item.domain_resolver_dns_type;
    }
}

// ------------------------------------------------------------------------------ server filters

function country_flag(country) {
    country = uc(trim(as_string(country)));
    if (match(country, /^[A-Z]{2}$/) == null)
        return "";
    let letter = (code) => {
        let point = 0x1f1e6 + code - 65;
        return chr(0xf0 | ((point >> 18) & 0x07)) + chr(0x80 | ((point >> 12) & 0x3f)) +
            chr(0x80 | ((point >> 6) & 0x3f)) + chr(0x80 | (point & 0x3f));
    };
    return letter(ord(country, 0)) + letter(ord(country, 1));
}

// The first of the names an option had, as 1.0.5 read a list under either.
function first_list(item, keys) {
    for (let key in keys)
        if (item[key] != null)
            return filter(map(model.list(item, key), (value) => trim(as_string(value))), (value) => value != "");
    return [];
}

function pattern(regexes, countries) {
    let parts = [ ...regexes ];
    for (let country in countries) {
        let flag = country_flag(country);
        if (flag != "" && !(flag in parts))
            push(parts, flag);
    }
    if (length(parts) <= 1)
        return parts[0] ?? "";
    return join("|", map(parts, (part) => "(?:" + part + ")"));
}

const PROTOCOLS = [ "vless", "vmess", "trojan", "shadowsocks", "socks", "http", "hysteria2", "direct" ];

function filter_side(item, side, level) {
    let aliases = side == "include" && level
        ? { outbounds: [ "include_outbounds", "server_name" ], regex: [ "include_regex", "regex" ], countries: [ "include_countries", "country" ] }
        : { outbounds: [ side + "_outbounds" ], regex: [ side + "_regex" ], countries: [ side + "_countries" ] };
    let regexes = first_list(item, aliases.regex);
    let result = {
        names: first_list(item, aliases.outbounds),
        pattern: pattern(filter(regexes, (value) => regex_valid(value)), first_list(item, aliases.countries)),
        countries: length(first_list(item, aliases.countries)) > 0,
        unreadable: filter(regexes, (value) => !regex_valid(value)),
        protocols: [],
        lost: []
    };
    if (model.flag(item, side + "_proxy_parameters", false)) {
        result.protocols = filter(model.list(item, side + "_protocols"), (value) => value in PROTOCOLS);
        for (let key in [ "transports", "securities" ])
            push(result.lost, ...model.list(item, side + "_" + key));
        result.parameters = true;
    }
    return result;
}

// 1.0.5 kept servers by name, pattern and country, and also by protocol, transport and security.
// 2.0.0 filters by name and pattern, and by protocol as the types it leaves out; countries became
// their flags in the name, and transports and securities have no counterpart.
function migrate_filter(item, level, what, ctx) {
    let mode = model.value(item, "filter_mode") || (level ? "include" : "disabled");
    let include = filter_side(item, "include", level);
    let exclude = filter_side(item, "exclude", level);
    let result = { server_filter_mode: "all", include_outbounds: [], include_regex: "", exclude_outbounds: [], exclude_regex: "", exclude_types: [] };

    if (level && model.flag(item, "direct", false))
        result.server_filter_mode = "direct";
    else if (mode in [ "include", "exclude", "mixed" ]) {
        let lost = [];
        let types = {};
        if (mode != "exclude") {
            result.include_outbounds = include.names;
            result.include_regex = include.pattern;
            if (length(include.protocols) > 0)
                for (let type_name in singbox_constants.FILTERABLE_GROUP_TYPES)
                    if (!(type_name in include.protocols))
                        types[type_name] = true;
            push(lost, ...include.lost);
        }
        if (mode != "include") {
            result.exclude_outbounds = exclude.names;
            result.exclude_regex = exclude.pattern;
            for (let type_name in exclude.protocols)
                types[type_name] = true;
            push(lost, ...exclude.lost);
        }
        result.exclude_types = sort(keys(types));

        let includes_by_name = length(result.include_outbounds) > 0 || result.include_regex != "";
        // Without a name to match, an include filter kept every server of the protocols it named,
        // or every server at all when it named only transports or securities.
        if (mode != "exclude" && !includes_by_name && include.parameters)
            result.server_filter_mode = length(result.exclude_outbounds) > 0 || result.exclude_regex != "" || length(result.exclude_types) > 0
                ? "exclude" : "all";
        else
            result.server_filter_mode = mode == "exclude" ? "exclude" : "include";

        if (length(lost) > 0)
            push(ctx.warnings, what + " no longer tells servers apart by transport or security (" + join(", ", lost) + ")");
        let unreadable = [ ...(mode != "exclude" ? include.unreadable : []), ...(mode != "include" ? exclude.unreadable : []) ];
        if (length(unreadable) > 0)
            push(ctx.warnings, what + " dropped the regular expressions Forkop cannot read: " + join(", ", unreadable));
        if (model.value(item, "detect_server_country") == "country_is" && (include.countries || exclude.countries))
            push(ctx.warnings, what + " matched countries by the server's address; it now matches the country flag in the server's name");
    }

    model.unset(item, [
        "filter_mode", "direct", "detect_server_country", "include_countries", "country", "server_name", "regex",
        "exclude_countries", "include_proxy_parameters", "include_protocols", "include_transports", "include_securities",
        "exclude_proxy_parameters", "exclude_protocols", "exclude_transports", "exclude_securities",
        "include_outbounds", "include_regex", "exclude_outbounds", "exclude_regex"
    ]);
    item.server_filter_mode = result.server_filter_mode;
    for (let key in [ "include_outbounds", "exclude_outbounds", "exclude_types" ])
        if (length(result[key]) > 0)
            item[key] = result[key];
    for (let key in [ "include_regex", "exclude_regex" ])
        if (result[key] != "")
            item[key] = result[key];
}

// ------------------------------------------------------------------------------------ groups

function section_label_by_name(config, section_name) {
    let section = model.find(config, section_name);
    return section != null ? label_of(section) : section_name;
}

// 1.0.5 interrupted connections on a switch unless told not to; 2.0.0 does not unless told to,
// so the choice is written out.
function interrupt_choice(group) {
    return model.flag(group, "interrupt_exist_connections", true) ? "1" : "0";
}

function migrate_urltests(config, ctx) {
    for (let group in model.of_type(config, "urltest")) {
        if (trim(model.value(group, "name")) == "")
            group.name = model.name(group);
        group.interrupt_exist_connections = interrupt_choice(group);
        migrate_filter(group, false, "URLTest '" + group.name + "' in section '" +
            section_label_by_name(config, model.value(group, "section")) + "'", ctx);
        model.unset(group, [ "pin_dashboard", "hide_added_outbounds" ]);
    }
}

// The priority groups of 1.0.5 checked their levels themselves; the fallback groups of the core
// check by their own defaults, so only the check address and the interrupt choice are kept. The
// core takes the first working server of a level in its order, as 1.0.5 did unless told to pick
// the fastest one.
function migrate_priority_groups(config, ctx) {
    for (let group in model.of_type(config, "priority_group")) {
        let address = model.value(group, "health_url");
        let kept = {
            section: group.section,
            name: trim(model.value(group, "name")) || model.name(group),
            interrupt_exist_connections: interrupt_choice(group)
        };
        if (address != "")
            kept.health_check_url = address;
        if (model.flag(group, "pick_fastest", false) || model.flag(group, "switch_to_faster_same_priority", false))
            push(ctx.warnings, "Fallback group '" + kept.name + "' in section '" + section_label_by_name(config, kept.section) +
                "' takes the first working server of a level in its order, not the fastest one: add a URLTest group " +
                "to a level to pick by speed there");
        for (let key in keys(group))
            if (substr(key, 0, 1) != ".")
                delete group[key];
        for (let key, value in kept)
            group[key] = value;
        group[".type"] = "fallback_group";

        for (let level in model.children(config, "priority_level", "group", model.name(group))) {
            level[".type"] = "fallback_level";
            if (trim(model.value(level, "name")) == "")
                level.name = model.name(level);
            migrate_filter(level, true, "Level '" + level.name + "' of fallback group '" + group.name + "' in section '" +
                section_label_by_name(config, model.value(group, "section")) + "'", ctx);
        }
    }
    // A level without its group was never read.
    for (let level in model.of_type(config, "priority_level"))
        model.remove(config, level);
}

// ------------------------------------------------------------------------------------- names

function readable(value) {
    return replace(trim(as_string(value)), /\//g, "／");
}

function json_entries(section) {
    let result = [];
    for (let value in model.list(section, "outbound_jsons")) {
        let outbound = parse_json(value);
        push(result, type(outbound) == "object" ? outbound : null);
    }
    return result;
}

// A JSON outbound's detour reached another JSON outbound of its section by tag, and any outbound
// by the runtime name 1.0.5 gave it: "<section>-out" for a section, "<section>-json-<n>-out" for
// the n-th JSON outbound of one. Those become the names 2.0.0 resolves.
function json_reference(config, section, entries, renamed, value) {
    value = as_string(value);
    if (renamed[value] != null)
        return renamed[value];
    if (length(value) <= 4 || substr(value, -4) != "-out")
        return value;
    let base = substr(value, 0, length(value) - 4);
    let ordinal = match(base, /^(.*)-json-([0-9]+)$/);
    if (ordinal != null && ordinal[1] == model.name(section) && entries[int(ordinal[2]) - 1] != null)
        return entries[int(ordinal[2]) - 1].tag;
    let target = model.find(config, base);
    return target != null && target[".type"] == "section" ? base : value;
}

function rewrite_json_references(config, section, renamed) {
    let values = model.list(section, "outbound_jsons");
    let entries = json_entries(section);
    let changed = false;
    for (let i = 0; i < length(entries); i++) {
        let outbound = entries[i];
        if (outbound == null)
            continue;
        let before = sprintf("%J", outbound);
        for (let key in [ "detour", "default" ])
            if (outbound[key] != null)
                outbound[key] = json_reference(config, section, entries, renamed, outbound[key]);
        if (type(outbound.outbounds) == "array")
            outbound.outbounds = map(outbound.outbounds, (value) => json_reference(config, section, entries, renamed, value));
        if (sprintf("%J", outbound) != before) {
            values[i] = sprintf("%J", outbound);
            changed = true;
        }
    }
    if (changed)
        section.outbound_jsons = values;
}

// Children run as "<section>/<name>", so each name is unique in its section and holds no "/".
// Servers keep their names before groups do; a renamed server joins every filter that named it,
// since a 1.0.5 filter matched all servers of a name.
function unique_child_names(config) {
    for (let section in model.of_type(config, "section")) {
        let taken = {};
        let renamed = {};
        let claim_name = (value, fallback) => {
            let base = readable(value) || fallback;
            let name = claim(taken, base, " #");
            if (name != trim(as_string(value)))
                renamed[trim(as_string(value))] = [ ...(renamed[trim(as_string(value))] ?? []), name ];
            return name;
        };

        let links = section_owned(config, "connection_link", section);
        for (let i = 0; i < length(links); i++)
            links[i].name = claim_name(links[i].name, "Node #" + (i + 1));
        for (let item in section_owned(config, "section_interface", section))
            item.display_name = claim_name(item.display_name, model.value(item, "name"));
        let tunnels = section_owned(config, "tunnel", section);
        for (let i = 0; i < length(tunnels); i++) {
            let endpoint = model.value(tunnels[i], "kind") == "json" ? parse_json(model.value(tunnels[i], "endpoint_json")) : null;
            if (type(endpoint) == "object") {
                endpoint.tag = claim_name(endpoint.tag, "Tunnel #" + (i + 1));
                tunnels[i].endpoint_json = sprintf("%J", endpoint);
            }
            else
                tunnels[i].name = claim_name(tunnels[i].name, "Tunnel #" + (i + 1));
        }
        // A tag reached the first JSON outbound holding it, so that one's new name is followed.
        let values = model.list(section, "outbound_jsons");
        let json_renamed = {};
        let first = {};
        for (let i = 0; i < length(values); i++) {
            let outbound = parse_json(values[i]);
            if (type(outbound) != "object")
                continue;
            let tag_name = as_string(outbound.tag);
            let name = claim_name(tag_name, "JSON outbound " + (i + 1));
            if (!first[tag_name]) {
                first[tag_name] = true;
                if (name != tag_name)
                    json_renamed[tag_name] = name;
            }
            if (name != tag_name) {
                outbound.tag = name;
                values[i] = sprintf("%J", outbound);
                section.outbound_jsons = values;
            }
        }
        rewrite_json_references(config, section, json_renamed);

        let filters = [ ...section_owned(config, "urltest", section) ];
        for (let group in section_owned(config, "fallback_group", section))
            push(filters, ...model.children(config, "fallback_level", "group", model.name(group)));
        for (let item in filters)
            for (let key in [ "include_outbounds", "exclude_outbounds" ]) {
                let names = model.list(item, key);
                let result = [ ...names ];
                for (let value in names)
                    for (let name in renamed[value] ?? [])
                        if (!(name in result))
                            push(result, name);
                if (length(result) != length(names))
                    item[key] = result;
            }

        for (let type_name in [ "urltest", "fallback_group" ])
            for (let group in section_owned(config, type_name, section))
                group.name = claim(taken, readable(group.name) || model.name(group), " #");

        let tags = {};
        let counter = 0;
        for (let subscription in section_owned(config, "subscription_url", section))
            subscription.tag = claim(tags, readable(subscription.tag) || "sub" + ++counter, " #");
    }

    for (let group in model.of_type(config, "fallback_group")) {
        let taken = {};
        for (let level in model.children(config, "fallback_level", "group", model.name(group)))
            level.name = claim(taken, readable(level.name) || model.name(level), " #");
    }

    // Labels are the runtime names of sections and servers, unique together.
    let taken = {};
    for (let tag_name in keys(singbox_constants.RESERVED_TAGS))
        taken[tag_name] = true;
    for (let type_name in [ "section", "server" ])
        for (let section in model.of_type(config, type_name))
            section.label = claim(taken, readable(model.value(section, "label")) || model.name(section), " #");
}

// --------------------------------------------------------------- what the 1.0.x runtime left

const CRONTAB_MARKERS = [ "# forkop-list-update", "# forkop-subscription-update", "# forkop-component-update-check" ];

const dnsmasq = {
    // Where 1.0.x pointed dnsmasq; it kept the previous values in forkop_* options, podkop in podkop_*.
    address: "127.0.0.42",
    prefixes: [ "forkop_", "podkop_" ],
    keys: [ "server", "noresolv", "cachesize", "rebind_protection", "notinterface" ]
};

function value_words(value) {
    return filter(map(type(value) == "array" ? value : split(trim(as_string(value)), /[ \t\r\n]+/),
        (item) => trim(as_string(item))), (item) => item != "");
}

function backup_words(instance, key) {
    for (let prefix in dnsmasq.prefixes) {
        let values = value_words(instance[prefix + key]);
        if (length(values) > 0)
            return values;
    }
    return [];
}

// The edits that undo a 1.0.x takeover of dhcp.@dnsmasq[0].
function dnsmasq_plan(instance, legacy_present, legacy_interfaces) {
    let servers = value_words(instance.server);
    let managed = dnsmasq.address in servers;
    let backed_up = false;
    for (let prefix in dnsmasq.prefixes)
        for (let key in dnsmasq.keys)
            if (instance[prefix + key] != null)
                backed_up = true;

    let plan = { changed: false, set: {}, set_lists: {}, delete_options: [], delete_legacy_instance: false };
    if (!managed && !backed_up && !legacy_present)
        return plan;
    plan.changed = true;

    let saved = backup_words(instance, "server");
    plan.set_lists.server = length(saved) > 0 ? saved : filter(servers, (server) => server != dnsmasq.address);

    let noresolv = join("", backup_words(instance, "noresolv"));
    if (noresolv != "")
        plan.set.noresolv = noresolv;
    else if (managed)
        plan.set.noresolv = "0";

    let cachesize = join("", backup_words(instance, "cachesize"));
    if (cachesize != "")
        plan.set.cachesize = cachesize;
    else if (managed)
        plan.set.cachesize = "150";

    // The takeover stored "__unset__" for a rebind protection that was not set.
    let rebind = join("", backup_words(instance, "rebind_protection"));
    if (rebind == "__unset__")
        push(plan.delete_options, "rebind_protection");
    else if (rebind != "")
        plan.set.rebind_protection = rebind;
    else if (managed && instance.forkop_rebind_protection != null)
        plan.set.rebind_protection = "1";

    let notinterface = backup_words(instance, "notinterface");
    if (length(notinterface) > 0)
        plan.set_lists.notinterface = notinterface;
    else if (legacy_present) {
        let interfaces = value_words(legacy_interfaces);
        if (length(interfaces) == 0)
            interfaces = [ "br-lan" ];
        plan.set_lists.notinterface = filter(value_words(instance.notinterface), (name) => !(name in interfaces));
    }

    for (let prefix in dnsmasq.prefixes)
        for (let key in dnsmasq.keys)
            if (instance[prefix + key] != null)
                push(plan.delete_options, prefix + key);
    plan.delete_legacy_instance = legacy_present;
    return plan;
}

function dnsmasq_summary(plan) {
    let parts = [];
    for (let key, values in plan.set_lists)
        push(parts, key + "='" + join(" ", values) + "'");
    for (let key, value in plan.set)
        push(parts, key + "='" + value + "'");
    if (length(plan.delete_options) > 0)
        push(parts, "removed " + join(", ", plan.delete_options));
    if (plan.delete_legacy_instance)
        push(parts, "removed the dhcp.forkop instance");
    return join("; ", parts);
}

function restore_dnsmasq() {
    let cursor = require("uci").cursor();
    if (!cursor.load("dhcp"))
        return true;
    let instance = null;
    cursor.foreach("dhcp", "dnsmasq", (section) => {
        instance = section;
        return false;
    });
    let legacy = cursor.get_all("dhcp", "forkop");
    let legacy_interfaces = legacy?.interface ?? "";
    if (legacy != null && trim(as_string(legacy_interfaces)) == "")
        legacy_interfaces = cursor.get("forkop", "settings", "source_network_interfaces") ?? "";
    let plan = dnsmasq_plan(instance ?? {}, legacy != null, legacy_interfaces);
    if (!plan.changed)
        return true;

    let name = instance != null ? instance[".name"] : null;
    if (name != null) {
        for (let key, values in plan.set_lists)
            if (length(values) > 0)
                cursor.set("dhcp", name, key, values);
            else
                cursor.delete("dhcp", name, key);
        for (let key, value in plan.set)
            cursor.set("dhcp", name, key, value);
        for (let key in plan.delete_options)
            cursor.delete("dhcp", name, key);
    }
    if (plan.delete_legacy_instance)
        cursor.delete("dhcp", "forkop");
    if (!cursor.commit("dhcp")) {
        exec.log("error", "Failed to restore the dnsmasq configuration Forkop 1.0.x had taken over");
        return false;
    }
    exec.log("info", "Restored the dnsmasq configuration Forkop 1.0.x had taken over: " + dnsmasq_summary(plan));
    if (fs.stat(paths.dnsmasq_init) != null)
        exec.ok([ paths.dnsmasq_init, "restart" ]);
    return true;
}

function remove_crontab_lines() {
    let current = exec.output([ "sh", "-c", "crontab -l 2>/dev/null" ]) ?? "";
    let lines = filter(split(current, "\n"), (line) => line != "");
    let kept = filter(lines, (line) => length(filter(CRONTAB_MARKERS, (marker) => index(line, marker) >= 0)) == 0);
    if (length(kept) == length(lines))
        return true;
    let temporary = "/tmp/forkop-crontab." + common.own_pid();
    let written = fs.writefile(temporary, join("", map(kept, (line) => line + "\n"))) != null &&
        exec.ok([ "crontab", temporary ]);
    fs.unlink(temporary);
    if (!written)
        exec.log("error", "Failed to remove the crontab lines Forkop 1.0.x had added");
    return written;
}

// Runs at every install: an unchanged 1.0.5 configuration is replaced by the package's own
// without a migration, yet the 1.0.x runtime around it is just as stale.
function leftovers() {
    for (let path in paths.leftovers)
        common.remove_tree(path);
    let crontab = remove_crontab_lines();
    let restored = restore_dnsmasq();
    return crontab && restored;
}

return {
    version: "2.0.0",
    types: [
        "settings", "section", "server", "server_client", "subscription_url", "section_interface",
        "connection_link", "urltest", "fallback_group", "fallback_level", "tunnel", "tunnel_peer"
    ],
    steps: [
        connection_aliases,
        section_items_become_children,
        urltest_aliases,
        remove_dpi_sections,
        migrate_settings,
        migrate_section_options,
        migrate_builtin_lists,
        migrate_conditions,
        migrate_json_outbounds,
        migrate_links,
        migrate_cascades,
        migrate_servers,
        migrate_section_proxies,
        migrate_subscriptions,
        migrate_interfaces,
        migrate_urltests,
        migrate_priority_groups,
        unique_child_names
    ],
    leftovers,
    dnsmasq_plan,
    paths
};
