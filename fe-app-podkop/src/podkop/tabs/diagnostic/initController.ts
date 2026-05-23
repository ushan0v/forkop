import { onMount, preserveScrollForPage } from '../../../helpers';
import { runDnsCheck } from './checks/runDnsCheck';
import { runSingBoxCheck } from './checks/runSingBoxCheck';
import { runNftCheck } from './checks/runNftCheck';
import { runFakeIPCheck } from './checks/runFakeIPCheck';
import { runZapretCheck } from './checks/runZapretCheck';
import { runByedpiCheck } from './checks/runByedpiCheck';
import {
  DiagnosticsProviderOptions,
  getDiagnosticsChecks,
  getLoadingDiagnosticsChecks,
} from './diagnostic.store';
import { logger, store, StoreType } from '../../services';
import {
  renderAvailableActions,
  renderCheckSection,
  renderRunAction,
  renderSystemInfo,
} from './partials';
import { PodkopShellMethods } from '../../methods';
import { fetchServicesInfo } from '../../fetchers';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';
import { renderModal } from '../../../partials';
import { PODKOP_LUCI_APP_VERSION } from '../../../constants';
import { showToast } from '../../../helpers/showToast';
import { renderWikiDisclaimer } from './partials/renderWikiDisclaimer';
import { runSectionsCheck } from './checks/runSectionsCheck';
import { getPodkopVersionRow } from './helpers/getPodkopVersionRow';

const UNKNOWN_DIAGNOSTICS_SYSTEM_INFO = {
  podkop_version: _('unknown'),
  podkop_latest_version: _('unknown'),
  luci_app_version: _('unknown'),
  sing_box_version: _('unknown'),
  providerInfoLoaded: false,
  zapret_version: _('unknown'),
  zapret_installed: 0,
  byedpi_version: _('unknown'),
  byedpi_installed: 0,
  openwrt_version: _('unknown'),
  device_model: _('unknown'),
};

const SERVICE_STATUS_REFRESH_INTERVAL_MS = 2000;
const SERVICE_ACTION_STATUS_TIMEOUT_MS = 45000;

let latestProviderInfoRequestId = 0;
let latestSystemInfoRequestId = 0;
let diagnosticLifecycleRegistered = false;
let diagnosticControllerInitialized = false;
let diagnosticMounted = false;
let diagnosticMountId = 0;
let servicesInfoRefreshTimer: ReturnType<typeof setInterval> | null = null;
let servicesInfoRefreshPromise: Promise<void> | null = null;

type ServiceRuntimeAction = 'restart' | 'start' | 'stop';

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

function getDiagnosticsProviderOptions(
  systemInfo: Pick<
    StoreType['diagnosticsSystemInfo'],
    'zapret_installed' | 'byedpi_installed'
  > = store.get().diagnosticsSystemInfo,
): DiagnosticsProviderOptions {
  return {
    includeZapret: Boolean(systemInfo.zapret_installed),
    includeByedpi: Boolean(systemInfo.byedpi_installed),
  };
}

function getNotRunningDiagnosticsChecks() {
  return getDiagnosticsChecks(
    _('Not running'),
    getDiagnosticsProviderOptions(),
  );
}

function resetDiagnosticsChecks() {
  store.set({
    diagnosticsChecks: getNotRunningDiagnosticsChecks(),
  });
}

function setDiagnosticActionLoading(
  action: keyof StoreType['diagnosticsActions'],
  loading: boolean,
) {
  const diagnosticsActions = store.get().diagnosticsActions;

  store.set({
    diagnosticsActions: {
      ...diagnosticsActions,
      [action]: { loading },
    },
  });
}

function isDiagnosticMountActive(mountId = diagnosticMountId) {
  return diagnosticMounted && diagnosticMountId === mountId;
}

function isMutatingServiceActionLoading() {
  const actions = store.get().diagnosticsActions;

  return (
    actions.restart.loading ||
    actions.start.loading ||
    actions.stop.loading ||
    actions.enable.loading ||
    actions.disable.loading
  );
}

