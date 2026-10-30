let t = require("t");
let stub = require("stub");
let fs = require("fs");
let repo = require("repo");
let pkg = require("service.package");
let nft = require("nft.apply");
let constants = require("core.constants");
let fixture = require("fixture");
let uci = require("uci");

let dir = stub.tmpdir();
let init = dir + "/forkop-init";
let state_init = dir + "/forkop-state";
let firewall_init = dir + "/firewall";
let include = dir + "/forkop.nft";

pkg.paths.init = init;
pkg.paths.state_service_init = state_init;
pkg.paths.was_running = dir + "/was-running";
pkg.paths.firewall_init = firewall_init;
pkg.paths.firewall_input_include = include;
pkg.paths.rpcd_init = dir + "/rpcd";
pkg.paths.luci_index_cache = [ dir + "/luci-indexcache*" ];
pkg.paths.runtime = [ dir + "/run", dir + "/internal-change" ];
pkg.paths.cache = dir + "/default/cache.db";
pkg.paths.core_workdir = dir + "/default-core";
nft.paths.rt_tables = dir + "/rt_tables";
for (let path in [ state_init, firewall_init, include, pkg.paths.rpcd_init ])
    fs.writefile(path, "");

const RT_TABLES = "100 main\n105 forkop\n1105 forkopx\n200 custom\n";

function leave_runtime() {
    fs.mkdir(dir + "/run");
    fs.mkdir(dir + "/run/bytecode");
    fs.writefile(dir + "/run/bytecode/manifest", "4\n");
    fs.writefile(dir + "/internal-change", "1\n");
}

function runtime_left() {
    return map(pkg.paths.runtime, (path) => fs.stat(path) != null);
}

function run(fn, handlers) {
    stub.commands([ ...(handlers ?? []), [ () => true, {} ] ]);
    let status = fn();
    let commands = stub.command_lines();
    stub.restore();
    return { status, commands };
}

t.test("a removal takes autostart away, stops the service, then drops the routing table name and what it kept in RAM", () => {
    fs.writefile(nft.paths.rt_tables, RT_TABLES);
    leave_runtime();
    let named_at_stop = null;
    let result = run(() => pkg.prerm("remove"), [
        [ init + " stop", () => { named_at_stop = index(fs.readfile(nft.paths.rt_tables), "105 forkop\n") >= 0; return {}; } ]
    ]);
    t.eq(result.status, 0);
    t.eq(result.commands, [ init + " disable", state_init + " disable", state_init + " stop", init + " stop" ]);
    t.ok(named_at_stop, "the stop still finds the table name it removes routes by");
    t.eq(fs.readfile(nft.paths.rt_tables), "100 main\n1105 forkopx\n200 custom\n");
    t.eq(runtime_left(), [ false, false ]);
});

t.test("an upgrade keeps autostart, the table name and the runtime files and remembers a running service", () => {
    fs.writefile(nft.paths.rt_tables, RT_TABLES);
    leave_runtime();
    let result = run(() => pkg.prerm("upgrade"), [ [ init + " status", { status: 0 } ] ]);
    t.eq(result.commands, [ init + " status", init + " stop" ]);
    t.eq(fs.readfile(pkg.paths.was_running), "1\n");
    t.eq(fs.readfile(nft.paths.rt_tables), RT_TABLES);
    t.eq(runtime_left(), [ true, true ]);

    run(() => pkg.prerm("upgrade"), [ [ init + " status", { status: 3 } ] ]);
    t.eq(fs.stat(pkg.paths.was_running), null, "a stopped service is not started after the upgrade");
});

t.test("a removal takes what the core kept for Forkop, an upgrade keeps it", () => {
    let cache = dir + "/cache/cache.db";
    let workdir = dir + "/core";
    fixture.seed({ settings: { cache_path: cache } });
    uci.__seed("sing-box", [ { ".type": "sing-box", ".name": "main", workdir } ]);
    for (let path in [ dir + "/cache", cache + ".rule-sets", workdir, workdir + "/ui", workdir + "/Taildrop" ])
        fs.mkdir(path);
    fs.writefile(cache, "bbolt");
    fs.writefile(cache + ".rule-sets/sub-0a1b2c3d", "vless://secret@203.0.113.1:443#one\n");
    fs.writefile(workdir + "/ui/index.html", "");
    fs.writefile(workdir + "/Taildrop/photo.jpg", "");
    let kept = () => map([ cache, cache + ".rule-sets", workdir + "/ui" ], (path) => fs.stat(path) != null);

    run(() => pkg.prerm("upgrade"), [ [ init + " status", { status: 3 } ] ]);
    t.eq(kept(), [ true, true, true ]);

    fs.writefile(nft.paths.rt_tables, RT_TABLES);
    run(() => pkg.prerm("remove"));
    t.eq(kept(), [ false, false, false ]);
    t.ok(fs.stat(workdir + "/Taildrop/photo.jpg") != null, "the files Taildrop received stay");

    fixture.seed({});
    fs.mkdir(dir + "/default");
    fs.writefile(pkg.paths.cache, "bbolt");
    run(() => pkg.prerm("remove"));
    t.eq(fs.stat(pkg.paths.cache), null, "without settings the cache file is where the core puts it by default");
});

