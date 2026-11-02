// The page carries its own copy of a few backend tables; tests/fixtures/page_contract.json holds
// both copies: this file checks the backend, fe-app-forkop/tests/pageContract.test.js the page.

let t = require("t");
let fs = require("fs");
let repo = require("repo");
let fixture = require("fixture");
let constants = require("singbox.constants");
let rulesets = require("singbox.rulesets");
let connections = require("config.connections");
let generator = require("singbox.generator");
let mask = require("diagnostics.mask");
let state_service = require("service.state_service");
let features = require("singbox.features");
let amnezia = require("singbox.amnezia");
let installer = require("service.installer");
let ubus = require("ubus");
let uloop = require("uloop");
let stub = require("stub");

let contract = json(fs.readfile(repo.path("tests/fixtures/page_contract.json")));

t.test("the reserved ports are every port Forkop's own inbounds bind", () => {
    let ports = [ constants.CLASH_API_CONTROLLER_PORT ];
    for (let name in keys(constants))
        if (match(name, /_INBOUND_PORT$/))
            push(ports, constants[name]);
    t.eq(sort(uniq(ports), (a, b) => a - b), contract.reserved_ports);
});

t.test("the reserved tags are the ones Forkop gives its own listeners", () => {
    t.eq(sort(keys(constants.RESERVED_TAGS)), contract.reserved_tags);
});

t.test("the community rule sets are the ones the generator can download, each from its own URL", () => {
    t.eq(sort(keys(rulesets.COMMUNITY_SERVICES)), contract.community_rule_sets);
    let urls = map(contract.community_rule_sets, rulesets.community_url);
    t.eq(length(uniq(urls)), length(urls));
});

t.test("the filterable server types are the ones the validator accepts", () => {
    t.eq(constants.FILTERABLE_PROVIDER_TYPES, contract.provider_types);
    t.eq(constants.FILTERABLE_GROUP_TYPES, contract.group_types);
});

t.test("the reserved override paths are the ones the validator refuses", () => {
    t.eq(constants.RESERVED_OVERRIDE_PATCH_PATHS, contract.reserved_override_patch_paths);
});

t.test("the page checks the domain the generated configuration answers with FakeIP", () => {
    t.eq(constants.FAKEIP_TEST_DOMAIN, contract.check_domains.fakeip);
});

t.test("an unset group option means what the dashboard says it means", () => {
    fixture.seed({
        section: [ { ".name": "proxy", action: "connection" } ],
        urltest: [ { ".name": "fast", section: "proxy", name: "Fast" } ],
        fallback_group: [ { ".name": "safe", section: "proxy", name: "Safe" } ]
    });
    connections.load();
    let section = { ".name": "proxy" };

    let urltest = contract.urltest_defaults;
    t.eq(connections.urltest_testing_url(section, "fast"), urltest.testing_url);
    t.eq(connections.urltest_expected_status(section, "fast"), urltest.expected_status);
    t.eq(connections.urltest_check_interval(section, "fast"), urltest.check_interval);
    t.eq(int(connections.urltest_tolerance(section, "fast")), urltest.tolerance);
    t.eq(connections.urltest_idle_timeout(section, "fast"), "", "left to sing-box");
    t.eq(constants.URLTEST_DEFAULT_IDLE_TIMEOUT, urltest.idle_timeout, "what sing-box applies");
    t.eq(connections.urltest_interrupt_exist_connections(section, "fast"), urltest.interrupt_exist_connections);

    let fallback = contract.fallback_defaults;
    t.eq(connections.fallback_group_health_check_url(section, "safe"), fallback.health_check_url);
    t.eq(connections.fallback_group_health_check_interval(section, "safe"), fallback.health_check_interval);
    t.eq(connections.fallback_group_health_check_timeout(section, "safe"), fallback.health_check_timeout);
    t.eq(connections.fallback_group_attempt_timeout(section, "safe"), fallback.attempt_timeout);
    t.eq(connections.fallback_group_expected_status(section, "safe"), fallback.expected_status);
    t.eq(connections.fallback_group_idle_timeout(section, "safe"), fallback.idle_timeout);
    t.eq(connections.fallback_group_interrupt_exist_connections(section, "safe"), fallback.interrupt_exist_connections);
});

