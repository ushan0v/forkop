// Stored as the native openvpn-client endpoint; fields the dialog does not edit are carried through.

import { OPENVPN_DEFAULT_PORT } from '../../../../helpers/parseOpenVPNConfig';
import {
  isValidHost,
  isValidPort,
  parseHostPort,
  unbracketHost,
} from '../../../../validators/hostPort';
import { message } from '../../../../validators/messages';
import { validateSubnet } from '../../../../validators/validateSubnet';
import { isIPv4, isIPv6 } from '../../../../validators/validateIp';
import { isRouterPath } from '../../../../helpers/material';
import { normalizeOptionValues } from '../../../cbi/listValues';

type Endpoint = Record<string, unknown>;
type Tls = Record<string, unknown>;

export const DATA_CIPHERS = [
  'AES-256-GCM',
  'AES-128-GCM',
  'CHACHA20-POLY1305',
  'AES-192-GCM',
  'AES-256-CBC',
  'AES-192-CBC',
  'AES-128-CBC',
  'CAMELLIA-256-CBC',
  'CAMELLIA-128-CBC',
  'BF-CBC',
  'NONE',
];

export const STATIC_CIPHERS = DATA_CIPHERS.filter(
  (cipher) => !/-(GCM|POLY1305)$/.test(cipher),
);

export const DIGESTS = ['SHA1', 'SHA256', 'SHA384', 'SHA512', 'SHA224', 'MD5'];

// compress and comp-lzo as a profile spells them, and the fields they set.
const COMPRESSIONS: Record<string, Endpoint> = {
  stub: { compression: 'stub' },
  'stub-v2': { compression: 'stub-v2' },
  lz4: { compression: 'lz4', allow_compression: 'asym' },
  'lz4-v2': { compression: 'lz4-v2', allow_compression: 'asym' },
  'lzo-no': { compression_lzo: 'no' },
  'lzo-yes': { compression_lzo: 'yes', allow_compression: 'asym' },
  'lzo-adaptive': { compression_lzo: 'adaptive', allow_compression: 'asym' },
};

export const COMPRESSION_LABELS: Record<string, string> = {
  stub: 'compress stub',
  'stub-v2': 'compress stub-v2',
  lz4: 'compress lz4',
  'lz4-v2': 'compress lz4-v2',
  'lzo-no': 'comp-lzo no',
  'lzo-yes': 'comp-lzo yes',
  'lzo-adaptive': 'comp-lzo adaptive',
};

// Anything beyond these (dial fields or pull filters a migration left) is kept as it was.
const MANAGED = [
  'type',
  'tag',
  'mode',
  'network',
  'server',
  'server_port',
  'servers',
  'remote_random',
  'username',
  'password',
  'tls',
  'static_key',
  'static_key_path',
  'key_direction',
  'cipher',
  'address',
  'peer_address',
  'peer_address_ipv6',
  'data_ciphers',
  'data_ciphers_fallback',
  'auth',
  'compression',
  'compression_lzo',
  'allow_compression',
  'mtu',
  'fragment',
  'mss_fix',
  'mss_fix_disabled',
  'ping_interval',
  'ping_restart',
  'ping_restart_disabled',
  'renegotiate_interval',
  'renegotiate_disabled',
];

const MANAGED_TLS = [
  'certificate',
  'certificate_path',
  'client_certificate',
  'client_certificate_path',
  'client_key',
  'client_key_path',
  'control_wrap',
  'server_name',
  'server_name_type',
  'remote_certificate_tls',
  'ns_certificate_type',
  'peer_fingerprint',
  'certificate_profile',
  'version_min',
  'cipher',
];

// The advanced fields and what each holds while it is left alone.
const ADVANCED_DEFAULTS: Record<string, unknown> = {
  openvpn_remote_random: '0',
  openvpn_server_name: '',
  openvpn_server_name_type: 'name',
  openvpn_verify_purpose: 'server',
  openvpn_peer_fingerprint: [],
  openvpn_certificate_profile: '',
  openvpn_tls_version_min: '',
  openvpn_tls_cipher: '',
  openvpn_data_ciphers: [],
  openvpn_data_ciphers_fallback: '',
  openvpn_auth: '',
  openvpn_compression: '',
  openvpn_mtu: '',
  openvpn_fragment: '',
  openvpn_mss_fix: '',
  openvpn_ping_interval: '',
  openvpn_ping_restart: '',
  openvpn_renegotiate: '',
};

