// Every check follows what sing-box accepts; a field is required only when the core has no default.

import { isRouterPath } from '../../../helpers/material';
import { decodeBase64 } from '../../../helpers/pem';
import { VLESS_ENCRYPTION_KEY_LENGTHS } from './constants';
import { validateCoreFeature } from '../../services/coreFeatures.service';
import { message } from '../../../validators/messages';
import { wholeNumberField } from '../../../validators/fields';
import {
  hasControlCharacters,
  isEmptyValue,
  liveOption,
  valueList,
} from './formValues';
import {
  isHost,
  isIpv4,
  isIpv6,
  isValidCidr,
  normalizeCidrOrIp,
} from './hosts';
import { occupiedPorts } from './network';
import {
  defaultSecurity,
  getProtocol,
  getShadowsocksMethod,
  securitiesFor,
  securityCoreFeature,
  serverListenTransports,
  servesXhttpHttp3,
  shadowsocksKeyBytes,
  vlessEncryptionAuth,
} from './protocols';

export function validateRequired(_sectionId: string, value: string) {
  return isEmptyValue(value) ? message.required() : true;
}

export function validateRequiredText(_sectionId: string, value: string) {
  if (isEmptyValue(value)) {
    return message.required();
  }

  return hasControlCharacters(`${value}`)
    ? message.noControlCharacters()
    : true;
}

function validatePort(_sectionId: string | null, value: string) {
  const port = parseInt(value, 10);
  if (isEmptyValue(value)) {
    return message.required();
  }
  return /^[0-9]+$/.test(`${value}`) && port >= 1 && port <= 65535
    ? true
    : message.invalidPort();
}

export function validateUuid(_sectionId: string, value: string) {
  return /^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/.test(
    `${value || ''}`,
  )
    ? true
    : message.invalidUuid();
}

export function validateHost(_sectionId: string, value: string) {
  if (isEmptyValue(value)) {
    return message.required();
  }
  return isHost(value) ? true : message.invalidHost();
}

export function validateOptionalHost(_sectionId: string, value: string) {
  return isEmptyValue(value) || isHost(value) ? true : message.invalidHost();
}

// Stored as typed and read by the core as a bare IP, so URL brackets are not stripped.
export function validateListenAddress(_sectionId: string, value: string) {
  const address = `${value || ''}`.trim();
  if (!address) {
    return message.required();
  }
  return !/[[\]]/.test(address) &&
    (address === '0.0.0.0' ||
      address === '::' ||
      isIpv4(address) ||
      isIpv6(address))
    ? true
    : message.invalidIp();
}

// A key read from the file the certificate is read from is refused by the core.
export function validateKeyFile(sectionId: string, value: string) {
  const key = `${value || ''}`.trim();
  return isRouterPath(key) &&
    key === liveOption(sectionId, 'tls_certificate').trim()
    ? _('Same file as the certificate')
    : true;
}

function validateHttpUrl(_sectionId: string | null, value: string) {
  try {
    const url = new URL(`${value || ''}`);
    return (url.protocol === 'http:' || url.protocol === 'https:') &&
      isHost(url.hostname)
      ? true
      : message.invalidUrl();
  } catch (_error) {
    return message.invalidUrl();
  }
}

// Hysteria2 accepts a masquerade target as a URL: https:// reverse proxies a real
// site, file:// serves a directory.
export function validateOptionalMasquerade(_sectionId: string, value: string) {
  if (isEmptyValue(value)) {
    return true;
  }

  const target = `${value}`.trim();
  if (target.startsWith('file://')) {
    return target.length > 'file://'.length ? true : _('Format: file:///www');
  }

  return validateHttpUrl(null, target) === true
    ? true
    : _('Only https://, http:// or file://');
}

// sing-box judges the pasted inbound; singbox/servers.uc overwrites its tag with the server name.
export function validateInboundJson(_sectionId: string, value: string) {
  if (isEmptyValue(value)) {
    return message.required();
  }

  let parsed;
  try {
    parsed = JSON.parse(`${value}`);
  } catch (_error) {
    return message.invalidJson();
  }

  return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
    ? true
    : message.invalidJson();
}

