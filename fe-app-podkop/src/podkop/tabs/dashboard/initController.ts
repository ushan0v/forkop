import {
  getClashWsUrl,
  isCopyableProxyLink,
  onMount,
  preserveScrollForPage,
} from '../../../helpers';
import { copyToClipboard } from '../../../helpers/copyToClipboard';
import { showToast } from '../../../helpers/showToast';
import { prettyBytes } from '../../../helpers/prettyBytes';
import { renderCopyIcon24 } from '../../../icons';
import { CustomPodkopMethods, PodkopShellMethods } from '../../methods';
import {
  logger,
  markUiActionOwned,
  setLocalLatencyAction,
  setLocalSubscriptionAction,
  shouldNotifyOwnedUiAction,
  socket,
  store,
  StoreType,
} from '../../services';
import { renderSections, renderWidget } from './partials';
import { fetchServicesInfo } from '../../fetchers/fetchServicesInfo';
import { getClashApiSecret } from '../../methods/custom/getClashApiSecret';
import { Podkop } from '../../types';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  subscribeRuntimeUiState,
} from '../../services/runtimeUiState.service';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { isTransientRpcError } from '../../helpers/isTransientRpcError';
import { shouldShowLoadingForRestoredAction } from '../../helpers/restoredActionLoading';

const SECTIONS_REFRESH_INTERVAL_MS = 10000;
let sectionsRefreshTimer: ReturnType<typeof setInterval> | null = null;
let sectionsRefreshPromise: Promise<boolean> | null = null;
let sectionsRefreshQueued = false;
let actionStateUnsubscribe: (() => void) | null = null;
let dashboardMounted = false;
let dashboardMountId = 0;
let pageUnloading = false;
const followedSubscriptionJobs = new Set<string>();
const followedLatencyJobs = new Set<string>();
const handledSubscriptionJobs = new Set<string>();
const handledLatencyJobs = new Set<string>();

if (typeof window !== 'undefined') {
  window.addEventListener('pagehide', () => {
    pageUnloading = true;
  });
  window.addEventListener('pageshow', () => {
    pageUnloading = false;
  });
}

// Fetchers

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
    const { data, success } = await CustomPodkopMethods.getDashboardSections();

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

function setSubscriptionUpdating(
  sectionName: string,
  updating: boolean,
  local = false,
) {
  if (local || !updating) {
    setLocalSubscriptionAction(sectionName, updating && local);
  }

  const sectionsWidget = store.get().sectionsWidget;
  const subscriptionUpdatingSections = {
    ...sectionsWidget.subscriptionUpdatingSections,
  };

  if (updating) {
    subscriptionUpdatingSections[sectionName] = true;
  } else {
    delete subscriptionUpdatingSections[sectionName];
  }

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      subscriptionUpdatingSections,
    },
  });
}

function setSelectorSwitching(sectionName: string, tag?: string) {
  const sectionsWidget = store.get().sectionsWidget;
  const selectorSwitchingSections = {
    ...sectionsWidget.selectorSwitchingSections,
  };

  if (tag) {
    selectorSwitchingSections[sectionName] = tag;
  } else {
    delete selectorSwitchingSections[sectionName];
  }

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      selectorSwitchingSections,
    },
  });
}

function setLatencyFetching(
  sectionName: string,
  fetching: boolean,
  local = false,
) {
  if (local || !fetching) {
    setLocalLatencyAction(sectionName, fetching && local);
  }

  const sectionsWidget = store.get().sectionsWidget;
  const latencyFetchingSections = {
    ...sectionsWidget.latencyFetchingSections,
  };

  if (fetching) {
    latencyFetchingSections[sectionName] = true;
  } else {
    delete latencyFetchingSections[sectionName];
  }

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      latencyFetchingSections,
    },
  });
}

