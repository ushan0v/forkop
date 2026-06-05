import { describe, expect, it, vi } from 'vitest';
import { canUseDirectClashApi } from '../getClashApiUrl';

describe('canUseDirectClashApi', () => {
  it('allows direct Clash API access from HTTP LuCI', () => {
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'http:' },
    });

    expect(canUseDirectClashApi()).toBe(true);
  });

  it('blocks direct Clash API access from HTTPS LuCI', () => {
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'https:' },
    });

    expect(canUseDirectClashApi()).toBe(false);
  });

  it('blocks direct Clash API access outside a browser location', () => {
    vi.stubGlobal('window', undefined);

    expect(canUseDirectClashApi()).toBe(false);
  });
});
