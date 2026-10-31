// Field names and encodings follow the core's link parser (parser/link), so the core reads these back.

import { DEFAULT_CLIENT_FINGERPRINT } from './constants';
import {
  certificateCanSignItself,
  certificateDnsName,
  decodeBase64,
  pemBlocks,
} from '../../../helpers/pem';
import { encodeTrustTunnelLink } from '../../../helpers/trustTunnelLink';
import {
  base64Encode,
  base64UrlEncode,
  encodeQuery,
  normalizeSha256,
} from './credentials';
import { option, optionList } from './formValues';
import { formatHostForUri } from './hosts';
import { loadIssuedMaterial } from './issued';
import { getListenPort, getPublicHost } from './network';
import {
  credentialFields,
  getEffectiveSecurity,
  getProtocol,
  getServerName,
  getShadowsocksMethod,
  isAuthenticationEnabled,
  isShadowsocks2022,
  linkScheme,
  usesSelfSignedCertificate,
  vlessEncryptionMode,
} from './protocols';

function clientLabel(sectionId: string, client: ServerClient) {
  return `${client?.name || ''}`.trim() || getServerName(sectionId);
}

function transportQuery(sectionId: string, params: Record<string, string>) {
  const transport = option(sectionId, 'transport') || 'tcp';
  params.type = transport === 'raw' ? 'tcp' : transport;

  if (transport === 'ws' || transport === 'httpupgrade') {
    params.path = option(sectionId, 'transport_path');
    params.host = option(sectionId, 'transport_host');
  } else if (transport === 'xhttp') {
    params.path = option(sectionId, 'transport_path') || '/';
    params.host = option(sectionId, 'transport_host');
    params.mode = option(sectionId, 'transport_xhttp_mode') || 'auto';
  } else if (transport === 'grpc') {
    params.serviceName = option(sectionId, 'transport_service_name');
  } else if (transport === 'http') {
    params.path = option(sectionId, 'transport_path');
    params.host = option(sectionId, 'transport_host');
  }

  return transport;
}

function tlsQuery(
  sectionId: string,
  params: Record<string, string>,
  includeSecurity?: boolean,
) {
  const security = getEffectiveSecurity(sectionId);

  if (security === 'none') {
    if (includeSecurity) {
      params.security = 'none';
    }
    return security;
  }

  if (includeSecurity) {
    params.security = security;
  }

  if (security === 'reality') {
    params.sni = option(sectionId, 'tls_server_name');
    params.pbk = option(sectionId, 'reality_public_key');
    params.sid = optionList(sectionId, 'reality_short_id')[0] || '';
    params.fp =
      option(sectionId, 'client_fingerprint') || DEFAULT_CLIENT_FINGERPRINT;
  } else {
    params.sni = option(sectionId, 'tls_server_name');
    if (usesSelfSignedCertificate(sectionId)) {
      params.insecure = '1';
    }
  }

  const alpn = optionList(sectionId, 'tls_alpn').join(',');
  if (alpn) {
    params.alpn = alpn;
  }

  return security;
}

// Xray-core no longer skips verification (allowInsecure): its clients connect to a self-signed
// server only by the fingerprint of its certificate, pinned as pcs.
function xrayCertificatePin(
  params: Record<string, string>,
  context: ShareLinkContext,
) {
  if (params.insecure) {
    params.pcs = normalizeSha256(context.tlsCertificateSha256);
  }
}

function shareUrl(
  scheme: string,
  sectionId: string,
  userInfo: string,
  params: Record<string, string>,
  label: string,
) {
  const host = formatHostForUri(getPublicHost(sectionId));
  const port = getListenPort(sectionId);
  const query = encodeQuery(params || {});

  return [
    scheme,
    '://',
    userInfo ? `${userInfo}@` : '',
    host,
    ':',
    port,
    query ? `?${query}` : '',
    '#',
    encodeURIComponent(label),
  ].join('');
}

function buildVlessLink(
  sectionId: string,
  client: ServerClient,
  context: ShareLinkContext,
) {
  const params: Record<string, string> = {};
  const security = tlsQuery(sectionId, params, true);

  if (security === 'reality' && (!params.pbk || !params.sid)) {
    return '';
  }

  xrayCertificatePin(params, context);

  transportQuery(sectionId, params);
  // Xray's client form: 0-RTT, which the server allows for ten minutes.
  const encryption = vlessEncryptionMode(sectionId);
  const encryptionKey = option(sectionId, 'vless_encryption_public_key');
  if (encryption && !encryptionKey) {
    return '';
  }
  params.encryption = encryption
    ? `mlkem768x25519plus.${encryption}.0rtt.${encryptionKey}`
    : 'none';
  if (client.flow && client.flow !== 'none') {
    params.flow = client.flow;
  }

  return shareUrl(
    'vless',
    sectionId,
    encodeURIComponent(client.uuid),
    params,
    clientLabel(sectionId, client),
  );
}