async function completeSubscriptionUpdateJob(
  jobId: string,
  sectionName: string,
  response: Podkop.MethodResponse<Podkop.SubscriptionUpdateJobState>,
) {
  if (pageUnloading) {
    setSubscriptionUpdating(sectionName, false);
    return;
  }

  if (jobId && handledSubscriptionJobs.has(jobId)) {
    setSubscriptionUpdating(sectionName, false);
    return;
  }

  const shouldNotify = jobId
    ? shouldNotifyOwnedUiAction('subscription', jobId)
    : false;
  const failed = !response.success || response.data.success === false;
  const message = response.success
    ? response.data.message || _('Failed to update subscriptions')
    : response.error || _('Failed to update subscriptions');

  if (failed && isTransientRpcError(message)) {
    void refreshRuntimeUiState({ force: true });
    return;
  }

  if (jobId) {
    handledSubscriptionJobs.add(jobId);
  }

  setSubscriptionUpdating(sectionName, false);

  if (jobId && response.success) {
    void PodkopShellMethods.uiActionAck('subscription', jobId);
  }

  if (failed) {
    if (shouldNotify) {
      showToast(_('Failed to update subscriptions'), 'error');
    }
    return;
  }

  if (shouldNotify) {
    showToast(_('Subscription update completed'), 'success');
  }
  void fetchDashboardSections({ force: true });
  void fetchServicesInfo();
}

async function followSubscriptionUpdateState(
  state: Podkop.SubscriptionUpdateJobState,
) {
  const jobId = state.job_id;
  const sectionName = state.section || '';

  if (!jobId || !sectionName || followedSubscriptionJobs.has(jobId)) {
    return;
  }

  if (!state.running && handledSubscriptionJobs.has(jobId)) {
    return;
  }

  followedSubscriptionJobs.add(jobId);
  if (shouldShowLoadingForRestoredAction(state)) {
    setSubscriptionUpdating(sectionName, true);
  }

  try {
    const response = state.running
      ? await PodkopShellMethods.waitSubscriptionUpdateJob(jobId)
      : ({
          success: true,
          data: state,
        } as Podkop.MethodSuccessResponse<Podkop.SubscriptionUpdateJobState>);

    await completeSubscriptionUpdateJob(jobId, sectionName, response);
  } catch (error) {
    logger.error('[DASHBOARD]', 'followSubscriptionUpdateState failed', error);
    if (!pageUnloading) {
      const message =
        error instanceof Error
          ? error.message
          : _('Failed to update subscriptions');

      setSubscriptionUpdating(sectionName, false);
      if (!isTransientRpcError(message)) {
        showToast(_('Failed to update subscriptions'), 'error');
      }
    }
  } finally {
    followedSubscriptionJobs.delete(jobId);
  }
}

async function completeLatencyTestJob(jobId: string, sectionName: string) {
  setLatencyFetching(sectionName, false);

  if (pageUnloading) {
    return;
  }

  if (jobId && handledLatencyJobs.has(jobId)) {
    return;
  }

  if (jobId) {
    handledLatencyJobs.add(jobId);
  }

  if (jobId) {
    void PodkopShellMethods.uiActionAck('latency', jobId);
  }

  void fetchDashboardSections({ force: true });
}

async function followLatencyTestState(state: Podkop.LatencyActionState) {
  const jobId = state.job_id;
  const sectionName = state.section || '';

  if (!jobId || !sectionName || followedLatencyJobs.has(jobId)) {
    return;
  }

  if (!state.running && handledLatencyJobs.has(jobId)) {
    return;
  }

  followedLatencyJobs.add(jobId);
  if (shouldShowLoadingForRestoredAction(state)) {
    setLatencyFetching(sectionName, true);
  }

  try {
    if (state.running) {
      await PodkopShellMethods.waitLatencyTestJob(jobId);
    }

    await completeLatencyTestJob(jobId, sectionName);
  } catch (error) {
    logger.error('[DASHBOARD]', 'followLatencyTestState failed', error);
    if (!pageUnloading) {
      setLatencyFetching(sectionName, false);
    }
  } finally {
    followedLatencyJobs.delete(jobId);
  }
}

function followDashboardActionsFromUiState(uiState: Podkop.UiState) {
  for (const state of uiState.actions.subscription || []) {
    if (state.running || (state.job_id && state.section)) {
      void followSubscriptionUpdateState(state);
    } else if (state.job_id && !handledSubscriptionJobs.has(state.job_id)) {
      handledSubscriptionJobs.add(state.job_id);
      void PodkopShellMethods.uiActionAck('subscription', state.job_id);
    }
  }

  for (const state of uiState.actions.latency || []) {
    if (state.running || (state.job_id && state.section)) {
      void followLatencyTestState(state);
    } else if (state.job_id && !handledLatencyJobs.has(state.job_id)) {
      handledLatencyJobs.add(state.job_id);
      void PodkopShellMethods.uiActionAck('latency', state.job_id);
    }
  }
}

