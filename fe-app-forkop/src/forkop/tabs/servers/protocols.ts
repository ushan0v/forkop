import {
  DEFAULT_PROTOCOL,
  SHADOWSOCKS_METHODS,
  VLESS_ENCRYPTION_MODES,
} from './constants';
import {
  coreFeatureOfType,
  coreHas,
} from '../../services/coreFeatures.service';
import { liveOption, option } from './formValues';

// One entry per protocol the tab can serve.
//   kind      - inbound: a sing-box inbound built from the form
//               endpoint: a sing-box endpoint (Tailscale, OpenVPN)
//               json: a raw inbound object written by hand
//   listener  - an endpoint that listens on a port of its own
//   clients   - the server has accounts even though it asks for no credential:
//               the router issues each one a certificate
//   profile   - a client is handed a profile file instead of a link
//   tunnel    - the server gives its clients addresses of a subnet of its own
//   anyAddress- a listener the core binds on every address, with no listen field
//   securities- the security modes the protocol accepts, best first
//   credentials- the per client fields the protocol needs
//   login     - the client name is the account name sent on the wire, so it has to
//               stay inside the ASCII subset clients and URIs can carry
//   link      - the share link scheme, empty when the protocol has no URI format
export const PROTOCOLS = [
  {
    id: 'mixed',
    label: 'Mixed',
    kind: 'inbound',
    securities: ['none'],
    login: true,
    optionalAuth: 'mixed_auth_enabled',
    credentials: ['password'],
    link: 'socks5',
  },
  {
    id: 'vless',
    label: 'VLESS',
    kind: 'inbound',
    securities: ['reality', 'tls', 'none'],
    transport: true,
    multiplex: true,
    credentials: ['uuid', 'flow'],
    link: 'vless',
  },
  {
    id: 'vmess',
    label: 'VMess',
    kind: 'inbound',
    securities: ['tls', 'none'],
    transport: true,
    multiplex: true,
    credentials: ['uuid'],
    link: 'vmess',
  },
  {
    id: 'trojan',
    label: 'Trojan',
    kind: 'inbound',
    securities: ['tls'],
    transport: true,
    multiplex: true,
    credentials: ['password'],
    link: 'trojan',
  },
  {
    id: 'shadowsocks',
    label: 'Shadowsocks',
    kind: 'inbound',
    securities: ['none'],
    multiplex: true,
    credentials: ['password'],
    link: 'ss',
  },
  {
    id: 'hysteria2',
    label: 'Hysteria2',
    kind: 'inbound',
    securities: ['tls'],
    credentials: ['password'],
    link: 'hysteria2',
  },
  {
    id: 'tuic',
    label: 'TUIC',
    kind: 'inbound',
    securities: ['tls'],
    credentials: ['uuid', 'password'],
    link: 'tuic',
  },
  {
    id: 'anytls',
    label: 'AnyTLS',
    kind: 'inbound',
    securities: ['tls'],
    credentials: ['password'],
    link: 'anytls',
  },
  {
    id: 'naive',
    label: 'NaiveProxy',
    kind: 'inbound',
    securities: ['tls'],
    login: true,
    credentials: ['password'],
    link: 'naive',
  },
  {
    id: 'mieru',
    label: 'Mieru',
    kind: 'inbound',
    securities: ['none'],
    login: true,
    credentials: ['password'],
    link: 'mierus',
  },
  {
    id: 'trusttunnel',
    label: 'TrustTunnel',
    kind: 'inbound',
    securities: ['tls'],
    login: true,
    credentials: ['password'],
    link: 'tt',
  },
  {
    id: 'tailscale',
    label: 'Tailscale',
    kind: 'endpoint',
    securities: ['none'],
    credentials: [],
  },
  {
    id: 'wireguard',
    label: 'WireGuard',
    kind: 'endpoint',
    listener: true,
    anyAddress: true,
    securities: ['none'],
    credentials: [],
    clients: true,
    profile: true,
    tunnel: true,
  },
  {
    id: 'amneziawg',
    label: 'AmneziaWG',
    kind: 'endpoint',
    listener: true,
    anyAddress: true,
    securities: ['none'],
    credentials: [],
    clients: true,
    profile: true,
    tunnel: true,
  },
  {
    id: 'openvpn',
    label: 'OpenVPN',
    kind: 'endpoint',
    coreType: 'openvpn-server',
    listener: true,
    securities: ['none'],
    credentials: [],
    clients: true,
    profile: true,
    tunnel: true,
  },
  {
    id: 'json_inbound',
    label: _('JSON inbound'),
    kind: 'json',
    securities: ['none'],
    credentials: [],
  },
];

