import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  getConfigSections: vi.fn(),
  clashApi: vi.fn(),
  clashSummary: vi.fn(),
  canUseDirectClashApi: vi.fn(),
}));

vi.mock('../getConfigSections', () => ({
  getConfigSections: mocks.getConfigSections,
}));

vi.mock('../../shell', () => ({
  ForkopShellMethods: {
    clashApi: mocks.clashApi,
    clashSummary: mocks.clashSummary,
  },
}));

vi.mock('../../../../helpers/getClashApiUrl', () => ({
  canUseDirectClashApi: mocks.canUseDirectClashApi,
  getClashApiUrl: () => 'http://router.example:9090',
}));
vi.mock('../../../../helpers/isCopyableProxyLink', () => ({
  isCopyableProxyLink: (link?: string) => Boolean(link),
}));

import {
  closeAllClashApiConnections,
  getClashApiConnections,
  getClashApiConnectionsSummary,
  getClashApiGroupLatency,
  getClashApiProxyLatency,
  getClashApiProxyLink,
  resetClashApiTransport,
  setClashApiGroupProxy,
  updateClashApiProxyProviders,
  updateClashApiRuleProviders,
} from '../clashApi';
import { getDashboardSections } from '../getDashboardSections';
import { ClashAPI, Forkop } from '../../../types';

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
    url: options.url,
    interval: options.interval,
    idle_timeout: options.idle_timeout,
    groups: options.groups,
    fixed: options.fixed,
    bandwidth: options.bandwidth,
  };
}

function section(
  options: Partial<Forkop.ConfigSection> = {},
): Forkop.ConfigSection {
  return {
    '.name': 'main',
    '.type': 'section',
    enabled: '1',
    action: 'connection',
    label: 'Office',
    ...options,
  };
}

function child(
  type: Forkop.ConfigSection['.type'],
  name: string,
  options: Partial<Forkop.ConfigSection> = {},
): Forkop.ConfigSection {
  return {
    '.name': name,
    '.type': type,
    section: 'main',
    ...options,
  };
}

function links(entries: Array<[string, string]>) {
  return entries.map(([name, uri], index) =>
    child('connection_link', `link${index + 1}`, {
      name,
      uri,
      order: `${index}`,
    }),
  );
}

function neverAnsweringFetch() {
  return vi.fn(
    (_url: string, init?: RequestInit) =>
      new Promise((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => {
          reject(new Error('The operation was aborted'));
        });
      }),
  );
}

function clashApiJson(status: number, payload: unknown) {
  return {
    success: true,
    data: {
      status,
      body: payload === undefined ? '' : JSON.stringify(payload),
    },
  };
}

let clashProxies: Record<string, ClashAPI.ProxyBase> = {};
let clashProviders: Record<string, unknown> = {};

function useClashApiRuntime() {
  mocks.clashApi.mockImplementation(async (_method: string, path: string) =>
    path === '/providers/proxies'
      ? clashApiJson(200, { providers: clashProviders })
      : clashApiJson(200, { proxies: clashProxies }),
  );
}

function setClashProxies(proxies: Record<string, ClashAPI.ProxyBase>) {
  clashProxies = proxies;
  useClashApiRuntime();
}

function setClashProviders(providers: Record<string, unknown>) {
  clashProviders = providers;
  useClashApiRuntime();
}

async function primeClashApi() {
  mocks.getConfigSections.mockResolvedValue([section()]);
  setClashProxies({
    Office: proxy('Selector', { all: ['Office/Node'] }),
    'Office/Node': proxy('VLESS'),
  });
  await getDashboardSections();
  mocks.clashApi.mockClear();
  mocks.clashApi.mockResolvedValue(clashApiJson(200, { connections: [] }));
}

async function useReachableClashApi() {
  mocks.canUseDirectClashApi.mockReturnValue(true);
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({ status: 200, text: async () => '{}' }),
  );
  resetClashApiTransport();

  await vi.waitFor(async () => {
    mocks.clashApi.mockClear();
    await getClashApiConnections();
    expect(mocks.clashApi).not.toHaveBeenCalled();
  });
}