t.test("postinst starts again only what the upgrade stopped", () => {
    fs.writefile(pkg.paths.was_running, "1\n");
    let result = run(() => pkg.postinst(), [ [ "nft list chain", { status: 1 } ] ]);
    t.eq(result.status, 0);
    t.eq(result.commands, [ "logger -t forkop -p user.info [info] Installed Forkop " + constants.FORKOP_VERSION, state_init + " enable", state_init + " restart",
        "nft list chain inet fw4 input", init + " start" ]);
    t.eq(fs.stat(pkg.paths.was_running), null);

    t.eq(run(() => pkg.postinst(), [ [ "nft list chain", { status: 1 } ] ]).commands,
        [ "logger -t forkop -p user.info [info] Installed Forkop " + constants.FORKOP_VERSION, state_init + " enable", state_init + " restart", "nft list chain inet fw4 input" ]);

    fs.writefile(pkg.paths.was_running, "1\n");
    t.eq(run(() => pkg.postinst(), [ [ "nft list chain", { status: 1 } ], [ init + " start", { status: 1 } ] ]).status, 1);
    t.ok(fs.stat(pkg.paths.was_running) != null, "a failed start leaves the mark for the next attempt");
    fs.unlink(pkg.paths.was_running);
});

t.test("postinst loads the firewall include into a running firewall that lacks it, and nowhere else", () => {
    let chain_without = "chain input {\n\tiif \"lo\" accept\n}\n";
    let chain_with = "chain input {\n" + fs.readfile(repo.path("forkop/files/usr/share/nftables.d/chain-pre/input/forkop.nft")) + "}\n";
    function reloads(nft_reply, reload_status) {
        let result = run(() => pkg.postinst(), [ [ "nft list chain", nft_reply ], [ firewall_init + " reload", { status: reload_status ?? 0 } ] ]);
        return filter(result.commands, (line) => line == firewall_init + " reload" || substr(line, 0, 32) == "logger -t forkop -p user.warning");
    }

    t.eq(reloads({ stdout: chain_without }), [ firewall_init + " reload" ]);
    t.eq(reloads({ stdout: chain_with }), [], "a firewall already carrying the accept is left alone");
    t.eq(reloads({ status: 1 }), [], "a firewall the user keeps stopped is not started");
    t.eq(reloads({ stdout: chain_without }, 1), [ firewall_init + " reload",
        "logger -t forkop -p user.warning [warn] Failed to reload the firewall; reload it by hand so that its input chain accepts Forkop's traffic" ]);

    fs.unlink(include);
    t.eq(reloads({ stdout: chain_without }), [], "without the shipped include there is nothing to load");
    fs.writefile(include, "");
});

t.test("the LuCI app starts the state service on install and stops it on removal", () => {
    fs.writefile(dir + "/luci-indexcache", "");
    fs.writefile(dir + "/luci-indexcache.abc", "");
    let result = run(() => pkg.luci_postinst());
    t.eq(result.commands, [ state_init + " enable", state_init + " restart", pkg.paths.rpcd_init + " reload" ]);
    t.eq(fs.glob(dir + "/luci-indexcache*"), []);
    t.eq(run(() => pkg.luci_prerm()).commands, [ state_init + " stop" ]);
});

t.test("the command line runs the hooks and returns their status", () => {
    fs.writefile(nft.paths.rt_tables, RT_TABLES);
    let result = run(() => require("service.cli").main([ "package_prerm", "upgrade" ], "/lib"), [ [ init + " status", { status: 3 } ] ]);
    t.eq([ result.status, result.commands ], [ 0, [ init + " status", init + " stop" ] ]);
});

t.done();
