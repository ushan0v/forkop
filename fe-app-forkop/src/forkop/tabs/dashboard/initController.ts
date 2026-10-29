import { latencyClassName } from '../../helpers/latencyClassName';
import {
  canUseDirectClashApi,
  getClashSocketUrl,
  getClashWsUrl,
} from '../../../helpers/getClashApiUrl';
import { onMount } from '../../../helpers/onMount';
import { preserveScrollForPage } from '../../../helpers/preserveScrollForPage';
import { copyToClipboard } from '../../../helpers/copyToClipboard';
import { showToast } from '../../../helpers/showToast';
import { prettyBytes } from '../../../helpers/prettyBytes';
import { renderPinIcon24 } from '../../../icons';
import { CustomForkopMethods } from '../../methods';
import { logger, socket, store, StoreType } from '../../services';
import {
  refreshSubscriptionAges,
  renderFlagEmojis,
  renderSections,
  renderSectionsPlaceholder,
  renderServers,
  renderToolbar,
  renderWidget,
} from './partials';
import { describeServers } from './serverActivity';
import type {
  ActivityConnection,
  ConnectionCounters,
  ServerView,
} from './serverActivity';
import { sectionLatencyTarget } from './sectionLatencyTarget';
import { exitNodeName } from './exitNodeName';
import type { ExitPanelState } from './partials/renderExitPanel';
import { getClashApiSecret } from '../../methods/custom/getClashApiSecret';
import { resetClashApiTransport } from '../../methods/custom/clashApi';
import { Forkop } from '../../types';
import { getLocalStorage } from '../../services/browserStorage.service';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { isDocumentVisible } from '../../../helpers/isDocumentVisible';
import { createTabLifecycle } from '../../helpers/tabLifecycle';
import { pollDelayForDuration } from '../../helpers/pollDelay';
import { createPollChain } from '../../helpers/pollChain';
import { formatDuration } from '../../helpers/formatDuration';
import {
  coreAgeSeconds,
  cpuShare,
  formatCpuShare,
  readCoreUsage,
} from './coreUsage';
import type { CoreUsageReading } from './coreUsage';
import { resolveOutboundProxyLink } from './resolveOutboundProxyLink';
import { showTailscaleDetailsModal } from '../servers/tailscale';
import { E } from '../../../helpers/element';

const SECTIONS_REFRESH_INTERVAL_MS = 10000;
const COLLAPSED_SECTIONS_STORAGE_KEY = 'forkop:dashboard-collapsed-sections:v1';
// While a latency test runs the router fills its delay records one at a time, so the sections
// refresh keeps up with it; the duty ceiling still applies.
const SECTIONS_LATENCY_REFRESH_INTERVAL_MS = 2000;
// A core that is down never answers and a hanging controller costs a connect timeout per try, so
// the refresh backs off while it keeps failing.
const SECTIONS_REFRESH_BACKOFF_MAX_MS = 60000;
const SECTIONS_REFRESH_DUTY_MAX_MS = 30000;
// The widgets come from websockets when the browser can open them, otherwise from the
// /connections snapshot, which costs the router per connection to build.
const WIDGETS_SNAPSHOT_INTERVAL_MS = 5000;
const WIDGETS_POLL_BACKOFF_MAX_MS = 30000;
const WIDGETS_POLL_DUTY_MAX_MS = 20000;
// A socket to a port that drops packets neither connects nor fails until the browser's own
// timeout, so after this the poll fills the widgets.
const WIDGETS_SOCKET_GRACE_MS = 2000;
let sectionsRefreshFailures = 0;
let lastSectionsRefreshDurationMs = 0;
let sectionsRefreshPromise: Promise<boolean> | null = null;
let sectionsRefreshQueued = false;
let dashboardMounted = false;
let dashboardMountId = 0;
let dashboardDataUpdatesStarted = false;
let dashboardDataUpdatesId = 0;
let widgetsPollFailures = 0;
let widgetsSocketGraceTimer: ReturnType<typeof setTimeout> | null = null;
let lastWidgetsPollDurationMs = 0;
let trafficSocketLive = false;
let connectionsSocketLive = false;
let trafficSocketUrl = '';
let connectionsSocketUrl = '';
let lastPolledTotals: { at: number; up: number; down: number } | null = null;
let serverViews: ServerView[] = [];
let serverViewsLive = false;
let serverCounters: ConnectionCounters | null = null;
let serverCountersAt = 0;
let renderedServersConfig = '';
let pageUnloading = false;
const latencyRequests = new Set<string>();
const latencySortedSections = new Set<string>();
const collapsedSections = readCollapsedSections();
const selectorRequests = new Set<string>();
const toolbarActions = new Set<'testAll' | 'subscriptions' | 'lists'>();
const fallbackPinRequests = new Set<string>();
let activeDetailsModal: {
  container: HTMLElement;
  render: () => Node[];
  unsubscribe: () => void;
} | null = null;
let exitPanel: (ExitPanelState & { sectionName: string }) | null = null;
let exitLookupId = 0;

// Folded sections stay folded across visits.
function readCollapsedSections() {
  try {
    const stored = JSON.parse(
      getLocalStorage()?.getItem(COLLAPSED_SECTIONS_STORAGE_KEY) || '[]',
    );
    return new Set<string>(
      Array.isArray(stored)
        ? stored.filter((name): name is string => typeof name === 'string')
        : [],
    );
  } catch {
    return new Set<string>();
  }
}

// Only sections still shown are written back, so removed ones do not linger.
function writeCollapsedSections() {
  const shown = new Set(
    store.get().sectionsWidget.data.map((section) => section.sectionName),
  );
  try {
    getLocalStorage()?.setItem(
      COLLAPSED_SECTIONS_STORAGE_KEY,
      JSON.stringify([...collapsedSections].filter((name) => shown.has(name))),
    );
  } catch {
    // Folding still works for this visit when the browser refuses to store it.
  }
}

function sectionLatencyRequestKey(sectionName: string) {
  return `section:${sectionName}`;
}

function outboundLatencyRequestKey(sectionName: string, tag: string) {
  return `outbound:${sectionName}:${tag}`;
}

if (typeof window !== 'undefined') {
  window.addEventListener('pagehide', () => {
    pageUnloading = true;
  });
  window.addEventListener('pageshow', () => {
    pageUnloading = false;
  });
}

async function fetchDashboardSectionsOnce(mountId: number) {
  const prev = store.get().sectionsWidget;
  const hasRenderedData = prev.data.length > 0;

  store.set({
    sectionsWidget: {
      ...prev,
      failed: false,
      loading: prev.loading && !hasRenderedData,
    },
  });

  try {
    const { data, servers, success, hasRemoteLists } =
      await CustomForkopMethods.getDashboardSections();

    if (!dashboardMounted || mountId !== dashboardMountId) {
      return false;
    }

    if (!success) {
      throw new Error('failed to fetch dashboard sections');
    }

    const current = store.get().sectionsWidget;

    store.set({
      sectionsWidget: {
        ...current,
        loading: false,
        failed: false,
        data,
        servers,
        hasRemoteLists,
      },
    });

    return true;
  } catch (error) {
    logger.error('[DASHBOARD]', 'fetchDashboardSections: failed', error);

    if (!dashboardMounted || mountId !== dashboardMountId) {
      return false;
    }

    const current = store.get().sectionsWidget;

    store.set({
      sectionsWidget: {
        ...current,
        loading: false,
        failed: current.data.length === 0,
        data: current.data,
      },
    });

    return false;
  }
}