function startActionStateWatcher() {
  if (actionStateUnsubscribe) {
    return;
  }

  actionStateUnsubscribe = subscribeRuntimeUiState((uiState) => {
    if (dashboardMounted) {
      followDashboardActionsFromUiState(uiState);
    }
  });
}

function stopActionStateWatcher() {
  if (!actionStateUnsubscribe) {
    return;
  }

  actionStateUnsubscribe();
  actionStateUnsubscribe = null;
}

async function connectToClashSockets() {
  const clashApiSecret = await getClashApiSecret();

  socket.subscribe(
    `${getClashWsUrl()}/traffic?token=${clashApiSecret}`,
    (msg) => {
      const parsedMsg = JSON.parse(msg);

      store.set({
        bandwidthWidget: {
          loading: false,
          failed: false,
          data: { up: parsedMsg.up, down: parsedMsg.down },
        },
      });
    },
    (_err) => {
      logger.error(
        '[DASHBOARD]',
        'connectToClashSockets - traffic: failed to connect to',
        getClashWsUrl(),
      );
      store.set({
        bandwidthWidget: {
          loading: false,
          failed: true,
          data: { up: 0, down: 0 },
        },
      });
    },
  );

  socket.subscribe(
    `${getClashWsUrl()}/connections?token=${clashApiSecret}`,
    (msg) => {
      const parsedMsg = JSON.parse(msg);

      store.set({
        trafficTotalWidget: {
          loading: false,
          failed: false,
          data: {
            downloadTotal: parsedMsg.downloadTotal,
            uploadTotal: parsedMsg.uploadTotal,
          },
        },
        systemInfoWidget: {
          loading: false,
          failed: false,
          data: {
            connections: parsedMsg.connections?.length,
            memory: parsedMsg.memory,
          },
        },
      });
    },
    (_err) => {
      logger.error(
        '[DASHBOARD]',
        'connectToClashSockets - connections: failed to connect to',
        getClashWsUrl(),
      );
      store.set({
        trafficTotalWidget: {
          loading: false,
          failed: true,
          data: { downloadTotal: 0, uploadTotal: 0 },
        },
        systemInfoWidget: {
          loading: false,
          failed: true,
          data: {
            connections: 0,
            memory: 0,
          },
        },
      });
    },
  );
}

// Handlers

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
    sectionsWidget.selectorSwitchingSections[sectionName] ||
    section.outbounds.some(
      (outbound) => outbound.code === tag && outbound.selected,
    )
  ) {
    return;
  }

  setSelectorSwitching(sectionName, tag);

  try {
    await PodkopShellMethods.setClashApiGroupProxy(selector, tag);
    await fetchDashboardSections({ force: true });
  } finally {
    setSelectorSwitching(sectionName);
  }
}

async function handleTestLatency(
  latencyType: Podkop.LatencyActionState['latency_type'],
  sectionName: string,
  tag: string,
  timeout?: string,
) {
  if (store.get().sectionsWidget.latencyFetchingSections[sectionName]) {
    return;
  }

  setLatencyFetching(sectionName, true, true);
  let jobId = '';
  let ownsJobFollow = false;
  let completed = false;

  try {
    const startResponse = await PodkopShellMethods.latencyTestStart(
      latencyType,
      sectionName,
      tag,
      timeout,
    );

    if (!startResponse.success) {
      throw new Error(startResponse.error);
    }

    jobId = startResponse.data.job_id;
    if (followedLatencyJobs.has(jobId)) {
      completed = true;
      return;
    }

    followedLatencyJobs.add(jobId);
    ownsJobFollow = true;
    await PodkopShellMethods.waitLatencyTestJob(jobId);
    await completeLatencyTestJob(jobId, sectionName);
    completed = true;
  } catch (error) {
    logger.error('[DASHBOARD]', 'handleTestLatency: failed', error);
  } finally {
    if (ownsJobFollow) {
      followedLatencyJobs.delete(jobId);
    }

    if (!completed) {
      setLatencyFetching(sectionName, false);
    }
  }
}

async function handleCopyOutbound(
  section: Podkop.OutboundGroup,
  outbound: Podkop.Outbound,
) {
  const link = outbound.link;

  if (link && isCopyableProxyLink(link)) {
    copyToClipboard(link);
    return;
  }

  const response = await PodkopShellMethods.getOutboundLink(
    section.sectionName,
    outbound.code,
  );

  if (response.success && isCopyableProxyLink(response.data.link)) {
    copyToClipboard(response.data.link);
    return;
  }

  showToast(_('Proxy link is unavailable'), 'error');
}

