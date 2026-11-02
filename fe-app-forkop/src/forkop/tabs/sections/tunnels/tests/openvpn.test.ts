import { describe, expect, it } from 'vitest';

import { parseOpenVPNConfig } from '../../../../../helpers/parseOpenVPNConfig';
import {
  CA,
  CLIENT_CERT,
  CLIENT_KEY,
  STATIC_KEY,
} from '../../../../../helpers/tests/openvpnFixtures';
import {
  openVPNEndpoint,
  openVPNInitialSettings,
  parseOpenVPNServer,
  validateOpenVPNSettings,
} from '../openvpn';

const lines = (value: string) => value.split('\n');

function imported(profile: string) {
  const result = parseOpenVPNConfig(profile);
  if (!result.valid) throw new Error(result.message);
  return result;
}

describe('OpenVPN tunnel form', () => {
  it('shows an imported profile and stores it back unchanged', () => {
    const { endpoint } = imported(`client
dev tun
proto udp
remote a.example.com 1194
remote b.example.com 443 tcp
remote-random
remote-cert-tls server
verify-x509-name vpn.example.com name
auth-user-pass
cipher AES-256-CBC
auth SHA256
comp-lzo no
tun-mtu 1400
fragment 1300
mssfix 0
keepalive 10 60
reneg-sec 0
tls-version-min 1.2
key-direction 1
<ca>
${CA}
</ca>
<cert>
${CLIENT_CERT}
</cert>
<key>
${CLIENT_KEY}
</key>
<tls-auth>
${STATIC_KEY}
</tls-auth>
`);
    endpoint.username = 'alice';
    endpoint.password = ' secret ';
    const settings = openVPNInitialSettings(endpoint);
    expect(settings).toMatchObject({
      openvpn_servers: ['a.example.com:1194', 'tcp://b.example.com:443'],
      openvpn_network: 'udp',
      openvpn_login: '1',
      openvpn_control_wrap: 'tls_auth',
      openvpn_key_direction: '1',
      openvpn_advanced: '1',
      openvpn_compression: 'lzo-no',
      openvpn_mss_fix: '0',
      openvpn_renegotiate: '0',
    });
    expect(openVPNEndpoint(settings)).toEqual(endpoint);
    expect(validateOpenVPNSettings(settings)).toBe(true);
  });

  it('builds the same endpoint when LuCI dropped the fields at their defaults', () => {
    const endpoint = openVPNEndpoint(
      openVPNInitialSettings({
        type: 'openvpn-client',
        server: 'vpn.example.com',
        server_port: 1194,
        network: 'udp',
        tls: {
          certificate: ['ca'],
          control_wrap: { type: 'tls_auth', key: ['key'], direction: 'client' },
        },
      }),
    );
    const settings = openVPNInitialSettings(endpoint);
    expect(settings.openvpn_key_direction).toBe('1');
    expect(settings.openvpn_server_name_type).toBe('name');
    expect(settings.openvpn_verify_purpose).toBe('server');

    delete settings.openvpn_key_direction;
    delete settings.openvpn_server_name_type;
    delete settings.openvpn_verify_purpose;
    expect(openVPNEndpoint(settings)).toEqual(endpoint);
  });

  it('tells both key directions from the default one', () => {
    const endpoint = openVPNEndpoint(
      openVPNInitialSettings({
        type: 'openvpn-client',
        server: 'vpn.example.com',
        server_port: 1194,
        network: 'udp',
        tls: {
          certificate: ['ca'],
          control_wrap: { type: 'tls_auth', key: ['key'] },
        },
      }),
    );
    const settings = openVPNInitialSettings(endpoint);
    expect(settings.openvpn_key_direction).toBe('both');
    expect(JSON.stringify(openVPNEndpoint(settings))).not.toContain(
      '"direction"',
    );
  });

  it('keeps what a stored endpoint holds beyond the form', () => {
    const endpoint = {
      type: 'openvpn-client',
      server: 'vpn.example.com',
      server_port: 1194,
      network: 'udp',
      connect_timeout: '5s',
      pull_filters: [{ action: 'ignore', text: 'route ' }],
      tls: { certificate_path: '/etc/openvpn/ca.crt', groups: 'X25519' },
    };
    const settings = openVPNInitialSettings(endpoint);
    expect(settings.openvpn_ca).toBe('/etc/openvpn/ca.crt');
    expect(settings.openvpn_advanced).toBe('0');
    expect(openVPNEndpoint(settings)).toEqual(endpoint);

    settings.openvpn_servers = ['new.example.com:443'];
    expect(openVPNEndpoint(settings)).toMatchObject({
      server: 'new.example.com',
      server_port: 443,
      connect_timeout: '5s',
    });
  });

  it('drops the advanced settings once they are switched off', () => {
    const settings = openVPNInitialSettings(
      imported(
        `client\nremote vpn.example.com 1194\nauth SHA512\ntun-mtu 1400\n<ca>\n${CA}\n</ca>\n`,
      ).endpoint,
    );
    expect(settings.openvpn_advanced).toBe('1');
    settings.openvpn_advanced = '0';
    expect(openVPNEndpoint(settings)).toEqual({
      type: 'openvpn-client',
      server: 'vpn.example.com',
      server_port: 1194,
      network: 'udp',
      tls: { certificate: lines(CA) },
    });
  });

  it('turns the check of the server certificate into what the core reads', () => {
    const base = {
      openvpn_servers: ['vpn.example.com:1194'],
      openvpn_ca: CA,
      openvpn_advanced: '1',
    };
    const tls = (purpose: string) =>
      openVPNEndpoint({ ...base, openvpn_verify_purpose: purpose }).tls;
    expect(tls('server')).toEqual({ certificate: lines(CA) });
    expect(tls('none')).toEqual({
      certificate: lines(CA),
      remote_certificate_tls: 'none',
    });
    expect(tls('ns')).toEqual({
      certificate: lines(CA),
      remote_certificate_tls: 'none',
      ns_certificate_type: 'server',
    });
  });

  it('round trips a static key tunnel', () => {
    const endpoint = {
      type: 'openvpn-client',
      network: 'udp',
      server: '203.0.113.1',
      server_port: 1194,
      mode: 'static_key',
      static_key: lines(STATIC_KEY),
      key_direction: 'client',
      cipher: 'AES-256-CBC',
      address: ['10.8.0.2/32'],
      peer_address: '10.8.0.1',
    };
    const settings = openVPNInitialSettings(endpoint);
    expect(openVPNEndpoint(settings)).toEqual(endpoint);
    expect(validateOpenVPNSettings(settings)).toBe(true);
    expect(
      validateOpenVPNSettings({ ...settings, openvpn_peer_address: '' }),
    ).toBe('Fix the settings');
  });

  it('shows a stored duration in the seconds the fields ask for', () => {
    const settings = openVPNInitialSettings({
      type: 'openvpn-client',
      server: 'vpn.example.com',
      server_port: 1194,
      ping_interval: '1m30s',
      renegotiate_interval: '1h',
    });
    expect(settings).toMatchObject({
      openvpn_advanced: '1',
      openvpn_ping_interval: '90',
      openvpn_renegotiate: '3600',
    });
    expect(openVPNEndpoint(settings)).toMatchObject({
      ping_interval: '90s',
      renegotiate_interval: '3600s',
    });
  });

  it('reads a server as host and port with an optional protocol', () => {
    expect(parseOpenVPNServer('vpn.example.com:443')).toEqual({
      server: 'vpn.example.com',
      port: 443,
      network: '',
    });
    expect(parseOpenVPNServer('tcp://[2001:db8::1]:443')).toEqual({
      server: '2001:db8::1',
      port: 443,
      network: 'tcp',
    });
    expect(parseOpenVPNServer('203.0.113.1')).toMatchObject({ port: 1194 });
    for (const value of ['vpn.example.com:0', 'http://vpn', 'a b:1', ''])
      expect(parseOpenVPNServer(value), value).toBe(null);
  });

  it('asks for what a TLS tunnel cannot connect without', () => {
    const base = { openvpn_servers: ['vpn.example.com:1194'], openvpn_ca: CA };
    expect(validateOpenVPNSettings(base)).toBe(true);
    expect(validateOpenVPNSettings({ ...base, openvpn_servers: [] })).toBe(
      'Fix the settings',
    );
    expect(validateOpenVPNSettings({ ...base, openvpn_ca: '' })).toBe(
      'Fix the settings',
    );
    expect(
      validateOpenVPNSettings({ ...base, openvpn_cert: CLIENT_CERT }),
    ).toBe('Fix the settings');
    expect(validateOpenVPNSettings({ ...base, openvpn_login: '1' })).toBe(
      'Fix the settings',
    );
    expect(
      validateOpenVPNSettings({ ...base, openvpn_control_wrap: 'tls_crypt' }),
    ).toBe('Fix the settings');
    expect(
      validateOpenVPNSettings({
        openvpn_servers: ['vpn.example.com:1194'],
        openvpn_advanced: '1',
        openvpn_peer_fingerprint: ['ab'.repeat(32)],
      }),
    ).toBe(true);
  });
});
