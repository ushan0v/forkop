import {
  ALPN_PROTOCOLS,
  CLIENT_FINGERPRINTS,
  DEFAULT_CLIENT_FINGERPRINT,
  TRANSPORTS,
  VLESS_ENCRYPTION_MODES,
} from '../constants';
import { configureMaterialOption } from '../../../cbi/material';
import { message } from '../../../../validators/messages';
import {
  addGenerateButton,
  addRealityKeypairButton,
  addVlessEncryptionKeypairButton,
  applyRealityKeypair,
  applyVlessEncryptionKeypair,
  autofill,
  camouflageSite,
  realityKeypair,
  syncSecurityChoices,
} from '../controls';
import { randomHex } from '../credentials';
import { isEmptyValue, liveOption, option, optionList } from '../formValues';
import {
  getEffectiveSecurity,
  protocolSpec,
  protocolsWhere,
  protocolsWith,
  vlessEncryptionAuth,
} from '../protocols';
import {
  validateGrpcServiceName,
  validateKeyFile,
  validateHost,
  validateOptionalHost,
  validateRealityKey,
  validateSecurity,
  validateShortId,
  validateTransport,
  validateTransportPath,
  validateVlessEncryptionKey,
} from '../validators';

export function addSecurityOptions(section: CBISection) {
  const streamProtocols = protocolsWith('transport');
  const tlsOnlyProtocols = protocolsWhere(
    (entry) =>
      (entry.securities || []).length === 1 && entry.securities?.[0] === 'tls',
  );
  const onTls = (o: CBIOption) => {
    streamProtocols.forEach((protocol: string) =>
      o.depends({ protocol, security: 'tls' }),
    );
    tlsOnlyProtocols.forEach((protocol: string) =>
      o.depends('protocol', protocol),
    );
  };
  const onReality = (o: CBIOption) =>
    o.depends({ protocol: 'vless', security: 'reality' });

  let o = section.option(form.ListValue, 'security', _('Security'));
  o.value('reality', 'Reality');
  o.value('tls', 'TLS');
  o.value('none', _('None'));
  o.rmempty = false;
  o.modalonly = true;
  [...streamProtocols, ...tlsOnlyProtocols].forEach((protocol: string) =>
    o.depends('protocol', protocol),
  );
  o.validate = validateSecurity;
  // Turning to Reality, by hand or with the protocol, draws the key pair the server needs.
  o.onchange = function (_ev, sectionId: string, value: unknown) {
    if (value === 'reality' && !liveOption(sectionId, 'reality_private_key')) {
      applyRealityKeypair(sectionId);
    }
  };
  {
    const renderWidget = o.renderWidget;
    o.renderWidget = function (
      sectionId: string,
      optionIndex,
      cfgvalue: unknown,
    ) {
      const node = renderWidget.call(this, sectionId, optionIndex, cfgvalue);
      window.setTimeout(() => syncSecurityChoices(sectionId), 0);
      return node;
    };
  }

  o = section.option(form.Value, 'tls_server_name', _('SNI'));
  o.placeholder = 'example.com';
  o.modalonly = true;
  o.rmempty = true;
  o.validate = function (sectionId: string, value: string) {
    if (isEmptyValue(value)) {
      return getEffectiveSecurity(sectionId) === 'reality'
        ? message.required()
        : true;
    }
    return validateHost(sectionId, value);
  };
  autofill(
    o,
    (sectionId: string) =>
      option(sectionId, 'tls_server_name') || camouflageSite(sectionId),
  );
  onTls(o);
  onReality(o);
  addGenerateButton(
    o,
    (sectionId: string) => camouflageSite(sectionId, true),
    _('Pick a domain'),
  );

  // Hysteria2 negotiates h3 and NaiveProxy h2 themselves and fight a filled list; TUIC clients
  // ignore it.
  o = section.option(form.MultiValue, 'tls_alpn', _('ALPN'));
  ['h3', 'h2', 'http/1.1'].forEach((value: string) => o.value(value, value));
  o.create = false;
  o.rmempty = true;
  o.modalonly = true;
  ALPN_PROTOCOLS.forEach((protocol: string) =>
    (protocolSpec(protocol)?.securities || []).includes('none')
      ? o.depends({ protocol, security: 'tls' })
      : o.depends('protocol', protocol),
  );
  onReality(o);

  // NaiveProxy clients refuse a self-signed certificate, so its dialog goes straight to the fields.
  const onOwnCertificate = (o: CBIOption) => {
    streamProtocols.forEach((protocol: string) =>
      o.depends({
        protocol,
        security: 'tls',
        tls_certificate_source: 'custom',
      }),
    );
    tlsOnlyProtocols.forEach((protocol: string) =>
      protocol === 'naive'
        ? o.depends('protocol', protocol)
        : o.depends({ protocol, tls_certificate_source: 'custom' }),
    );
  };

  o = section.option(
    form.ListValue,
    'tls_certificate_source',
    _('Certificate'),
  );
  o.value('self_signed', _('Self-signed'));
  o.value('custom', _('Your own certificate'));
  o.default = 'self_signed';
  o.rmempty = false;
  o.modalonly = true;
  streamProtocols.forEach((protocol: string) =>
    o.depends({ protocol, security: 'tls' }),
  );
  tlsOnlyProtocols
    .filter((protocol: string) => protocol !== 'naive')
    .forEach((protocol: string) => o.depends('protocol', protocol));

  o = section.option(
    form.TextValue,
    'tls_certificate',
    _('Server certificate'),
    _('PEM text or the path of a file on the router'),
  );
  o.modalonly = true;
  configureMaterialOption(o, 'certificate', () => true, 'tls_key');
  onOwnCertificate(o);

  o = section.option(
    form.TextValue,
    'tls_key',
    _('Private key'),
    _('PEM text or the path of a file on the router'),
  );
  o.modalonly = true;
  configureMaterialOption(o, 'key', () => true, 'tls_certificate');
  {
    const validateMaterial = o.validate;
    o.validate = function (sectionId: string, value: string) {
      const result = validateMaterial.call(this, sectionId, value);
      return result === true ? validateKeyFile(sectionId, value) : result;
    };
  }
  onOwnCertificate(o);

  o = section.option(
    form.Value,
    'reality_private_key',
    _('Reality private key'),
  );
  o.modalonly = true;
  o.password = true;
  o.validate = validateRealityKey;
  autofill(
    o,
    (sectionId: string) =>
      option(sectionId, 'reality_private_key') ||
      realityKeypair(sectionId).then(
        (pair: { private_key?: string; public_key?: string } | null) =>
          pair ? pair.private_key : '',
      ),
  );
  onReality(o);
  addRealityKeypairButton(o);

  o = section.option(form.Value, 'reality_public_key', _('Reality public key'));
  o.modalonly = true;
  o.validate = validateRealityKey;
  autofill(
    o,
    (sectionId: string) =>
      option(sectionId, 'reality_public_key') ||
      realityKeypair(sectionId).then(
        (pair: { private_key?: string; public_key?: string } | null) =>
          pair ? pair.public_key : '',
      ),
  );
  onReality(o);

  o = section.option(form.Value, 'reality_short_id', _('Reality short ID'));
  o.modalonly = true;
  o.validate = validateShortId;
  autofill(
    o,
    // A configuration written before this was one field keeps its first value.
    (sectionId: string) =>
      optionList(sectionId, 'reality_short_id')[0] || randomHex(4),
  );
  onReality(o);
  addGenerateButton(o, () => randomHex(4));

  o = section.option(
    form.ListValue,
    'client_fingerprint',
    _('Client fingerprint'),
  );
  CLIENT_FINGERPRINTS.forEach((value: string) => o.value(value, value));
  o.default = DEFAULT_CLIENT_FINGERPRINT;
  o.rmempty = true;
  o.modalonly = true;
  onReality(o);
}