function formatUrlTestModalValue(value: unknown) {
  if (typeof value === 'boolean') {
    return value ? _('Yes') : _('No');
  }

  const text = `${value ?? ''}`.trim();
  return text || _('N/A');
}

function renderUrlTestCopyButton(
  title: string,
  onClick: (event: MouseEvent) => void,
) {
  return E(
    'button',
    {
      type: 'button',
      class: 'btn pdk_dashboard-page__outbound-grid__item__copy-button',
      title,
      'aria-label': title,
      click: onClick,
    },
    renderCopyIcon24(),
  );
}

function renderUrlTestInfoModal(
  section: Podkop.OutboundGroup,
  outbound: Podkop.Outbound,
) {
  const info = outbound.urlTestInfo;

  if (!info) {
    return E('div', {}, _('URLTest details are unavailable'));
  }

  const fields: Array<[string, unknown, string?]> = [
    [_('Selected'), info.selectedName || info.selectedCode],
    [_('Testing URL'), info.url, info.url],
    [_('Interval'), info.interval],
    [_('Tolerance'), info.tolerance],
    [_('Idle timeout'), info.idleTimeout],
    [_('Interrupt existing connections'), info.interruptExistConnections],
  ];

  return E('div', { class: 'pdk_dashboard-page__urltest-details' }, [
    E(
      'dl',
      { class: 'pdk_dashboard-page__urltest-details__params' },
      fields.map(([label, value, copyValue]) =>
        E('div', { class: 'pdk_dashboard-page__urltest-details__param' }, [
          E('dt', {}, label),
          E('dd', {}, [
            E('span', {}, formatUrlTestModalValue(value)),
            ...(copyValue
              ? [
                  renderUrlTestCopyButton(_('Copy URL'), (event) => {
                    event.preventDefault();
                    copyToClipboard(copyValue);
                  }),
                ]
              : []),
          ]),
        ]),
      ),
    ),
    E('div', { class: 'pdk_dashboard-page__urltest-details__outbounds' }, [
      E(
        'div',
        { class: 'pdk_dashboard-page__urltest-details__outbounds-title' },
        _('Outbounds'),
      ),
      E(
        'div',
        { class: 'pdk_dashboard-page__urltest-details__table' },
        info.outbounds.length
          ? info.outbounds.map((member) =>
              E(
                'div',
                {
                  class: [
                    'pdk_dashboard-page__urltest-details__row',
                    member.selected
                      ? 'pdk_dashboard-page__urltest-details__row--active'
                      : '',
                  ]
                    .filter(Boolean)
                    .join(' '),
                },
                [
                  E(
                    'div',
                    {
                      class: 'pdk_dashboard-page__urltest-details__row-name',
                    },
                    [
                      E('b', {}, member.displayName),
                      member.selected ? E('span', {}, _('Selected')) : '',
                    ],
                  ),
                  E(
                    'div',
                    {
                      class: 'pdk_dashboard-page__urltest-details__row-meta',
                    },
                    [
                      E('span', {}, member.type || _('N/A')),
                      E(
                        'span',
                        {},
                        member.latency ? `${member.latency}ms` : 'N/A',
                      ),
                    ],
                  ),
                  ...(member.canCopyLink
                    ? [
                        renderUrlTestCopyButton(
                          _('Copy proxy link'),
                          (event) => {
                            event.preventDefault();
                            void handleCopyOutbound(section, member);
                          },
                        ),
                      ]
                    : []),
                ],
              ),
            )
          : [E('div', {}, _('No outbounds'))],
      ),
    ]),
  ]);
}

function handleShowUrlTestInfo(
  section: Podkop.OutboundGroup,
  outbound: Podkop.Outbound,
) {
  if (!outbound.urlTestInfo) {
    return;
  }

  ui.showModal(_('URLTest details'), renderUrlTestInfoModal(section, outbound));
}

