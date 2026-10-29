let t = require("t");
let v = require("validation");
let fixture = require("fixture");

function data(options) {
    return {
        section: [ { ".name": "proxy", enabled: "1", action: "connection" } ],
        connection_link: fixture.links("proxy", [ "socks://127.0.0.1:1080#Node" ]),
        urltest: [ { ".name": "auto", section: "proxy", name: "Auto", bandwidth_enabled: "1", bandwidth_url: "https://download.example/file", ...options } ]
    };
}

t.test("bandwidth qualification is optional and accepts bounded settings", () => {
    v.accepts(data({}));
    v.accepts(data({ bandwidth_enabled: "0", bandwidth_url: "broken", bandwidth_sample_mib: "bad" }));
    v.accepts(data({ bandwidth_interval: "24h", bandwidth_timeout: "30s", bandwidth_sample_mib: "64", bandwidth_minimum_mbps: "100", bandwidth_confirmations: "3" }));
});

t.test("invalid bandwidth settings are refused before generating a core config", () => {
    for (let options in [
        { bandwidth_interval: "1s" }, { bandwidth_timeout: "61s" }, { bandwidth_interval: "169h" },
        { bandwidth_url: "file:///tmp/input" }, { bandwidth_url: "https://user:password@example.com/file" },
        { bandwidth_url: "https://example.com/file#fragment" },
        { bandwidth_sample_mib: "0" }, { bandwidth_sample_mib: "513" }, { bandwidth_sample_mib: "1.5" },
        { bandwidth_minimum_mbps: "0" }, { bandwidth_minimum_mbps: "-1" },
        { bandwidth_confirmations: "11" }, { bandwidth_confirmations: "NaN" }
        , { bandwidth_strategy: "random" }, { bandwidth_speed_tolerance: "101" },
        { bandwidth_adaptive: "1", bandwidth_selected_interval: "1s" },
        { bandwidth_adaptive: "1", bandwidth_selected_interval: "7h" }
    ])
        t.ok(v.run(data(options)).error != null, sprintf("accepted %J", options));
});
t.done();