const PROTOCOL_BY_ID = new Map(
  PROTOCOLS.map((entry: ServerProtocol) => [entry.id, entry]),
);

export function protocolSpec(protocol: unknown) {
  return PROTOCOL_BY_ID.get(`${protocol || ''}`) || null;
}

export function getProtocol(sectionId: string) {
  return liveOption(sectionId, 'protocol') || DEFAULT_PROTOCOL;
}

export function protocolLabel(protocol: string) {
  const spec = protocolSpec(protocol);
  return spec ? spec.label : `${protocol || ''}`;
}

export function protocolsWhere(
  predicate: (entry: ServerProtocol) => boolean,
): string[] {
  return PROTOCOLS.filter(predicate).map((entry: ServerProtocol) => entry.id);
}

export function protocolsWith(flag: string) {
  return protocolsWhere((entry: ServerProtocol) => !!entry[flag]);
}

export function listenerProtocols() {
  return protocolsWhere(
    (entry: ServerProtocol) => entry.kind === 'inbound' || !!entry.listener,
  );
}

// The transports a listener of this protocol takes, as singbox/servers.uc reads
// them: a port can be shared by two servers when one takes TCP and the other UDP.
export function listenTransports(protocol: string, network: string) {
  const value = `${network || ''}`.toLowerCase();
  const http = protocol === 'naive' || protocol === 'trusttunnel';
  if (protocol === 'openvpn') return [value === 'tcp' ? 'tcp' : 'udp'];
  if (
    protocol === 'hysteria2' ||
    protocol === 'tuic' ||
    protocol === 'wireguard' ||
    protocol === 'amneziawg'
  )
    return ['udp'];
  if (protocol === 'shadowsocks' || (http && value === 'tcp_udp'))
    return ['tcp', 'udp'];
  if ((http || protocol === 'mieru') && value === 'udp') return ['udp'];
  return ['tcp'];
}

// A server's option by name, from its section or from its open dialog.
type ServerValue = (name: string) => unknown;

function listOf(value: unknown) {
  return (Array.isArray(value) ? value : `${value ?? ''}`.split(/[\s,]+/))
    .map((item) => `${item}`.trim())
    .filter(Boolean);
}

// sing-box serves XHTTP over HTTP/3, on UDP, when TLS other than Reality offers h3 alone, as Xray
// does; singbox/servers.uc reads it the same way.
export function servesXhttpHttp3(protocol: string, value: ServerValue) {
  const alpn = listOf(value('tls_alpn'));
  return (
    ['vless', 'vmess', 'trojan'].includes(protocol) &&
    `${value('transport') || 'tcp'}` === 'xhttp' &&
    effectiveSecurity(protocol, `${value('security') || ''}`) === 'tls' &&
    alpn.length === 1 &&
    alpn[0] === 'h3'
  );
}

export function serverListenTransports(protocol: string, value: ServerValue) {
  if (servesXhttpHttp3(protocol, value)) {
    return ['udp'];
  }
  const network = transportOption(protocol);
  return listenTransports(protocol, network ? `${value(network) || ''}` : '');
}

const TRANSPORT_OPTIONS: Record<string, string> = {
  naive: 'naive_network',
  trusttunnel: 'trusttunnel_network',
  mieru: 'mieru_transport',
  openvpn: 'openvpn_network',
};

export function transportOption(protocol: string) {
  return TRANSPORT_OPTIONS[protocol] || '';
}

export function hasListener(protocol: string) {
  const spec = protocolSpec(protocol);
  return !!spec && (spec.kind === 'inbound' || !!spec.listener);
}

export function credentialFields(protocol: string) {
  const spec = protocolSpec(protocol);
  return spec ? (spec.credentials || []).slice() : [];
}

export function usesClients(protocol: string) {
  return (
    credentialFields(protocol).length > 0 || !!protocolSpec(protocol)?.clients
  );
}

export function usesProfile(protocol: string) {
  return !!protocolSpec(protocol)?.profile;
}

export function usesLoginName(protocol: string) {
  const spec = protocolSpec(protocol);
  return !!spec && !!spec.login;
}

export function linkScheme(protocol: string) {
  const spec = protocolSpec(protocol);
  return spec && spec.link ? spec.link : '';
}

export function securitiesFor(protocol: unknown) {
  const spec = protocolSpec(protocol);
  return spec ? spec.securities.slice() : ['none'];
}

// The core feature a security mode needs, or '' for one every build has.
export function securityCoreFeature(security: unknown) {
  return security === 'reality' ? 'utls' : '';
}

// The protocol's best mode the installed core can run.
export function defaultSecurity(protocol: unknown) {
  const allowed = securitiesFor(protocol);
  return (
    allowed.find((security) => {
      const feature = securityCoreFeature(security);
      return !feature || coreHas(feature);
    }) || allowed[0]
  );
}