async function fetchDashboardSections(options: { force?: boolean } = {}) {
  if (sectionsRefreshPromise) {
    if (options.force) {
      sectionsRefreshQueued = true;
    }

    return sectionsRefreshPromise;
  }

  const mountId = dashboardMountId;
  const promise = (async () => {
    let success = false;

    do {
      sectionsRefreshQueued = false;
      success = await fetchDashboardSectionsOnce(mountId);
    } while (
      sectionsRefreshQueued &&
      dashboardMounted &&
      mountId === dashboardMountId
    );

    return success;
  })();

  sectionsRefreshPromise = promise;

  try {
    return await promise;
  } finally {
    if (sectionsRefreshPromise === promise) {
      sectionsRefreshPromise = null;
    }
  }
}

function handleSortByLatency(sectionName: string, enabled: boolean) {
  if (enabled) {
    latencySortedSections.add(sectionName);
  } else {
    latencySortedSections.delete(sectionName);
  }

  void renderSectionsWidget();
}

function handleCollapsedChange(sectionName: string, collapsed: boolean) {
  if (collapsed) {
    collapsedSections.add(sectionName);
  } else {
    collapsedSections.delete(sectionName);
  }
  writeCollapsedSections();

  void renderSectionsWidget();
}

function widgetsAreLive() {
  return trafficSocketLive && connectionsSocketLive;
}

// The snapshot carries only totals, so the rate is what they gained between two polls; a core that
// restarted resets its counters, and the first poll has nothing to compare.
function polledBandwidth(uploadTotal: number, downloadTotal: number) {
  const at = Date.now();
  const previous = lastPolledTotals;

  lastPolledTotals = { at, up: uploadTotal, down: downloadTotal };

  if (!previous || at <= previous.at) {
    return null;
  }

  const seconds = (at - previous.at) / 1000;

  // Whole bytes per second, like the socket sends; prettyBytes prints small values verbatim.
  return {
    up: Math.round(Math.max(0, uploadTotal - previous.up) / seconds),
    down: Math.round(Math.max(0, downloadTotal - previous.down) / seconds),
  };
}

// A widget whose socket delivers keeps what the socket said.
function applyWidgetsSnapshot(summary: Forkop.ClashConnectionsSummary) {
  const { uploadTotal, downloadTotal } = summary;
  const bandwidth = polledBandwidth(uploadTotal, downloadTotal);

  store.set({
    ...(trafficSocketLive || !bandwidth
      ? {}
      : {
          bandwidthWidget: {
            loading: false,
            failed: false,
            data: bandwidth,
          },
        }),
    ...(connectionsSocketLive
      ? {}
      : {
          trafficTotalWidget: {
            loading: false,
            failed: false,
            data: { downloadTotal, uploadTotal },
          },
          connectionsWidget: {
            loading: false,
            failed: false,
            data: { connections: summary.connections },
          },
        }),
  });
}

function reportWidgetsFailure() {
  widgetsPollFailures += 1;
  lastPolledTotals = null;

  store.set({
    ...(trafficSocketLive
      ? {}
      : {
          bandwidthWidget: {
            loading: false,
            failed: true,
            data: { up: 0, down: 0 },
          },
        }),
    ...(connectionsSocketLive
      ? {}
      : {
          trafficTotalWidget: {
            loading: false,
            failed: true,
            data: { downloadTotal: 0, uploadTotal: 0 },
          },
          connectionsWidget: {
            loading: false,
            failed: true,
            data: { connections: 0 },
          },
        }),
  });
}

// The clients are told apart only by each connection of the snapshot, which the summary leaves out.
function applyServerConnections(connections: ActivityConnection[] | null) {
  const servers = store.get().sectionsWidget.servers;

  if (connections) {
    const at = Date.now();
    const described = describeServers(
      servers,
      connections,
      serverCounters,
      (at - serverCountersAt) / 1000,
    );
    serverViews = described.servers;
    serverCounters = described.counters;
    serverCountersAt = at;
  } else {
    serverViews = describeServers(servers, [], null, 0).servers;
    serverCounters = null;
  }

  serverViewsLive = Boolean(connections);
  renderedServersConfig = JSON.stringify(servers);
  renderServersWidget();
}

async function pollServerConnections() {
  if (connectionsSocketLive || !store.get().sectionsWidget.servers.length) {
    return;
  }

  const dataUpdatesId = dashboardDataUpdatesId;
  const response = await CustomForkopMethods.getClashApiConnections().catch(
    () => null,
  );

  if (
    !widgetsPoll.active ||
    connectionsSocketLive ||
    dataUpdatesId !== dashboardDataUpdatesId
  ) {
    return;
  }

  const connections = response?.success
    ? (response.data as { connections?: ActivityConnection[] })?.connections
    : null;
  applyServerConnections(connections || (response?.success ? [] : null));
}

async function pollWidgetsSnapshot(dataUpdatesId: number) {
  const startedAt = Date.now();

  try {
    const [response] = await Promise.all([
      CustomForkopMethods.getClashApiConnectionsSummary(),
      pollServerConnections(),
    ]);

    lastWidgetsPollDurationMs = Date.now() - startedAt;

    if (!widgetsPoll.active || dataUpdatesId !== dashboardDataUpdatesId) {
      return;
    }

    if (!response.success) {
      reportWidgetsFailure();
      return;
    }

    widgetsPollFailures = 0;
    applyWidgetsSnapshot(response.data);
  } catch (error) {
    logger.error('[DASHBOARD]', 'pollWidgetsSnapshot: failed', error);

    if (widgetsPoll.active && dataUpdatesId === dashboardDataUpdatesId) {
      reportWidgetsFailure();
    }
  }
}

// A stopped core answers nothing, so the poll slows down while it keeps failing.
function widgetsPollDelay() {
  if (widgetsPollFailures > 0) {
    return Math.min(
      WIDGETS_SNAPSHOT_INTERVAL_MS * 2 ** widgetsPollFailures,
      WIDGETS_POLL_BACKOFF_MAX_MS,
    );
  }

  return pollDelayForDuration(
    WIDGETS_SNAPSHOT_INTERVAL_MS,
    lastWidgetsPollDurationMs,
    WIDGETS_POLL_DUTY_MAX_MS,
  );
}

const widgetsPoll = createPollChain(
  () => pollWidgetsSnapshot(dashboardDataUpdatesId),
  widgetsPollDelay,
);

function startWidgetsPolling(dataUpdatesId: number) {
  if (widgetsPoll.active || dataUpdatesId !== dashboardDataUpdatesId) {
    return;
  }

  widgetsPollFailures = 0;
  widgetsPoll.start(0);
}

function stopWidgetsPolling() {
  widgetsPoll.stop();
  widgetsPollFailures = 0;
  lastPolledTotals = null;
  lastWidgetsPollDurationMs = 0;

  if (widgetsSocketGraceTimer) {
    clearTimeout(widgetsSocketGraceTimer);
    widgetsSocketGraceTimer = null;
  }
}