function getPodkopStatusText(running: boolean, enabled: boolean) {
  if (running) {
    return enabled ? 'running & enabled' : 'running but disabled';
  }

  return enabled ? 'stopped but enabled' : 'stopped & disabled';
}

function setDisplayedPodkopRunning(running: boolean) {
  const servicesInfoWidget = store.get().servicesInfoWidget;
  const enabled = Boolean(servicesInfoWidget.data.podkopEnabled);

  store.set({
    servicesInfoWidget: {
      ...servicesInfoWidget,
      loading: false,
      data: {
        ...servicesInfoWidget.data,
        podkopRunning: running ? 1 : 0,
        podkopStatus: getPodkopStatusText(running, enabled),
      },
    },
  });
}

async function refreshDiagnosticServicesInfo({
  force = false,
  mountId = diagnosticMountId,
}: {
  force?: boolean;
  mountId?: number;
} = {}) {
  if (!isDiagnosticMountActive(mountId)) {
    return;
  }

  if (!force && isMutatingServiceActionLoading()) {
    return;
  }

  if (servicesInfoRefreshPromise) {
    return servicesInfoRefreshPromise;
  }

  const promise = fetchServicesInfo()
    .catch((error) => {
      logger.error(
        '[DIAGNOSTIC]',
        'refreshDiagnosticServicesInfo failed',
        error,
      );
    })
    .finally(() => {
      if (servicesInfoRefreshPromise === promise) {
        servicesInfoRefreshPromise = null;
      }
    });

  servicesInfoRefreshPromise = promise;
  return promise;
}

async function waitForPodkopRunningState(
  expectedRunning: boolean,
  mountId: number,
) {
  const startedAt = Date.now();

  while (isDiagnosticMountActive(mountId)) {
    await refreshDiagnosticServicesInfo({ force: true, mountId });

    const podkopRunning = Boolean(
      store.get().servicesInfoWidget.data.podkopRunning,
    );

    if (podkopRunning === expectedRunning) {
      return true;
    }

    if (Date.now() - startedAt >= SERVICE_ACTION_STATUS_TIMEOUT_MS) {
      return false;
    }

    await sleep(SERVICE_STATUS_REFRESH_INTERVAL_MS);
  }

  return false;
}

function startServicesInfoRefreshTimer() {
  if (servicesInfoRefreshTimer) {
    clearInterval(servicesInfoRefreshTimer);
  }

  servicesInfoRefreshTimer = setInterval(() => {
    void refreshDiagnosticServicesInfo();
  }, SERVICE_STATUS_REFRESH_INTERVAL_MS);
}

function stopServicesInfoRefreshTimer() {
  if (!servicesInfoRefreshTimer) {
    return;
  }

  clearInterval(servicesInfoRefreshTimer);
  servicesInfoRefreshTimer = null;
}

async function fetchSystemInfo() {
  const requestId = ++latestSystemInfoRequestId;
  const currentSystemInfo = store.get().diagnosticsSystemInfo;

  store.set({
    diagnosticsSystemInfo: {
      ...currentSystemInfo,
      loading: true,
    },
  });

  try {
    const systemInfo = await PodkopShellMethods.getSystemInfo();

    if (requestId !== latestSystemInfoRequestId) {
      return;
    }

    if (systemInfo.success) {
      const nextSystemInfo = {
        loading: false,
        providerInfoLoaded: true,
        ...systemInfo.data,
      };

      store.set({
        diagnosticsSystemInfo: nextSystemInfo,
        diagnosticsChecks: getDiagnosticsChecks(
          _('Not running'),
          getDiagnosticsProviderOptions(nextSystemInfo),
        ),
      });
      return;
    }
  } catch (error) {
    logger.error('[DIAGNOSTIC]', 'fetchSystemInfo failed', error);
  }

  if (requestId === latestSystemInfoRequestId) {
    const currentSystemInfo = store.get().diagnosticsSystemInfo;
    store.set({
      diagnosticsSystemInfo: {
        ...UNKNOWN_DIAGNOSTICS_SYSTEM_INFO,
        loading: false,
        providerInfoLoaded: currentSystemInfo.providerInfoLoaded,
        zapret_installed: currentSystemInfo.zapret_installed,
        byedpi_installed: currentSystemInfo.byedpi_installed,
      },
    });
  }
}