describe('getDashboardSections', () => {
  beforeEach(async () => {
    mocks.getConfigSections.mockReset();
    mocks.getConfigSections.mockResolvedValue([]);
    mocks.clashApi.mockReset();
    mocks.clashSummary.mockReset();
    clashProxies = {};
    clashProviders = {};
    useClashApiRuntime();
    mocks.canUseDirectClashApi.mockReset();

    await useReachableClashApi();

    mocks.getConfigSections.mockReset();
    mocks.getConfigSections.mockResolvedValue([]);
    mocks.clashApi.mockReset();
    useClashApiRuntime();
    mocks.canUseDirectClashApi.mockReturnValue(false);
    vi.stubGlobal('window', undefined);
    vi.stubGlobal('fetch', undefined);
  });

  it('derives manual node identity and presentation from readable runtime tags', async () => {
    const uris = [
      'vless://first@example.com:443#Same',
      'vless://second@example.com:443#Same',
      'trojan://secret@example.com:443',
      'vmess://example#Folder%2FNode',
    ];
    mocks.getConfigSections.mockResolvedValue([
      section(),
      ...links([
        ['Same', uris[0]],
        ['Same #2', uris[1]],
        ['Node #3', uris[2]],
        ['Folder/Node', uris[3]],
      ]),
    ]);
    setClashProxies({
      Office: proxy('Selector', {
        name: 'Office',
        now: 'Office/Same',
        all: [
          'Office/Same',
          'Office/Same #2',
          'Office/Node #3',
          'Office/Folder/Node',
        ],
      }),
      'Office/Same': proxy('VLESS'),
      'Office/Same #2': proxy('VLESS'),
      'Office/Node #3': proxy('Trojan'),
      'Office/Folder/Node': proxy('VMess'),
    });

    const result = await getDashboardSections();
    const [dashboardSection] = result.data;

    expect(result.success).toBe(true);
    expect(dashboardSection.code).toBe('Office');
    expect(dashboardSection.outbounds).toEqual([
      expect.objectContaining({
        code: 'Office/Same',
        displayName: 'Same',
        link: uris[0],
        selected: true,
      }),
      expect.objectContaining({
        code: 'Office/Same #2',
        displayName: 'Same #2',
        link: uris[1],
      }),
      expect.objectContaining({
        code: 'Office/Node #3',
        displayName: 'Node #3',
        link: uris[2],
      }),
      expect.objectContaining({
        code: 'Office/Folder/Node',
        displayName: 'Folder/Node',
        link: uris[3],
      }),
    ]);
  });

  it("uses a subscription's tag as structure and as its nodes' badge", async () => {
    mocks.getConfigSections.mockResolvedValue([
      section(),
      child('subscription_url', 'subscription1', {
        url: 'https://example.com/subscription',
        tag: 'premium',
        show_dashboard_metadata: '1',
      }),
    ]);
    setClashProxies({
      Office: proxy('Selector', {
        name: 'Office',
        now: 'Office/premium/DE/Frankfurt',
        all: ['Office/premium/DE/Frankfurt'],
      }),
      'Office/premium/DE/Frankfurt': proxy('HTTP'),
    });
    setClashProviders({
      'Office/premium': {
        name: 'Office/premium',
        type: 'Remote',
        vehicleType: 'HTTP',
        proxies: [proxy('HTTP', { name: 'Office/premium/DE/Frankfurt' })],
        subscriptionInfo: {
          upload: 10,
          download: 20,
          total: 100,
          expire: 200,
        },
      },
    });

    const result = await getDashboardSections();
    const [dashboardSection] = result.data;

    expect(dashboardSection.proxyConfigType).toBe('subscription');
    expect(dashboardSection.outbounds[0]).toMatchObject({
      code: 'Office/premium/DE/Frankfurt',
      displayName: 'DE/Frankfurt',
      subscriptionTag: 'premium',
      canCopyLink: true,
    });
    expect(dashboardSection.subscriptionMetadata?.[0]).toMatchObject({
      sourceSection: 'Office/premium',
      traffic: { used: 30, total: 100, remaining: 70 },
      expire: 200,
    });
    expect(dashboardSection.subscriptionProviderTags).toEqual([
      'Office/premium',
    ]);
  });

  it('offers the link of a subscription node whose link the core writes', async () => {
    mocks.getConfigSections.mockResolvedValue([
      section(),
      child('subscription_url', 'subscription1', {
        url: 'https://example.com/subscription',
        tag: 'premium',
      }),
    ]);
    const types = ['TrustTunnel', 'AnyTLS', 'Naive', 'Mieru', 'Snell'];
    const nodes = types.map((type) =>
      proxy(type, { name: `Office/premium/${type}` }),
    );
    setClashProxies({
      Office: proxy('Selector', {
        name: 'Office',
        now: nodes[0].name,
        all: nodes.map((node) => node.name),
      }),
      ...Object.fromEntries(nodes.map((node) => [node.name, node])),
    });
    setClashProviders({
      'Office/premium': {
        name: 'Office/premium',
        type: 'Remote',
        vehicleType: 'HTTP',
        proxies: nodes,
      },
    });

    const [dashboardSection] = (await getDashboardSections()).data;

    expect(
      Object.fromEntries(
        dashboardSection.outbounds.map((outbound) => [
          outbound.code,
          outbound.canCopyLink,
        ]),
      ),
    ).toEqual({
      'Office/premium/TrustTunnel': true,
      'Office/premium/AnyTLS': true,
      'Office/premium/Naive': true,
      'Office/premium/Mieru': true,
      'Office/premium/Snell': false,
    });
  });

  it('shows two subscriptions of one address under their own tags', async () => {
    mocks.getConfigSections.mockResolvedValue([
      section(),
      child('subscription_url', 'subscription1', {
        url: 'https://example.com/subscription',
        tag: 'sub1',
        show_dashboard_metadata: '0',
      }),
      child('subscription_url', 'subscription2', {
        url: 'https://example.com/subscription',
        tag: 'sub2',
        show_dashboard_metadata: '1',
      }),
    ]);
    setClashProxies({
      Office: proxy('Selector', {
        name: 'Office',
        now: 'Office/sub1/DE',
        all: ['Office/sub1/DE', 'Office/sub2/DE'],
      }),
      'Office/sub1/DE': proxy('HTTP'),
      'Office/sub2/DE': proxy('HTTP'),
    });
    const provider = (tag: string) => ({
      name: `Office/${tag}`,
      type: 'Remote',
      vehicleType: 'HTTP',
      proxies: [proxy('HTTP', { name: `Office/${tag}/DE` })],
      subscriptionInfo: { upload: 10, download: 20, total: 100, expire: 200 },
    });
    setClashProviders({
      'Office/sub1': provider('sub1'),
      'Office/sub2': provider('sub2'),
    });

    const [dashboardSection] = (await getDashboardSections()).data;

    expect(dashboardSection.subscriptionProviderTags).toEqual([
      'Office/sub1',
      'Office/sub2',
    ]);
    expect(
      dashboardSection.outbounds.map((outbound) => outbound.subscriptionTag),
    ).toEqual(['sub1', 'sub2']);
    expect(
      dashboardSection.subscriptionMetadata?.map((item) => item.sourceSection),
    ).toEqual(['Office/sub2']);
  });

  it("carries the core's last update, and none for a subscription it never downloaded", async () => {
    mocks.getConfigSections.mockResolvedValue([
      section(),
      child('subscription_url', 'subscription1', {
        url: 'https://example.com/one',
        tag: 'sub1',
      }),
      child('subscription_url', 'subscription2', {
        url: 'https://example.com/two',
        tag: 'sub2',
      }),
    ]);
    setClashProxies({
      Office: proxy('Selector', {
        name: 'Office',
        now: 'Office/sub1/DE',
        all: ['Office/sub1/DE'],
      }),
      'Office/sub1/DE': proxy('HTTP'),
    });
    // An expired subscription keeps the headers of the answer it was refused with.
    setClashProviders({
      'Office/sub1': {
        name: 'Office/sub1',
        type: 'Proxy',
        vehicleType: 'Remote',
        proxies: [proxy('HTTP', { name: 'Office/sub1/DE' })],
        updatedAt: '2026-10-21T17:42:30.868334621Z',
        subscriptionInfo: { Upload: 0, Download: 20, Total: 100, Expire: 0 },
      },
      'Office/sub2': {
        name: 'Office/sub2',
        type: 'Proxy',
        vehicleType: 'Remote',
        proxies: [],
        updatedAt: '0001-01-01T00:00:00Z',
        subscriptionInfo: { Upload: 0, Download: 0, Total: 0, Expire: 200 },
      },
    });

    const [dashboardSection] = (await getDashboardSections()).data;

    expect(
      dashboardSection.subscriptionMetadata?.map((item) => [
        item.subscriptionTag,
        item.updatedAt,
      ]),
    ).toEqual([
      ['sub1', Date.UTC(2026, 9, 21, 17, 42, 30, 868) / 1000],
      ['sub2', undefined],
    ]);
  });

  it('does not classify a static slash name as a subscription node', async () => {
    mocks.getConfigSections.mockResolvedValue([
      section(),
      ...links([
        ['premium/Static', 'vless://static@example.com:443#premium%2FStatic'],
      ]),
      child('subscription_url', 'subscription1', {
        url: 'https://example.com/subscription',
        tag: 'premium',
      }),
    ]);
    setClashProxies({
      Office: proxy('Selector', {
        name: 'Office',
        now: 'Office/premium/Static',
        all: ['Office/premium/Static', 'Office/premium/Remote'],
      }),
      'Office/premium/Static': proxy('VLESS'),
      'Office/premium/Remote': proxy('Trojan'),
    });
    setClashProviders({
      'Office/premium': {
        name: 'Office/premium',
        type: 'Remote',
        vehicleType: 'HTTP',
        proxies: [proxy('Trojan', { name: 'Office/premium/Remote' })],
      },
    });

    const result = await getDashboardSections();

    expect(result.data[0].outbounds).toEqual([
      expect.objectContaining({
        code: 'Office/premium/Static',
        displayName: 'premium/Static',
        subscriptionTag: undefined,
      }),
      expect.objectContaining({
        code: 'Office/premium/Remote',
        displayName: 'Remote',
        subscriptionTag: 'premium',
      }),
    ]);
  });

  it('hydrates readable URLTest and Fallback groups from UCI and Clash API', async () => {
    mocks.getConfigSections.mockResolvedValue([
      section(),
      child('subscription_url', 'office', {
        url: 'https://office.example/sub',
        tag: 'sub1',
      }),
      child('urltest', 'fast', {
        name: 'Fast',
        testing_url: 'https://fast.example/204',
        expected_status: '204/200-299',
        check_interval: '30s',
        tolerance: '25',
      }),
      child('fallback_group', 'rescue', {
        name: 'Rescue',
        health_check_url: 'https://fallback.example/204',
        attempt_timeout: '9s',
      }),
      child('fallback_level', 'primary', {
        section: undefined,
        group: 'rescue',
        name: 'Primary',
        order: '0',
      }),
      child('fallback_level', 'backup', {
        section: undefined,
        group: 'rescue',
        name: 'Backup',
        order: '1',
      }),
    ]);
    setClashProxies({
      Office: proxy('Selector', {
        name: 'Office',
        now: 'Office/Rescue',
        all: ['Office/Fast', 'Office/Rescue', 'Office/Nested'],
      }),
      'Office/Fast': proxy('URLTest', {
        name: 'Office/Fast',
        now: 'Office/Node A',
        all: ['Office/Node A', 'Office/Node B'],
        url: 'https://runtime.example/204',
        interval: '45s',
        bandwidth: {
          running: false,
          minimum_mbps: 50,
          results: {
            'Office/Node A': {
              time: '2026-10-29T10:00:00Z',
              mbps: 123,
              bytes: 33554432,
              admitted: true,
            },
          },
        },
      }),
      'Office/Rescue': proxy('Fallback', {
        name: 'Office/Rescue',
        now: 'Office/Node B',
        fixed: 'Office/Node B',
        groups: [
          { outbounds: ['Office/Node A'] },
          { outbounds: ['Office/Node B'] },
        ],
      }),
      'Office/Node A': proxy('VLESS', {
        history: [{ time: '2026-08-13T00:00:00Z', delay: 80 }],
      }),
      'Office/Node B': proxy('Trojan', {
        history: [{ time: '2026-08-13T00:00:00Z', delay: 120 }],
      }),
      'Office/Nested': proxy('Selector', {
        all: ['Office/Node C'],
        now: 'Office/Node C',
      }),
      'Office/Node C': proxy('VLESS'),
    });

    const result = await getDashboardSections();
    const [urltest, fallback] = result.data[0].outbounds;

    expect(urltest).toMatchObject({
      code: 'Office/Fast',
      displayName: 'Fast',
      type: 'URLTest',
      urlTestInfo: {
        selectedName: 'Node A',
        url: 'https://runtime.example/204',
        interval: '45s',
        tolerance: 25,
        expectedStatus: '204/200-299',
        interruptExistConnections: false,
      },
    });
    expect(result.data[0].code).toBe('Office');
    expect(urltest.urlTestInfo?.bandwidth?.minimum_mbps).toBe(50);
    expect(
      urltest.urlTestInfo?.outbounds.find(
        (node) => node.code === 'Office/Node A',
      )?.bandwidth,
    ).toMatchObject({ mbps: 123, admitted: true });
    expect(fallback).toMatchObject({
      code: 'Office/Rescue',
      displayName: 'Rescue',
      type: 'Fallback',
      selected: true,
      fallbackInfo: {
        selectedName: 'Node B',
        healthCheckUrl: 'https://fallback.example/204',
        attemptTimeout: '9s',
        interruptExistConnections: false,
      },
    });
    expect(fallback.fallbackInfo?.outbounds).toEqual([
      expect.objectContaining({
        code: 'Office/Node A',
        displayName: 'Node A',
        levelName: 'Primary',
        pinned: false,
      }),
      expect.objectContaining({
        code: 'Office/Node B',
        displayName: 'Node B',
        levelName: 'Backup',
        selected: true,
        pinned: true,
      }),
    ]);
  });

  it('leaves out a configured group the runtime does not carry', async () => {
    mocks.getConfigSections.mockResolvedValue([
      section(),
      ...links([['Node A', 'vless://node@example.com:443#Node A']]),
      child('urltest', 'ghost', { name: 'Ghost' }),
      child('fallback_group', 'ghostGroup', { name: 'Ghost group' }),
      child('fallback_level', 'primary', {
        section: undefined,
        group: 'ghostGroup',
        name: 'Primary',
        order: '0',
      }),
    ]);
    setClashProxies({
      Office: proxy('Selector', {
        name: 'Office',
        now: 'Office/Node A',
        all: ['Office/Node A'],
      }),
      'Office/Node A': proxy('VLESS'),
    });

    const result = await getDashboardSections();

    expect(result.data[0].outbounds).toHaveLength(1);
    expect(result.data[0].outbounds[0]).toMatchObject({
      code: 'Office/Node A',
      urlTestInfo: undefined,
      fallbackInfo: undefined,
    });
  });

  it('uses readable child tags for interface outbounds', async () => {
    mocks.getConfigSections.mockResolvedValue([
      section(),
      child('section_interface', 'interface1', {
        name: 'wg0',
        display_name: 'Home WG',
      }),
    ]);
    setClashProxies({
      Office: proxy('Selector', {
        name: 'Office',
        now: 'Office/Home WG',
        all: ['Office/Home WG'],
      }),
      'Office/Home WG': proxy('WireGuard'),
    });

    const result = await getDashboardSections();

    expect(result.data[0]).toMatchObject({
      code: 'Office',
      displayName: 'Office',
      proxyConfigType: 'interface',
    });
    expect(result.data[0].outbounds[0]).toMatchObject({
      code: 'Office/Home WG',
      displayName: 'Home WG',
      type: 'WireGuard',
    });
  });

  it('fetches Clash API directly when browser access is safe', async () => {
    mocks.getConfigSections.mockResolvedValue([
      section(),
      ...links([['Node', 'vless://example#Node']]),
    ]);
    mocks.canUseDirectClashApi.mockReturnValue(true);
    const fetchMock = vi.fn().mockResolvedValue({
      status: 200,
      text: async () =>
        JSON.stringify({
          proxies: {
            Office: proxy('Selector', { all: ['Office/Node'] }),
            'Office/Node': proxy('VLESS'),
          },
        }),
    });
    vi.stubGlobal('fetch', fetchMock);

    const result = await getDashboardSections();

    expect(result.success).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      'http://router.example:9090/proxies',
      expect.objectContaining({ signal: expect.anything() }),
    );
    expect(mocks.clashApi).not.toHaveBeenCalled();
  });

  it('falls back to the CLI transport when the controller is unreachable', async () => {
    mocks.getConfigSections.mockResolvedValue([
      section(),
      ...links([['Node', 'vless://example#Node']]),
    ]);
    mocks.canUseDirectClashApi.mockReturnValue(true);
    vi.stubGlobal(
      'fetch',
      vi.fn().mockRejectedValue(new TypeError('Failed to fetch')),
    );
    setClashProxies({
      Office: proxy('Selector', { all: ['Office/Node'] }),
      'Office/Node': proxy('VLESS'),
    });

    const result = await getDashboardSections();

    expect(result.success).toBe(true);
    expect(mocks.clashApi).toHaveBeenCalledWith('GET', '/proxies', '');
  });

  it('switches selectors through the direct Clash API', async () => {
    mocks.getConfigSections.mockResolvedValue([section()]);
    setClashProxies({
      Office: proxy('Selector', { all: ['Office/Node'] }),
      'Office/Node': proxy('VLESS'),
    });
    await getDashboardSections();
    mocks.clashApi.mockClear();

    mocks.canUseDirectClashApi.mockReturnValue(true);
    const fetchMock = vi.fn().mockResolvedValue({ status: 204 });
    vi.stubGlobal('fetch', fetchMock);

    const result = await setClashApiGroupProxy('Office/OUT', 'Office/Node');

    expect(result.success).toBe(true);
    expect(fetchMock).toHaveBeenLastCalledWith(
      'http://router.example:9090/proxies/Office%2FOUT',
      expect.objectContaining({
        method: 'PUT',
        body: JSON.stringify({ name: 'Office/Node' }),
      }),
    );
    expect(mocks.clashApi).not.toHaveBeenCalled();
  });

  it('fetches provider links and refreshes providers through the direct Clash API', async () => {
    mocks.getConfigSections.mockResolvedValue([section()]);
    setClashProxies({
      Office: proxy('Selector', { all: ['Office/Node'] }),
      'Office/Node': proxy('VLESS'),
    });
    await getDashboardSections();
    mocks.clashApi.mockClear();

    mocks.canUseDirectClashApi.mockReturnValue(true);
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        status: 200,
        text: async () => JSON.stringify({ url: 'vless://id@example.com:443' }),
      })
      .mockResolvedValue({ status: 204 });
    vi.stubGlobal('fetch', fetchMock);

    await expect(getClashApiProxyLink('Office/Node')).resolves.toEqual({
      success: true,
      data: { url: 'vless://id@example.com:443' },
    });
    await expect(
      updateClashApiProxyProviders(['Office/premium', 'Office/backup']),
    ).resolves.toEqual({ success: true, data: undefined });

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      'http://router.example:9090/proxies/Office%2FNode/link',
      expect.anything(),
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      'http://router.example:9090/providers/proxies/Office%2Fpremium',
      expect.objectContaining({ method: 'PUT' }),
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      'http://router.example:9090/providers/proxies/Office%2Fbackup',
      expect.objectContaining({ method: 'PUT' }),
    );
    expect(mocks.clashApi).not.toHaveBeenCalled();
  });

  it('surfaces a real Clash API HTTP error instead of retrying through the CLI', async () => {
    mocks.getConfigSections.mockResolvedValue([section()]);
    setClashProxies({
      Office: proxy('Selector', { all: ['Office/Node'] }),
      'Office/Node': proxy('VLESS'),
    });
    await getDashboardSections();
    mocks.clashApi.mockClear();

    mocks.canUseDirectClashApi.mockReturnValue(true);
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        status: 403,
        text: async () => 'Forbidden',
      }),
    );

    await expect(getClashApiProxyLink('Office/Node')).resolves.toEqual({
      success: false,
      error: 'Forbidden',
      status: 403,
    });
    expect(mocks.clashApi).not.toHaveBeenCalled();
  });

  it('knows whether any enabled section names a list to download', async () => {
    setClashProxies({
      Office: proxy('Selector', { all: ['Office/Node'] }),
      'Office/Node': proxy('VLESS'),
    });
    const cases: Array<[Forkop.ConfigSection[], boolean]> = [
      [[section()], false],
      [
        [
          section(),
          section({
            '.name': 'dns',
            action: 'bypass',
            community_lists: ['youtube'],
          }),
        ],
        true,
      ],
      [
        [
          section(),
          section({
            '.name': 'lists',
            action: 'block',
            rule_set: ['https://example.com/ads.srs'],
          }),
        ],
        true,
      ],
      [
        [section({ rule_set_with_subnets: ['https://example.com/mixed.txt'] })],
        true,
      ],
      [[section({ rule_set: ['/etc/forkop/local.srs'] })], false],
      [
        [
          section({ enabled: '0', community_lists: ['telegram'] }),
          section({ '.name': 'other' }),
        ],
        false,
      ],
    ];

    for (const [configSections, expected] of cases) {
      mocks.getConfigSections.mockResolvedValue(configSections);
      expect((await getDashboardSections()).hasRemoteLists).toBe(expected);
    }
  });

  it('refreshes every rule-set through the one bulk request', async () => {
    await useReachableClashApi();
    const fetchMock = vi.fn().mockResolvedValue({ status: 204 });
    vi.stubGlobal('fetch', fetchMock);

    await expect(updateClashApiRuleProviders()).resolves.toEqual({
      success: true,
      data: undefined,
    });
    expect(fetchMock).toHaveBeenCalledOnce();
    expect(fetchMock).toHaveBeenCalledWith(
      'http://router.example:9090/providers/rules',
      expect.objectContaining({ method: 'PUT' }),
    );
  });

  it('reports the Clash API failure message instead of its JSON envelope', async () => {
    mocks.getConfigSections.mockResolvedValue([section()]);
    setClashProxies({
      Office: proxy('Selector', { all: ['Office/Node'] }),
      'Office/Node': proxy('VLESS'),
    });
    await getDashboardSections();

    mocks.canUseDirectClashApi.mockReturnValue(true);
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        status: 503,
        text: async () =>
          '{"message":"update 1 of 3 rule-sets failed: geosite: timeout"}',
      }),
    );

    await expect(updateClashApiRuleProviders()).resolves.toEqual({
      success: false,
      error: 'update 1 of 3 rule-sets failed: geosite: timeout',
      status: 503,
    });
  });

  it('does not repeat a mutation that timed out after it was sent', async () => {
    mocks.getConfigSections.mockResolvedValue([section()]);
    setClashProxies({
      Office: proxy('Selector', { all: ['Office/Node'] }),
      'Office/Node': proxy('VLESS'),
    });
    await getDashboardSections();
    mocks.clashApi.mockClear();

    mocks.canUseDirectClashApi.mockReturnValue(true);
    vi.stubGlobal('fetch', neverAnsweringFetch());
    vi.useFakeTimers();

    const pending = closeAllClashApiConnections();
    await vi.advanceTimersByTimeAsync(60000);
    const result = await pending;
    vi.useRealTimers();

    expect(result.success).toBe(false);
    expect(mocks.clashApi).not.toHaveBeenCalled();
  });

  it('does not repeat a mutation or a delay test after a lost response', async () => {
    for (const action of [
      () => updateClashApiProxyProviders(['Office/premium']),
      () => getClashApiGroupLatency('Office'),
    ]) {
      await useReachableClashApi();
      mocks.clashApi.mockClear();
      vi.stubGlobal(
        'fetch',
        vi.fn().mockRejectedValue(new TypeError('Failed to fetch')),
      );

      expect((await action()).success).toBe(false);
      expect(mocks.clashApi).not.toHaveBeenCalled();
    }
  });

  it('uses the compact summary on the first direct failure and probes recovery while polling it', async () => {
    await primeClashApi();
    mocks.canUseDirectClashApi.mockReturnValue(true);
    const fetchMock = vi
      .fn()
      .mockRejectedValue(new TypeError('Failed to fetch'));
    vi.stubGlobal('fetch', fetchMock);
    mocks.clashSummary.mockResolvedValue(
      clashApiJson(200, {
        downloadTotal: 10,
        uploadTotal: 20,
        connections: 2,
      }),
    );

    expect(await getClashApiConnectionsSummary()).toEqual({
      success: true,
      data: { downloadTotal: 10, uploadTotal: 20, connections: 2 },
    });
    expect(mocks.clashApi).not.toHaveBeenCalled();
    resetClashApiTransport();
    await getClashApiConnectionsSummary();
    await vi.waitFor(() =>
      expect(fetchMock).toHaveBeenCalledWith(
        'http://router.example:9090/version',
        expect.anything(),
      ),
    );
  });

  it('retries an aborted read through the CLI transport', async () => {
    mocks.getConfigSections.mockResolvedValue([section()]);
    setClashProxies({
      Office: proxy('Selector', { all: ['Office/Node'] }),
      'Office/Node': proxy('VLESS'),
    });
    await getDashboardSections();
    mocks.clashApi.mockClear();
    mocks.clashApi.mockResolvedValue(clashApiJson(200, { connections: [] }));

    mocks.canUseDirectClashApi.mockReturnValue(true);
    vi.stubGlobal('fetch', neverAnsweringFetch());
    vi.useFakeTimers();

    const pending = getClashApiConnections();
    await vi.advanceTimersByTimeAsync(60000);
    const result = await pending;
    vi.useRealTimers();

    expect(result).toEqual({
      success: true,
      data: { connections: [] },
    });
    expect(mocks.clashApi).toHaveBeenCalledWith('GET', '/connections', '');
  });

  it('does not repeat a latency test that ran out of time', async () => {
    await primeClashApi();

    mocks.canUseDirectClashApi.mockReturnValue(true);
    vi.stubGlobal('fetch', neverAnsweringFetch());
    vi.useFakeTimers();

    const pending = getClashApiGroupLatency('Office', '10000');
    await vi.advanceTimersByTimeAsync(60000);
    const result = await pending;
    vi.useRealTimers();

    expect(result.success).toBe(false);
    expect(mocks.clashApi).not.toHaveBeenCalled();
  });

  it('tells a failed delay test from a controller that did not answer', async () => {
    await primeClashApi();

    mocks.clashApi.mockResolvedValueOnce(
      clashApiJson(504, { message: 'Timeout' }),
    );
    expect(await getClashApiProxyLatency('Office/Node')).toEqual({
      success: false,
      error: 'Timeout',
      status: 504,
    });

    mocks.clashApi.mockResolvedValueOnce({
      success: false,
      error: 'Clash API request failed: GET /proxies/Office%2FNode/delay',
    });
    const unanswered = await getClashApiProxyLatency('Office/Node');
    expect(unanswered.success).toBe(false);
    expect(unanswered).not.toHaveProperty('status');
  });

  it('stops asking the controller directly once a direct request fails', async () => {
    await primeClashApi();

    mocks.canUseDirectClashApi.mockReturnValue(true);
    const fetchMock = vi
      .fn()
      .mockRejectedValue(new TypeError('Failed to fetch'));
    vi.stubGlobal('fetch', fetchMock);

    await getClashApiConnections();
    await getClashApiConnections();

    expect(fetchMock).toHaveBeenCalledOnce();
    expect(mocks.clashApi).toHaveBeenCalledTimes(2);
  });

  it('stops asking the controller directly once a direct request runs out of time', async () => {
    await primeClashApi();

    mocks.canUseDirectClashApi.mockReturnValue(true);
    const fetchMock = neverAnsweringFetch();
    vi.stubGlobal('fetch', fetchMock);
    vi.useFakeTimers();

    const pending = getClashApiConnections();
    await vi.advanceTimersByTimeAsync(6000);
    await pending;
    await getClashApiConnections();
    vi.useRealTimers();

    expect(fetchMock).toHaveBeenCalledOnce();
    expect(mocks.clashApi).toHaveBeenCalledTimes(2);
  });

  it('probes beside the request instead of making it wait', async () => {
    await primeClashApi();

    mocks.canUseDirectClashApi.mockReturnValue(true);
    const fetchMock = vi
      .fn()
      .mockRejectedValue(new TypeError('Failed to fetch'));
    vi.stubGlobal('fetch', fetchMock);

    await getClashApiConnections();
    resetClashApiTransport();
    await expect(getClashApiConnections()).resolves.toEqual({
      success: true,
      data: { connections: [] },
    });
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));

    expect(fetchMock).toHaveBeenLastCalledWith(
      'http://router.example:9090/version',
      expect.anything(),
    );
    expect(mocks.clashApi).toHaveBeenLastCalledWith('GET', '/connections', '');
  });

  it('returns to the direct path once a probe reaches the controller', async () => {
    await primeClashApi();

    mocks.canUseDirectClashApi.mockReturnValue(true);
    const answer = {
      status: 200,
      text: async () => JSON.stringify({ connections: [] }),
    };
    const fetchMock = vi
      .fn()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValue(answer);
    vi.stubGlobal('fetch', fetchMock);

    await getClashApiConnections();
    resetClashApiTransport();
    await getClashApiConnections();

    await vi.waitFor(async () => {
      mocks.clashApi.mockClear();
      await expect(getClashApiConnections()).resolves.toEqual({
        success: true,
        data: { connections: [] },
      });
      expect(mocks.clashApi).not.toHaveBeenCalled();
    });

    expect(fetchMock).toHaveBeenCalledWith(
      'http://router.example:9090/version',
      expect.anything(),
    );
  });

  it('treats an unauthorised probe answer as a reachable controller', async () => {
    await primeClashApi();

    mocks.canUseDirectClashApi.mockReturnValue(true);
    const fetchMock = vi
      .fn()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce({ status: 401, text: async () => 'Unauthorized' })
      .mockResolvedValue({
        status: 200,
        text: async () => JSON.stringify({ connections: [] }),
      });
    vi.stubGlobal('fetch', fetchMock);

    await getClashApiConnections();
    resetClashApiTransport();
    await getClashApiConnections();

    await vi.waitFor(async () => {
      mocks.clashApi.mockClear();
      await getClashApiConnections();
      expect(mocks.clashApi).not.toHaveBeenCalled();
    });

    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      'http://router.example:9090/version',
      expect.anything(),
    );
  });

  it('summarises the snapshot the browser fetched itself', async () => {
    await primeClashApi();

    mocks.canUseDirectClashApi.mockReturnValue(true);
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        status: 200,
        text: async () =>
          JSON.stringify({
            downloadTotal: 10,
            uploadTotal: 20,
            memory: 30,
            connections: [{ id: 'a' }, { id: 'b' }],
          }),
      }),
    );

    await expect(getClashApiConnectionsSummary()).resolves.toEqual({
      success: true,
      data: {
        downloadTotal: 10,
        uploadTotal: 20,
        connections: 2,
      },
    });
    expect(mocks.clashSummary).not.toHaveBeenCalled();
  });

  it('asks the router to narrow the snapshot it cannot fetch itself', async () => {
    await primeClashApi();

    mocks.canUseDirectClashApi.mockReturnValue(false);
    mocks.clashSummary.mockResolvedValue(
      clashApiJson(200, {
        downloadTotal: 10,
        uploadTotal: 20,
        connections: 2,
      }),
    );

    await expect(getClashApiConnectionsSummary()).resolves.toEqual({
      success: true,
      data: {
        downloadTotal: 10,
        uploadTotal: 20,
        connections: 2,
      },
    });
    expect(mocks.clashApi).not.toHaveBeenCalled();
  });

  it('leaves a proxy section without a single node test budget of its own', async () => {
    const nodes = Array.from({ length: 30 }, (_, index): [string, string] => [
      `Node${index}`,
      `vless://node@example.com:443#Node${index}`,
    ]);
    const members = nodes.map(([name]) => `Office/${name}`);
    mocks.getConfigSections.mockResolvedValue([section(), ...links(nodes)]);
    setClashProxies({
      Office: proxy('Selector', {
        name: 'Office',
        all: members,
        now: members[0],
      }),
      ...Object.fromEntries(members.map((tag) => [tag, proxy('VLESS')])),
    });

    const { data } = await getDashboardSections();

    expect(data[0].outbounds).toHaveLength(members.length);
  });

  it('surfaces a narrowed summary failure instead of an empty widget', async () => {
    await primeClashApi();

    mocks.canUseDirectClashApi.mockReturnValue(false);
    mocks.clashSummary.mockResolvedValue({
      success: false,
      error: 'Failed to execute',
    });

    await expect(getClashApiConnectionsSummary()).resolves.toEqual({
      success: false,
      error: 'Failed to execute',
    });
  });
});