// The load is what the core used between two readings, so they come close together; the widget
// waits for its first load, so the second reading comes sooner.
const CORE_USAGE_INTERVAL_MS = 2000;
const CORE_USAGE_FIRST_INTERVAL_MS = 500;
const CORE_USAGE_BACKOFF_MAX_MS = 30000;
// Ages are counted on this browser's clock between readings.
const AGE_TICK_MS = 1000;
let coreUsageFailures = 0;
let lastCoreUsage: CoreUsageReading | null = null;
let coreStartedAt = 0;
let ageTimer: ReturnType<typeof setInterval> | null = null;

function reportCoreUsageFailure() {
  coreUsageFailures += 1;
  lastCoreUsage = null;
  store.set({
    coreUsageWidget: {
      loading: false,
      failed: true,
      data: { cpu: null, memory: 0, startedAt: 0 },
    },
  });
}

// Anchored once per core process: re-anchoring on every reading would make the age step back and
// forth by each answer's travel time.
function applyCoreUsage(reading: CoreUsageReading) {
  if (lastCoreUsage?.started !== reading.started) {
    coreStartedAt = Date.now() - coreAgeSeconds(reading) * 1000;
  }
  const cpu = cpuShare(lastCoreUsage, reading);
  lastCoreUsage = reading;
  store.set({
    coreUsageWidget: {
      loading: false,
      failed: false,
      data: { cpu, memory: reading.memory_kb * 1024, startedAt: coreStartedAt },
    },
  });
}

async function pollCoreUsage(dataUpdatesId: number) {
  const response = await readCoreUsage();

  if (!coreUsagePoll.active || dataUpdatesId !== dashboardDataUpdatesId) {
    return;
  }

  if (!response.success || !response.data.running) {
    reportCoreUsageFailure();
    return;
  }

  coreUsageFailures = 0;
  applyCoreUsage(response.data);
}

const coreUsagePoll = createPollChain(
  () => pollCoreUsage(dashboardDataUpdatesId),
  () => {
    if (coreUsageFailures > 0) {
      return Math.min(
        CORE_USAGE_INTERVAL_MS * 2 ** coreUsageFailures,
        CORE_USAGE_BACKOFF_MAX_MS,
      );
    }
    return store.get().coreUsageWidget.data.cpu === null
      ? CORE_USAGE_FIRST_INTERVAL_MS
      : CORE_USAGE_INTERVAL_MS;
  },
);

function restartCoreUsagePollAfterFailure() {
  if (coreUsageFailures === 0) {
    return;
  }

  coreUsageFailures = 0;
  coreUsagePoll.now();
}

function stopCoreUsagePolling() {
  coreUsagePoll.stop();
  coreUsageFailures = 0;
  lastCoreUsage = null;
  coreStartedAt = 0;
}

async function connectToClashSockets(dataUpdatesId: number) {
  const mountId = dashboardMountId;
  // Without the secret the sockets are refused, and the polls cover for them.
  const clashApiSecret = await getClashApiSecret().catch(() => '');

  if (
    !dashboardMounted ||
    mountId !== dashboardMountId ||
    dataUpdatesId !== dashboardDataUpdatesId
  ) {
    return;
  }

  trafficSocketUrl = getClashSocketUrl('/traffic', clashApiSecret);
  connectionsSocketUrl = `${getClashSocketUrl('/connections', clashApiSecret)}&interval=${WIDGETS_SNAPSHOT_INTERVAL_MS}`;

  socket.subscribe(
    trafficSocketUrl,
    (msg) => {
      if (dataUpdatesId !== dashboardDataUpdatesId) {
        return;
      }

      const parsedMsg = JSON.parse(msg);

      trafficSocketLive = true;

      if (widgetsAreLive()) {
        stopWidgetsPolling();
      }

      store.set({
        bandwidthWidget: {
          loading: false,
          failed: false,
          data: { up: parsedMsg.up, down: parsedMsg.down },
        },
      });
    },
    (_err) => {
      if (dataUpdatesId !== dashboardDataUpdatesId) {
        return;
      }

      logger.error(
        '[DASHBOARD]',
        'connectToClashSockets - traffic: failed to connect to',
        getClashWsUrl(),
      );
      trafficSocketLive = false;
      startWidgetsPolling(dataUpdatesId);
    },
  );

  socket.subscribe(
    connectionsSocketUrl,
    (msg) => {
      if (dataUpdatesId !== dashboardDataUpdatesId) {
        return;
      }

      const parsedMsg = JSON.parse(msg);

      connectionsSocketLive = true;

      if (widgetsAreLive()) {
        stopWidgetsPolling();
      }

      applyServerConnections(parsedMsg.connections || []);

      store.set({
        trafficTotalWidget: {
          loading: false,
          failed: false,
          data: {
            downloadTotal: parsedMsg.downloadTotal,
            uploadTotal: parsedMsg.uploadTotal,
          },
        },
        connectionsWidget: {
          loading: false,
          failed: false,
          data: { connections: parsedMsg.connections?.length },
        },
      });
    },
    (_err) => {
      if (dataUpdatesId !== dashboardDataUpdatesId) {
        return;
      }

      logger.error(
        '[DASHBOARD]',
        'connectToClashSockets - connections: failed to connect to',
        getClashWsUrl(),
      );
      connectionsSocketLive = false;
      startWidgetsPolling(dataUpdatesId);
    },
  );
}

function sectionsRefreshDelay() {
  if (sectionsRefreshFailures > 0) {
    return Math.min(
      SECTIONS_REFRESH_INTERVAL_MS * 2 ** sectionsRefreshFailures,
      SECTIONS_REFRESH_BACKOFF_MAX_MS,
    );
  }

  return pollDelayForDuration(
    latencyRequests.size > 0
      ? SECTIONS_LATENCY_REFRESH_INTERVAL_MS
      : SECTIONS_REFRESH_INTERVAL_MS,
    lastSectionsRefreshDurationMs,
    SECTIONS_REFRESH_DUTY_MAX_MS,
  );
}

// A test started right after a refresh would show nothing until the next interval; a refresh
// already on its way asks for its next delay once the test is running.
function restartSectionsRefresh() {
  if (!dashboardDataUpdatesStarted || sectionsRefreshPromise) {
    return;
  }

  sectionsRefresh.stop();
  sectionsRefresh.start(sectionsRefreshDelay());
}

const sectionsRefresh = createPollChain(async () => {
  const startedAt = Date.now();
  const success = await fetchDashboardSections();
  lastSectionsRefreshDurationMs = Date.now() - startedAt;
  sectionsRefreshFailures = success ? 0 : sectionsRefreshFailures + 1;
}, sectionsRefreshDelay);

function stopDashboardDataUpdates() {
  dashboardDataUpdatesStarted = false;
  dashboardDataUpdatesId += 1;
  sectionsRefresh.stop();
  sectionsRefreshFailures = 0;
  lastSectionsRefreshDurationMs = 0;
  sectionsRefreshQueued = false;
  stopWidgetsPolling();
  stopCoreUsagePolling();
  trafficSocketLive = false;
  connectionsSocketLive = false;
  for (const url of [trafficSocketUrl, connectionsSocketUrl]) {
    if (url) {
      socket.disconnect(url);
    }
  }
  trafficSocketUrl = '';
  connectionsSocketUrl = '';
  serverViewsLive = false;
  serverCounters = null;
  renderedServersConfig = '';
}