// VLESS Encryption of Xray, a layer of its own under VLESS that carries the flow over any
// transport. Turning it on, or picking another kind of key, draws a pair of that kind.
export function addVlessEncryptionOptions(section: CBISection) {
  const onEncryption = (o: CBIOption) =>
    VLESS_ENCRYPTION_MODES.forEach((mode: string) =>
      o.depends({ protocol: 'vless', vless_encryption: mode }),
    );

  let o = section.option(
    form.ListValue,
    'vless_encryption',
    _('VLESS Encryption'),
  );
  o.value('', _('Off'));
  VLESS_ENCRYPTION_MODES.forEach((mode: string) => o.value(mode, mode));
  o.rmempty = true;
  o.modalonly = true;
  o.depends('protocol', 'vless');
  o.onchange = function (_ev, sectionId: string, value: unknown) {
    if (value && !liveOption(sectionId, 'vless_encryption_private_key')) {
      applyVlessEncryptionKeypair(sectionId, vlessEncryptionAuth(sectionId));
    }
  };

  o = section.option(
    form.ListValue,
    'vless_encryption_auth',
    _('Authentication'),
  );
  o.value('x25519', 'X25519');
  o.value('mlkem768', 'ML-KEM-768');
  o.default = 'x25519';
  o.rmempty = false;
  o.modalonly = true;
  onEncryption(o);
  o.onchange = function (_ev, sectionId: string, value: unknown) {
    applyVlessEncryptionKeypair(sectionId, `${value || 'x25519'}`);
  };

  o = section.option(
    form.Value,
    'vless_encryption_private_key',
    _('VLESS Encryption private key'),
  );
  o.modalonly = true;
  o.password = true;
  o.validate = (sectionId: string, value: string) =>
    validateVlessEncryptionKey(sectionId, value, 'private');
  onEncryption(o);
  addVlessEncryptionKeypairButton(o);

  o = section.option(
    form.Value,
    'vless_encryption_public_key',
    _('VLESS Encryption public key'),
  );
  o.modalonly = true;
  o.validate = (sectionId: string, value: string) =>
    validateVlessEncryptionKey(sectionId, value, 'public');
  onEncryption(o);
}