function text(value: unknown) {
  return `${value ?? ''}`;
}

export function trimmed(value: unknown) {
  return text(value).trim();
}

function list(value: unknown): string[] {
  return value == null
    ? []
    : Array.isArray(value)
      ? value.map(text)
      : [text(value)];
}

// The content, or the path the core reads it from on the router.
function material(object: Record<string, unknown>, key: string) {
  const content = list(object[key]).join('\n').trim();
  return content || trimmed(object[`${key}_path`]);
}

function setMaterial(
  object: Record<string, unknown>,
  key: string,
  value: unknown,
) {
  const content = trimmed(value);
  if (!content) return;
  if (isRouterPath(content)) {
    object[`${key}_path`] = content;
  } else {
    object[key] = content.split(/\r?\n/).map((line) => line.trimEnd());
  }
}

// A duration of the endpoint in the seconds the dialog asks for.
function secondsValue(value: unknown) {
  const match = /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/.exec(trimmed(value));
  if (!match || !trimmed(value)) return trimmed(value);
  const [, hours = '0', minutes = '0', seconds = '0'] = match;
  return `${Number(hours) * 3600 + Number(minutes) * 60 + Number(seconds)}`;
}

function formatServer(server: unknown, port: unknown, network: string) {
  const host = trimmed(server);
  const address = isIPv6(host) ? `[${host}]` : host;
  const scheme = network ? `${network}://` : '';
  return `${scheme}${address}:${port ?? OPENVPN_DEFAULT_PORT}`;
}

// Host and port, with tcp:// or udp:// before a server not on the tunnel's protocol.
export function parseOpenVPNServer(value: unknown) {
  let rest = trimmed(value);
  let network = '';
  const scheme = /^(udp|tcp):\/\//i.exec(rest);
  if (scheme) {
    network = scheme[1].toLowerCase();
    rest = rest.slice(scheme[0].length);
  }
  const hostPort = parseHostPort(rest);
  if (hostPort) {
    return isValidPort(hostPort.port)
      ? {
          server: unbracketHost(hostPort.host),
          port: Number(hostPort.port),
          network,
        }
      : null;
  }
  return rest && !rest.includes('/') && isValidHost(rest)
    ? { server: unbracketHost(rest), port: OPENVPN_DEFAULT_PORT, network }
    : null;
}

function compressionValue(endpoint: Endpoint) {
  const lzo = trimmed(endpoint.compression_lzo);
  if (['no', 'yes', 'adaptive'].includes(lzo)) return `lzo-${lzo}`;
  const compression = trimmed(endpoint.compression);
  return COMPRESSIONS[compression] ? compression : '';
}

function verifyPurpose(tls: Tls) {
  if (trimmed(tls.remote_certificate_tls) !== 'none') return 'server';
  return trimmed(tls.ns_certificate_type) === 'server' ? 'ns' : 'none';
}

function keyDirectionValue(value: unknown) {
  return value === 'client' ? '1' : value === 'server' ? '0' : 'both';
}

// LuCI's forms since 2026-05 (not 25.12) delete a field saved at its default, so no value means it.
function keyDirectionName(value: unknown) {
  return value === '0' ? 'server' : value === 'both' ? '' : 'client';
}

function advancedInUse(settings: ChildSettings) {
  return Object.entries(ADVANCED_DEFAULTS).some(([key, empty]) =>
    Array.isArray(empty)
      ? normalizeOptionValues(settings[key]).length > 0
      : trimmed(settings[key]) !== trimmed(empty),
  );
}