// The tab asks the Clash API directly rather than first asking whether the core runs. A browser
// that cannot open a plaintext socket (an HTTPS page) polls the connections snapshot instead.
function startDashboardDataUpdates() {
  if (dashboardDataUpdatesStarted || !dashboardMounted) {
    return;
  }

  dashboardDataUpdatesStarted = true;
  const dataUpdatesId = ++dashboardDataUpdatesId;
  void fetchDashboardSections({ force: true });

  if (canUseDirectClashApi()) {
    void connectToClashSockets(dataUpdatesId);
    widgetsSocketGraceTimer = setTimeout(() => {
      widgetsSocketGraceTimer = null;
      startWidgetsPolling(dataUpdatesId);
    }, WIDGETS_SOCKET_GRACE_MS);
  } else {
    startWidgetsPolling(dataUpdatesId);
  }

  sectionsRefresh.start(SECTIONS_REFRESH_INTERVAL_MS);
  coreUsagePoll.start(0);
}

async function handleChooseOutbound(
  sectionName: string,
  selector: string,
  tag: string,
) {
  const sectionsWidget = store.get().sectionsWidget;
  const section = sectionsWidget.data.find(
    (item) => item.sectionName === sectionName,
  );

  if (
    !section?.withTagSelect ||
    selectorRequests.has(selector) ||
    section.outbounds.some(
      (outbound) => outbound.code === tag && outbound.selected,
    )
  ) {
    return;
  }

  selectorRequests.add(selector);

  try {
    const response = await CustomForkopMethods.setClashApiGroupProxy(
      selector,
      tag,
    );
    if (!response.success) {
      throw new Error(response.error);
    }

    const current = store.get().sectionsWidget;
    store.set({
      sectionsWidget: {
        ...current,
        data: current.data.map((item) =>
          item.sectionName === sectionName
            ? {
                ...item,
                outbounds: item.outbounds.map((outbound) => ({
                  ...outbound,
                  selected: outbound.code === tag,
                })),
              }
            : item,
        ),
      },
    });
    void fetchDashboardSections({ force: true });
  } catch (error) {
    logger.error('[DASHBOARD]', 'handleChooseOutbound failed', error);
    showToast(_('Failed to switch the server'), 'error');
  } finally {
    selectorRequests.delete(selector);
  }
}

// Carries the answer of the test that just returned into the page before the next refresh,
// leaving every member it did not report alone.
function applyLatencyResult(
  sectionName: string,
  latencies: Record<string, number>,
) {
  const sectionsWidget = store.get().sectionsWidget;
  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      data: sectionsWidget.data.map((section) => {
        if (section.sectionName !== sectionName) {
          return section;
        }

        return {
          ...section,
          outbounds: section.outbounds.map((outbound) => {
            const updateMembers = <T extends Forkop.UrlTestMember>(
              members: T[],
            ) =>
              members.map((member) => ({
                ...member,
                latency: latencies[member.code] ?? member.latency,
              }));
            const urlTestInfo = outbound.urlTestInfo
              ? {
                  ...outbound.urlTestInfo,
                  outbounds: updateMembers(outbound.urlTestInfo.outbounds),
                }
              : undefined;
            const fallbackInfo = outbound.fallbackInfo
              ? {
                  ...outbound.fallbackInfo,
                  outbounds: updateMembers(outbound.fallbackInfo.outbounds),
                }
              : undefined;
            const selectedLatency = (
              urlTestInfo?.outbounds || fallbackInfo?.outbounds
            )?.find((member) => member.selected)?.latency;

            return {
              ...outbound,
              latency:
                latencies[outbound.code] ?? selectedLatency ?? outbound.latency,
              urlTestInfo,
              fallbackInfo,
            };
          }),
        };
      }),
    },
  });
}

// A group sweep has the same ceiling everywhere. Results need no message: only a controller that
// gave no answer is reported.
async function handleTestLatency(
  latencyType: 'group' | 'proxy',
  section: Forkop.OutboundGroup,
  tag: string,
  requestKey: string,
) {
  if (latencyRequests.has(requestKey)) {
    return true;
  }

  let answered = true;

  latencyRequests.add(requestKey);
  void renderSectionsWidget();
  restartSectionsRefresh();
  try {
    const response =
      latencyType === 'group'
        ? await CustomForkopMethods.getClashApiGroupLatency(tag)
        : await CustomForkopMethods.getClashApiProxyLatency(tag);
    if (!response.success) {
      if (response.status === undefined) {
        answered = false;
        showToast(
          _('Latency test failed: the Clash API did not answer'),
          'error',
        );
      }
      throw new Error(response.error);
    }

    applyLatencyResult(
      section.sectionName,
      latencyType === 'group'
        ? (response.data as Record<string, number>)
        : { [tag]: response.data.delay },
    );
  } catch (error) {
    logger.error('[DASHBOARD]', 'handleTestLatency: failed', error);
  } finally {
    latencyRequests.delete(requestKey);
    void renderSectionsWidget();
    void fetchDashboardSections({ force: true });
  }

  return answered;
}

function handleTestSectionLatency(section: Forkop.OutboundGroup) {
  const target = sectionLatencyTarget(section);
  return target
    ? handleTestLatency(
        target.type,
        section,
        target.tag,
        sectionLatencyRequestKey(section.sectionName),
      )
    : Promise.resolve(true);
}

async function handleCopyOutbound(outbound: Forkop.Outbound) {
  const link = await resolveOutboundProxyLink(
    outbound,
    CustomForkopMethods.getClashApiProxyLink,
  );
  if (link) {
    copyToClipboard(link);
    return;
  }

  showToast(_('Proxy link is unavailable'), 'error');
}

// One section's exit panel is open at a time; the sections refresh redraws it from here.
async function lookupExit(section: Forkop.OutboundGroup) {
  const target = sectionLatencyTarget(section);
  if (!target) {
    return;
  }

  const lookupId = ++exitLookupId;
  exitPanel = {
    sectionName: section.sectionName,
    loading: true,
    report:
      exitPanel?.sectionName === section.sectionName
        ? exitPanel.report
        : undefined,
  };
  void renderSectionsWidget();

  const response = await CustomForkopMethods.getClashApiProxyExit(target.tag);
  if (lookupId !== exitLookupId) {
    return;
  }

  exitPanel = response.success
    ? {
        sectionName: section.sectionName,
        loading: false,
        report: response.data,
      }
    : {
        sectionName: section.sectionName,
        loading: false,
        error: response.error,
      };
  void renderSectionsWidget();
}

function closeExitPanel() {
  if (!exitPanel) {
    return;
  }

  exitPanel = null;
  exitLookupId += 1;
  void renderSectionsWidget();
}

function handleToggleExit(section: Forkop.OutboundGroup) {
  if (exitPanel?.sectionName === section.sectionName) {
    closeExitPanel();
    return;
  }

  exitPanel = null;
  void lookupExit(section);
}

// Captured before any handler below can stop the click, so a press anywhere else closes the panel.
function closeExitPanelOnOutsidePress(event: Event) {
  const target = event.target as Element | null;
  if (
    exitPanel &&
    !target?.closest?.(
      '.fkp_dashboard-page__exit-panel, .fkp_dashboard-page__outbound-section__exit',
    )
  ) {
    closeExitPanel();
  }
}