function buildTrojanLink(
  sectionId: string,
  client: ServerClient,
  context: ShareLinkContext,
) {
  const params: Record<string, string> = {};
  tlsQuery(sectionId, params, true);
  xrayCertificatePin(params, context);
  transportQuery(sectionId, params);

  return shareUrl(
    'trojan',
    sectionId,
    encodeURIComponent(client.password),
    params,
    clientLabel(sectionId, client),
  );
}

function buildVmessLink(
  sectionId: string,
  client: ServerClient,
  context: ShareLinkContext,
) {
  const params: Record<string, string> = {};
  const security = tlsQuery(sectionId, params, false);
  xrayCertificatePin(params, context);
  const transportParams: Record<string, string> = {};
  transportQuery(sectionId, transportParams);
  const payload: Record<string, string> = {
    v: '2',
    ps: clientLabel(sectionId, client),
    add: getPublicHost(sectionId),
    port: getListenPort(sectionId),
    id: client.uuid,
    aid: '0',
    scy: 'auto',
    // As the query spells it, so the raw-to-tcp mapping stays in one place.
    net: transportParams.type,
    // v2rayN keeps the XHTTP mode in the field of the TCP header, the core's parser reads "mode".
    type: transportParams.mode || 'none',
    host: transportParams.host || '',
    path: transportParams.path || transportParams.serviceName || '',
    tls: security === 'tls' ? 'tls' : '',
    sni: security === 'tls' ? params.sni || '' : '',
    alpn: security === 'tls' ? params.alpn || '' : '',
  };

  if (transportParams.mode) {
    payload.mode = transportParams.mode;
  }
  if (params.insecure) {
    payload.insecure = '1';
  }
  if (params.pcs) {
    payload.pcs = params.pcs;
  }

  // Unpadded standard base64, the encoding the core generator emits.
  return `vmess://${base64Encode(JSON.stringify(payload)).replace(/=+$/, '')}`;
}

function buildShadowsocksLink(sectionId: string, client: ServerClient) {
  const method = getShadowsocksMethod(sectionId);
  // A 2022 client password is the server key and the client key joined.
  const password = isShadowsocks2022(method)
    ? `${option(sectionId, 'shadowsocks_psk')}:${client.password}`
    : client.password;

  return shareUrl(
    'ss',
    sectionId,
    base64UrlEncode(`${method}:${password}`),
    {},
    clientLabel(sectionId, client),
  );
}

function buildMixedLinks(sectionId: string, client: ServerClient) {
  const userInfo = isAuthenticationEnabled(sectionId)
    ? `${encodeURIComponent(client.name)}:${encodeURIComponent(client.password)}`
    : '';
  const label = clientLabel(sectionId, client);

  return [
    {
      title: _('SOCKS5'),
      link: shareUrl('socks5', sectionId, userInfo, {}, label),
    },
    {
      title: _('HTTP'),
      link: shareUrl('http', sectionId, userInfo, {}, label),
    },
  ];
}

function buildHysteria2Link(
  sectionId: string,
  client: ServerClient,
  context: ShareLinkContext = {},
) {
  const params: Record<string, string> = {};
  tlsQuery(sectionId, params, false);

  const certificatePin = normalizeSha256(context.tlsCertificateSha256);
  if (certificatePin) {
    params.pinSHA256 = certificatePin;
  }

  if (
    ['salamander', 'gecko'].includes(option(sectionId, 'hysteria2_obfs_type'))
  ) {
    params.obfs = option(sectionId, 'hysteria2_obfs_type');
    params['obfs-password'] = option(sectionId, 'hysteria2_obfs_password');
  }

  return shareUrl(
    'hysteria2',
    sectionId,
    encodeURIComponent(client.password),
    params,
    clientLabel(sectionId, client),
  );
}

function buildTuicLink(sectionId: string, client: ServerClient) {
  const params: Record<string, string> = {};
  tlsQuery(sectionId, params, false);

  const congestion = option(sectionId, 'tuic_congestion_control');
  if (congestion && congestion !== 'cubic') {
    params.congestion_control = congestion;
  }

  return shareUrl(
    'tuic',
    sectionId,
    `${encodeURIComponent(client.uuid)}:${encodeURIComponent(client.password)}`,
    params,
    clientLabel(sectionId, client),
  );
}

function buildAnytlsLink(sectionId: string, client: ServerClient) {
  const params: Record<string, string> = {};
  tlsQuery(sectionId, params, false);

  return shareUrl(
    'anytls',
    sectionId,
    encodeURIComponent(client.password),
    params,
    clientLabel(sectionId, client),
  );
}

function buildNaiveLink(sectionId: string, client: ServerClient) {
  const params: Record<string, string> = {};
  tlsQuery(sectionId, params, false);

  // naive+quic marks the HTTP/3 listener, naive+https the HTTP/2 one.
  const scheme =
    option(sectionId, 'naive_network') === 'udp' ? 'naive+quic' : 'naive+https';

  return shareUrl(
    scheme,
    sectionId,
    `${encodeURIComponent(client.name)}:${encodeURIComponent(client.password)}`,
    params,
    clientLabel(sectionId, client),
  );
}

