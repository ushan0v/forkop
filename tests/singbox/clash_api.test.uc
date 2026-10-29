let t = require("t");
let stub = require("stub");
let fs = require("fs");
let fixture = require("fixture");
let repo = require("repo");
let cli = require("service.cli");
let clash = require("singbox.clash_api");
let controller = require("controller").start();

let dir = stub.tmpdir();

function numbers(count) {
    let result = [];
    for (let i = 0; i < count; i++)
        push(result, i);
    return result;
}

function config(address, secret) {
    let path = dir + "/config.json";
    let clash_api = address == null ? null : { external_controller: address, secret: secret ?? "local-secret" };
    fs.writefile(path, sprintf("%J", { experimental: clash_api == null ? {} : { clash_api } }));
    fixture.seed({ settings: { config_path: path, yacd_secret_key: "stale-secret" } });
}

function call(argv) {
    let result = stub.capture(() => cli.main(argv, "/lib"));
    return { status: result.result, reply: result.stdout == "" ? null : json(result.stdout), stderr: result.stderr };
}

// The requests the controller received from here on, each as { line, headers, body }.
let seen = 0;
function received() {
    let all = controller.requests();
    let result = map(slice(all, seen), (text) => {
        let end = index(text, "\r\n\r\n");
        let lines = split(substr(text, 0, end), "\r\n");
        let headers = {};
        for (let line in slice(lines, 1))
            headers[lc(substr(line, 0, index(line, ":")))] = trim(substr(line, index(line, ":") + 1));
        return { line: lines[0], headers, body: substr(text, end + 4) };
    });
    seen = length(all);
    return result;
}

t.test("an allowlisted request reaches the controller as asked, with the secret sing-box runs with", () => {
    config(controller.endpoint);
    controller.reply({ status: 200, body: "{\"url\":\"vless://id@example.com:443\"}" });
    received();
    let result = call([ "clash_api", "GET", "/proxies/provider%2Fnode/link" ]);
    t.eq([ result.status, result.reply.status, json(result.reply.body).url ], [ 0, 200, "vless://id@example.com:443" ]);
    let request = received()[0];
    t.eq(request.line, "GET /proxies/provider%2Fnode/link HTTP/1.0", "the path goes as the page wrote it");
    t.eq([ request.headers.host, request.headers.authorization ], [ controller.endpoint, "Bearer local-secret" ]);

    config(controller.endpoint, "");
    call([ "clash_api", "GET", "/proxies" ]);
    t.eq(received()[0].headers.authorization, null, "a controller without a secret gets no header");
});

t.test("the pages' own requests pass, with their methods and bodies", () => {
    config(controller.endpoint);
    controller.reply({ status: 204 });
    received();
    for (let request in [
        [ "GET", "/providers/proxies", "" ],
        [ "GET", "/tailscale", "" ],
        [ "GET", "/proxies/proxy-out/delay?url=https%3A%2F%2Flatency.example%2Fgenerate_204&timeout=5000", "" ],
        [ "GET", "/proxies/main-out/exit?timeout=8000", "" ],
        [ "GET", "/tailscale/home%2Ftailnet/ping?address=fd7a%3A115c%3Aa1e0%3A%3A2&timeout=5000", "" ],
        [ "PUT", "/proxies/main-out", "{\"name\":\"main-1-out\"}" ],
        [ "PUT", "/proxies/fallback-out", "{\"name\":\"\"}" ],
        [ "PUT", "/providers/rules", "" ],
        [ "PUT", "/providers/proxies/main%2Fsub1", "" ],
        [ "DELETE", "/connections/abc-123", "" ]
    ]) {
        let result = call([ "clash_api", ...request ]);
        t.eq([ result.status, result.reply?.status ], [ 0, 204 ], join(" ", request));
    }
    let requests = received();
    t.eq(map(requests, (request) => request.line), [
        "GET /providers/proxies HTTP/1.0", "GET /tailscale HTTP/1.0",
        "GET /proxies/proxy-out/delay?url=https%3A%2F%2Flatency.example%2Fgenerate_204&timeout=5000 HTTP/1.0",
        "GET /proxies/main-out/exit?timeout=8000 HTTP/1.0",
        "GET /tailscale/home%2Ftailnet/ping?address=fd7a%3A115c%3Aa1e0%3A%3A2&timeout=5000 HTTP/1.0",
        "PUT /proxies/main-out HTTP/1.0", "PUT /proxies/fallback-out HTTP/1.0",
        "PUT /providers/rules HTTP/1.0", "PUT /providers/proxies/main%2Fsub1 HTTP/1.0", "DELETE /connections/abc-123 HTTP/1.0"
    ]);
    t.eq([ requests[5].body, requests[5].headers["content-type"], requests[5].headers["content-length"] ],
        [ "{\"name\":\"main-1-out\"}", "application/json", "21" ]);
    t.eq([ requests[7].body, requests[7].headers["content-length"] ], [ "", null ], "a request without a body sends none");
});

