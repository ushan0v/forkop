let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let core_ip = require("core.ip");
let core_url = require("core.url");
let uci = require("core.uci");
let singbox_constants = require("singbox.constants");
let mask = require("diagnostics.mask");

const LOG_LINES = 50;

// logread's line: ctime, facility.level, then the message with its tag.
const CORE_LINE = /^.{24} [a-z]+\.[a-z]+ sing-box\[/;

let paths = {
    forkop_config: "/etc/config/forkop"
};

function output(argv) {
    return exec.output(argv) ?? "";
}

function log_tail(text) {
    let lines = filter(split(text ?? "", "\n"), (line) => line != "");
    let left = { core: LOG_LINES, forkop: LOG_LINES };
    let kept = [];
    for (let i = length(lines) - 1; i >= 0 && (left.core > 0 || left.forkop > 0); i--)
        if (left[match(lines[i], CORE_LINE) ? "core" : "forkop"]-- > 0)
            unshift(kept, lines[i]);
    return length(kept) == 0 ? "" : join("\n", kept) + "\n";
}

function chains(table) {
    return replace(table, /\tset [^\n]*\{\n(\t\t[^\n]*\n)*\t\}\n\n/g, "");
}

function server_hosts() {
    let result = [];
    for (let section in uci.section_objects(constants.FORKOP_CONFIG_NAME, "server"))
        for (let key in [ "public_host", "tls_server_name" ]) {
            let host = lc(trim(common.option(section, key, "")));
            if (host != "" && match(host, /[a-z]/) != null && index(host, ":") < 0)
                push(result, host);
        }
    return result;
}

// Public resolvers stay readable: which one the router asks matters to any DNS question.
function resolver_addresses(settings) {
    let result = [];
    for (let key in [ "dns_server", "bootstrap_dns_server" ])
        for (let server in common.list_option(settings, key)) {
            let host = core_url.host(server) || server;
            if (core_ip.valid_ip(host))
                push(result, host);
        }
    return result;
}

function report(visibility, checks) {
    let masked = visibility != "raw";
    let settings = uci.get_all(constants.FORKOP_CONFIG_NAME, "settings") ?? {};
    let sing_box = masked ? common.read_json_file(singbox_constants.config_path(settings)) : null;
    let hosts = masked ? sort(uniq([ ...mask.hosts(sing_box), ...server_hosts() ]), (a, b) => length(b) - length(a)) : [];
    let resolvers = resolver_addresses(settings);
    let text = (value) => masked ? mask.text(value, hosts, resolvers) : value;
    let names = (value) => masked ? mask.names(value, hosts) : value;
    let forkop = fs.readfile(paths.forkop_config) ?? "";

    return {
        checks: text(checks ?? ""),
        log: text(log_tail(output([ "logread", "-e", constants.FORKOP_LOG_PATTERN ]))),
        forkop_config: names(masked ? mask.forkop_config(forkop) : forkop),
        nftables: text(chains(output([ "nft", "-t", "list", "table", "inet", constants.NFT_TABLE_NAME ]))),
        ip_rules: text(output([ "ip", "-4", "rule" ]) + output([ "ip", "-6", "rule" ]))
    };
}

return { paths, report };
