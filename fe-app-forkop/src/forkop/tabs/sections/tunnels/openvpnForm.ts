// In the order a profile is read: server, identity, control channel wrapping; tuning follows
// behind one switch, the static key mode only when asked for.

import { OPENVPN_DEFAULT_DATA_CIPHERS } from '../../../../helpers/parseOpenVPNConfig';
import type { OpenVPNImportResult } from '../../../../helpers/parseOpenVPNConfig';
import { normalizeOptionValues } from '../../../cbi/listValues';
import { setModalOptionValue } from '../../../cbi/modal';
import { configureMaterialOption } from '../../../cbi/material';
import { required, requiredList } from '../../../cbi/required';
import { message } from '../../../../validators/messages';
import {
  ipv4Field,
  ipv6Field,
  wholeNumberField,
} from '../../../../validators/fields';
import { isIPv4, isIPv6 } from '../../../../validators/validateIp';
import { currentOptionValue } from '../subscriptions/model';
import {
  COMPRESSION_LABELS,
  DATA_CIPHERS,
  DIGESTS,
  STATIC_CIPHERS,
  openVPNInitialSettings,
  trimmed,
  validateAddress,
  validateServerEntry,
} from './openvpn';

function secondsOption(
  section: CBISection,
  name: string,
  title: string,
  description: string | null,
  placeholder: string,
) {
  const o = section.option(form.Value, name, title, description ?? undefined);
  o.validate = wholeNumberField(0);
  o.placeholder = placeholder;
  o.rmempty = true;
  return o;
}

// The other end of a static key tunnel, which each address family of the
// tunnel addresses needs.
function peerAddressCheck(
  family: (address: string) => boolean,
  check: (sectionId: string, value: unknown) => true | string,
) {
  return function (this: CBIOption, sectionId: string, value: unknown) {
    const needed = normalizeOptionValues(
      currentOptionValue(this, sectionId, 'openvpn_address'),
    ).some((address) => family(address.split('/')[0]));
    return needed && !trimmed(value)
      ? message.required()
      : check(sectionId, value);
  };
}

function onKind(o: CBIOption, extra: Record<string, unknown> = {}) {
  o.depends({ tunnel_type: 'openvpn-client', ...extra });
  return o;
}