// The official client checks a certificate the link carries against hostname and sends custom_sni,
// so the router's own goes with the name it was issued for. One an older core issued is no issuer
// to BoringSSL, so that server goes unchecked, as in other protocols' links.
function buildTrustTunnelLink(
  sectionId: string,
  client: ServerClient,
  context: ShareLinkContext,
) {
  const sni = option(sectionId, 'tls_server_name');
  const link = {
    hostname: sni || getPublicHost(sectionId),
    address: `${formatHostForUri(getPublicHost(sectionId))}:${getListenPort(sectionId)}`,
    username: client.name,
    password: client.password,
    http3: option(sectionId, 'trusttunnel_network') === 'udp',
    name: clientLabel(sectionId, client),
  };
  if (!usesSelfSignedCertificate(sectionId)) {
    return encodeTrustTunnelLink(link);
  }

  const block = pemBlocks(context.tlsCertificate || '').find(
    (item) => item.label === 'CERTIFICATE',
  );
  const certificate = block ? decodeBase64(block.body) : null;
  if (!certificate) {
    return '';
  }
  const hostname = certificateDnsName(certificate);
  if (!hostname || !certificateCanSignItself(certificate)) {
    return encodeTrustTunnelLink({ ...link, skipVerification: true });
  }
  return encodeTrustTunnelLink({
    ...link,
    hostname,
    customSni: sni && sni !== hostname ? sni : '',
    certificate,
  });
}

export function hasRequiredCredentials(
  sectionId: string,
  client: ServerClient,
) {
  return credentialFields(getProtocol(sectionId))
    .filter((field: string) => field !== 'flow')
    .every((field: string) => {
      if (field === 'password' && !isAuthenticationEnabled(sectionId)) {
        return true;
      }
      return !!client[field as keyof ServerClient];
    });
}

// The Mieru project's format: port and transport in the query, and a required profile name, for
// which the server name stands in.
function buildMieruLink(sectionId: string, client: ServerClient) {
  const label = clientLabel(sectionId, client);
  const query = encodeQuery({
    profile: getServerName(sectionId),
    port: getListenPort(sectionId),
    protocol: option(sectionId, 'mieru_transport') || 'TCP',
  });

  return [
    'mierus://',
    `${encodeURIComponent(client.name)}:${encodeURIComponent(client.password)}@`,
    formatHostForUri(getPublicHost(sectionId)),
    `?${query}`,
    '#',
    encodeURIComponent(label),
  ].join('');
}

// Most protocols produce one; a Mixed listener one per scheme it answers.
export function buildClientLinks(
  sectionId: string,
  client: ServerClient,
  context: ShareLinkContext = {},
) {
  const protocol = getProtocol(sectionId);

  // Only protocols the table gives a scheme have a share link at all.
  if (
    !client ||
    !linkScheme(protocol) ||
    !getPublicHost(sectionId) ||
    !getListenPort(sectionId) ||
    !hasRequiredCredentials(sectionId, client)
  ) {
    return [];
  }

  const single = (link: string) => (link ? [{ title: _('Link'), link }] : []);

  switch (protocol) {
    case 'vless':
      return single(buildVlessLink(sectionId, client, context));
    case 'vmess':
      return single(buildVmessLink(sectionId, client, context));
    case 'trojan':
      return single(buildTrojanLink(sectionId, client, context));
    case 'shadowsocks':
      return single(buildShadowsocksLink(sectionId, client));
    case 'mixed':
      return buildMixedLinks(sectionId, client);
    case 'hysteria2':
      return single(buildHysteria2Link(sectionId, client, context));
    case 'tuic':
      return single(buildTuicLink(sectionId, client));
    case 'anytls':
      return single(buildAnytlsLink(sectionId, client));
    case 'naive':
      return single(buildNaiveLink(sectionId, client));
    case 'mieru':
      return single(buildMieruLink(sectionId, client));
    case 'trusttunnel':
      return single(buildTrustTunnelLink(sectionId, client, context));
    default:
      return [];
  }
}

// Hysteria2, VLESS, VMess and Trojan links pin the fingerprint of the certificate the router
// issued, a TrustTunnel link carries the certificate itself.
export function loadLinkContext(sectionId: string): Promise<ShareLinkContext> {
  if (
    !['hysteria2', 'vless', 'vmess', 'trojan', 'trusttunnel'].includes(
      getProtocol(sectionId),
    ) ||
    !usesSelfSignedCertificate(sectionId)
  ) {
    return Promise.resolve({});
  }

  return loadIssuedMaterial().then((material) => ({
    tlsCertificateSha256: normalizeSha256(
      material[sectionId]?.tls_self_signed_sha256,
    ),
    tlsCertificate: `${material[sectionId]?.tls_self_signed_certificate || ''}`,
  }));
}