async function handleUpdateSubscription(section: Podkop.OutboundGroup) {
  if (
    store.get().sectionsWidget.subscriptionUpdatingSections[section.sectionName]
  ) {
    return;
  }

  setSubscriptionUpdating(section.sectionName, true, true);
  let jobId = '';
  let ownsJobFollow = false;

  try {
    const startResponse = await PodkopShellMethods.subscriptionUpdateStart(
      section.sectionName,
    );

    if (!startResponse.success) {
      throw new Error(startResponse.error);
    }

    jobId = startResponse.data.job_id;
    markUiActionOwned('subscription', jobId);
    if (followedSubscriptionJobs.has(jobId)) {
      return;
    }

    followedSubscriptionJobs.add(jobId);
    ownsJobFollow = true;
    const response = await PodkopShellMethods.waitSubscriptionUpdateJob(jobId);
    await completeSubscriptionUpdateJob(jobId, section.sectionName, response);
  } catch (error) {
    logger.error('[DASHBOARD]', 'handleUpdateSubscription: failed', error);
    if (!pageUnloading) {
      const message =
        error instanceof Error
          ? error.message
          : _('Failed to update subscriptions');

      setSubscriptionUpdating(section.sectionName, false);
      if (!isTransientRpcError(message)) {
        showToast(_('Failed to update subscriptions'), 'error');
      }
    }
  } finally {
    if (ownsJobFollow) {
      followedSubscriptionJobs.delete(jobId);
    }
  }
}

// Renderer

async function renderSectionsWidget() {
  logger.debug('[DASHBOARD]', 'renderSectionsWidget');
  const sectionsWidget = store.get().sectionsWidget;
  const container = document.getElementById('dashboard-sections-grid');

  if (!container) {
    return;
  }

  if (sectionsWidget.loading || sectionsWidget.failed) {
    const renderedWidget = renderSections({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
      section: {
        code: '',
        sectionName: '',
        displayName: '',
        outbounds: [],
        withTagSelect: false,
      },
      onTestLatency: () => {},
      onChooseOutbound: () => {},
      onCopyOutbound: () => {},
      onShowUrlTestInfo: () => {},
      onUpdateSubscription: () => {},
      latencyFetching: false,
      subscriptionUpdating: false,
      selectorSwitchingTag: undefined,
    });

    return preserveScrollForPage(() => {
      container.replaceChildren(renderedWidget);
    });
  }

  const renderedWidgets = sectionsWidget.data.map((section) =>
    renderSections({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
      section,
      latencyFetching: Boolean(
        sectionsWidget.latencyFetchingSections[section.sectionName],
      ),
      subscriptionUpdating: Boolean(
        sectionsWidget.subscriptionUpdatingSections[section.sectionName],
      ),
      selectorSwitchingTag:
        sectionsWidget.selectorSwitchingSections[section.sectionName],
      onTestLatency: (tag) => {
        if (section.withTagSelect) {
          if (Array.isArray(tag)) {
            return handleTestLatency(
              'proxy_list',
              section.sectionName,
              JSON.stringify(tag),
            );
          }

          return handleTestLatency('group', section.sectionName, tag);
        }

        return handleTestLatency(
          'proxy',
          section.sectionName,
          Array.isArray(tag) ? JSON.stringify(tag) : tag,
          section.latencyTestTimeout,
        );
      },
      onChooseOutbound: (sectionName, selector, tag) => {
        void handleChooseOutbound(sectionName, selector, tag);
      },
      onCopyOutbound: (section, outbound) => {
        void handleCopyOutbound(section, outbound);
      },
      onShowUrlTestInfo: (section, outbound) => {
        handleShowUrlTestInfo(section, outbound);
      },
      onUpdateSubscription: (section) => {
        void handleUpdateSubscription(section);
      },
    }),
  );

  return preserveScrollForPage(() => {
    container.replaceChildren(...renderedWidgets);
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

async function renderSystemInfoWidget() {
  logger.debug('[DASHBOARD]', 'renderSystemInfoWidget');
  const systemInfoWidget = store.get().systemInfoWidget;

  const container = document.getElementById('dashboard-widget-system-info');

  if (!container) {
    return;
  }

  if (systemInfoWidget.loading || systemInfoWidget.failed) {
    const renderedWidget = renderWidget({
      loading: systemInfoWidget.loading,
      failed: systemInfoWidget.failed,
      title: '',
      items: [],
    });

    return container.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: systemInfoWidget.loading,
    failed: systemInfoWidget.failed,
    title: _('System info'),
    items: [
      {
        key: _('Active Connections'),
        value: String(systemInfoWidget.data.connections),
      },
      {
        key: _('Memory Usage'),
        value: String(prettyBytes(systemInfoWidget.data.memory)),
      },
    ],
  });

  container.replaceChildren(renderedWidget);
}

async function renderServicesInfoWidget() {
  logger.debug('[DASHBOARD]', 'renderServicesInfoWidget');
  const servicesInfoWidget = store.get().servicesInfoWidget;

  const container = document.getElementById('dashboard-widget-service-info');

  if (!container) {
    return;
  }

  if (servicesInfoWidget.loading || servicesInfoWidget.failed) {
    const renderedWidget = renderWidget({
      loading: servicesInfoWidget.loading,
      failed: servicesInfoWidget.failed,
      title: '',
      items: [],
    });

    return container.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: servicesInfoWidget.loading,
    failed: servicesInfoWidget.failed,
    title: _('Services info'),
    items: [
      {
        key: 'Podkop Plus',
        value: servicesInfoWidget.data.podkopRunning
          ? _('✔ Running')
          : _('✘ Stopped'),
        attributes: {
          class: servicesInfoWidget.data.podkopRunning
            ? 'pdk_dashboard-page__widgets-section__item__row--success'
            : 'pdk_dashboard-page__widgets-section__item__row--error',
        },
      },
      {
        key: 'Sing-box',
        value: servicesInfoWidget.data.singbox
          ? _('✔ Running')
          : _('✘ Stopped'),
        attributes: {
          class: servicesInfoWidget.data.singbox
            ? 'pdk_dashboard-page__widgets-section__item__row--success'
            : 'pdk_dashboard-page__widgets-section__item__row--error',
        },
      },
    ],
  });

  container.replaceChildren(renderedWidget);
}

async function onStoreUpdate(
  _next: StoreType,
  _prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.sectionsWidget) {
    renderSectionsWidget();
  }

  if (diff.bandwidthWidget) {
    renderBandwidthWidget();
  }

  if (diff.trafficTotalWidget) {
    renderTrafficTotalWidget();
  }

  if (diff.systemInfoWidget) {
    renderSystemInfoWidget();
  }

  if (diff.servicesInfoWidget) {
    renderServicesInfoWidget();
  }
}

