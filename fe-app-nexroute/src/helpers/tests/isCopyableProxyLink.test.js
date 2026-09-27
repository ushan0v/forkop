import { describe, expect, it } from 'vitest';
import { isCopyableProxyLink } from '../isCopyableProxyLink';

const copyableLinks = [
  'vless://uuid@example.com:443',
  'vmess://encoded',
  'trojan://password@example.com:443',
  'ss://encoded@example.com:443',
  'ssr://encoded',
  'hysteria2://password@example.com:443',
  'hy2://password@example.com:443',
  'tuic://uuid:password@example.com:443',
  'socks4://example.com:1080',
  'socks4a://example.com:1080',
  'socks5://user:pass@example.com:1080',
];

const nonCopyableLinks = [
  '',
  'direct',
  'block',
  'urltest',
  'http://example.com:80',
  'https://user:pass@example.com:443',
  'https://example.com/subscription',
  'https://example.com',
  'http://example.com:99999',
  'wireguard://example.com',
];

describe('isCopyableProxyLink', () => {
  describe.each(copyableLinks)('copyable proxy URI %s', (link) => {
    it('returns true', () => {
      expect(isCopyableProxyLink(link)).toBe(true);
    });
  });

  describe.each(nonCopyableLinks)('non-copyable value %s', (link) => {
    it('returns false', () => {
      expect(isCopyableProxyLink(link)).toBe(false);
    });
  });
});
