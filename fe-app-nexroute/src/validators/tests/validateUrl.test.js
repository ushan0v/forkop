import { describe, it, expect } from 'vitest';
import { validateUrl } from '../validateUrl';

const validUrls = [
  ['Simple HTTP', 'http://example.com'],
  ['Simple HTTPS', 'https://example.com'],
  ['With path', 'https://example.com/path/to/page'],
  ['With query', 'https://example.com/?q=test'],
  ['With port', 'http://example.com:8080'],
  ['With subdomain', 'https://sub.example.com'],
  ['IPv4 host', 'http://127.0.0.1/forkop-subscription-test.json'],
  ['IPv4 host with port', 'http://192.168.1.1:8080/sub'],
  ['IPv6 host', 'https://[2001:db8::1]/sub'],
  ['IPv6 host with port', 'https://[2001:db8::1]:8443/sub'],
  ['localhost host', 'http://localhost/sub'],
];

const invalidUrls = [
  ['Invalid format', 'not a url'],
  ['Missing protocol', 'example.com'],
  ['Unsupported protocol (ftp)', 'ftp://example.com'],
  ['Unsupported protocol (ws)', 'ws://example.com'],
  ['Empty string', ''],
  ['Without tld', 'https://google'],
  ['Invalid IPv4 host', 'http://999.0.0.1/sub'],
  ['Unbracketed IPv6 host with port', 'http://2001:db8::1:8080/sub'],
];

describe('validateUrl', () => {
  describe.each(validUrls)('Valid URL: %s', (_desc, url) => {
    it(`returns valid=true for "${url}"`, () => {
      const res = validateUrl(url);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidUrls)('Invalid URL: %s', (_desc, url) => {
    it(`returns valid=false for "${url}"`, () => {
      const res = validateUrl(url);
      expect(res.valid).toBe(false);
    });
  });

  it('allows custom protocol list (ftp)', () => {
    const res = validateUrl('ftp://example.com', ['ftp:']);
    expect(res.valid).toBe(true);
  });
});
