import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Forkop } from '../../../types';

const mocks = vi.hoisted(() => ({
  getDashboardSections: vi.fn(),
  getClashApiGroupLatency: vi.fn(),
  getClashApiProxyLatency: vi.fn(),
  updateClashApiRuleProviders: vi.fn(),
  updateClashApiProxyProviders: vi.fn(),
  showToast: vi.fn(),
}));

vi.mock('../../../services/socket.service', () => ({
  socket: { subscribe: vi.fn(), disconnect: vi.fn(), resetAll: vi.fn() },
}));
vi.mock('../../../../helpers/onMount', () => ({ onMount: async () => ({}) }));
vi.mock('../../../../helpers/showToast', () => ({
  showToast: mocks.showToast,
}));
vi.mock('../../../methods', () => ({
  CustomForkopMethods: {
    getDashboardSections: mocks.getDashboardSections,
    getClashApiConnectionsSummary: async () => ({ success: false }),
    getClashApiGroupLatency: mocks.getClashApiGroupLatency,
    getClashApiProxyLatency: mocks.getClashApiProxyLatency,
    updateClashApiRuleProviders: mocks.updateClashApiRuleProviders,
    updateClashApiProxyProviders: mocks.updateClashApiProxyProviders,
  },
}));
vi.mock('../../../methods/custom/getClashApiSecret', () => ({
  getClashApiSecret: async () => 'secret',
}));
vi.mock('../../../services/runtimeUiState.service', () => ({
  refreshRuntimeUiState: vi.fn(),
}));

interface FakeNode {
  type: string;
  attrs: Record<string, unknown>;
  children: Array<FakeNode | string>;
  isConnected: boolean;
  scrollTop: number;
  appendChild(child: FakeNode): void;
  setAttribute(name: string, value: string): void;
  replaceChildren(...nodes: FakeNode[]): void;
  querySelector(selector: string): FakeNode | null;
}

function findByClass(
  node: FakeNode | string,
  className: string,
): FakeNode | null {
  if (typeof node === 'string') {
    return null;
  }
  if (
    String(node.attrs.class || '')
      .split(' ')
      .includes(className)
  ) {
    return node;
  }
  for (const child of node.children) {
    const found = findByClass(child, className);
    if (found) {
      return found;
    }
  }
  return null;
}

function fakeNode(type: string, attrs: unknown, children?: unknown): FakeNode {
  return {
    type,
    attrs: (attrs || {}) as Record<string, unknown>,
    children:
      children === undefined
        ? []
        : Array.isArray(children)
          ? (children as Array<FakeNode | string>)
          : [children as FakeNode | string],
    isConnected: true,
    scrollTop: 0,
    appendChild(child) {
      this.children.push(child);
    },
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
    replaceChildren(...nodes) {
      this.children = nodes;
    },
    querySelector(selector) {
      return findByClass(this, selector.replace(/^./, ''));
    },
  };
}

function textOf(node: FakeNode | string): string {
  return typeof node === 'string' ? node : node.children.map(textOf).join('');
}

const containers: Record<string, { children: FakeNode[] }> = {};
let overlayActive = true;
let shownModal: FakeNode | null = null;
const stored = new Map<string, string>();
const COLLAPSED_KEY = 'forkop:dashboard-collapsed-sections:v1';

function container(id: string) {
  containers[id] ||= {
    children: [],
    replaceChildren(...nodes: FakeNode[]) {
      this.children = nodes;
    },
  } as { children: FakeNode[] };
  return containers[id];
}