t.test("the reply is handed back as the controller sent it, its status and its body", () => {
    config(controller.endpoint);
    let large = sprintf("{\"proxies\":{%s}}", join(",", map(numbers(4000), (i) => sprintf("\"node-%d\":{\"type\":\"VLESS\",\"history\":[]}", i))));
    controller.reply({ status: 200, body: large });
    t.eq(clash.request("GET", "/proxies", ""), { status: 200, body: large }, "a body larger than one read");
    controller.reply({ status: 404, body: "{\"message\":\"Resource not found\"}" });
    t.eq(clash.request("GET", "/proxies", ""), { status: 404, body: "{\"message\":\"Resource not found\"}" }, "an error status is the controller's answer, not a failure");
    controller.reply({ raw: "HTTP/1.1 204 No Content\r\nDate: Thu, 22 Oct 2026 10:00:00 GMT\r\n\r\n" });
    t.eq(clash.request("PUT", "/proxies/main-out", "{\"name\":\"x\"}"), { status: 204, body: "" });
    received();
});

t.test("only the bodyless bandwidth POST is allowlisted", () => {
    config(controller.endpoint);
    controller.reply({ status: 202, body: "{\"running\":true}" });
    t.eq(clash.request("POST", "/proxies/main%2FAuto/bandwidth", ""), { status: 202, body: "{\"running\":true}" });
    t.eq(call([ "clash_api", "POST", "/proxies/main%2FAuto/bandwidth", "{}" ]).status, 1);
    t.eq(call([ "clash_api", "POST", "/proxies/main%2FAuto/delay", "" ]).status, 1);
    received();
});

t.test("a controller that is not there, answers no HTTP or drops the reply fails the request, naming it", () => {
    for (let reply in [ { raw: "" }, { raw: "SSH-2.0-dropbear\r\n" }, { raw: "HTTP/1.0 200 OK\r\nContent-Type: application/json" } ]) {
        config(controller.endpoint);
        controller.reply(reply);
        let result = call([ "clash_api", "GET", "/proxies" ]);
        t.eq([ result.status, result.reply ], [ 1, null ], reply.raw);
        t.contains(result.stderr, "Clash API request failed: GET /proxies");
    }
    config("127.0.0.1:1");
    let result = call([ "clash_api", "GET", "/proxies" ]);
    t.contains(result.stderr, "Clash API request failed: GET /proxies");
    received();
});

t.test("a reply that does not come in time is given up at the deadline", () => {
    let api = { endpoint: controller.endpoint, secret: "" };
    controller.reply({ status: 200, body: "{}", delay_ms: 3000 });
    let start = clock(true);
    t.eq(clash.exchange(api, "GET", "/providers/rules/events?since=1", { seconds: 1 }), false);
    let waited = clock(true)[0] - start[0];
    t.ok(waited >= 0 && waited < 3, "waited " + waited + " s");
    controller.reply({ status: 200, body: "{}" });
    received();
});

t.test("a reply is decoded as it arrives when the caller asks for it", () => {
    let api = { endpoint: controller.endpoint, secret: "" };
    let body = sprintf("{\"revision\":3,\"providers\":{%s}}", join(",", map(numbers(3000), (i) => sprintf("\"p%d\":{\"revision\":%d}", i, i))));
    controller.reply({ status: 200, body });
    let reply = clash.exchange(api, "GET", "/providers/rules", { seconds: 10, decode: json });
    t.eq([ reply.status, reply.value.revision, length(keys(reply.value.providers)), reply.body ], [ 200, 3, 3000, null ]);
    controller.reply({ status: 200, body: "{\"revision\":" });
    t.eq(clash.exchange(api, "GET", "/providers/rules", { seconds: 10, decode: json }), { status: 200, value: null }, "a body cut short decodes to nothing");
    received();
});