export function addOpenVPNOptions(section: CBISection) {
  const options: Record<string, CBIOption> = {};
  const add = (name: string, o: CBIOption) => {
    options[name] = o;
    return o;
  };
  const tls = { openvpn_mode: 'tls' };
  const staticKey = { openvpn_mode: 'static_key' };
  const advanced = { openvpn_advanced: '1' };

  let o = add(
    'openvpn_servers',
    onKind(
      section.option(
        form.DynamicList,
        'openvpn_servers',
        _('Servers'),
        _(
          'Host and port. Put tcp:// or udp:// before a server on the other transport',
        ),
      ),
    ),
  );
  o.rmempty = false;
  o.validate = requiredList((_sectionId, value) => validateServerEntry(value));

  o = add(
    'openvpn_network',
    onKind(section.option(form.ListValue, 'openvpn_network', _('Transport'))),
  );
  o.value('udp', 'UDP');
  o.value('tcp', 'TCP');
  o.default = 'udp';
  o.rmempty = false;

  o = add(
    'openvpn_mode',
    onKind(section.option(form.ListValue, 'openvpn_mode', _('Mode'))),
  );
  o.value('tls', _('TLS (certificates)'));
  o.value('static_key', _('Static key'));
  o.default = 'tls';
  o.rmempty = false;

  o = add(
    'openvpn_login',
    onKind(
      section.option(form.Flag, 'openvpn_login', _('Username and password')),
      tls,
    ),
  );
  o.default = '0';
  o.rmempty = false;

  o = add(
    'openvpn_username',
    onKind(section.option(form.Value, 'openvpn_username', _('Username')), {
      ...tls,
      openvpn_login: '1',
    }),
  );
  o.validate = required();

  o = add(
    'openvpn_password',
    onKind(section.option(form.Value, 'openvpn_password', _('Password')), {
      ...tls,
      openvpn_login: '1',
    }),
  );
  o.password = true;
  o.rmempty = true;

  o = add(
    'openvpn_ca',
    onKind(
      section.option(form.TextValue, 'openvpn_ca', _('CA certificate')),
      tls,
    ),
  );
  configureMaterialOption(
    o,
    'ca',
    (value) =>
      !(
        value('openvpn_advanced') === '1' &&
        normalizeOptionValues(value('openvpn_peer_fingerprint')).length
      ),
  );

  o = add(
    'openvpn_cert',
    onKind(
      section.option(form.TextValue, 'openvpn_cert', _('Client certificate')),
      tls,
    ),
  );
  configureMaterialOption(
    o,
    'certificate',
    (value) => !!trimmed(value('openvpn_key')),
    'openvpn_key',
  );

  o = add(
    'openvpn_key',
    onKind(section.option(form.TextValue, 'openvpn_key', _('Client key')), tls),
  );
  configureMaterialOption(
    o,
    'key',
    (value) => !!trimmed(value('openvpn_cert')),
    'openvpn_cert',
  );

  o = add(
    'openvpn_control_wrap',
    onKind(
      section.option(
        form.ListValue,
        'openvpn_control_wrap',
        _('Control channel protection'),
      ),
      tls,
    ),
  );
  o.value('', _('None'));
  o.value('tls_auth', 'tls-auth');
  o.value('tls_crypt', 'tls-crypt');
  o.value('tls_crypt_v2', 'tls-crypt-v2');
  o.rmempty = true;

  o = add(
    'openvpn_control_wrap_key',
    section.option(
      form.TextValue,
      'openvpn_control_wrap_key',
      _('Control channel key'),
    ),
  );
  for (const type of ['tls_auth', 'tls_crypt', 'tls_crypt_v2']) {
    onKind(o, { ...tls, openvpn_control_wrap: type });
  }
  configureMaterialOption(
    o,
    (value) =>
      value('openvpn_control_wrap') === 'tls_crypt_v2' ? 'crypt-v2' : 'static',
    () => true,
  );
  options.openvpn_control_wrap.onchange = () =>
    window.setTimeout(
      () => options.openvpn_control_wrap_key.triggerValidation('settings'),
      0,
    );

  o = add(
    'openvpn_key_direction',
    section.option(form.ListValue, 'openvpn_key_direction', _('Key direction')),
  );
  o.value('1', '1');
  o.value('0', '0');
  o.value('both', _('Both directions'));
  o.default = '1';
  o.rmempty = true;
  onKind(o, { ...tls, openvpn_control_wrap: 'tls_auth' });
  onKind(o, staticKey);

  o = add(
    'openvpn_static_key',
    onKind(
      section.option(form.TextValue, 'openvpn_static_key', _('Static key')),
      staticKey,
    ),
  );
  configureMaterialOption(o, 'static', () => true);

  o = add(
    'openvpn_static_cipher',
    onKind(
      section.option(form.ListValue, 'openvpn_static_cipher', _('Cipher')),
      staticKey,
    ),
  );
  o.value('', _('Default (BF-CBC)'));
  STATIC_CIPHERS.forEach((cipher) => o.value(cipher, cipher));
  o.rmempty = true;

  o = add(
    'openvpn_address',
    onKind(
      section.option(
        form.DynamicList,
        'openvpn_address',
        _('Tunnel addresses'),
        _('ifconfig and ifconfig-ipv6 in the profile'),
      ),
      staticKey,
    ),
  );
  o.rmempty = false;
  o.validate = requiredList((_sectionId, value) => validateAddress(value));

  o = add(
    'openvpn_peer_address',
    onKind(
      section.option(
        form.Value,
        'openvpn_peer_address',
        _('Peer address'),
        _('The second address of ifconfig in the profile'),
      ),
      staticKey,
    ),
  );
  o.validate = peerAddressCheck(isIPv4, ipv4Field);

  o = add(
    'openvpn_peer_address_ipv6',
    onKind(
      section.option(
        form.Value,
        'openvpn_peer_address_ipv6',
        _('Peer IPv6 address'),
        _('The second address of ifconfig-ipv6 in the profile'),
      ),
      staticKey,
    ),
  );
  o.validate = peerAddressCheck(isIPv6, ipv6Field);

  o = add(
    'openvpn_advanced',
    onKind(
      section.option(form.Flag, 'openvpn_advanced', _('Advanced settings')),
    ),
  );
  o.default = '0';
  o.rmempty = false;

  o = add(
    'openvpn_remote_random',
    onKind(
      section.option(
        form.Flag,
        'openvpn_remote_random',
        _('Random server order'),
      ),
      advanced,
    ),
  );
  o.default = '0';
  o.rmempty = true;

  o = add(
    'openvpn_server_name',
    onKind(
      section.option(
        form.Value,
        'openvpn_server_name',
        _('Server certificate name'),
        _('verify-x509-name in the profile'),
      ),
      { ...tls, ...advanced },
    ),
  );
  o.rmempty = true;

  o = add(
    'openvpn_server_name_type',
    onKind(
      section.option(
        form.ListValue,
        'openvpn_server_name_type',
        _('Name match'),
      ),
      {
        ...tls,
        ...advanced,
      },
    ),
  );
  o.value('name', _('Common name (name)'));
  o.value('name-prefix', _('Start of the common name (name-prefix)'));
  o.value('subject', _('Whole subject (subject)'));
  o.default = 'name';
  o.rmempty = true;

  o = add(
    'openvpn_verify_purpose',
    onKind(
      section.option(
        form.ListValue,
        'openvpn_verify_purpose',
        _('Server certificate purpose'),
      ),
      { ...tls, ...advanced },
    ),
  );
  o.value('server', 'remote-cert-tls server');
  o.value('ns', 'ns-cert-type server');
  o.value('none', _('Do not check'));
  o.default = 'server';
  o.rmempty = true;

  o = add(
    'openvpn_peer_fingerprint',
    onKind(
      section.option(
        form.DynamicList,
        'openvpn_peer_fingerprint',
        _('Server certificate fingerprints'),
        _(
          'With fingerprints the CA certificate is not needed (peer-fingerprint in the profile)',
        ),
      ),
      { ...tls, ...advanced },
    ),
  );
  o.rmempty = true;
  o.validate = (_sectionId: string, value: unknown) =>
    !trimmed(value) ||
    /^[0-9a-f]{64}$/.test(trimmed(value).replace(/:/g, '').toLowerCase())
      ? true
      : _('Invalid SHA-256 fingerprint');

  o = add(
    'openvpn_certificate_profile',
    onKind(
      section.option(
        form.ListValue,
        'openvpn_certificate_profile',
        _('Certificate profile'),
        _(
          'The signature algorithms and key sizes accepted (tls-cert-profile in the profile)',
        ),
      ),
      { ...tls, ...advanced },
    ),
  );
  o.value('', _('Default (legacy)'));
  o.value('preferred', 'preferred');
  o.value('insecure', _('insecure: also MD5 and short keys'));
  o.value('suiteb', 'suiteb');
  o.rmempty = true;

  o = add(
    'openvpn_tls_version_min',
    onKind(
      section.option(
        form.ListValue,
        'openvpn_tls_version_min',
        _('Minimum TLS version'),
      ),
      {
        ...tls,
        ...advanced,
      },
    ),
  );
  o.value('', _('Default (1.2)'));
  ['1.0', '1.1', '1.2', '1.3'].forEach((version) => o.value(version, version));
  o.rmempty = true;

  o = add(
    'openvpn_tls_cipher',
    onKind(
      section.option(
        form.Value,
        'openvpn_tls_cipher',
        _('TLS ciphers'),
        _(
          'Cipher suites up to TLS 1.2, separated by colons (tls-cipher in the profile)',
        ),
      ),
      { ...tls, ...advanced },
    ),
  );
  o.rmempty = true;

  o = add(
    'openvpn_data_ciphers',
    onKind(
      section.option(
        form.MultiValue,
        'openvpn_data_ciphers',
        _('Data ciphers'),
        _('data-ciphers in the profile'),
      ),
      { ...tls, ...advanced },
    ),
  );
  o.placeholder = OPENVPN_DEFAULT_DATA_CIPHERS.join(', ');
  DATA_CIPHERS.forEach((cipher) => o.value(cipher, cipher));
  o.create = true;
  o.rmempty = true;

  o = add(
    'openvpn_data_ciphers_fallback',
    onKind(
      section.option(
        form.ListValue,
        'openvpn_data_ciphers_fallback',
        _('Fallback cipher'),
        _(
          'Only for a server older than 2.4 (data-ciphers-fallback in the profile)',
        ),
      ),
      { ...tls, ...advanced },
    ),
  );
  o.value('', _('None'));
  DATA_CIPHERS.forEach((cipher) => o.value(cipher, cipher));
  o.rmempty = true;

  o = add(
    'openvpn_auth',
    onKind(
      section.option(
        form.ListValue,
        'openvpn_auth',
        _('Packet authentication'),
        _('auth in the profile'),
      ),
      advanced,
    ),
  );
  o.value('', _('Default (SHA1)'));
  DIGESTS.forEach((digest) => o.value(digest, digest));
  o.rmempty = true;

  o = add(
    'openvpn_compression',
    onKind(
      section.option(
        form.ListValue,
        'openvpn_compression',
        _('Compression'),
        _('Only for a server that requires it: compression weakens encryption'),
      ),
      advanced,
    ),
  );
  o.value('', _('Off'));
  Object.entries(COMPRESSION_LABELS).forEach(([value, label]) =>
    o.value(value, label),
  );
  o.rmempty = true;

  o = add(
    'openvpn_mtu',
    onKind(
      section.option(
        form.Value,
        'openvpn_mtu',
        _('MTU'),
        _('tun-mtu in the profile'),
      ),
      advanced,
    ),
  );
  o.validate = wholeNumberField(576, 65535);
  o.placeholder = '1500';
  o.rmempty = true;

  o = add(
    'openvpn_fragment',
    onKind(
      section.option(
        form.Value,
        'openvpn_fragment',
        _('Fragment size'),
        _('Only if the server uses it too (fragment in the profile)'),
      ),
      { ...advanced, openvpn_network: 'udp' },
    ),
  );
  o.validate = wholeNumberField(68, 65535);
  o.rmempty = true;

  o = add(
    'openvpn_mss_fix',
    onKind(
      section.option(
        form.Value,
        'openvpn_mss_fix',
        _('MSS clamping'),
        _('0 switches it off (mssfix in the profile)'),
      ),
      advanced,
    ),
  );
  o.validate = wholeNumberField(0, 65535);
  o.placeholder = '1492';
  o.rmempty = true;

  add(
    'openvpn_ping_interval',
    onKind(
      secondsOption(
        section,
        'openvpn_ping_interval',
        _('Ping interval, seconds'),
        _('ping in the profile'),
        '',
      ),
      advanced,
    ),
  );
  add(
    'openvpn_ping_restart',
    onKind(
      secondsOption(
        section,
        'openvpn_ping_restart',
        _('Reconnect after silence, seconds'),
        _('0 switches it off (ping-restart in the profile)'),
        '120',
      ),
      advanced,
    ),
  );
  add(
    'openvpn_renegotiate',
    onKind(
      secondsOption(
        section,
        'openvpn_renegotiate',
        _('Key renegotiation, seconds'),
        _('0 switches it off (reneg-sec in the profile)'),
        '3600',
      ),
      { ...tls, ...advanced },
    ),
  );

  return options;
}

export function applyImportedOpenVPN(
  map: CBIMap,
  options: Record<string, CBIOption>,
  result: Extract<OpenVPNImportResult, { valid: true }>,
) {
  const settings = openVPNInitialSettings(result.endpoint);
  settings.openvpn_login = result.login ? '1' : '0';
  // The advanced switch first: the fields behind it take values only while shown.
  setModalOptionValue(map, options.openvpn_advanced, settings.openvpn_advanced);
  setModalOptionValue(map, options.openvpn_mode, settings.openvpn_mode);
  setModalOptionValue(map, options.openvpn_login, settings.openvpn_login);
  map.checkDepends();
  Object.entries(options).forEach(([name, option]) => {
    if (name in settings) setModalOptionValue(map, option, settings[name]);
  });
  map.data.set(
    map.config,
    'settings',
    'openvpn_preserved',
    settings.openvpn_preserved,
  );
  map.checkDepends();
}