function preservedFields(endpoint: Endpoint) {
  const preserved: Endpoint = {};
  Object.entries(endpoint).forEach(([key, value]) => {
    if (!MANAGED.includes(key)) preserved[key] = value;
  });
  const tls = (endpoint.tls || {}) as Tls;
  const preservedTls: Tls = {};
  Object.entries(tls).forEach(([key, value]) => {
    if (!MANAGED_TLS.includes(key)) preservedTls[key] = value;
  });
  if (Object.keys(preservedTls).length) preserved.tls = preservedTls;
  return preserved;
}

export function openVPNInitialSettings(endpoint: Endpoint): ChildSettings {
  const tls = (endpoint.tls || {}) as Tls;
  const wrap = (tls.control_wrap || {}) as Record<string, unknown>;
  const network = trimmed(endpoint.network).replace(/[46]$/, '') || 'udp';
  const staticMode = endpoint.mode === 'static_key';
  const servers =
    Array.isArray(endpoint.servers) && endpoint.servers.length
      ? (endpoint.servers as Endpoint[]).map((entry) => {
          const own = trimmed(entry.network).replace(/[46]$/, '');
          return formatServer(
            entry.server,
            entry.server_port,
            own && own !== network ? own : '',
          );
        })
      : trimmed(endpoint.server)
        ? [formatServer(endpoint.server, endpoint.server_port, '')]
        : [];
  const lzo = compressionValue(endpoint);
  const settings: ChildSettings = {
    openvpn_servers: servers,
    openvpn_network: network,
    openvpn_mode: staticMode ? 'static_key' : 'tls',
    openvpn_login:
      endpoint.username != null || endpoint.password != null ? '1' : '0',
    openvpn_username: text(endpoint.username),
    openvpn_password: text(endpoint.password),
    openvpn_ca: material(tls, 'certificate'),
    openvpn_cert: material(tls, 'client_certificate'),
    openvpn_key: material(tls, 'client_key'),
    openvpn_control_wrap: trimmed(wrap.type),
    openvpn_control_wrap_key: material(wrap, 'key'),
    openvpn_key_direction: keyDirectionValue(
      staticMode ? endpoint.key_direction : wrap.direction,
    ),
    openvpn_static_key: material(endpoint, 'static_key'),
    openvpn_static_cipher: trimmed(endpoint.cipher),
    openvpn_address: list(endpoint.address),
    openvpn_peer_address: trimmed(endpoint.peer_address),
    openvpn_peer_address_ipv6: trimmed(endpoint.peer_address_ipv6),
    openvpn_remote_random: endpoint.remote_random ? '1' : '0',
    openvpn_server_name: trimmed(tls.server_name),
    openvpn_server_name_type: trimmed(tls.server_name_type) || 'name',
    openvpn_verify_purpose: verifyPurpose(tls),
    openvpn_peer_fingerprint: list(tls.peer_fingerprint),
    openvpn_certificate_profile: trimmed(tls.certificate_profile),
    openvpn_tls_version_min: trimmed(tls.version_min),
    openvpn_tls_cipher: trimmed(tls.cipher),
    openvpn_data_ciphers: list(endpoint.data_ciphers),
    openvpn_data_ciphers_fallback: trimmed(endpoint.data_ciphers_fallback),
    openvpn_auth: trimmed(endpoint.auth),
    openvpn_compression: lzo,
    openvpn_mtu: trimmed(endpoint.mtu),
    openvpn_fragment: trimmed(endpoint.fragment),
    openvpn_mss_fix: endpoint.mss_fix_disabled
      ? '0'
      : trimmed(endpoint.mss_fix),
    openvpn_ping_interval: secondsValue(endpoint.ping_interval),
    openvpn_ping_restart: endpoint.ping_restart_disabled
      ? '0'
      : secondsValue(endpoint.ping_restart),
    openvpn_renegotiate: endpoint.renegotiate_disabled
      ? '0'
      : secondsValue(endpoint.renegotiate_interval),
    openvpn_preserved: JSON.stringify(preservedFields(endpoint)),
  };
  settings.openvpn_advanced = advancedInUse(settings) ? '1' : '0';
  return settings;
}

