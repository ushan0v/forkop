export const FORKOP_UCI_PACKAGE = 'forkop';
export const FORKOP_LUCI_APP_VERSION = '__COMPILED_VERSION_VARIABLE__';
export const FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT =
  'forkop:action-providers-availability';
export const FAKEIP_CHECK_DOMAIN = 'fakeip.podkop.fyi';
export const IP_CHECK_DOMAIN = 'ip.podkop.fyi';
export const DEFAULT_LATENCY_TEST_URL = 'https://www.gstatic.com/generate_204';
export const LATENCY_TEST_URL_OPTIONS = [
  DEFAULT_LATENCY_TEST_URL,
  'https://cp.cloudflare.com/generate_204',
  'https://captive.apple.com',
  'https://connectivity-check.ubuntu.com',
];

export const REGIONAL_OPTIONS = [
  'russia_inside',
  'russia_outside',
  'ukraine_inside',
];

export const ALLOWED_WITH_RUSSIA_INSIDE = [
  'russia_inside',
  'meta',
  'twitter',
  'discord',
  'telegram',
  'cloudflare',
  'google_ai',
  'google_play',
  'hetzner',
  'ovh',
  'hodca',
  'roblox',
  'digitalocean',
  'cloudfront',
];

export const DOMAIN_LIST_OPTIONS = {
  russia_inside: 'Russia inside',
  russia_outside: 'Russia outside',
  ukraine_inside: 'Ukraine',
  geoblock: 'Geo Block',
  block: 'Block',
  porn: 'Porn',
  news: 'News',
  anime: 'Anime',
  youtube: 'Youtube',
  discord: 'Discord',
  meta: 'Meta',
  twitter: 'Twitter (X)',
  hdrezka: 'HDRezka',
  tiktok: 'Tik-Tok',
  telegram: 'Telegram',
  cloudflare: 'Cloudflare',
  google_ai: 'Google AI',
  google_play: 'Google Play',
  hodca: 'H.O.D.C.A',
  roblox: 'Roblox',
  ads_hagezi_pro: 'Ads (Hagezi Pro)',
  supercell: 'Supercell',
  github: 'GitHub',
  hetzner: 'Hetzner ASN',
  ovh: 'OVH ASN',
  digitalocean: 'Digital Ocean ASN',
  cloudfront: 'CloudFront ASN',
};

export const DNS_SERVER_OPTIONS = {
  '1.1.1.1': '1.1.1.1 (Cloudflare)',
  '8.8.8.8': '8.8.8.8 (Google)',
  '9.9.9.9': '9.9.9.9 (Quad9)',
  'dns.adguard-dns.com': 'dns.adguard-dns.com (AdGuard Default)',
  'unfiltered.adguard-dns.com':
    'unfiltered.adguard-dns.com (AdGuard Unfiltered)',
  'family.adguard-dns.com': 'family.adguard-dns.com (AdGuard Family)',
};
export const BOOTSTRAP_DNS_SERVER_OPTIONS = {
  '77.88.8.8': '77.88.8.8 (Yandex DNS)',
  '77.88.8.1': '77.88.8.1 (Yandex DNS)',
  '1.1.1.1': '1.1.1.1 (Cloudflare DNS)',
  '1.0.0.1': '1.0.0.1 (Cloudflare DNS)',
  '8.8.8.8': '8.8.8.8 (Google DNS)',
  '8.8.4.4': '8.8.4.4 (Google DNS)',
  '9.9.9.9': '9.9.9.9 (Quad9 DNS)',
  '9.9.9.11': '9.9.9.11 (Quad9 DNS)',
};

export const COMMAND_TIMEOUT = 10000; // 10 seconds