export const validateOptionalPositiveInteger = wholeNumberField(1);

export function validateTransportPath(_sectionId: string, value: string) {
  return isEmptyValue(value) || `${value}`.startsWith('/')
    ? true
    : _('Path must start with /');
}

export function validateGrpcServiceName(_sectionId: string, value: string) {
  return isEmptyValue(value) || /^[A-Za-z0-9_.-]+$/.test(`${value}`)
    ? true
    : message.nameCharacters();
}

export function validateOptionalCidrOrIp(_sectionId: string, value: string) {
  if (isEmptyValue(value)) {
    return true;
  }

  return valueList(value).some((item) => !isValidCidr(normalizeCidrOrIp(item)))
    ? message.invalidIpOrSubnet()
    : true;
}

// sing-box decodes a short ID as hex bytes, eight at most. One value: sing-box takes a list, but a
// share link carries one, so a second could reach no client.
export function validateShortId(sectionId: string, value: string) {
  const required = validateRequiredText(sectionId, value);
  if (required !== true) {
    return required;
  }

  const id = `${value}`.trim();
  return /^(?:[0-9a-fA-F]{2})+$/.test(id) && id.length <= 16
    ? true
    : _('An even number of hex digits, up to 16');
}

export function validateRealityKey(_sectionId: string, value: string) {
  if (isEmptyValue(value)) {
    return message.required();
  }

  return /^[A-Za-z0-9_-]{43}$/.test(`${value}`.trim())
    ? true
    : message.invalidKey();
}

// A key of the kind the server authenticates with, whole: the core refuses a cut private key and
// clients a cut public one.
export function validateVlessEncryptionKey(
  sectionId: string,
  value: string,
  half: 'private' | 'public',
) {
  if (isEmptyValue(value)) {
    return message.required();
  }

  const key = `${value}`.trim();
  return /^[A-Za-z0-9_-]+$/.test(key) &&
    key.length ===
      VLESS_ENCRYPTION_KEY_LENGTHS[vlessEncryptionAuth(sectionId)]?.[half]
    ? true
    : message.invalidKey();
}

export function validateSecurity(sectionId: string, value: string) {
  const protocol = getProtocol(sectionId);
  const selected = value || defaultSecurity(protocol);

  if (!securitiesFor(protocol).includes(selected)) {
    return _('Not supported by this protocol');
  }
  return validateCoreFeature(securityCoreFeature(selected));
}

export function validateTransport(sectionId: string, value: string) {
  return validateCoreFeature(
    servesXhttpHttp3(getProtocol(sectionId), (name) =>
      name === 'transport' ? value : liveOption(sectionId, name),
    )
      ? 'quic'
      : '',
  );
}

export function validateShadowsocksPassword(sectionId: string, value: string) {
  const required = validateRequiredText(sectionId, value);
  if (required !== true) {
    return required;
  }

  const keyBytes = shadowsocksKeyBytes(getShadowsocksMethod(sectionId));
  if (keyBytes === 0) {
    return true;
  }

  // Padded standard base64, as the core decodes it: atob also takes an unpadded key the core refuses.
  const decoded = decodeBase64(`${value}`.trim());
  return decoded != null && decoded.length === keyBytes
    ? true
    : _('Needs a base64 key of %d bytes').format(keyBytes);
}

export function validateListenPort(sectionId: string, value: string) {
  const result = validatePort(sectionId, value);
  if (result !== true) {
    return result;
  }

  const owners = occupiedPorts(sectionId);
  const owner = serverListenTransports(getProtocol(sectionId), (name) =>
    liveOption(sectionId, name),
  )
    .map((transport) => owners.get(`${transport}/${Number(`${value}`.trim())}`))
    .find(Boolean);
  return owner ? _('Port taken by %s').format(owner) : true;
}
