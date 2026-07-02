#!/usr/bin/env ucode

let common = require("core.common");
let runtime_constants = require("singbox.constants");

let option = common.option;
let bool_option = common.bool_option;

function bool_value(value) {
    return value === true || value == "1" || value == "true" || value == "yes" || value == "on";
}

function config(settings, runtime) {
    let output_network_interface = option(settings, "output_network_interface", "");
    let mwan3_active = type(runtime) == "object" && bool_value(runtime.mwan3_active);
    let result = {
        rules: [
            { action: "sniff", inbound: [ runtime_constants.TPROXY_INBOUND_TAG, runtime_constants.DNS_INBOUND_TAG ] },
            { action: "hijack-dns", port: 53 },
            { action: "hijack-dns", protocol: "dns" },
            { action: "reject", ip_version: 6 }
        ],
        rule_set: [],
        final: runtime_constants.DIRECT_OUTBOUND_TAG,
        auto_detect_interface: output_network_interface == "" && !mwan3_active,
        default_domain_resolver: runtime_constants.DNS_SERVER_TAG,
        default_mark: runtime_constants.OUTBOUND_MARK
    };

    if (output_network_interface != "")
        result.default_interface = output_network_interface;
    if (bool_option(settings, "disable_quic", false))
        push(result.rules, { action: "reject", inbound: runtime_constants.TPROXY_INBOUND_TAG, protocol: "quic" });

    return result;
}

function target(section, outbound_tag_name) {
    let action = option(section, "action", "");
    if (action == "proxy" || action == "outbound" || action == "vpn" ||
        action == "byedpi" || action == "zapret" || action == "zapret2")
        return { action: "route", outbound: outbound_tag_name };
    if (action == "bypass")
        return { action: "route", outbound: runtime_constants.BYPASS_OUTBOUND_TAG };
    if (action == "block")
        return { action: "reject" };
    return { unsupported: "unsupported action " + action };
}

function has_resolve_matchers(rule) {
    return rule.domain != null || rule.domain_suffix != null || rule.domain_keyword != null ||
        rule.domain_regex != null || rule.rule_set != null;
}

function resolve_rule_for_section(section, route_rule) {
    let action = option(section, "action", "");
    let should_resolve = action == "byedpi" ||
        ((action == "proxy" || action == "outbound" || action == "vpn") &&
            bool_option(section, "resolve_real_ip_for_routing", false));

    if (!should_resolve)
        return null;

    if (!has_resolve_matchers(route_rule)) {
        return {
            warning: "Resolve real IP is enabled for '" + section[".name"] + "', but no domain or rule-set matchers found"
        };
    }

    let resolve_rule = {};
    for (let key in [ "inbound", "source_ip_cidr", "domain", "domain_suffix", "domain_keyword", "domain_regex", "rule_set", "port", "port_range" ]) {
        if (route_rule[key] != null)
            resolve_rule[key] = route_rule[key];
    }
    resolve_rule.action = "resolve";
    resolve_rule.server = runtime_constants.DNS_SERVER_TAG;

    return { rule: resolve_rule };
}

return {
    config,
    target,
    has_resolve_matchers,
    resolve_rule_for_section
};
