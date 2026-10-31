// The lists of github.com/ushan0v/forkop-lists by the name a section stores; a release names
// each file after its list, "-" for "_". subnets: the list carries addresses the core exports
// for nftables.
const LISTS_URL = "https://github.com/ushan0v/forkop-lists/releases/latest/download";

const COMMUNITY_SERVICES = {
    ru_blocked_all: { subnets: true },
    ru_blocked_rkn: { subnets: true },
    ru_blocked_geo: { subnets: true },
    ru_only: {},
    ua_blocked: {},
    ai: { subnets: true },
    chatgpt: {},
    claude: { subnets: true },
    cloudflare: { subnets: true },
    digitalocean: { subnets: true },
    discord: { subnets: true },
    facebook: {},
    gemini: {},
    github: {},
    google_play: {},
    hetzner: { subnets: true },
    instagram: {},
    ovh: { subnets: true },
    roblox: { subnets: true },
    spotify: {},
    supercell: {},
    telegram: { subnets: true },
    tiktok: {},
    twitch: {},
    whatsapp: { subnets: true },
    x: { subnets: true },
    youtube: {},
    ads: {}
};

function as_string(value) {
    return value == null ? "" : "" + value;
}

function is_community(name) {
    return type(COMMUNITY_SERVICES[as_string(name)]) == "object";
}

function community_has_subnets(name) {
    return is_community(name) && COMMUNITY_SERVICES[as_string(name)].subnets == true;
}

function community_url(name) {
    return LISTS_URL + "/" + replace(as_string(name), /_/g, "-") + ".srs";
}

// Twelve hex digits naming a rule set reference too long for a tag: two multiplicative hashes
// folded to 24 bits each. The constants are frozen, since changing one renames every inline
// custom rule set in the generated config.
function hash12(value) {
    value = as_string(value);
    let first = 2166136261;
    let second = 16777619;

    for (let i = 0; i < length(value); i++) {
        let code = ord(substr(value, i, 1));
        first = (first * 33 + code) % 4294967296;
        second = (second * 131 + code) % 4294967296;
    }

    return sprintf("%06x%06x", first % 16777216, second % 16777216);
}

function section_tag(section_name, name, kind) {
    kind = as_string(kind);
    return kind == ""
        ? as_string(section_name) + "-" + as_string(name) + "-ruleset"
        : as_string(section_name) + "-" + as_string(name) + "-" + kind + "-ruleset";
}

function community_tag(section_name, community) {
    return section_tag(section_name, community, "community");
}

function custom_reference_tag(reference) {
    reference = as_string(reference);
    return is_community(reference)
        ? "builtin-" + reference + "-ruleset"
        : "inline-custom-" + hash12(reference) + "-ruleset";
}

return {
    COMMUNITY_SERVICES,
    is_community,
    community_has_subnets,
    community_url,
    community_tag,
    custom_reference_tag
};
