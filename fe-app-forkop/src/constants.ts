export const FORKOP_UCI_PACKAGE = 'forkop';
export const FORKOP_LUCI_APP_VERSION = '__COMPILED_VERSION_VARIABLE__';
export const FAKEIP_CHECK_DOMAIN = 'fakeip.podkop.fyi';
// Tags sing-box already uses for Forkop's own objects; a display name becomes a tag verbatim,
// so these are refused. The contract test holds this to singbox/constants.uc.
export const RESERVED_RUNTIME_TAGS = new Set([
  'dns-server',
  'fakeip-server',
  'bootstrap-dns-server',
  'dnsmasq-server',
  'hosts-server',
  'fakeip-dns-rule-tag',
  'fakeip-ruleset-dns-rule-tag',
  'service-fakeip-dns-rule-tag',
  'tproxy-in',
  'tproxy6-in',
  'dns-in',
  'source-dns-in',
  'system-in',
  'system6-in',
  'system-dns-in',
  'service-warp-in',
  'direct-out',
]);

// Actions whose section can carry another section's traffic.
export const DETOUR_TARGET_ACTIONS = ['connection'];

export const TAILSCALE_CONTROL_URL = 'https://controlplane.tailscale.com';

export const DEFAULT_LATENCY_TEST_URL = 'https://www.gstatic.com/generate_204';
export const LATENCY_TEST_URL_OPTIONS = [
  DEFAULT_LATENCY_TEST_URL,
  'https://cp.cloudflare.com/generate_204',
  'https://captive.apple.com',
  'https://connectivity-check.ubuntu.com',
];

// The lists of forkop-lists in the page's order; their names stay untranslated.
export const DOMAIN_LIST_OPTIONS = {
  ru_blocked_all: 'RU Blocked (All)',
  ru_blocked_rkn: 'RU Blocked (RKN)',
  ru_blocked_geo: 'RU Blocked (Geo)',
  ru_only: 'RU Only',
  ua_blocked: 'UA Blocked',
  ai: 'AI',
  chatgpt: 'ChatGPT',
  claude: 'Claude',
  cloudflare: 'Cloudflare',
  digitalocean: 'DigitalOcean',
  discord: 'Discord',
  facebook: 'Facebook',
  gemini: 'Gemini',
  github: 'GitHub',
  google_play: 'Google Play',
  hetzner: 'Hetzner',
  instagram: 'Instagram',
  ovh: 'OVH',
  roblox: 'Roblox',
  spotify: 'Spotify',
  supercell: 'Supercell',
  telegram: 'Telegram',
  tiktok: 'TikTok',
  twitch: 'Twitch',
  whatsapp: 'WhatsApp',
  x: 'X (Twitter)',
  youtube: 'YouTube',
  ads: 'Ads',
};

const RU_BLOCKED_RKN_LISTS = [
  'youtube',
  'discord',
  'facebook',
  'instagram',
  'x',
  'telegram',
  'whatsapp',
  'roblox',
];
const RU_BLOCKED_GEO_LISTS = [
  'chatgpt',
  'claude',
  'gemini',
  'spotify',
  'supercell',
  'tiktok',
];

// The lists forkop-lists builds into a regional list whole, subnets included (its lists.toml).
export const DOMAIN_LIST_INCLUDES: Record<string, string[]> = {
  ru_blocked_all: [
    'ru_blocked_rkn',
    'ru_blocked_geo',
    ...RU_BLOCKED_RKN_LISTS,
    ...RU_BLOCKED_GEO_LISTS,
  ],
  ru_blocked_rkn: RU_BLOCKED_RKN_LISTS,
  ru_blocked_geo: RU_BLOCKED_GEO_LISTS,
};

export const COMMAND_TIMEOUT = 10000;

// The theme's own monospace stack falls back to Courier New on Windows and Linux.
export const MONOSPACE_FONT =
  'ui-monospace, "Cascadia Mono", "SF Mono", SFMono-Regular, Menlo, Consolas, "DejaVu Sans Mono", "Liberation Mono", monospace';
