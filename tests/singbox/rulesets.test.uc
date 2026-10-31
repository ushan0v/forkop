let t = require("t");
let rulesets = require("singbox.rulesets");

t.test("a list is named for its section and a reference for itself, stably", () => {
    t.ok(rulesets.is_community("youtube"));
    t.ok(!rulesets.is_community("unknown_service"));
    t.eq(rulesets.community_tag("proxy", "discord"), "proxy-discord-community-ruleset");
    t.eq(rulesets.custom_reference_tag("https://example.com/rules.srs"), "inline-custom-ea6fa9f2951d-ruleset");
    t.eq(rulesets.custom_reference_tag("https://example.com/mixed.txt"), "inline-custom-11ae9de91dfd-ruleset");
    t.eq(rulesets.custom_reference_tag("youtube"), "builtin-youtube-ruleset");
});

t.test("a list downloads the file forkop-lists releases under its name", () => {
    let release = "https://github.com/ushan0v/forkop-lists/releases/latest/download/";
    t.eq(rulesets.community_url("ru_blocked_all"), release + "ru-blocked-all.srs");
    t.eq(rulesets.community_url("google_play"), release + "google-play.srs");
    t.eq(rulesets.community_url("x"), release + "x.srs");
});

t.test("only the lists that carry addresses export subnets", () => {
    t.eq(filter(sort(keys(rulesets.COMMUNITY_SERVICES)), rulesets.community_has_subnets),
        [ "ai", "claude", "cloudflare", "digitalocean", "discord", "hetzner", "ovh", "roblox", "ru_blocked_all",
          "ru_blocked_geo", "ru_blocked_rkn", "telegram", "whatsapp", "x" ]);
    t.ok(!rulesets.community_has_subnets("unknown_service"));
});

t.done();