export function addTransportOptions(section: CBISection) {
  const streamProtocols = protocolsWith('transport');
  const onTransport = (o: CBIOption, transport: string) =>
    streamProtocols.forEach((protocol: string) =>
      o.depends({ protocol, transport }),
    );

  let o = section.option(form.ListValue, 'transport', _('Transport'));
  TRANSPORTS.forEach(([value, label]) => o.value(value, label));
  o.default = 'tcp';
  o.rmempty = false;
  o.modalonly = true;
  o.validate = validateTransport;
  streamProtocols.forEach((protocol: string) =>
    o.depends('protocol', protocol),
  );

  o = section.option(form.Value, 'transport_path', _('Transport path'));
  o.placeholder = '/ws';
  o.modalonly = true;
  o.rmempty = true;
  o.validate = validateTransportPath;
  ['ws', 'http', 'httpupgrade', 'xhttp'].forEach((transport: string) =>
    onTransport(o, transport),
  );

  o = section.option(form.Value, 'transport_host', _('Transport host'));
  o.placeholder = 'example.com';
  o.modalonly = true;
  o.rmempty = true;
  o.validate = validateOptionalHost;
  ['ws', 'http', 'httpupgrade', 'xhttp'].forEach((transport: string) =>
    onTransport(o, transport),
  );

  o = section.option(form.Value, 'transport_service_name', _('gRPC service'));
  o.placeholder = 'grpc';
  o.modalonly = true;
  o.rmempty = true;
  o.validate = validateGrpcServiceName;
  onTransport(o, 'grpc');

  o = section.option(form.ListValue, 'transport_xhttp_mode', _('XHTTP mode'));
  ['auto', 'packet-up', 'stream-up', 'stream-one'].forEach((value: string) =>
    o.value(value, value),
  );
  o.default = 'auto';
  o.rmempty = false;
  o.modalonly = true;
  onTransport(o, 'xhttp');
}

export function addMultiplexOptions(section: CBISection) {
  const multiplexProtocols = protocolsWith('multiplex');
  const onMultiplex = (o: CBIOption, extra?: Record<string, unknown>) =>
    multiplexProtocols.forEach((protocol: string) =>
      o.depends(Object.assign({ protocol }, extra || {})),
    );

  let o = section.option(form.Flag, 'multiplex_enabled', _('Multiplex'));
  o.default = '0';
  o.rmempty = true;
  o.modalonly = true;
  onMultiplex(o);

  o = section.option(form.Flag, 'multiplex_padding', _('Padding'));
  o.default = '0';
  o.rmempty = true;
  o.modalonly = true;
  onMultiplex(o, { multiplex_enabled: '1' });
}
