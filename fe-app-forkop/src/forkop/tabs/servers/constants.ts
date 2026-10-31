export const STYLE_ID = 'forkop-server-styles';

export const DEFAULT_PROTOCOL = 'mixed';

export const CLIENT_TYPE = 'server_client';

export const CLIENT_OWNER_OPTION = 'server';

export const MAX_CLIENT_NAME_LENGTH = 64;

// Ports Forkop's own sing-box binds; a server taking one stops the whole service.
export const RESERVED_PORTS = [
  ['53', _('Forkop DNS')],
  ['1602', _('Forkop transparent proxy')],
  ['1603', _('Forkop transparent proxy')],
  ['1604', _('Forkop transparent proxy')],
  ['1605', _('Forkop transparent proxy')],
  ['4536', _('Forkop service proxy')],
  ['9090', _('sing-box Clash API')],
];

// Reachable worldwide, TLS 1.3 with X25519 and HTTP/2, not behind a CDN rewriting the handshake.
export const CAMOUFLAGE_SITES = [
  'www.microsoft.com',
  'www.apple.com',
  'swdist.apple.com',
  'www.samsung.com',
  'www.nvidia.com',
  'www.amd.com',
  'www.tesla.com',
  'dl.google.com',
  'www.bing.com',
  'www.wolframalpha.com',
];

// Best first. 2022 methods take a base64 key of an exact length; older AEAD ones derive it from any
// password. The default matches what panels hand out. 2022-blake3-chacha20-poly1305 has no identity
// header for a client key of its own (SIP022 defines it for AES only), so the core refuses it on a
// server with clients.
export const SHADOWSOCKS_METHODS = [
  { id: '2022-blake3-aes-256-gcm', keyBytes: 32 },
  { id: '2022-blake3-aes-128-gcm', keyBytes: 16 },
  { id: 'aes-256-gcm', keyBytes: 0 },
  { id: 'aes-128-gcm', keyBytes: 0 },
  { id: 'chacha20-ietf-poly1305', keyBytes: 0 },
];

export const TRANSPORTS = [
  ['tcp', 'TCP'],
  ['ws', 'WebSocket'],
  ['grpc', 'gRPC'],
  ['http', 'HTTP'],
  ['httpupgrade', 'HTTPUpgrade'],
  ['xhttp', 'XHTTP'],
];

// Only these leave the negotiated protocol to the configuration; the rest pin it.
export const ALPN_PROTOCOLS = ['vless', 'vmess', 'trojan', 'anytls'];

// REALITY clients refuse a link without a fingerprint.
export const DEFAULT_CLIENT_FINGERPRINT = 'chrome';

export const CLIENT_FINGERPRINTS = [
  'chrome',
  'firefox',
  'edge',
  'safari',
  'ios',
  'android',
  'random',
];

export const CLIENT_KEYS = [
  'name',
  'uuid',
  'password',
  'flow',
  'routing_override',
  'routing_mode',
  'routing_section',
];

// Rules clones the shared rule set for the account, only when its server does not already.
export const CLIENT_ROUTING_MODES = [
  ['rules', _('Rules')],
  ['direct', _('Direct')],
  ['section', _('Section')],
];

// Credentials the protocol no longer uses are dropped when it changes, so they do not linger in
// diagnostics or the config signature.
export const CLIENT_ROUTING_KEYS = [
  'routing_override',
  'routing_mode',
  'routing_section',
];
