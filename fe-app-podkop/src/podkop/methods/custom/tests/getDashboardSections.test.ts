import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  getConfigSections: vi.fn(),
  getClashApiProxies: vi.fn(),
  fsRead: vi.fn(),
}));

vi.mock('../getConfigSections', () => ({
  getConfigSections: mocks.getConfigSections,
}));

vi.mock('../../shell', () => ({
  PodkopShellMethods: {
    getClashApiProxies: mocks.getClashApiProxies,
  },
}));

vi.mock('../../../../helpers', () => ({
  getClashHttpUrl: () => 'http://router.example:9090',
  getProxyUrlName: (link?: string) =>
    link?.includes('#') ? decodeURIComponent(link.split('#').pop() || '') : '',
  isCopyableProxyLink: (link?: string) => Boolean(link),
}));

import { getDashboardSections } from '../getDashboardSections';
import { ClashAPI, Podkop } from '../../../types';

function proxy(
  type: string,
  options: Partial<ClashAPI.ProxyBase> = {},
): ClashAPI.ProxyBase {
  return {
    type,
    name: options.name || '',
    udp: true,
    history: options.history || [],
    now: options.now,
    all: options.all,
  };
}

function proxySection(
  options: Partial<Podkop.ConfigSection> = {},
): Podkop.ConfigSection {
  return {
    '.name': 'main',
    '.type': 'section',
    enabled: '1',
    action: 'proxy',
    selector_proxy_links: ['vless://example#one'],
    urltest_enabled: '1',
    urltest_filter_mode: 'exclude',
    urltest_hide_filtered_outbounds: '0',
    ...options,
  };
}

const clashProxies: Record<string, ClashAPI.ProxyBase> = {
  'main-out': proxy('Selector', {
    name: 'main-out',
    now: 'main-1-out',
    all: ['main-1-out', 'main-2-out', 'main-3-out', 'main-urltest-out'],
  }),
  'main-urltest-out': proxy('URLTest', {
    name: 'main-urltest-out',
    history: [{ time: '2026-05-27T00:00:00Z', delay: 10 }],
    all: ['main-1-out', 'main-3-out'],
  }),
  'main-1-out': proxy('VLESS', {
    name: 'Included 1',
    history: [{ time: '2026-05-27T00:00:00Z', delay: 100 }],
  }),
  'main-2-out': proxy('VLESS', {
    name: 'Filtered 2',
    history: [{ time: '2026-05-27T00:00:00Z', delay: 200 }],
  }),
  'main-3-out': proxy('VLESS', {
    name: 'Included 3',
    history: [{ time: '2026-05-27T00:00:00Z', delay: 300 }],
  }),
};

describe('getDashboardSections', () => {
  beforeEach(() => {
    mocks.getConfigSections.mockReset();
    mocks.getClashApiProxies.mockReset();
    mocks.fsRead.mockReset();
    mocks.fsRead.mockRejectedValue(new Error('cache miss'));
    vi.stubGlobal('fs', { read: mocks.fsRead });
    vi.stubGlobal('window', undefined);
    vi.stubGlobal('fetch', undefined);

    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: { proxies: clashProxies },
    });
  });

  it('shows the full selector group by default', async () => {
    mocks.getConfigSections.mockResolvedValue([proxySection()]);

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.latencyTestCode).toBe('main-out');
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-2-out',
      'main-3-out',
    ]);
  });

  it('shows and tests only the URLTest group when filtered servers are hidden', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({ urltest_hide_filtered_outbounds: '1' }),
    ]);

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.latencyTestCode).toBe('main-urltest-out');
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-3-out',
    ]);
  });

  it('does not expose flag-emoji detected countries on dashboard outbounds', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({ detect_server_country: 'flag_emoji' }),
    ]);
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        outboundMetadata: {
          names: {},
          countries: { 'main-1-out': 'US' },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(
      section.outbounds.find((item) => item.code === 'main-1-out')?.country,
    ).toBeUndefined();
  });

  it('exposes country.is detected countries on dashboard outbounds', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({ detect_server_country: 'country_is' }),
    ]);
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        outboundMetadata: {
          names: {},
          countries: { 'main-1-out': 'US' },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(
      section.outbounds.find((item) => item.code === 'main-1-out')?.country,
    ).toBe('US');
  });

  it('does not hide servers when URLTest filtering is set to all servers', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        detect_server_country: 'country_is',
        urltest_filter_mode: 'disabled',
        urltest_hide_filtered_outbounds: '1',
      }),
    ]);
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        outboundMetadata: {
          names: {},
          countries: { 'main-1-out': 'US' },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.latencyTestCode).toBe('main-out');
    expect(section.outbounds.map((item) => item.code)).toContain('main-2-out');
    expect(
      section.outbounds.find((item) => item.code === 'main-1-out')?.country,
    ).toBeUndefined();
  });

  it('uses allocated tags for section names that collide with system tags', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({ '.name': 'direct', urltest_enabled: '0' }),
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'direct-1-out': proxy('Selector', {
            name: 'direct-1-out',
            now: 'direct-1-1-out',
            all: ['direct-1-1-out'],
          }),
          'direct-1-1-out': proxy('VLESS', {
            name: 'Direct manual',
            history: [{ time: '2026-05-27T00:00:00Z', delay: 100 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.code).toBe('direct-1-out');
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'direct-1-1-out',
    ]);
  });

  it('fetches Clash API proxies directly in the browser to avoid rpcd output limits', async () => {
    mocks.getConfigSections.mockResolvedValue([
      { '.name': 'settings', '.type': 'settings', yacd_secret_key: 'secret' },
      proxySection(),
    ]);
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ proxies: clashProxies }),
    });

    vi.stubGlobal('window', { location: { hostname: 'router.example' } });
    vi.stubGlobal('fetch', fetchMock);

    const result = await getDashboardSections();

    expect(result.success).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      'http://router.example:9090/proxies',
      {
        headers: { Authorization: 'Bearer secret' },
      },
    );
    expect(mocks.getClashApiProxies).not.toHaveBeenCalled();
  });
});