// LuCI's forms since 2026-05 (not 25.12) delete a field saved at its default, so UCI holds nothing for it.
t.test("an option LuCI dropped at its form default generates what the default generates", () => {
    let generated = (data) => {
        fixture.seed({
            section: [ { ".name": "proxy", enabled: "1", action: "connection" } ],
            connection_link: fixture.links("proxy", [ "socks5://socks.example:1080#Node" ]),
            ...data
        });
        return sprintf("%J", generator.build({ service_address: "192.168.1.1" }));
    };
    let shapes = {
        settings: (values) => ({ settings: fixture.settings({ list_update_enabled: "1", ...values }) }),
        urltest: (values) => ({
            settings: fixture.settings(),
            urltest: [ { ".name": "fast", section: "proxy", name: "Fast", server_filter_mode: "all", ...values } ]
        }),
        fallback_group: (values) => ({
            settings: fixture.settings(),
            fallback_group: [ { ".name": "safe", section: "proxy", name: "Safe", ...values } ],
            fallback_level: [ { ".name": "level", group: "safe", name: "Level", server_filter_mode: "all" } ]
        })
    };
    for (let kind, shape in shapes)
        for (let name, value in contract.defaults_dropped_on_save[kind])
            if (kind != "urltest" || name != "idle_timeout")
                t.eq(generated(shape({ [name]: value })), generated(shape({})), kind + "." + name);
    t.eq(contract.defaults_dropped_on_save.urltest.idle_timeout, constants.URLTEST_DEFAULT_IDLE_TIMEOUT, "left to sing-box, which applies the same");

    let server = contract.defaults_dropped_on_save.server;
    t.eq(generated({ settings: fixture.settings(), server: [
        { ".name": "open", enabled: "1", protocol: "mixed", listen_port: "18081", mixed_auth_enabled: "0", routing_mode: "direct", listen: server.listen } ] }),
        generated({ settings: fixture.settings(), server: [
        { ".name": "open", enabled: "1", protocol: "mixed", listen_port: "18081", mixed_auth_enabled: "0", routing_mode: "direct" } ] }), "server.listen");
    t.eq(generated({ settings: fixture.settings(), server: [
        { ".name": "tail", enabled: "1", protocol: "tailscale", tailscale_auth_key: "tskey-auth-test", routing_mode: "direct", tailscale_control_url: server.tailscale_control_url } ] }),
        generated({ settings: fixture.settings(), server: [
        { ".name": "tail", enabled: "1", protocol: "tailscale", tailscale_auth_key: "tskey-auth-test", routing_mode: "direct" } ] }), "server.tailscale_control_url");

    let tunnel = (values) => ({ settings: fixture.settings(), tunnel: [
        { ".name": "tailnet", section: "proxy", order: "0", kind: "tailscale", name: "Tailnet", tailscale_auth_key: "tskey-auth-test", ...values } ] });
    t.eq(generated(tunnel({ tailscale_control_url: contract.defaults_dropped_on_save.tunnel.tailscale_control_url })), generated(tunnel({})), "tunnel.tailscale_control_url");
});

t.test("an unset path of the core's configuration is the page's default", () => {
    t.eq(constants.config_path({}), contract.defaults_dropped_on_save.settings.config_path);
    t.eq(constants.config_path({ config_path: "/tmp/sing-box/config.json" }), "/tmp/sing-box/config.json");
});

t.test("the state service parks a request as long as the page expects", () => {
    t.eq(state_service.MAX_WAIT_MS, contract.state_wait_ms);
});

// rpcd refuses a method the page's ACL does not list; the one that changes something is a write.
t.test("the page may call every method the state service publishes", () => {
    let acl = json(fs.readfile(repo.path("luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json")))["luci-app-forkop"];
    t.eq(sort([ ...acl.read.ubus.forkop, ...acl.write.ubus.forkop ]), sort(keys(state_service.object_methods())));
    t.eq(acl.write.ubus.forkop, [ "import_config" ]);
});

t.test("the option every password field is stored in is masked in diagnostics", () => {
    for (let field, stored in contract.password_fields) {
        let masked = mask.forkop_config("config tunnel 'probe'\n\toption " + stored + " 'secret-value'\n");
        t.excludes(masked, "secret-value", field);
    }
});

t.test("a link needs what the core needs to dial it", () => {
    for (let entry in contract.link_features)
        t.eq(features.link_features(entry[0]), entry[1], entry[0]);
});

t.test("the AmneziaWG parameters are read by the kinds and sides the page writes them with", () => {
    t.eq(amnezia.PARAMETERS, contract.amnezia_parameters);
});

t.test("the core report the page is built against is the backend's for the base build", () => {
    let base = contract.core_report_base;
    t.eq(features.report(base.tags), base);
});

t.test("the page follows a run of install.sh through the object and methods its runner publishes", () => {
    t.eq(installer.OBJECT_NAME, contract.installer.object);
    t.eq(installer.ACTIONS, contract.installer.actions);
    let dir = stub.tmpdir();
    installer.paths.state = dir + "/state.json";
    installer.paths.output = dir + "/output";
    installer.paths.package_databases = [];
    fs.writefile(installer.paths.state, sprintf("%J", { schema: 1, id: "run-1", action: "update", lang: "en", interactive: true, finished_at: null }));
    ubus.__reset();
    uloop.__reset();
    let methods = null;
    uloop.__on_run(() => {
        methods = sort(keys(ubus.__published(contract.installer.object)));
        uloop.__exit(0, 7);
        uloop.__fire("timer");
    });
    installer.run("run-1");
    t.eq(methods, contract.installer.methods);
});

t.done();
