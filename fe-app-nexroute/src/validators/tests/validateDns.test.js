import { describe, expect, it } from 'vitest';
import { validateDNS } from '../validateDns.js';
import { invalidIPs, validIPs } from './validateIp.test';
import { invalidDomains, validDomains } from './validateDomain.test';

export const additionalValidDns = [
  ['Google DNS (port 53)', '8.8.8.8:53'],
  ['Google DNS (port 5353)', '8.8.8.8:5353'],
  ['Cloudflare DNS (port 853)', '1.1.1.1:853'],
  ['Cloudflare domain (port 853)', 'cloudflare-dns.com:853'],
  ['DoH IP', '1.1.1.1/dns-query'],
  ['DoH IP with port 443', '1.1.1.1:443/dns-query'],
  ['DoH domain', 'cloudflare-dns.com/dns-query'],
  ['DoH domain with port 443', 'cloudflare-dns.com:443/dns-query'],
  ['IPv6 DNS', '2606:4700:4700::1111'],
  ['IPv6 DNS with port', '[2606:4700:4700::1111]:853'],
  ['IPv6 DoH with port', '[2606:4700:4700::1111]:443/dns-query'],
];

const validDns = [...validIPs, ...validDomains, ...additionalValidDns];

const invalidDns = [
  ...invalidIPs,
  ...invalidDomains,
  ['Non-numeric port', '8.8.8.8:abc'],
  ['Port too high', 'dns.example.com:99999'],
  ['Zero IPv6 port', '[2606:4700:4700::1111]:0'],
];

describe('validateDns', () => {
  describe.each(validDns)('Valid dns: %s', (_desc, domain) => {
    it(`returns valid=true for "${domain}"`, () => {
      const res = validateDNS(domain);
      expect(res.valid).toBe(true);
    });
  });

  describe.each(invalidDns)('Invalid dns: %s', (_desc, domain) => {
    it(`returns valid=false for "${domain}"`, () => {
      const res = validateDNS(domain);
      expect(res.valid).toBe(false);
    });
  });
});