function toolbarButton(label: string) {
  const toolbar = container('dashboard-sections-toolbar').children[0];
  return toolbar?.children.find(
    (child): child is FakeNode =>
      typeof child !== 'string' && textOf(child) === label,
  );
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

function section(
  name: string,
  overrides: Partial<Forkop.OutboundGroup> = {},
): Forkop.OutboundGroup {
  return {
    code: `${name}-out`,
    sectionName: name,
    displayName: name,
    withTagSelect: true,
    outbounds: [
      {
        code: `${name}/Node`,
        displayName: 'Node',
        latency: 0,
        type: 'VLESS',
        selected: true,
      },
    ],
    ...overrides,
  };
}

beforeEach(() => {
  vi.resetModules();
  vi.useFakeTimers();
  for (const mock of Object.values(mocks)) {
    mock.mockReset();
  }
  for (const id of Object.keys(containers)) {
    delete containers[id];
  }
  (globalThis as unknown as { E: unknown }).E = fakeNode;
  stored.clear();
  vi.stubGlobal('window', {
    location: { hostname: '192.168.1.1', protocol: 'http:' },
    localStorage: {
      getItem: (key: string) => stored.get(key) ?? null,
      setItem: (key: string, value: string) => stored.set(key, value),
    },
    scrollY: 0,
    scrollTo() {},
    addEventListener() {},
  });
  vi.stubGlobal('requestAnimationFrame', () => 0);
  overlayActive = true;
  shownModal = null;
  vi.stubGlobal('ui', {
    showModal: (_title: string, content: FakeNode) => {
      shownModal = content;
    },
    hideModal: () => {},
  });
  vi.stubGlobal(
    'MutationObserver',
    class {
      observe() {}
    },
  );
  vi.stubGlobal('document', {
    visibilityState: 'visible',
    timeline: { currentTime: 0 },
    body: {
      classList: { contains: () => overlayActive },
    },
    getElementById: (id: string) =>
      id === 'dashboard-sections-grid' || id === 'dashboard-sections-toolbar'
        ? container(id)
        : null,
    createElementNS: (_namespace: string, type: string) => fakeNode(type, {}),
    querySelector: () => null,
    querySelectorAll: () => [],
    addEventListener() {},
    removeEventListener() {},
  });
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

async function openDashboard(
  data: Forkop.OutboundGroup[],
  hasRemoteLists = true,
) {
  mocks.getDashboardSections.mockResolvedValue({
    success: true,
    data,
    hasRemoteLists,
  });
  const { store } = await import('../../../services/store.service');
  store.set({ tabService: { current: 'dashboard', all: [] } });
  const { initController } = await import('../initController');
  await initController();
  await vi.advanceTimersByTimeAsync(0);
}

describe('the dashboard toolbar', () => {
  it('offers only what there is to act on', async () => {
    await openDashboard([section('alone')], false);

    expect(toolbarButton('Test all sections')).toBeUndefined();
    expect(toolbarButton('Update subscriptions')).toBeUndefined();
    expect(toolbarButton('Update lists')).toBeUndefined();
  });

  it('tests every section in turn, each once the one before has answered', async () => {
    const first = deferred<unknown>();
    const second = deferred<unknown>();
    mocks.getClashApiGroupLatency
      .mockReturnValueOnce(first.promise)
      .mockResolvedValue({ success: true, data: {} });
    mocks.getClashApiProxyLatency.mockReturnValueOnce(second.promise);
    await openDashboard([
      section('first'),
      section('single', { withTagSelect: false }),
      section('last'),
    ]);

    (toolbarButton('Test all sections')?.attrs.click as () => void)();
    await vi.advanceTimersByTimeAsync(0);
    expect(mocks.getClashApiGroupLatency.mock.calls).toEqual([['first-out']]);
    expect(mocks.getClashApiProxyLatency).not.toHaveBeenCalled();
    expect(toolbarButton('Test all sections')?.attrs.disabled).toBe(true);

    first.resolve({ success: true, data: {} });
    await vi.advanceTimersByTimeAsync(0);
    expect(mocks.getClashApiProxyLatency.mock.calls).toEqual([['single/Node']]);
    expect(mocks.getClashApiGroupLatency).toHaveBeenCalledTimes(1);

    second.resolve({ success: true, data: { delay: 50 } });
    await vi.advanceTimersByTimeAsync(0);
    expect(mocks.getClashApiGroupLatency.mock.calls).toEqual([
      ['first-out'],
      ['last-out'],
    ]);
    expect(toolbarButton('Test all sections')?.attrs.disabled).toBeUndefined();
  });

  it('stops at the first section the controller gave no answer for', async () => {
    mocks.getClashApiGroupLatency.mockResolvedValue({
      success: false,
      error: 'unreachable',
    });
    await openDashboard([section('first'), section('second')]);

    (toolbarButton('Test all sections')?.attrs.click as () => void)();
    await vi.advanceTimersByTimeAsync(0);

    expect(mocks.getClashApiGroupLatency).toHaveBeenCalledTimes(1);
    expect(mocks.showToast).toHaveBeenCalledOnce();
  });

  it('refreshes every list of the router in one request', async () => {
    mocks.updateClashApiRuleProviders.mockResolvedValue({ success: true });
    await openDashboard([section('first'), section('second')]);

    (toolbarButton('Update lists')?.attrs.click as () => void)();
    await vi.advanceTimersByTimeAsync(0);

    expect(mocks.updateClashApiRuleProviders).toHaveBeenCalledOnce();
    expect(mocks.updateClashApiRuleProviders).toHaveBeenCalledWith();
    expect(mocks.showToast).toHaveBeenCalledWith('Lists updated', 'success');
  });

  it('refreshes each subscription of every section once', async () => {
    mocks.updateClashApiProxyProviders.mockResolvedValue({ success: true });
    await openDashboard([
      section('office', { subscriptionProviderTags: ['office/sub1'] }),
      section('home', {
        subscriptionProviderTags: ['home/sub1', 'home/sub2'],
      }),
      section('plain'),
    ]);

    (toolbarButton('Update subscriptions')?.attrs.click as () => void)();
    await vi.advanceTimersByTimeAsync(0);

    expect(mocks.updateClashApiProxyProviders.mock.calls).toEqual([
      [['office/sub1', 'home/sub1', 'home/sub2']],
    ]);
    expect(mocks.showToast).toHaveBeenCalledWith(
      'Subscriptions updated',
      'success',
    );
  });

  it('reports a refresh that did not go through', async () => {
    mocks.updateClashApiRuleProviders.mockResolvedValue({
      success: false,
      error: 'update 1 of 3 rule-sets failed',
    });
    await openDashboard([section('first'), section('second')]);

    (toolbarButton('Update lists')?.attrs.click as () => void)();
    await vi.advanceTimersByTimeAsync(0);

    expect(mocks.showToast).toHaveBeenCalledWith(
      'Failed to update lists',
      'error',
    );
    expect(toolbarButton('Update lists')?.attrs.disabled).toBeUndefined();
  });
});

describe('folded sections', () => {
  function rendered(name: string) {
    return container('dashboard-sections-grid').children.find((root) =>
      textOf(root).includes(name),
    );
  }

  function collapseButton(name: string) {
    const find = (node: FakeNode | string): FakeNode | undefined => {
      if (typeof node === 'string') {
        return undefined;
      }
      if (
        String(node.attrs.class || '').includes(
          'fkp_dashboard-page__outbound-section__collapse',
        )
      ) {
        return node;
      }
      for (const child of node.children) {
        const found = find(child);
        if (found) {
          return found;
        }
      }
      return undefined;
    };
    return find(rendered(name) as FakeNode);
  }

  it('stay folded on the next visit', async () => {
    stored.set(COLLAPSED_KEY, JSON.stringify(['second']));
    await openDashboard([section('first'), section('second')]);

    expect(collapseButton('first')?.attrs['aria-expanded']).toBe('true');
    expect(collapseButton('second')?.attrs['aria-expanded']).toBe('false');
  });

  it('are stored as they are folded, without sections that are gone', async () => {
    stored.set(COLLAPSED_KEY, JSON.stringify(['removed', 'first']));
    await openDashboard([section('first'), section('second')]);

    (collapseButton('second')?.attrs.click as (event: MouseEvent) => void)({
      preventDefault() {},
      stopPropagation() {},
    } as MouseEvent);
    expect(JSON.parse(stored.get(COLLAPSED_KEY) || '[]')).toEqual([
      'first',
      'second',
    ]);

    (collapseButton('first')?.attrs.click as (event: MouseEvent) => void)({
      preventDefault() {},
      stopPropagation() {},
    } as MouseEvent);
    expect(JSON.parse(stored.get(COLLAPSED_KEY) || '[]')).toEqual(['second']);
  });

  it('still fold when the browser keeps nothing', async () => {
    stored.set(COLLAPSED_KEY, 'not json');
    await openDashboard([section('first'), section('second')]);

    expect(collapseButton('first')?.attrs['aria-expanded']).toBe('true');
    (collapseButton('first')?.attrs.click as (event: MouseEvent) => void)({
      preventDefault() {},
      stopPropagation() {},
    } as MouseEvent);
    expect(collapseButton('first')?.attrs['aria-expanded']).toBe('false');
  });
});

describe('the group details dialogs', () => {
  function urlTestSection(latency: number) {
    return section('main', {
      outbounds: [
        {
          code: 'main/auto',
          displayName: 'Auto',
          latency,
          type: 'URLTest',
          selected: true,
          urlTestInfo: {
            code: 'main/auto',
            displayName: 'Auto',
            outbounds: [
              {
                code: 'main/node',
                displayName: 'Node',
                latency,
                type: 'VLESS',
                selected: true,
              },
            ],
          },
        },
      ],
    });
  }

  async function openUrlTestDetails() {
    const button = (function find(node: FakeNode | string): FakeNode | null {
      if (typeof node === 'string') return null;
      if (node.attrs['aria-label'] === 'URLTest details') return node;
      for (const child of node.children) {
        const found = find(child);
        if (found) return found;
      }
      return null;
    })(container('dashboard-sections-grid').children[0]);
    (button?.attrs.click as (event: MouseEvent) => void)({
      stopPropagation() {},
    } as MouseEvent);
    return shownModal as unknown as FakeNode;
  }

  async function publish(data: Forkop.OutboundGroup[]) {
    const { store } = await import('../../../services/store.service');
    store.set({
      sectionsWidget: { ...store.get().sectionsWidget, data },
    });
    await vi.advanceTimersByTimeAsync(0);
  }

  it('follow the sections refresh and keep the list where it was scrolled', async () => {
    await openDashboard([urlTestSection(50), section('other')]);
    const dialog = await openUrlTestDetails();
    expect(textOf(dialog)).toContain('50ms');
    dialog.querySelector(
      '.fkp_dashboard-page__urltest-details__table',
    )!.scrollTop = 120;

    await publish([urlTestSection(70), section('other')]);

    expect(textOf(dialog)).toContain('70ms');
    expect(
      dialog.querySelector('.fkp_dashboard-page__urltest-details__table')
        ?.scrollTop,
    ).toBe(120);
  });

  it('stop redrawing once LuCI has closed them', async () => {
    await openDashboard([urlTestSection(50), section('other')]);
    const dialog = await openUrlTestDetails();

    overlayActive = false;
    await publish([urlTestSection(70), section('other')]);
    overlayActive = true;
    await publish([urlTestSection(90), section('other')]);

    expect(textOf(dialog)).toContain('50ms');
  });

  it('shows measured throughput and qualification in URLTest details', async () => {
    const data = urlTestSection(20);
    const info = data.outbounds[0].urlTestInfo!;
    info.bandwidth = { running: true, minimum_mbps: 50, results: {} };
    info.outbounds[0].bandwidth = {
      time: '2026-10-29T10:00:00Z',
      mbps: 123.4,
      bytes: 33554432,
      admitted: true,
    };
    await openDashboard([data]);
    const dialog = await openUrlTestDetails();
    expect(textOf(dialog)).toContain('123.4 Mbps');
    expect(textOf(dialog)).toContain('Qualified');
    expect(textOf(dialog)).toContain('Testing download speed…');
    const updated = urlTestSection(20);
    updated.outbounds[0].urlTestInfo!.bandwidth = {
      ...info.bandwidth,
      running: false,
    };
    await publish([updated]);
    const buttons: FakeNode[] = [];
    (function collect(node: FakeNode | string) {
      if (typeof node === 'string') return;
      if (node.type === 'button' && textOf(node) === 'Measure server speeds')
        buttons.push(node);
      node.children.forEach(collect);
    })(dialog);
    expect(buttons).toHaveLength(1);
    expect(buttons[0].attrs.disabled).toBeUndefined();
    expect(buttons[0].attrs.title).toContain('every server in this group');
  });

  function fallbackSection(levels: string[]) {
    return section('chain', {
      outbounds: [
        {
          code: 'chain/fallback',
          displayName: 'Fallback',
          latency: 0,
          type: 'Fallback',
          selected: true,
          fallbackInfo: {
            code: 'chain/fallback',
            displayName: 'Fallback',
            outbounds: levels.map((level, index) => ({
              code: `chain/node${index}`,
              displayName: `Node ${index}`,
              latency: 0,
              type: 'VLESS',
              selected: index === 0,
              pinned: false,
              levelIndex: index,
              levelName: level,
              levelId: level,
            })),
          },
        },
      ],
    });
  }

  async function fallbackLevelChips(levels: string[]) {
    await openDashboard([fallbackSection(levels), section('other')]);
    const button = (function find(node: FakeNode | string): FakeNode | null {
      if (typeof node === 'string') return null;
      if (node.attrs['aria-label'] === 'Fallback details') return node;
      for (const child of node.children) {
        const found = find(child);
        if (found) return found;
      }
      return null;
    })(container('dashboard-sections-grid').children[0]);
    (button?.attrs.click as (event: MouseEvent) => void)({
      stopPropagation() {},
    } as MouseEvent);
    const chips: string[] = [];
    (function collect(node: FakeNode | string) {
      if (typeof node === 'string') return;
      if (
        String(node.attrs.class || '').includes(
          'fkp_dashboard-page__urltest-details__fallback-level',
        )
      ) {
        chips.push(textOf(node));
      }
      node.children.forEach(collect);
    })(shownModal as unknown as FakeNode);
    return chips;
  }

  it('name a fallback level on a node only when there are levels to tell apart', async () => {
    expect(await fallbackLevelChips(['Group #1', 'Group #1'])).toEqual([]);
  });

  it('name it on every node, the chosen one included, when there are', async () => {
    expect(await fallbackLevelChips(['Group #1', 'Group #2'])).toEqual([
      'Group #1',
      'Group #1',
      'Group #2',
    ]);
  });
});