async function fetchDiagnosticsProviderInfo() {
  const requestId = ++latestProviderInfoRequestId;

  try {
    const [zapretRuntime, byedpiRuntime] = await Promise.all([
      PodkopShellMethods.checkZapretRuntime(),
      PodkopShellMethods.checkByedpiRuntime(),
    ]);

    if (requestId !== latestProviderInfoRequestId) {
      return;
    }

    const currentSystemInfo = store.get().diagnosticsSystemInfo;
    const nextSystemInfo = {
      ...currentSystemInfo,
      providerInfoLoaded: true,
      zapret_installed: zapretRuntime.success
        ? zapretRuntime.data.zapret_installed
        : currentSystemInfo.zapret_installed,
      byedpi_installed: byedpiRuntime.success
        ? byedpiRuntime.data.byedpi_installed
        : currentSystemInfo.byedpi_installed,
    };

    if (!zapretRuntime.success) {
      logger.error('[DIAGNOSTIC]', 'fetchZapretRuntime failed', zapretRuntime);
    }

    if (!byedpiRuntime.success) {
      logger.error('[DIAGNOSTIC]', 'fetchByedpiRuntime failed', byedpiRuntime);
    }

    if (!nextSystemInfo.zapret_installed) {
      nextSystemInfo.zapret_version = 'not installed';
    }

    if (!nextSystemInfo.byedpi_installed) {
      nextSystemInfo.byedpi_version = 'not installed';
    }

    store.set({
      diagnosticsSystemInfo: nextSystemInfo,
      diagnosticsChecks: getDiagnosticsChecks(
        _('Not running'),
        getDiagnosticsProviderOptions(nextSystemInfo),
      ),
    });
  } catch (error) {
    logger.error('[DIAGNOSTIC]', 'fetchDiagnosticsProviderInfo failed', error);

    if (requestId === latestProviderInfoRequestId) {
      const currentSystemInfo = store.get().diagnosticsSystemInfo;

      store.set({
        diagnosticsSystemInfo: {
          ...currentSystemInfo,
          providerInfoLoaded: true,
        },
      });
    }
  }
}

async function ensureDiagnosticsProviderInfo() {
  if (store.get().diagnosticsSystemInfo.providerInfoLoaded) {
    return;
  }

  await fetchDiagnosticsProviderInfo();
}

function renderDiagnosticsChecks() {
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticsChecks');
  const diagnosticsChecks = [...store.get().diagnosticsChecks].sort(
    (a, b) => a.order - b.order,
  );
  const container = document.getElementById('pdk_diagnostic-page-checks');

  const renderedDiagnosticsChecks = diagnosticsChecks.map((check) =>
    renderCheckSection(check),
  );

  return preserveScrollForPage(() => {
    container!.replaceChildren(...renderedDiagnosticsChecks);
  });
}

function renderDiagnosticRunActionWidget() {
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticRunActionWidget');

  const { loading } = store.get().diagnosticsRunAction;
  const providerInfoLoaded =
    store.get().diagnosticsSystemInfo.providerInfoLoaded;
  const container = document.getElementById('pdk_diagnostic-page-run-check');

  const renderedAction = renderRunAction({
    loading,
    disabled: !providerInfoLoaded,
    click: () => runChecks(),
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedAction);
  });
}