function mergePreserved(endpoint: Endpoint, settings: ChildSettings) {
  let preserved: Endpoint = {};
  try {
    preserved = JSON.parse(text(settings.openvpn_preserved) || '{}');
  } catch (_error) {
    preserved = {};
  }
  const tls = {
    ...((preserved.tls || {}) as Tls),
    ...((endpoint.tls || {}) as Tls),
  };
  const result = { ...preserved, ...endpoint };
  if (Object.keys(tls).length) result.tls = tls;
  return result;
}

function servers(settings: ChildSettings, network: string) {
  return normalizeOptionValues(settings.openvpn_servers)
    .map(parseOpenVPNServer)
    .filter(Boolean)
    .map((entry) => {
      const result: Endpoint = {
        server: entry!.server,
        server_port: entry!.port,
      };
      if (entry!.network && entry!.network !== network) {
        result.network = entry!.network;
      }
      return result;
    });
}

function number(value: unknown) {
  return /^\d+$/.test(trimmed(value)) ? Number(trimmed(value)) : null;
}

function applyAdvanced(endpoint: Endpoint, tls: Tls, settings: ChildSettings) {
  if (settings.openvpn_advanced !== '1') return;
  const tlsMode = settings.openvpn_mode !== 'static_key';
  if (settings.openvpn_remote_random === '1') endpoint.remote_random = true;

  const mtu = number(settings.openvpn_mtu);
  if (mtu) endpoint.mtu = mtu;
  const fragment = number(settings.openvpn_fragment);
  if (fragment && settings.openvpn_network !== 'tcp')
    endpoint.fragment = fragment;
  const mssFix = number(settings.openvpn_mss_fix);
  if (mssFix === 0) endpoint.mss_fix_disabled = true;
  else if (mssFix) endpoint.mss_fix = mssFix;
  const ping = number(settings.openvpn_ping_interval);
  if (ping) endpoint.ping_interval = `${ping}s`;
  const restart = number(settings.openvpn_ping_restart);
  if (restart === 0) endpoint.ping_restart_disabled = true;
  else if (restart) endpoint.ping_restart = `${restart}s`;
  Object.assign(
    endpoint,
    COMPRESSIONS[text(settings.openvpn_compression)] || {},
  );
  if (!tlsMode) return;

  const serverName = trimmed(settings.openvpn_server_name);
  if (serverName) {
    tls.server_name = serverName;
    tls.server_name_type = trimmed(settings.openvpn_server_name_type) || 'name';
  }
  if (settings.openvpn_verify_purpose === 'none')
    tls.remote_certificate_tls = 'none';
  if (settings.openvpn_verify_purpose === 'ns') {
    tls.remote_certificate_tls = 'none';
    tls.ns_certificate_type = 'server';
  }
  const fingerprints = normalizeOptionValues(
    settings.openvpn_peer_fingerprint,
  ).map((value) => value.replace(/:/g, '').toLowerCase());
  if (fingerprints.length) tls.peer_fingerprint = fingerprints;
  for (const [key, field] of [
    ['certificate_profile', 'openvpn_certificate_profile'],
    ['version_min', 'openvpn_tls_version_min'],
    ['cipher', 'openvpn_tls_cipher'],
  ]) {
    if (trimmed(settings[field])) tls[key] = trimmed(settings[field]);
  }
  const ciphers = normalizeOptionValues(settings.openvpn_data_ciphers);
  if (ciphers.length) endpoint.data_ciphers = ciphers;
  if (trimmed(settings.openvpn_data_ciphers_fallback)) {
    endpoint.data_ciphers_fallback = trimmed(
      settings.openvpn_data_ciphers_fallback,
    );
  }
  if (trimmed(settings.openvpn_auth))
    endpoint.auth = trimmed(settings.openvpn_auth);
  const renegotiate = number(settings.openvpn_renegotiate);
  if (renegotiate === 0) endpoint.renegotiate_disabled = true;
  else if (renegotiate) endpoint.renegotiate_interval = `${renegotiate}s`;
}

