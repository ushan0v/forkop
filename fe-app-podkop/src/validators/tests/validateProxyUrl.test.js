import { describe, it, expect } from 'vitest';
import { validateProxyUrl } from '../validateProxyUrl';

const validUrls = [
  ['shadowsocks', 'ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388'],
  [
    'vless',
    'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@example.com:443?type=tcp&encryption=none&security=none',
  ],
  [
    'vmess',
    `vmess://${Buffer.from(
      JSON.stringify({
        v: '2',
        ps: 'Example VMess',
        add: 'example.com',
        port: '443',
        id: '94792286-7bbe-4f33-8b36-18d1bbf70723',
        aid: '0',
        scy: 'auto',
        net: 'ws',
        type: 'none',
        host: 'example.com',
        path: '/ws',
        tls: 'tls',
        sni: 'example.com',
      }),
    ).toString('base64')}`,
  ],
  ['trojan', 'trojan://password@example.com:443'],
  ['socks4', 'socks4://127.0.0.1:1080'],
  ['socks4a', 'socks4a://example.com:1080'],
  ['socks5', 'socks5://user:pass@example.com:1080'],
  ['hysteria2', 'hysteria2://password@example.com:443'],
  ['hy2', 'hy2://password@example.com:443'],
];

describe('validateProxyUrl', () => {
  describe.each(validUrls)('Valid proxy URL: %s', (_desc, url) => {
    it(`returns valid=true for "${url}"`, () => {
      const res = validateProxyUrl(url);
      expect(res.valid).toBe(true);
    });
  });

  it('trims surrounding whitespace before dispatching', () => {
    const res = validateProxyUrl('  socks5://user:pass@example.com:1080  ');

    expect(res.valid).toBe(true);
  });

  it('returns a clear error for unsupported protocols', () => {
    const res = validateProxyUrl('http://example.com');

    expect(res.valid).toBe(false);
    expect(res.message).toContain('vmess://');
    expect(res.message).toContain('socks4a://');
    expect(res.message).toContain('hy2://');
  });
});