async function onPageMount() {
  // Cleanup before mount
  onPageUnmount();

  dashboardMounted = true;
  dashboardMountId += 1;
  const mountId = dashboardMountId;
  const hasRuntimeSnapshot = Boolean(getCachedRuntimeUiState());

  if (!hasRuntimeSnapshot) {
    const uiState = await refreshRuntimeUiState({ force: true });

    if (!dashboardMounted || mountId !== dashboardMountId) {
      return;
    }

    if (!uiState) {
      void fetchServicesInfo();
    }
  }

  // Add new listener
  store.subscribe(onStoreUpdate);
  startActionStateWatcher();
  void renderSectionsWidget();
  void renderBandwidthWidget();
  void renderTrafficTotalWidget();
  void renderSystemInfoWidget();
  void renderServicesInfoWidget();

  void fetchDashboardSections({ force: true });
  if (hasRuntimeSnapshot) {
    void refreshRuntimeUiState({ force: true });
  }
  void connectToClashSockets();

  sectionsRefreshTimer = setInterval(() => {
    void fetchDashboardSections();
  }, SECTIONS_REFRESH_INTERVAL_MS);
}

function onPageUnmount() {
  dashboardMounted = false;
  dashboardMountId += 1;

  if (sectionsRefreshTimer) {
    clearInterval(sectionsRefreshTimer);
    sectionsRefreshTimer = null;
  }
  stopActionStateWatcher();
  sectionsRefreshQueued = false;
  sectionsRefreshPromise = null;
  // Remove old listener
  store.unsubscribe(onStoreUpdate);
  // Clear store
  store.reset(['bandwidthWidget', 'trafficTotalWidget', 'systemInfoWidget']);
  socket.resetAll();
}

let dashboardLifecycleRegistered = false;
let dashboardControllerInitialized = false;

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
      const isDashboardVisible = next.tabService.current === 'dashboard';

      if (isDashboardVisible) {
        logger.debug(
          '[DASHBOARD]',
          'registerLifecycleListeners',
          'onPageMount',
        );
        return onPageMount();
      }

      if (!isDashboardVisible) {
        logger.debug(
          '[DASHBOARD]',
          'registerLifecycleListeners',
          'onPageUnmount',
        );
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (dashboardControllerInitialized) {
    return;
  }

  dashboardControllerInitialized = true;

  onMount('dashboard-status').then(() => {
    logger.debug('[DASHBOARD]', 'initController', 'onMount');
    registerLifecycleListeners();
    if (
      store.get().tabService.current === 'dashboard' ||
      isActiveLuciTab('dashboard')
    ) {
      onPageMount();
    }
  });
}