function closeExitPanelOnEscape(event: KeyboardEvent) {
  if (event.key === 'Escape') {
    closeExitPanel();
  }
}

function formatUrlTestModalValue(value: unknown) {
  if (typeof value === 'boolean') {
    return value ? _('Yes') : _('No');
  }

  const text = `${value ?? ''}`.trim();
  return text || _('No');
}

function formatUrlTestLatency(latency: number) {
  return latency ? `${latency}ms` : _('N/A');
}

function renderDetailsUrl(value: unknown) {
  const url = `${value ?? ''}`.trim();

  if (!/^https?:\/\//i.test(url)) {
    return E('span', {}, formatUrlTestModalValue(value));
  }

  return E(
    'a',
    {
      class: 'fkp_dashboard-page__urltest-details__url',
      href: url,
      target: '_blank',
      rel: 'noopener noreferrer',
    },
    url,
  );
}

function renderDetailsMemberName(member: Forkop.UrlTestMember) {
  return [
    ...(member.subscriptionTag
      ? [
          E(
            'span',
            {
              class:
                'fkp_dashboard-page__outbound-grid__item__subscription-tag',
            },
            member.subscriptionTag,
          ),
        ]
      : []),
    ...renderFlagEmojis(member.displayName),
  ];
}

function renderUrlTestSelectedValue(info: Forkop.UrlTestInfo) {
  const selectedMember = info.outbounds.find((member) => member.selected);
  const selectedName =
    selectedMember?.displayName || info.selectedName || info.selectedCode || '';
  const name = formatUrlTestModalValue(selectedName);

  if (!selectedName.trim()) {
    return E('span', {}, name);
  }

  return E(
    'span',
    { class: 'fkp_dashboard-page__urltest-details__selected-value' },
    [
      E(
        'span',
        { class: 'fkp_dashboard-page__urltest-details__selected-name' },
        selectedMember ? renderDetailsMemberName(selectedMember) : name,
      ),
      ...(selectedMember?.type
        ? [
            E(
              'span',
              { class: 'fkp_dashboard-page__urltest-details__selected-type' },
              selectedMember.type,
            ),
          ]
        : []),
      ...(selectedMember
        ? [
            E(
              'span',
              { class: latencyClassName(selectedMember.latency) },
              formatUrlTestLatency(selectedMember.latency),
            ),
          ]
        : []),
    ],
  );
}

