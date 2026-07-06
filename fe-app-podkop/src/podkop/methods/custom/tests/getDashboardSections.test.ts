import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  getConfigSections: vi.fn(),
  getClashApiProxies: vi.fn(),
  canUseDirectClashApi: vi.fn(),
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
  canUseDirectClashApi: mocks.canUseDirectClashApi,
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
    urltests: ['urltest'],
    urltest_settings: urlTestSettings('urltest', {
      display_name: 'Fastest',
      urltest_filter_mode: 'exclude',
    }),
    ...options,
  };
}

function urlTestSettings(
  id: string,
  settings: Record<string, string> = {},
): string {
  return JSON.stringify({
    [id]: settings,
  });
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
    mocks.canUseDirectClashApi.mockReset();
    mocks.fsRead.mockReset();
    mocks.fsRead.mockRejectedValue(new Error('cache miss'));
    vi.stubGlobal('fs', { read: mocks.fsRead });
    vi.stubGlobal('window', undefined);
    vi.stubGlobal('fetch', undefined);

    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: { proxies: clashProxies },
    });
    mocks.canUseDirectClashApi.mockReturnValue(false);
  });

  it('shows the full selector group by default', async () => {
    mocks.getConfigSections.mockResolvedValue([proxySection()]);

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.latencyTestCode).toBe('main-out');
    expect(section.latencyTestCodes).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-2-out',
      'main-3-out',
    ]);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-2-out',
      'main-3-out',
    ]);
  });

  it('hydrates URLTest details from the section cache and Clash API', async () => {
    mocks.getConfigSections.mockResolvedValue([proxySection()]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          ...clashProxies,
          'main-urltest-out': proxy('URLTest', {
            name: 'main-urltest-out',
            now: 'main-3-out',
            history: [{ time: '2026-05-27T00:00:00Z', delay: 10 }],
            all: ['main-1-out', 'main-3-out'],
          }),
        },
      },
    });
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        outboundMetadata: {
          names: {
            'main-1-out': 'First cached',
            'main-3-out': 'Third cached',
          },
          countries: {},
        },
        urltestGroups: {
          'main-urltest-out': {
            displayName: 'Fastest',
            outbounds: ['main-1-out', 'main-3-out', 'main-2-out'],
            url: 'https://probe.example/204',
            interval: '3m',
            tolerance: 50,
            interrupt_exist_connections: true,
          },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;
    const urltest = section.outbounds.find(
      (item) => item.code === 'main-urltest-out',
    );

    expect(result.success).toBe(true);
    expect(urltest?.urlTestInfo).toMatchObject({
      code: 'main-urltest-out',
      displayName: 'Fastest',
      url: 'https://probe.example/204',
      interval: '3m',
      tolerance: 50,
      idleTimeout: '30m',
      interruptExistConnections: true,
      selectedCode: 'main-3-out',
      selectedName: 'Third cached',
    });
    expect(urltest?.urlTestInfo?.outbounds.map((item) => item.code)).toEqual([
      'main-3-out',
      'main-1-out',
      'main-2-out',
    ]);
    expect(urltest?.urlTestInfo?.outbounds[0]).toMatchObject({
      displayName: 'Third cached',
      latency: 300,
      type: 'VLESS',
      selected: true,
    });
    expect(urltest?.urlTestInfo?.outbounds[1]).toMatchObject({
      displayName: 'one',
      latency: 100,
      selected: false,
    });
  });

  it('hides servers already added to the URLTest group when enabled', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltest_settings: urlTestSettings('urltest', {
          display_name: 'Fastest',
          hide_added_outbounds: '1',
        }),
      }),
    ]);

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.latencyTestCode).toBe('main-out');
    expect(section.latencyTestCodes).toEqual([
      'main-urltest-out',
      'main-2-out',
    ]);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-2-out',
    ]);
  });

  it('keeps legacy URLTest sections compatible before migration', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltests: undefined,
        urltest_settings: undefined,
        urltest_enabled: '1',
        urltest_filter_mode: 'exclude',
      }),
    ]);

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-2-out',
      'main-3-out',
    ]);
    expect(section.outbounds[0].displayName).toBe('Fastest');
  });

  it('supports multiple configured URLTest groups', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltests: undefined,
        urltest_settings: undefined,
      }),
      {
        '.name': 'cfg010001',
        '.type': 'urltest',
        section: 'main',
        name: 'Fast group',
      },
      {
        '.name': 'cfg010002',
        '.type': 'urltest',
        section: 'main',
        name: 'Stable group',
      },
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          ...clashProxies,
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'main-urltest-cfg010001-out',
            all: [
              'main-1-out',
              'main-urltest-cfg010002-out',
              'main-2-out',
              'main-urltest-cfg010001-out',
            ],
          }),
          'main-urltest-cfg010001-out': proxy('URLTest', {
            name: 'main-urltest-cfg010001-out',
            history: [{ time: '2026-05-27T00:00:00Z', delay: 10 }],
            all: ['main-1-out'],
          }),
          'main-urltest-cfg010002-out': proxy('URLTest', {
            name: 'main-urltest-cfg010002-out',
            history: [{ time: '2026-05-27T00:00:00Z', delay: 50 }],
            all: ['main-2-out'],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-cfg010001-out',
      'main-urltest-cfg010002-out',
      'main-1-out',
      'main-2-out',
    ]);
    expect(section.outbounds.map((item) => item.displayName)).toEqual([
      'Fast group',
      'Stable group',
      'one',
      'Filtered 2',
    ]);
  });

  it.each(['exclude', 'include', 'mixed', 'disabled'] as const)(
    'hides added URLTest members independently from %s filter mode',
    async (urltest_filter_mode) => {
      mocks.getConfigSections.mockResolvedValue([
        proxySection({
          urltest_settings: urlTestSettings('urltest', {
            display_name: 'Fastest',
            urltest_filter_mode,
            hide_added_outbounds: '1',
          }),
        }),
      ]);

      const result = await getDashboardSections();
      const [section] = result.data;

      expect(result.success).toBe(true);
      expect(section.latencyTestCode).toBe('main-out');
      expect(section.latencyTestCodes).toEqual([
        'main-urltest-out',
        'main-2-out',
      ]);
    },
  );

  it('keeps non-built-in URLTest groups in selector order when latency sorting is disabled', async () => {
    mocks.getConfigSections.mockResolvedValue([proxySection()]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'main-2-out',
            all: [
              'main-2-out',
              'main-provider-urltest-out',
              'main-1-out',
              'main-urltest-out',
            ],
          }),
          'main-urltest-out': proxy('URLTest', {
            name: 'main-urltest-out',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 10 }],
            all: ['main-2-out', 'main-1-out'],
          }),
          'main-provider-urltest-out': proxy('URLTest', {
            name: 'Provider URLTest',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 150 }],
            all: ['provider-hidden-1-out'],
          }),
          'main-1-out': proxy('VLESS', {
            name: 'Fast leaf',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 100 }],
          }),
          'main-2-out': proxy('VLESS', {
            name: 'Slow leaf',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 300 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.latencyTestCodes).toEqual([
      'main-urltest-out',
      'main-2-out',
      'main-provider-urltest-out',
      'main-1-out',
    ]);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-2-out',
      'main-provider-urltest-out',
      'main-1-out',
    ]);
  });

  it('sorts outbounds by latency only when enabled and does not prioritize URLTest groups except Fastest', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({ sort_by_latency: '1' }),
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'main-2-out',
            all: [
              'main-2-out',
              'main-provider-urltest-out',
              'main-1-out',
              'main-urltest-out',
            ],
          }),
          'main-urltest-out': proxy('URLTest', {
            name: 'main-urltest-out',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 10 }],
            all: ['main-2-out', 'main-1-out'],
          }),
          'main-provider-urltest-out': proxy('URLTest', {
            name: 'Provider URLTest',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 150 }],
            all: ['provider-hidden-1-out'],
          }),
          'main-1-out': proxy('VLESS', {
            name: 'Fast leaf',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 100 }],
          }),
          'main-2-out': proxy('VLESS', {
            name: 'Slow leaf',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 300 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.latencyTestCodes).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-provider-urltest-out',
      'main-2-out',
    ]);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-provider-urltest-out',
      'main-2-out',
    ]);
  });

  it('sorts an unpinned configured URLTest group by latency', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        sort_by_latency: '1',
        urltest_settings: urlTestSettings('urltest', {
          display_name: 'Fastest',
          pin_dashboard: '0',
        }),
      }),
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'main-2-out',
            all: ['main-2-out', 'main-1-out', 'main-urltest-out'],
          }),
          'main-urltest-out': proxy('URLTest', {
            name: 'main-urltest-out',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 250 }],
            all: ['main-2-out', 'main-1-out'],
          }),
          'main-1-out': proxy('VLESS', {
            name: 'Fast leaf',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 100 }],
          }),
          'main-2-out': proxy('VLESS', {
            name: 'Slow leaf',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 300 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-1-out',
      'main-urltest-out',
      'main-2-out',
    ]);
  });

  it('keeps visible URLTest groups when added leaf servers are hidden', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltest_settings: urlTestSettings('urltest', {
          display_name: 'Fastest',
          hide_added_outbounds: '1',
        }),
      }),
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'main-1-out',
            all: [
              'main-1-out',
              'main-provider-urltest-out',
              'main-2-out',
              'main-3-out',
              'main-urltest-out',
            ],
          }),
          'main-urltest-out': proxy('URLTest', {
            name: 'main-urltest-out',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 10 }],
            all: ['main-1-out', 'main-3-out'],
          }),
          'main-provider-urltest-out': proxy('URLTest', {
            name: 'Provider URLTest',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 150 }],
            all: ['provider-hidden-1-out'],
          }),
          'main-1-out': proxy('VLESS', {
            name: 'Included 1',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 100 }],
          }),
          'main-2-out': proxy('VLESS', {
            name: 'Filtered 2',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 200 }],
          }),
          'main-3-out': proxy('VLESS', {
            name: 'Included 3',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 300 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.latencyTestCodes).toEqual([
      'main-urltest-out',
      'main-provider-urltest-out',
      'main-2-out',
    ]);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-provider-urltest-out',
      'main-2-out',
    ]);
  });

  it('does not expose flag-emoji detected countries on dashboard outbounds', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltest_settings: urlTestSettings('urltest', {
          display_name: 'Fastest',
          urltest_filter_mode: 'exclude',
          detect_server_country: 'flag_emoji',
        }),
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
    expect(
      section.outbounds.find((item) => item.code === 'main-1-out')?.country,
    ).toBeUndefined();
  });

  it('exposes country.is detected countries on dashboard outbounds', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltest_settings: urlTestSettings('urltest', {
          display_name: 'Fastest',
          urltest_filter_mode: 'exclude',
          detect_server_country: 'country_is',
        }),
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
    expect(
      section.outbounds.find((item) => item.code === 'main-1-out')?.country,
    ).toBe('US');
  });

  it('marks subscription outbounds as copyable when section cache has link refs', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        subscription_urls: ['https://subscription.example/list'],
      }),
    ]);
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        links: {},
        linkRefs: {
          'main-2-out': {
            sourceSection: 'main-subscription-1',
            sourceIndex: 1,
          },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;
    const subscriptionOutbound = section.outbounds.find(
      (item) => item.code === 'main-2-out',
    );

    expect(result.success).toBe(true);
    expect(subscriptionOutbound?.link).toBe('');
    expect(subscriptionOutbound?.canCopyLink).toBe(true);
  });

  it('does not expose countries when URLTest filtering is set to all servers', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltest_settings: urlTestSettings('urltest', {
          display_name: 'Fastest',
          detect_server_country: 'country_is',
          urltest_filter_mode: 'disabled',
        }),
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
    expect(section.latencyTestCodes).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-2-out',
      'main-3-out',
    ]);
    expect(section.outbounds.map((item) => item.code)).toContain('main-2-out');
    expect(
      section.outbounds.find((item) => item.code === 'main-1-out')?.country,
    ).toBeUndefined();
  });

  it('uses allocated tags for section names that collide with system tags', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        '.name': 'direct',
        urltests: [],
        urltest_settings: undefined,
        urltest_enabled: '0',
      }),
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'direct-out-1': proxy('Selector', {
            name: 'direct-out-1',
            now: 'direct-1-out',
            all: ['direct-1-out'],
          }),
          'direct-1-out': proxy('VLESS', {
            name: 'Direct manual',
            history: [{ time: '2026-05-27T00:00:00Z', delay: 100 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.code).toBe('direct-out-1');
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'direct-1-out',
    ]);
  });

  it('shows legacy VPN interface sections as a Connection selector group', async () => {
    mocks.getConfigSections.mockResolvedValue([
      {
        '.name': 'AWG',
        '.type': 'section',
        enabled: '1',
        action: 'vpn',
        interface: 'awg1',
      },
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'AWG-out': proxy('Selector', {
            name: 'AWG-out',
            now: 'AWG-interface-1-out',
            all: ['AWG-interface-1-out'],
          }),
          'AWG-interface-1-out': proxy('Direct', {
            name: 'awg1',
            history: [{ time: '2026-06-07T00:00:00Z', delay: 445 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.action).toBe('vpn');
    expect(section.withTagSelect).toBe(true);
    expect(section.proxyConfigType).toBe('interface');
    expect(section.outbounds[0]).toMatchObject({
      code: 'AWG-interface-1-out',
      displayName: 'awg1',
      selected: true,
    });
  });

  it('does not expose ByeDPI sections on the dashboard', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection(),
      {
        '.name': 'dpi',
        '.type': 'section',
        enabled: '1',
        action: 'byedpi',
      },
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          ...clashProxies,
          'dpi-out': proxy('Socks', {
            name: 'dpi-out',
            history: [{ time: '2026-06-10T00:00:00Z', delay: 20 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();

    expect(result.success).toBe(true);
    expect(result.data.map((section) => section.sectionName)).toEqual(['main']);
  });

  it('fetches Clash API proxies directly in the browser to avoid rpcd output limits', async () => {
    mocks.getConfigSections.mockResolvedValue([
      { '.name': 'settings', '.type': 'settings', yacd_secret_key: 'secret' },
      proxySection(),
    ]);
    mocks.canUseDirectClashApi.mockReturnValue(true);
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

  it('uses rpcd fallback when direct Clash API access is unsafe', async () => {
    mocks.getConfigSections.mockResolvedValue([proxySection()]);
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ proxies: clashProxies }),
    });

    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'https:' },
    });
    vi.stubGlobal('fetch', fetchMock);

    const result = await getDashboardSections();

    expect(result.success).toBe(true);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(mocks.getClashApiProxies).toHaveBeenCalledTimes(1);
  });
});