t.test("anything else is refused before it reaches the controller", () => {
    config(controller.endpoint);
    controller.reply({ status: 204 });
    received();
    for (let request in [ [ "GET", "/configs", "" ], [ "PUT", "/configs", "{\"mode\":\"global\"}" ], [ "POST", "/proxies", "{\"name\":\"x\"}" ],
        [ "GET", "/proxies/../configs", "" ], [ "PUT", "/proxies/main-out", "{\"name\":\"x\",\"extra\":1}" ], [ "PUT", "/proxies/main-out", "not-json" ],
        [ "GET", "/proxies/main-out/delay?url=x&timeout=abc", "" ], [ "DELETE", "/connections", "{\"all\":true}" ],
        [ "GET", "/proxies/main-out/exit", "" ], [ "GET", "/proxies/main-out/exit?timeout=5000&url=https%3A%2F%2Fexample.com", "" ],
        [ "GET", "/group/main/exit?timeout=5000", "" ], [ "GET", "/tailscale?tag=x", "" ], [ "PUT", "/tailscale", "" ],
        [ "GET", "/tailscale/tailnet/ping?address=100.64.0.2", "" ], [ "GET", "/tailscale/tailnet/ping?address=phone&timeout=5000", "" ],
        [ "GET", "/tailscale/tailnet/ping?address=100.64.0.2&timeout=5000&size=1200", "" ],
        [ "PUT", "/tailscale/tailnet/ping?address=100.64.0.2&timeout=5000", "" ],
        [ "PUT", "/providers/rules", "{\"name\":\"geosite\"}" ], [ "PUT", "/providers/rules/geosite", "" ],
        [ "GET", "/proxies HTTP/1.0\r\nX-Injected: 1", "" ] ]) {
        let result = call([ "clash_api", ...request ]);
        t.eq([ result.status, result.reply ], [ 1, null ], join(" ", request));
        t.contains(result.stderr, "not allowlisted");
    }
    t.eq(received(), []);
});

t.test("the controller is the address the configuration bound", () => {
    for (let pair in [ [ "192.168.1.1:9090", "192.168.1.1:9090" ], [ "0.0.0.0:9090", "127.0.0.1:9090" ], [ "[::]:9090", "127.0.0.1:9090" ],
        [ "[fd00::1]:9090", "[fd00::1]:9090" ], [ null, "127.0.0.1:9090" ] ]) {
        config(pair[0]);
        t.eq(clash.controller().endpoint, pair[1], "" + pair[0]);
    }
});

t.test("the summary carries the totals and the count, never the connection list", () => {
    config(controller.endpoint);
    controller.reply({ status: 200, body: "{\"downloadTotal\":10,\"uploadTotal\":20,\"memory\":30,\"connections\":[{\"id\":\"a\",\"metadata\":{}},{\"id\":\"b\"}]}" });
    received();
    let result = call([ "clash_summary" ]);
    t.eq(json(result.reply.body), { downloadTotal: 10, uploadTotal: 20, connections: 2 });
    t.eq(received()[0].line, "GET /connections HTTP/1.0");
});

t.test("read deadlines are short while probes through an outbound and updates retain their budget", () => {
    for (let pair in [
        [ "GET", "/proxies", 5 ],
        [ "GET", "/connections", 5 ],
        [ "GET", "/group/main/delay?url=https%3A%2F%2Fexample.com&timeout=40000", 50 ],
        [ "GET", "/proxies/main-out/exit?timeout=8000", 18 ],
        [ "GET", "/tailscale/home%2Ftailnet/ping?address=100.64.0.2&timeout=5000", 15 ],
        [ "PUT", "/providers/rules", 60 ]
    ])
        t.eq(clash.budget(pair[0], pair[1]), pair[2], pair[0] + " " + pair[1]);
});

t.test("the transport loads nothing beyond core, the constants and socket", () => {
    let probe = stub.tmpdir() + "/probe.uc";
    fs.writefile(probe, "require(\"singbox.clash_api\");\nprint(join(\" \", keys(global.modules)), \"\\n\");\n");
    let pipe = fs.popen("ucode -L '" + repo.path("forkop/files/usr/lib") + "' '" + probe + "'", "r");
    let loaded = split(trim(pipe.read("all")), " ");
    pipe.close();
    t.contains(loaded, "singbox.clash_api");
    t.eq(filter(loaded, (name) => substr(name, 0, 5) != "core." &&
        index([ "fs", "socket", "singbox.constants", "singbox.clash_api" ], name) < 0), []);
});

t.done();
