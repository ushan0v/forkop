let t = require("t");
let ip = require("core.ip");

t.test("an address or a prefix is one sing-box and nft both read", () => {
    for (let value in [ "192.168.1.1", "0.0.0.0", "10.0.0.0/8", "0.0.0.0/0", "2001:db8::1", "::", "2001:db8::/32", "::ffff:192.0.2.1" ])
        t.ok(ip.ip_family(value) != 0, value);
    t.eq([ ip.ip_family("198.51.100.0/24"), ip.ip_family("fd00::/8") ], [ 4, 6 ]);
});

t.test("a leading zero, a trailing dot or a prefix past the family is not an address", () => {
    for (let value in [ "192.168.01.1", "010.0.0.1", "10.0.0.0/08", "192.168.1.10.", "10.0.0.0/33", "2001:db8::/129",
        "2001:db8::/064", "::ffff:192.0.02.1", "256.1.1.1", "1.2.3", "10.0.0.0/", "/8", "fe80::1%eth0" ]) {
        t.eq(ip.ip_family(value), 0, value);
        t.ok(!ip.valid_ip_or_cidr(value), value);
    }
});

t.test("a public address is one outside every reserved range", () => {
    for (let value in [ "8.8.8.8", "2606:4700::1111" ])
        t.ok(ip.valid_public_ip(value), value);
    for (let value in [ "10.1.2.3", "192.168.1.1", "100.64.0.1", "172.16.0.1", "198.18.0.1", "2001:db8::1", "2001:2::1", "fd00::1", "fe80::1", "08.8.8.8" ])
        t.ok(!ip.valid_public_ip(value), value);
});

t.done();
