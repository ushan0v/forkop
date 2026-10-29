let t = require("t");
let fixture = require("fixture");
let q = require("sbconfig");
let generator = require("singbox.generator");

function build(options) {
    fixture.seed({
        settings: { dns_server: "1.1.1.1" },
        section: [ { ".name": "proxy", enabled: "1", action: "connection" } ],
        connection_link: fixture.links("proxy", [ "socks://127.0.0.1:1080#Node" ]),
        urltest: [ { ".name": "auto", section: "proxy", name: "Auto", ...options } ]
    });
    return q.outbound(generator.build({ service_address: "127.0.0.1" }), "proxy/Auto");
}

t.test("ordinary URLTest does not emit the optional bandwidth schema", () => {
    t.eq(build({}).bandwidth_test, null);
    t.eq(build({ bandwidth_enabled: "0", bandwidth_url: "broken" }).bandwidth_test, null);
});

t.test("bandwidth settings reach the native core without rewriting member filters", () => {
    let result = build({ bandwidth_enabled: "1", bandwidth_url: "https://download.example/file", bandwidth_sample_mib: "64", bandwidth_minimum_mbps: "80", bandwidth_confirmations: "3" });
    t.eq(result.bandwidth_test, { enabled: true, url: "https://download.example/file", interval: "6h", timeout: "10s", max_bytes: 67108864, minimum_mbps: 80, confirmations: 3 });
    t.eq(result.outbounds, [ "proxy/Node" ]);
});
t.done();