async function handleServiceRuntimeAction({
  action,
  command,
  expectedRunning,
  optimisticRunning,
}: {
  action: ServiceRuntimeAction;
  command: () => Promise<unknown>;
  expectedRunning: boolean;
  optimisticRunning?: boolean;
}) {
  const mountId = diagnosticMountId;

  setDiagnosticActionLoading(action, true);

  if (optimisticRunning !== undefined) {
    setDisplayedPodkopRunning(optimisticRunning);
  }

  try {
    await command();

    const reachedExpectedState = await waitForPodkopRunningState(
      expectedRunning,
      mountId,
    );

    if (!reachedExpectedState && isDiagnosticMountActive(mountId)) {
      logger.error(
        '[DIAGNOSTIC]',
        `${action} did not reach expected running state`,
      );
      showToast(_('Failed to execute!'), 'error');
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', `handleServiceRuntimeAction(${action})`, e);
  } finally {
    if (isDiagnosticMountActive(mountId)) {
      setDiagnosticActionLoading(action, false);
      resetDiagnosticsChecks();
    }
  }
}

async function handleRestart() {
  await handleServiceRuntimeAction({
    action: 'restart',
    command: PodkopShellMethods.restart,
    expectedRunning: true,
    optimisticRunning: false,
  });
}

async function handleStart() {
  await handleServiceRuntimeAction({
    action: 'start',
    command: PodkopShellMethods.start,
    expectedRunning: true,
  });
}

async function handleStop() {
  await handleServiceRuntimeAction({
    action: 'stop',
    command: PodkopShellMethods.stop,
    expectedRunning: false,
  });
}

async function handleEnable() {
  const mountId = diagnosticMountId;

  setDiagnosticActionLoading('enable', true);

  try {
    await PodkopShellMethods.enable();
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleEnable - e', e);
  } finally {
    await refreshDiagnosticServicesInfo({ force: true, mountId });

    if (isDiagnosticMountActive(mountId)) {
      setDiagnosticActionLoading('enable', false);
    }
  }
}

async function handleDisable() {
  const mountId = diagnosticMountId;

  setDiagnosticActionLoading('disable', true);

  try {
    await PodkopShellMethods.disable();
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleDisable - e', e);
  } finally {
    await refreshDiagnosticServicesInfo({ force: true, mountId });

    if (isDiagnosticMountActive(mountId)) {
      setDiagnosticActionLoading('disable', false);
    }
  }
}

async function handleShowGlobalCheck() {
  setDiagnosticActionLoading('globalCheck', true);

  try {
    const globalCheck = await PodkopShellMethods.globalCheck();

    if (globalCheck.success) {
      ui.showModal(
        _('Global check'),
        renderModal(globalCheck.data as string, 'global_check'),
      );
    } else {
      logger.error('[DIAGNOSTIC]', 'handleShowGlobalCheck - e', globalCheck);
      showToast(_('Failed to execute!'), 'error');
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleShowGlobalCheck - e', e);
    showToast(_('Failed to execute!'), 'error');
  } finally {
    setDiagnosticActionLoading('globalCheck', false);
  }
}

async function handleViewLogs() {
  setDiagnosticActionLoading('viewLogs', true);

  try {
    const viewLogs = await PodkopShellMethods.checkLogs();

    if (viewLogs.success) {
      const getLatestLogs = async () => {
        const latestLogs = await PodkopShellMethods.checkLogs();

        if (!latestLogs.success) {
          throw latestLogs;
        }

        return (latestLogs.data as string) ?? '';
      };

      ui.showModal(
        _('View logs'),
        renderModal(viewLogs.data as string, 'view_logs', {
          getText: getLatestLogs,
          refreshMs: 250,
          initialAutoRefresh: true,
          showAutoRefreshToggle: true,
          startAtEnd: true,
        }),
      );
    } else {
      logger.error('[DIAGNOSTIC]', 'handleViewLogs - e', viewLogs);
      showToast(_('Failed to execute!'), 'error');
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleViewLogs - e', e);
    showToast(_('Failed to execute!'), 'error');
  } finally {
    setDiagnosticActionLoading('viewLogs', false);
  }
}

async function handleShowSingBoxConfig() {
  setDiagnosticActionLoading('showSingBoxConfig', true);

  try {
    const showSingBoxConfig = await PodkopShellMethods.showSingBoxConfig();

    if (showSingBoxConfig.success) {
      ui.showModal(
        _('Show sing-box config'),
        renderModal(
          JSON.stringify(showSingBoxConfig.data, null, 2),
          'show_sing_box_config',
        ),
      );
    } else {
      logger.error(
        '[DIAGNOSTIC]',
        'handleShowSingBoxConfig - e',
        showSingBoxConfig,
      );
      showToast(_('Failed to execute!'), 'error');
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleShowSingBoxConfig - e', e);
    showToast(_('Failed to execute!'), 'error');
  } finally {
    setDiagnosticActionLoading('showSingBoxConfig', false);
  }
}

function renderWikiDisclaimerWidget() {
  const diagnosticsChecks = store.get().diagnosticsChecks;

  function getWikiKind() {
    const allResults = diagnosticsChecks.map((check) => check.state);

    if (allResults.includes('error')) {
      return 'error';
    }

    if (allResults.includes('warning')) {
      return 'warning';
    }

    return 'default';
  }

  const container = document.getElementById('pdk_diagnostic-page-wiki');

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderWikiDisclaimer(getWikiKind()));
  });
}

function renderDiagnosticAvailableActionsWidget() {
  const diagnosticsActions = store.get().diagnosticsActions;
  const servicesInfoWidget = store.get().servicesInfoWidget;
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticAvailableActionsWidget');

  const podkopEnabled = Boolean(servicesInfoWidget.data.podkopEnabled);
  const podkopRunning = Boolean(servicesInfoWidget.data.podkopRunning);
  const restartLoading = diagnosticsActions.restart.loading;
  const atLeastOneMutatingActionLoading =
    restartLoading ||
    diagnosticsActions.start.loading ||
    diagnosticsActions.stop.loading ||
    diagnosticsActions.enable.loading ||
    diagnosticsActions.disable.loading;
  const serviceControlsDisabled =
    servicesInfoWidget.loading || atLeastOneMutatingActionLoading;
  const utilityActionsDisabled = atLeastOneMutatingActionLoading;

  const container = document.getElementById('pdk_diagnostic-page-actions');

  const renderedActions = renderAvailableActions({
    restart: {
      loading: restartLoading,
      visible: true,
      onClick: handleRestart,
      disabled: serviceControlsDisabled,
    },
    start: {
      loading: diagnosticsActions.start.loading,
      visible: !podkopRunning,
      onClick: handleStart,
      disabled: serviceControlsDisabled,
    },
    stop: {
      loading: diagnosticsActions.stop.loading,
      visible: podkopRunning,
      onClick: handleStop,
      disabled: serviceControlsDisabled,
    },
    enable: {
      loading: diagnosticsActions.enable.loading,
      visible: !podkopEnabled,
      onClick: handleEnable,
      disabled: serviceControlsDisabled,
    },
    disable: {
      loading: diagnosticsActions.disable.loading,
      visible: podkopEnabled,
      onClick: handleDisable,
      disabled: serviceControlsDisabled,
    },
    globalCheck: {
      loading: diagnosticsActions.globalCheck.loading,
      visible: true,
      onClick: handleShowGlobalCheck,
      disabled: utilityActionsDisabled,
    },
    viewLogs: {
      loading: diagnosticsActions.viewLogs.loading,
      visible: true,
      onClick: handleViewLogs,
      disabled: false,
    },
    showSingBoxConfig: {
      loading: diagnosticsActions.showSingBoxConfig.loading,
      visible: true,
      onClick: handleShowSingBoxConfig,
      disabled: utilityActionsDisabled,
    },
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedActions);
  });
}