function renderUrlTestInfoModal(info?: Forkop.UrlTestInfo) {
  if (!info) {
    return [E('div', {}, _('URLTest details are unavailable'))];
  }

  const fields: Array<{
    label: string;
    value?: unknown;
    children?: Array<HTMLElement | string>;
  }> = [
    {
      label: _('Selected'),
      children: [renderUrlTestSelectedValue(info)],
    },
    { label: _('Check URL'), children: [renderDetailsUrl(info.url)] },
    {
      label: _('Expected status'),
      value: info.expectedStatus === '*' ? _('Any') : info.expectedStatus,
    },
    { label: _('Check interval'), value: info.interval },
    { label: _('Tolerance'), value: info.tolerance },
    { label: _('Idle timeout'), value: info.idleTimeout },
    {
      label: _('Interrupt connections'),
      value: info.interruptExistConnections,
    },
  ];

  return [
    E(
      'dl',
      { class: 'fkp_dashboard-page__urltest-details__params' },
      fields.map(({ label, value, children }) =>
        E('div', { class: 'fkp_dashboard-page__urltest-details__param' }, [
          E('dt', {}, label),
          E(
            'dd',
            {},
            children || [E('span', {}, formatUrlTestModalValue(value))],
          ),
        ]),
      ),
    ),
    E('div', { class: 'fkp_dashboard-page__urltest-details__outbounds' }, [
      E(
        'div',
        { class: 'fkp_dashboard-page__urltest-details__outbounds-title' },
        _('Nodes'),
      ),
      E(
        'div',
        { class: 'fkp_dashboard-page__urltest-details__table' },
        info.outbounds.length
          ? info.outbounds.map((member) =>
              E(
                'div',
                {
                  class: [
                    'fkp_dashboard-page__urltest-details__row',
                    member.selected
                      ? 'fkp_dashboard-page__urltest-details__row--active'
                      : '',
                  ]
                    .filter(Boolean)
                    .join(' '),
                },
                [
                  E(
                    'div',
                    { class: 'fkp_dashboard-page__urltest-details__row-name' },
                    [
                      E('b', {}, renderDetailsMemberName(member)),
                      ...(member.type
                        ? [
                            E(
                              'span',
                              {
                                class:
                                  'fkp_dashboard-page__urltest-details__row-type',
                              },
                              member.type,
                            ),
                          ]
                        : []),
                    ],
                  ),
                  E(
                    'div',
                    { class: 'fkp_dashboard-page__urltest-details__row-meta' },
                    [
                      E(
                        'span',
                        { class: latencyClassName(member.latency) },
                        formatUrlTestLatency(member.latency),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : [
              E(
                'div',
                { class: 'fkp_dashboard-page__urltest-details__empty' },
                _('Node list is empty'),
              ),
            ],
      ),
    ]),
    renderDetailsFooter(),
  ];
}

function handleShowUrlTestInfo(outbound: Forkop.Outbound) {
  const info = outbound.urlTestInfo;

  if (!info) {
    return;
  }

  showDetailsModal(
    `${_('URLTest details')}: ${info.displayName || outbound.displayName}`,
    () => renderUrlTestInfoModal(findGroupInfo('urlTestInfo', info.code)),
  );
}

// With a single level every node would carry the same chip.
function hasSeveralLevels(info: Forkop.FallbackInfo) {
  return (
    new Set(info.outbounds.map((member) => member.levelId ?? member.levelName))
      .size > 1
  );
}

function renderFallbackSelectedValue(info: Forkop.FallbackInfo) {
  const selectedMember = info.outbounds.find((member) => member.selected);
  const selectedName =
    selectedMember?.displayName || info.selectedName || info.selectedCode || '';
  const name = formatUrlTestModalValue(selectedName);

  if (!selectedName.trim()) {
    return E('span', {}, name);
  }

  return E(
    'span',
    { class: 'fkp_dashboard-page__urltest-details__selected-value' },
    [
      E(
        'span',
        {
          class: [
            'fkp_dashboard-page__urltest-details__selected-name',
            selectedMember
              ? 'fkp_dashboard-page__urltest-details__fallback-name'
              : '',
          ]
            .filter(Boolean)
            .join(' '),
        },
        selectedMember
          ? renderFallbackMemberName(selectedMember, hasSeveralLevels(info))
          : name,
      ),
      ...(selectedMember?.type
        ? [
            E(
              'span',
              { class: 'fkp_dashboard-page__urltest-details__selected-type' },
              selectedMember.type,
            ),
          ]
        : []),
      ...(selectedMember
        ? [
            E(
              'span',
              { class: latencyClassName(selectedMember.latency) },
              formatUrlTestLatency(selectedMember.latency),
            ),
          ]
        : []),
    ],
  );
}

function renderFallbackMemberName(
  member: Forkop.FallbackMember,
  showLevel: boolean,
) {
  return [
    ...(showLevel
      ? [
          E(
            'span',
            { class: 'fkp_dashboard-page__urltest-details__fallback-level' },
            member.levelName || _('Level'),
          ),
        ]
      : []),
    E(
      'span',
      { class: 'fkp_dashboard-page__urltest-details__fallback-node' },
      renderDetailsMemberName(member),
    ),
  ];
}

// Looked up by code on every redraw, so a dialog shows the latest refresh.
function findGroupInfo<K extends 'urlTestInfo' | 'fallbackInfo'>(
  kind: K,
  code: string,
): Forkop.Outbound[K] {
  for (const section of store.get().sectionsWidget.data) {
    for (const outbound of section.outbounds) {
      if (outbound[kind]?.code === code) {
        return outbound[kind];
      }
    }
  }

  return undefined;
}

function fallbackPinRequestKey(code: string, memberCode: string) {
  return `${code}:${memberCode}`;
}

async function handleFallbackPin(code: string, member: Forkop.FallbackMember) {
  const requestKey = fallbackPinRequestKey(code, member.code);

  if (fallbackPinRequests.has(requestKey)) {
    return;
  }

  fallbackPinRequests.add(requestKey);
  refreshDetailsModal();

  try {
    const response = await CustomForkopMethods.setClashApiGroupProxy(
      code,
      member.pinned ? '' : member.code,
    );

    if (!response.success) {
      throw new Error(response.error);
    }

    await fetchDashboardSections({ force: true });
  } catch (error) {
    showToast(_('Failed to pin the server'), 'error');
    logger.error('[DASHBOARD]', 'handleFallbackPin failed', error);
  } finally {
    fallbackPinRequests.delete(requestKey);
    refreshDetailsModal();
  }
}

function renderFallbackMemberRow(
  info: Forkop.FallbackInfo,
  member: Forkop.FallbackMember,
  showLevel: boolean,
) {
  const busy = fallbackPinRequests.has(
    fallbackPinRequestKey(info.code, member.code),
  );
  const choose = () => {
    void handleFallbackPin(info.code, member);
  };

  return E(
    'div',
    {
      class: [
        'fkp_dashboard-page__urltest-details__row',
        'fkp_dashboard-page__urltest-details__row--selectable',
        member.selected
          ? 'fkp_dashboard-page__urltest-details__row--active'
          : '',
        busy ? 'fkp_dashboard-page__urltest-details__row--busy' : '',
      ]
        .filter(Boolean)
        .join(' '),
      role: 'button',
      tabIndex: 0,
      'aria-pressed': member.pinned ? 'true' : 'false',
      click: (event: MouseEvent) => {
        event.preventDefault();
        choose();
      },
      keydown: (event: KeyboardEvent) => {
        if (event.key !== 'Enter' && event.key !== ' ') {
          return;
        }

        event.preventDefault();
        choose();
      },
    },
    [
      E('div', { class: 'fkp_dashboard-page__urltest-details__row-name' }, [
        E(
          'b',
          { class: 'fkp_dashboard-page__urltest-details__fallback-name' },
          renderFallbackMemberName(member, showLevel),
        ),
        ...(member.type
          ? [
              E(
                'span',
                { class: 'fkp_dashboard-page__urltest-details__row-type' },
                member.type,
              ),
            ]
          : []),
        ...(member.pinned
          ? [
              E(
                'span',
                {
                  class: 'fkp_dashboard-page__urltest-details__row-pin',
                  'aria-hidden': 'true',
                },
                renderPinIcon24(),
              ),
            ]
          : []),
      ]),
      E('div', { class: 'fkp_dashboard-page__urltest-details__row-meta' }, [
        E(
          'span',
          { class: latencyClassName(member.latency) },
          formatUrlTestLatency(member.latency),
        ),
      ]),
    ],
  );
}

function renderFallbackInfoModal(info?: Forkop.FallbackInfo) {
  if (!info) {
    return [E('div', {}, _('Fallback details are unavailable'))];
  }

  const fields: Array<{
    label: string;
    value?: unknown;
    children?: Array<HTMLElement | string>;
  }> = [
    {
      label: _('Selected'),
      children: [renderFallbackSelectedValue(info)],
    },
    {
      label: _('Check URL'),
      children: [renderDetailsUrl(info.healthCheckUrl)],
    },
    {
      label: _('Expected status'),
      value: info.expectedStatus === '*' ? _('Any') : info.expectedStatus,
    },
    { label: _('Check interval'), value: info.healthCheckInterval },
    { label: _('Check timeout'), value: info.healthCheckTimeout },
    { label: _('Connection timeout'), value: info.attemptTimeout },
    { label: _('Idle timeout'), value: info.idleTimeout },
    {
      label: _('Interrupt connections'),
      value: info.interruptExistConnections,
    },
  ];

  return [
    E(
      'dl',
      { class: 'fkp_dashboard-page__urltest-details__params' },
      fields.map(({ label, value, children }) =>
        E('div', { class: 'fkp_dashboard-page__urltest-details__param' }, [
          E('dt', {}, label),
          E(
            'dd',
            {},
            children || [E('span', {}, formatUrlTestModalValue(value))],
          ),
        ]),
      ),
    ),
    E('div', { class: 'fkp_dashboard-page__urltest-details__outbounds' }, [
      E(
        'div',
        { class: 'fkp_dashboard-page__urltest-details__outbounds-title' },
        _('Nodes'),
      ),
      E(
        'div',
        { class: 'fkp_dashboard-page__urltest-details__hint' },
        _('Click a node to pin it, and click it again to unpin it.'),
      ),
      E(
        'div',
        { class: 'fkp_dashboard-page__urltest-details__table' },
        info.outbounds.length
          ? info.outbounds.map((member) =>
              renderFallbackMemberRow(info, member, hasSeveralLevels(info)),
            )
          : [
              E(
                'div',
                { class: 'fkp_dashboard-page__urltest-details__empty' },
                _('Node list is empty'),
              ),
            ],
      ),
    ]),
    renderDetailsFooter(),
  ];
}

function renderDetailsFooter() {
  return E('div', { class: 'fkp_dashboard-page__urltest-details__footer' }, [
    E(
      'button',
      {
        type: 'button',
        class: 'btn cbi-button cbi-button-neutral',
        click: () => {
          closeDetailsModal();
          ui.hideModal();
        },
      },
      _('Close'),
    ),
  ]);
}

function closeDetailsModal() {
  activeDetailsModal?.unsubscribe();
  activeDetailsModal = null;
}

// The details dialogs follow the sections refresh and keep their scroll position. LuCI keeps a
// closed dialog in the page, so whether it shows is read from the overlay.
function refreshDetailsModal() {
  const modal = activeDetailsModal;

  if (!modal) {
    return;
  }

  if (
    !modal.container.isConnected ||
    !document.body.classList.contains('modal-overlay-active')
  ) {
    closeDetailsModal();
    return;
  }

  const table = '.fkp_dashboard-page__urltest-details__table';
  const scrollTop = modal.container.querySelector(table)?.scrollTop ?? 0;
  modal.container.replaceChildren(...modal.render());
  const redrawn = modal.container.querySelector(table);
  if (redrawn) {
    redrawn.scrollTop = scrollTop;
  }
}

function showDetailsModal(title: string, render: () => Node[]) {
  closeDetailsModal();

  const container = E(
    'div',
    { class: 'fkp_dashboard-page__urltest-details' },
    render(),
  ) as HTMLElement;

  activeDetailsModal = {
    container,
    render,
    unsubscribe: store.subscribeKey('sectionsWidget', () => {
      refreshDetailsModal();
    }),
  };

  ui.showModal(title, container);
}

function handleShowFallbackInfo(outbound: Forkop.Outbound) {
  const info = outbound.fallbackInfo;

  if (!info) {
    return;
  }

  showDetailsModal(
    `${_('Fallback details')}: ${info.displayName || outbound.displayName}`,
    () => renderFallbackInfoModal(findGroupInfo('fallbackInfo', info.code)),
  );
}

// The Servers tab's Tailscale dialog, which polls the core itself rather than follow the sections.
function handleShowTailscaleInfo(outbound: Forkop.Outbound) {
  closeDetailsModal();
  showTailscaleDetailsModal(
    `${_('Tailscale details')}: ${outbound.displayName}`,
    outbound.code,
    _('The tunnel is not running yet. Apply the settings, or start Forkop.'),
  );
}

async function runToolbarAction(
  action: 'testAll' | 'subscriptions' | 'lists',
  run: () => Promise<void>,
) {
  if (toolbarActions.has(action)) {
    return;
  }

  toolbarActions.add(action);
  void renderSectionsWidget();
  try {
    await run();
  } finally {
    toolbarActions.delete(action);
    void renderSectionsWidget();
  }
}

// One section after another: sweeping every group at once would dial them all together. A
// controller that did not answer one will not answer the next, so that ends the run.
function handleTestAllSections() {
  return runToolbarAction('testAll', async () => {
    for (const section of store.get().sectionsWidget.data) {
      if (!dashboardMounted || !(await handleTestSectionLatency(section))) {
        return;
      }
    }
  });
}

function subscriptionProviderTags() {
  return [
    ...new Set(
      store
        .get()
        .sectionsWidget.data.flatMap(
          (section) => section.subscriptionProviderTags || [],
        ),
    ),
  ];
}

// Both endpoints answer 204 on success and 503 naming what failed; anything short of every target
// succeeding is a failure.
function handleUpdateLists() {
  return runToolbarAction('lists', async () => {
    const response = await CustomForkopMethods.updateClashApiRuleProviders();

    if (response.success) {
      showToast(_('Lists updated'), 'success');
      return;
    }

    logger.error('[DASHBOARD]', 'handleUpdateLists: failed', response.error);
    showToast(_('Failed to update lists'), 'error');
  });
}

function handleUpdateSubscriptions() {
  return runToolbarAction('subscriptions', async () => {
    const response = await CustomForkopMethods.updateClashApiProxyProviders(
      subscriptionProviderTags(),
    );

    if (!pageUnloading) {
      void fetchDashboardSections({ force: true });
    }

    if (response.success) {
      showToast(_('Subscriptions updated'), 'success');
      return;
    }

    logger.error(
      '[DASHBOARD]',
      'handleUpdateSubscriptions: failed',
      response.error,
    );
    showToast(_('Failed to update subscriptions'), 'error');
  });
}

async function renderSectionsWidget() {
  logger.debug('[DASHBOARD]', 'renderSectionsWidget');
  const sectionsWidget = store.get().sectionsWidget;
  const container = document.getElementById('dashboard-sections-grid');

  if (!container) {
    return;
  }

  const toolbar = document.getElementById('dashboard-sections-toolbar');

  if (sectionsWidget.loading || sectionsWidget.failed) {
    const renderedWidget = renderSectionsPlaceholder({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
    });

    return preserveScrollForPage(() => {
      toolbar?.replaceChildren();
      container.replaceChildren(renderedWidget);
    });
  }

  const renderedToolbar = renderToolbar({
    testAll:
      sectionsWidget.data.length > 1
        ? {
            busy: toolbarActions.has('testAll'),
            onClick: () => void handleTestAllSections(),
          }
        : undefined,
    updateSubscriptions: subscriptionProviderTags().length
      ? {
          busy: toolbarActions.has('subscriptions'),
          onClick: () => void handleUpdateSubscriptions(),
        }
      : undefined,
    updateLists: sectionsWidget.hasRemoteLists
      ? {
          busy: toolbarActions.has('lists'),
          onClick: () => void handleUpdateLists(),
        }
      : undefined,
  });

  // A lone section has nothing to be folded out of the way of.
  const collapsible = sectionsWidget.data.length > 1;
  const renderedWidgets = sectionsWidget.data.map((section) =>
    renderSections({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
      section,
      collapsible,
      collapsed: collapsedSections.has(section.sectionName),
      onCollapsedChange: handleCollapsedChange,
      latencyFetching: latencyRequests.has(
        sectionLatencyRequestKey(section.sectionName),
      ),
      latencyFetchingTargets: new Set(
        section.outbounds
          .map((outbound) => outbound.code)
          .filter((tag) =>
            latencyRequests.has(
              outboundLatencyRequestKey(section.sectionName, tag),
            ),
          ),
      ),
      sortByLatency: latencySortedSections.has(section.sectionName),
      onSortByLatencyChange: handleSortByLatency,
      onTestLatency: () => {
        void handleTestSectionLatency(section);
      },
      onTestOutboundLatency: (latencyType, tag) => {
        void handleTestLatency(
          latencyType,
          section,
          tag,
          outboundLatencyRequestKey(section.sectionName, tag),
        );
      },
      onChooseOutbound: (sectionName, selector, tag) => {
        void handleChooseOutbound(sectionName, selector, tag);
      },
      onCopyOutbound: (_section, outbound) => {
        void handleCopyOutbound(outbound);
      },
      onShowUrlTestInfo: (outbound) => {
        handleShowUrlTestInfo(outbound);
      },
      onShowFallbackInfo: (outbound) => {
        handleShowFallbackInfo(outbound);
      },
      onShowTailscaleInfo: (outbound) => {
        handleShowTailscaleInfo(outbound);
      },
      exitPanel:
        exitPanel?.sectionName === section.sectionName
          ? {
              ...exitPanel,
              nodeName: exitNodeName(section, exitPanel.report?.outbound),
            }
          : undefined,
      onToggleExit: () => handleToggleExit(section),
      onRefreshExit: () => {
        void lookupExit(section);
      },
      onCopyExitAddress: (address) => copyToClipboard(address),
    }),
  );

  return preserveScrollForPage(() => {
    toolbar?.replaceChildren(...renderedToolbar);
    container.replaceChildren(...renderedWidgets);
  });
}

function renderServersWidget() {
  const container = document.getElementById('dashboard-servers-grid');

  if (!container) {
    return;
  }

  const servers = store.get().sectionsWidget.servers;
  const config = JSON.stringify(servers);

  // A changed configuration is described afresh; the rates wait for the next snapshot.
  if (config !== renderedServersConfig) {
    renderedServersConfig = config;
    serverViews = describeServers(servers, [], null, 0).servers;
    serverCounters = null;
    serverViewsLive = false;
  }

  preserveScrollForPage(() => {
    container.replaceChildren(
      ...serverViews.map((server) =>
        renderServers({ server, live: serverViewsLive }),
      ),
    );
  });
}

async function renderBandwidthWidget() {
  logger.debug('[DASHBOARD]', 'renderBandwidthWidget');
  const traffic = store.get().bandwidthWidget;

  const container = document.getElementById('dashboard-widget-traffic');

  if (!container) {
    return;
  }

  if (traffic.loading || traffic.failed) {
    const renderedWidget = renderWidget({
      loading: traffic.loading,
      failed: traffic.failed,
      title: '',
      items: [],
    });

    return container.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: traffic.loading,
    failed: traffic.failed,
    title: _('Traffic'),
    items: [
      { key: _('Uplink'), value: `${prettyBytes(traffic.data.up)}/s` },
      { key: _('Downlink'), value: `${prettyBytes(traffic.data.down)}/s` },
    ],
  });

  container.replaceChildren(renderedWidget);
}

async function renderTrafficTotalWidget() {
  logger.debug('[DASHBOARD]', 'renderTrafficTotalWidget');
  const trafficTotalWidget = store.get().trafficTotalWidget;

  const container = document.getElementById('dashboard-widget-traffic-total');

  if (!container) {
    return;
  }

  if (trafficTotalWidget.loading || trafficTotalWidget.failed) {
    const renderedWidget = renderWidget({
      loading: trafficTotalWidget.loading,
      failed: trafficTotalWidget.failed,
      title: '',
      items: [],
    });

    return container.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: trafficTotalWidget.loading,
    failed: trafficTotalWidget.failed,
    title: _('Traffic Total'),
    items: [
      {
        key: _('Uplink'),
        value: String(prettyBytes(trafficTotalWidget.data.uploadTotal)),
      },
      {
        key: _('Downlink'),
        value: String(prettyBytes(trafficTotalWidget.data.downloadTotal)),
      },
    ],
  });

  container.replaceChildren(renderedWidget);
}

async function renderLoadWidget() {
  logger.debug('[DASHBOARD]', 'renderLoadWidget');
  const usage = store.get().coreUsageWidget;

  const container = document.getElementById('dashboard-widget-load');

  if (!container) {
    return;
  }

  // The load needs two readings; until the second the widget waits rather than flash a dash.
  const loading = usage.loading || (!usage.failed && usage.data.cpu === null);

  container.replaceChildren(
    renderWidget({
      loading,
      failed: usage.failed,
      title: _('Load'),
      items: [
        {
          key: _('CPU'),
          value: usage.data.cpu === null ? '—' : formatCpuShare(usage.data.cpu),
        },
        { key: _('Memory'), value: String(prettyBytes(usage.data.memory)) },
      ],
    }),
  );
}

let renderedCoreWidget = '';

// Rendered every second for the age, and redrawn only when what it says changed.
function renderCoreWidget() {
  const connections = store.get().connectionsWidget;
  const usage = store.get().coreUsageWidget;

  const container = document.getElementById('dashboard-widget-core');

  if (!container) {
    return;
  }

  const connectionsKnown = !connections.loading && !connections.failed;
  const ageKnown = !usage.loading && !usage.failed;
  const props = {
    loading: connections.loading && usage.loading,
    failed: connections.failed && usage.failed,
    title: _('Core'),
    items: [
      {
        key: _('Connections'),
        value: connectionsKnown ? String(connections.data.connections) : '—',
      },
      {
        key: _('Uptime'),
        value: ageKnown
          ? formatDuration((Date.now() - usage.data.startedAt) / 1000)
          : '—',
      },
    ],
  };
  const key = JSON.stringify(props);

  if (key === renderedCoreWidget && container.firstChild) {
    return;
  }

  renderedCoreWidget = key;
  container.replaceChildren(renderWidget(props));
}

function renderAges() {
  renderCoreWidget();
  const sections = document.getElementById('dashboard-sections-grid');
  if (sections) {
    refreshSubscriptionAges(sections);
  }
}

async function onStoreUpdate(
  next: StoreType,
  prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.sectionsWidget) {
    renderSectionsWidget();
    if (JSON.stringify(next.sectionsWidget.servers) !== renderedServersConfig) {
      renderServersWidget();
    }
  }

  if (diff.bandwidthWidget) {
    renderBandwidthWidget();
  }

  if (diff.trafficTotalWidget) {
    renderTrafficTotalWidget();
  }

  if (diff.coreUsageWidget) {
    renderLoadWidget();
  }

  if (diff.connectionsWidget || diff.coreUsageWidget) {
    renderCoreWidget();
  }

  // A core that has just come up is asked about at once rather than when the
  // backed-off poll comes round.
  if (diff.serviceState && next.serviceState.data.singbox) {
    restartCoreUsagePollAfterFailure();
  }
}

async function onPageMount() {
  onPageUnmount();

  dashboardMounted = true;
  dashboardMountId += 1;
  resetClashApiTransport();

  store.subscribe(onStoreUpdate);
  document.addEventListener('pointerdown', closeExitPanelOnOutsidePress, true);
  document.addEventListener('keydown', closeExitPanelOnEscape);
  void renderSectionsWidget();
  renderServersWidget();
  void renderBandwidthWidget();
  void renderTrafficTotalWidget();
  void renderLoadWidget();
  renderCoreWidget();
  ageTimer = setInterval(renderAges, AGE_TICK_MS);
  startDashboardDataUpdates();
}

function onPageUnmount() {
  dashboardMounted = false;
  dashboardMountId += 1;

  stopDashboardDataUpdates();
  sectionsRefreshQueued = false;
  sectionsRefreshPromise = null;
  if (ageTimer) {
    clearInterval(ageTimer);
    ageTimer = null;
  }
  store.unsubscribe(onStoreUpdate);
  document.removeEventListener(
    'pointerdown',
    closeExitPanelOnOutsidePress,
    true,
  );
  document.removeEventListener('keydown', closeExitPanelOnEscape);
  exitPanel = null;
  exitLookupId += 1;
  store.reset([
    'bandwidthWidget',
    'trafficTotalWidget',
    'connectionsWidget',
    'coreUsageWidget',
  ]);
}

let dashboardLifecycleRegistered = false;
let dashboardControllerInitialized = false;

const dashboardLifecycle = createTabLifecycle({
  shown: () =>
    isDocumentVisible() &&
    (store.get().tabService.current === 'dashboard' ||
      isActiveLuciTab('dashboard')),
  start: onPageMount,
  stop: onPageUnmount,
});

function registerLifecycleListeners() {
  if (dashboardLifecycleRegistered) {
    return;
  }

  dashboardLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      logger.debug(
        '[DASHBOARD]',
        'active tab diff event, active tab:',
        diff.tabService.current,
      );
      dashboardLifecycle.update();
    }
  });
  document.addEventListener('visibilitychange', () =>
    dashboardLifecycle.update(),
  );
}

export async function initController(): Promise<void> {
  if (dashboardControllerInitialized) {
    return;
  }

  dashboardControllerInitialized = true;

  onMount('dashboard-status').then(() => {
    logger.debug('[DASHBOARD]', 'initController', 'onMount');
    registerLifecycleListeners();
    dashboardLifecycle.update();
  });
}