export function openVPNEndpoint(settings: ChildSettings): Endpoint {
  const network = settings.openvpn_network === 'tcp' ? 'tcp' : 'udp';
  const endpoint: Endpoint = { type: 'openvpn-client', network };
  const tls: Tls = {};
  const remotes = servers(settings, network);
  if (remotes.length === 1 && !remotes[0].network)
    Object.assign(endpoint, remotes[0]);
  else if (remotes.length) endpoint.servers = remotes;

  if (settings.openvpn_mode === 'static_key') {
    endpoint.mode = 'static_key';
    setMaterial(endpoint, 'static_key', settings.openvpn_static_key);
    const direction = keyDirectionName(settings.openvpn_key_direction);
    if (direction) endpoint.key_direction = direction;
    if (trimmed(settings.openvpn_static_cipher)) {
      endpoint.cipher = trimmed(settings.openvpn_static_cipher);
    }
    const addresses = normalizeOptionValues(settings.openvpn_address);
    if (addresses.length) endpoint.address = addresses;
    for (const key of ['peer_address', 'peer_address_ipv6']) {
      if (trimmed(settings[`openvpn_${key}`])) {
        endpoint[key] = trimmed(settings[`openvpn_${key}`]);
      }
    }
    applyAdvanced(endpoint, tls, settings);
    return mergePreserved(endpoint, settings);
  }

  // The dialog drops both fields while the switch is off.
  if (
    settings.openvpn_login === '1' ||
    text(settings.openvpn_username) ||
    text(settings.openvpn_password)
  ) {
    endpoint.username = text(settings.openvpn_username);
    endpoint.password = text(settings.openvpn_password);
  }
  setMaterial(tls, 'certificate', settings.openvpn_ca);
  setMaterial(tls, 'client_certificate', settings.openvpn_cert);
  setMaterial(tls, 'client_key', settings.openvpn_key);
  const wrapType = trimmed(settings.openvpn_control_wrap);
  if (wrapType) {
    const wrap: Record<string, unknown> = { type: wrapType };
    setMaterial(wrap, 'key', settings.openvpn_control_wrap_key);
    const direction = keyDirectionName(settings.openvpn_key_direction);
    if (wrapType === 'tls_auth' && direction) wrap.direction = direction;
    tls.control_wrap = wrap;
  }
  applyAdvanced(endpoint, tls, settings);
  endpoint.tls = tls;
  return mergePreserved(endpoint, settings);
}

export function validateServerEntry(value: unknown) {
  return parseOpenVPNServer(value) ? true : _('Format: host:port');
}

export function validateAddress(value: unknown) {
  const address = trimmed(value);
  return address.includes('/')
    ? validateSubnet(address)
    : message.prefixLength();
}

// Each field marks itself in the dialog; a closed tunnel is only told to be fixed.
function openVPNSettingsComplete(settings: ChildSettings) {
  const servers = normalizeOptionValues(settings.openvpn_servers);
  if (
    !servers.length ||
    servers.some((server) => validateServerEntry(server) !== true)
  ) {
    return false;
  }
  if (settings.openvpn_mode === 'static_key') {
    const addresses = normalizeOptionValues(settings.openvpn_address);
    const family = (test: (address: string) => boolean) =>
      addresses.some((address) => test(address.split('/')[0]));
    return (
      !!trimmed(settings.openvpn_static_key) &&
      addresses.length > 0 &&
      addresses.every((address) => validateAddress(address) === true) &&
      (!family(isIPv4) || !!trimmed(settings.openvpn_peer_address)) &&
      (!family(isIPv6) || !!trimmed(settings.openvpn_peer_address_ipv6))
    );
  }
  return (
    (!!trimmed(settings.openvpn_ca) ||
      (settings.openvpn_advanced === '1' &&
        normalizeOptionValues(settings.openvpn_peer_fingerprint).length > 0)) &&
    !trimmed(settings.openvpn_cert) === !trimmed(settings.openvpn_key) &&
    (settings.openvpn_login !== '1' || !!trimmed(settings.openvpn_username)) &&
    (!trimmed(settings.openvpn_control_wrap) ||
      !!trimmed(settings.openvpn_control_wrap_key))
  );
}

export function validateOpenVPNSettings(settings: ChildSettings) {
  return openVPNSettingsComplete(settings) ? true : message.fixSettings();
}