function renderDiagnosticSystemInfoWidget() {
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticSystemInfoWidget');
  const diagnosticsSystemInfo = store.get().diagnosticsSystemInfo;

  const container = document.getElementById('pdk_diagnostic-page-system-info');

  const items = [
    getPodkopVersionRow(diagnosticsSystemInfo),
    {
      key: 'Luci App',
      value: normalizeCompiledVersion(PODKOP_LUCI_APP_VERSION),
    },
    {
      key: 'Sing-box',
      value: diagnosticsSystemInfo.sing_box_version,
    },
  ];

  if (diagnosticsSystemInfo.zapret_installed) {
    items.push({
      key: 'Zapret',
      value: diagnosticsSystemInfo.zapret_version,
    });
  }

  if (diagnosticsSystemInfo.byedpi_installed) {
    items.push({
      key: 'ByeDPI',
      value: diagnosticsSystemInfo.byedpi_version,
    });
  }

  items.push(
    {
      key: 'OS',
      value: diagnosticsSystemInfo.openwrt_version,
    },
    {
      key: 'Device',
      value: diagnosticsSystemInfo.device_model,
    },
  );

  const renderedSystemInfo = renderSystemInfo({
    items,
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedSystemInfo);
  });
}

async function onStoreUpdate(
  next: StoreType,
  prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.diagnosticsChecks) {
    renderDiagnosticsChecks();
    renderWikiDisclaimerWidget();
  }

  if (diff.diagnosticsRunAction) {
    renderDiagnosticRunActionWidget();
  }

  if (diff.diagnosticsActions || diff.servicesInfoWidget) {
    renderDiagnosticAvailableActionsWidget();
  }

  if (diff.diagnosticsSystemInfo) {
    renderDiagnosticSystemInfoWidget();
    renderDiagnosticRunActionWidget();
  }
}