export function securityLabel(security: string) {
  if (security === 'reality') {
    return 'Reality';
  }
  if (security === 'tls') {
    return 'TLS';
  }
  return _('None');
}

// A stored mode the protocol no longer offers falls back to its first choice.
function effectiveSecurity(protocol: string, security: string) {
  const allowed = securitiesFor(protocol);
  return allowed.includes(security) ? security : allowed[0];
}

export function getEffectiveSecurity(sectionId: string) {
  return effectiveSecurity(
    getProtocol(sectionId),
    liveOption(sectionId, 'security'),
  );
}

function authFlagOption(protocol: string) {
  const spec = protocolSpec(protocol);
  return spec && spec.optionalAuth ? spec.optionalAuth : '';
}

export function isAuthenticationEnabled(sectionId: string) {
  const flag = authFlagOption(getProtocol(sectionId));
  if (!flag) {
    return true;
  }

  const value = liveOption(sectionId, flag);
  return value === ''
    ? true
    : !['0', 'false', 'no', 'off'].includes(value.toLowerCase());
}

export function getServerName(sectionId: string) {
  return option(sectionId, 'label') || sectionId;
}

// The mode of VLESS Encryption a VLESS server runs, or '' without it.
export function vlessEncryptionMode(sectionId: string) {
  const mode = liveOption(sectionId, 'vless_encryption');
  return getProtocol(sectionId) === 'vless' &&
    VLESS_ENCRYPTION_MODES.includes(mode)
    ? mode
    : '';
}

export function vlessEncryptionAuth(sectionId: string) {
  return liveOption(sectionId, 'vless_encryption_auth') || 'x25519';
}

// XTLS Vision needs the raw TLS stream, which a transport wraps, or VLESS Encryption, which carries
// it over any transport and without TLS, as Xray does; a multiplexed client drops the flow, after
// which the listener refuses the account.
export function supportsVisionFlow(sectionId: string) {
  if (getProtocol(sectionId) !== 'vless') {
    return false;
  }
  if (liveOption(sectionId, 'multiplex_enabled') === '1') {
    return false;
  }
  if (vlessEncryptionMode(sectionId)) {
    return true;
  }
  if ((liveOption(sectionId, 'transport') || 'tcp') !== 'tcp') {
    return false;
  }

  return getEffectiveSecurity(sectionId) !== 'none';
}

export function shadowsocksKeyBytes(method: string) {
  const entry = SHADOWSOCKS_METHODS.find((item) => item.id === method);
  return entry ? entry.keyBytes : 0;
}

export function isShadowsocks2022(method: string) {
  return shadowsocksKeyBytes(method) > 0;
}

export function getShadowsocksMethod(sectionId: string) {
  return (
    liveOption(sectionId, 'shadowsocks_method') || SHADOWSOCKS_METHODS[0].id
  );
}

// A NaiveProxy client trusts only what a browser would, so that server always takes the user's own.
export function certificateSource(sectionId: string) {
  return getProtocol(sectionId) === 'naive' ||
    liveOption(sectionId, 'tls_certificate_source') === 'custom'
    ? 'custom'
    : 'self_signed';
}

// A server on the certificate the router issued it hands out links that tell the
// client to accept it.
export function usesSelfSignedCertificate(sectionId: string) {
  return (
    getEffectiveSecurity(sectionId) === 'tls' &&
    certificateSource(sectionId) === 'self_signed'
  );
}

// The core feature a protocol needs, or '' for one every build has.
export function protocolCoreFeature(protocol: unknown) {
  const spec = protocolSpec(protocol);
  if (!spec || spec.kind === 'json') {
    return '';
  }
  return coreFeatureOfType(spec.coreType || spec.id, [
    spec.kind === 'endpoint' ? 'endpoint' : 'inbound',
  ]);
}

// What a server asks of the core that the installed one lacks, or ''. The
// Reality handshake needs uTLS, and a NaiveProxy or TrustTunnel server over UDP
// is HTTP/3, as is XHTTP when TLS other than Reality offers h3 alone.
export function serverMissingCoreFeature(sectionId: string) {
  const protocol = getProtocol(sectionId);
  const needed = [
    protocolCoreFeature(protocol),
    securityCoreFeature(getEffectiveSecurity(sectionId)),
    ((protocol === 'naive' || protocol === 'trusttunnel') &&
      ['udp', 'tcp_udp'].includes(
        liveOption(sectionId, transportOption(protocol)),
      )) ||
    servesXhttpHttp3(protocol, (name) => liveOption(sectionId, name))
      ? 'quic'
      : '',
  ];
  return needed.find((feature) => feature && !coreHas(feature)) || '';
}