async function runChecks() {
  try {
    await ensureDiagnosticsProviderInfo();

    const providerOptions = getDiagnosticsProviderOptions();
    const runners = [
      runDnsCheck,
      runSingBoxCheck,
      runNftCheck,
      ...(providerOptions.includeZapret ? [runZapretCheck] : []),
      ...(providerOptions.includeByedpi ? [runByedpiCheck] : []),
      runSectionsCheck,
      runFakeIPCheck,
    ];

    store.set({
      diagnosticsRunAction: { loading: true },
      diagnosticsChecks:
        getLoadingDiagnosticsChecks(providerOptions).diagnosticsChecks,
    });

    for (const runner of runners) {
      try {
        await runner();
      } catch (e) {
        logger.error('[DIAGNOSTIC]', `runChecks - ${runner.name} failed`, e);
      }
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'runChecks - e', e);
  } finally {
    store.set({ diagnosticsRunAction: { loading: false } });
  }
}

async function loadInitialDiagnosticData() {
  const diagnosticStatus = document.getElementById('diagnostic-status');

  if (diagnosticStatus?.isConnected && diagnosticStatus.offsetParent !== null) {
    void fetchSystemInfo();
    await ensureDiagnosticsProviderInfo();
  }
}

function onPageMount() {
  // Cleanup before mount
  onPageUnmount();

  diagnosticMounted = true;
  diagnosticMountId += 1;

  // Add new listener
  store.subscribe(onStoreUpdate);

  // Initial checks render
  renderDiagnosticsChecks();

  // Initial run checks action render
  renderDiagnosticRunActionWidget();

  // Initial available actions render
  renderDiagnosticAvailableActionsWidget();

  // Initial system info render
  renderDiagnosticSystemInfoWidget();

  // Initial Wiki disclaimer render
  renderWikiDisclaimerWidget();

  void refreshDiagnosticServicesInfo({ force: true });
  startServicesInfoRefreshTimer();
  void loadInitialDiagnosticData();
}

function onPageUnmount() {
  diagnosticMounted = false;
  diagnosticMountId += 1;
  stopServicesInfoRefreshTimer();
  servicesInfoRefreshPromise = null;

  // Remove old listener
  store.unsubscribe(onStoreUpdate);

  // Clear store
  store.reset(['diagnosticsActions', 'diagnosticsRunAction']);
  resetDiagnosticsChecks();
}

function registerLifecycleListeners() {
  if (diagnosticLifecycleRegistered) {
    return;
  }

  diagnosticLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      logger.debug(
        '[DIAGNOSTIC]',
        'active tab diff event, active tab:',
        diff.tabService.current,
      );
      const isDIAGNOSTICVisible = next.tabService.current === 'diagnostic';

      if (isDIAGNOSTICVisible) {
        logger.debug(
          '[DIAGNOSTIC]',
          'registerLifecycleListeners',
          'onPageMount',
        );
        return onPageMount();
      }

      if (!isDIAGNOSTICVisible) {
        logger.debug(
          '[DIAGNOSTIC]',
          'registerLifecycleListeners',
          'onPageUnmount',
        );
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (diagnosticControllerInitialized) {
    return;
  }

  diagnosticControllerInitialized = true;

  onMount('diagnostic-status').then(() => {
    logger.debug('[DIAGNOSTIC]', 'initController', 'onMount');
    onPageMount();
    registerLifecycleListeners();
  });
}
