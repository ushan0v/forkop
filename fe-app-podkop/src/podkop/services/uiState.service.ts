import { getComponentActionKey } from '../helpers/getComponentActionKey';
import { normalizeSingBoxVariantFields } from '../helpers/singBoxVariant';
import type { Podkop } from '../types';
import { getLocalActionOverlay } from './localActionOverlay.service';
import { store } from './store.service';
import type { StoreType } from './store.service';

type UiActionMap = Partial<Podkop.UiState['actions']>;

function isRunningAction(state: { running?: boolean }) {
  return state.running === true;
}

function getEmptyUpdatesActions(): StoreType['updatesActions'] {
  return {
    podkopCheck: { loading: false },
    podkopInstall: { loading: false },
    singBoxCheck: { loading: false },
    singBoxInstall: { loading: false },
    singBoxInstallExtended: { loading: false },
    singBoxInstallExtendedCompressed: { loading: false },
    singBoxInstallTiny: { loading: false },
    singBoxInstallStable: { loading: false },
    zapretCheck: { loading: false },
    zapretInstall: { loading: false },
    zapretRemove: { loading: false },
    zapret2Check: { loading: false },
    zapret2Install: { loading: false },
    zapret2Remove: { loading: false },
    byedpiCheck: { loading: false },
    byedpiInstall: { loading: false },
    byedpiRemove: { loading: false },
  };
}

function getEmptyDiagnosticsActions(): StoreType['diagnosticsActions'] {
  return {
    ...store.get().diagnosticsActions,
    restart: { loading: false },
    start: { loading: false },
    stop: { loading: false },
  };
}

function normalizeLatencyProgress(
  progress?: Podkop.LatencyActionProgress,
): Podkop.LatencyActionProgress | undefined {
  const total = Math.trunc(Number(progress?.total ?? 0));

  if (!Number.isFinite(total) || total <= 0) {
    return undefined;
  }

  const completedValue = Number(progress?.completed ?? 0);
  const failedValue = Number(progress?.failed ?? 0);
  const completed = Number.isFinite(completedValue)
    ? Math.trunc(completedValue)
    : 0;
  const failed = Number.isFinite(failedValue) ? Math.trunc(failedValue) : 0;

  return {
    completed: Math.min(Math.max(0, completed), total),
    total,
    failed: Math.max(0, failed),
  };
}

function applyServiceState(uiState: Podkop.UiState) {
  const currentSystemInfo = store.get().diagnosticsSystemInfo;
  const nextSystemInfo = {
    ...currentSystemInfo,
    providerInfoLoaded: true,
    zapret_installed: uiState.capabilities.zapret_installed,
    zapret2_installed: uiState.capabilities.zapret2_installed,
    byedpi_installed: uiState.capabilities.byedpi_installed,
    server_inbounds_enabled_count:
      uiState.capabilities.server_inbounds_enabled_count,
  };

  nextSystemInfo.sing_box_extended = uiState.capabilities.sing_box_extended;
  nextSystemInfo.sing_box_tiny = uiState.capabilities.sing_box_tiny;
  nextSystemInfo.sing_box_compressed = uiState.capabilities.sing_box_compressed;
  nextSystemInfo.sing_box_tailscale = uiState.capabilities.sing_box_tailscale;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: false,
      data: {
        singbox: uiState.service.sing_box.running,
        podkopRunning: uiState.service.podkop.running,
        podkopEnabled: uiState.service.podkop.enabled,
        podkopStatus: uiState.service.podkop.status,
      },
    },
    diagnosticsSystemInfo: normalizeSingBoxVariantFields(nextSystemInfo),
  });
}

function applyActionState(actions: UiActionMap = {}) {
  const current = store.get();
  const localOverlay = getLocalActionOverlay();
  const currentLatencyProgressSections =
    current.sectionsWidget.latencyProgressSections;
  const subscriptionUpdatingSections: Record<string, boolean> = {};
  const latencyFetchingSections: Record<string, boolean> = {};
  const latencyProgressSections: Record<string, Podkop.LatencyActionProgress> =
    {};
  const updatesActions = getEmptyUpdatesActions();
  const diagnosticsActions = getEmptyDiagnosticsActions();

  for (const state of actions.subscription || []) {
    if (isRunningAction(state) && state.section) {
      subscriptionUpdatingSections[state.section] = true;
    }
  }

  for (const state of actions.latency || []) {
    if (isRunningAction(state) && state.section) {
      latencyFetchingSections[state.section] = true;
      const progress = normalizeLatencyProgress(state.progress);
      if (progress) {
        latencyProgressSections[state.section] = progress;
      } else if (currentLatencyProgressSections[state.section]) {
        latencyProgressSections[state.section] =
          currentLatencyProgressSections[state.section];
      }
    }
  }

  for (const state of actions.component || []) {
    if (!isRunningAction(state)) {
      continue;
    }

    const key = getComponentActionKey(state.component, state.action);
    if (key) {
      updatesActions[key] = { loading: true };
    }
  }

  for (const state of actions.service || []) {
    if (!isRunningAction(state)) {
      continue;
    }

    if (state.action === 'start') {
      diagnosticsActions.start = { loading: true };
    } else if (state.action === 'stop') {
      diagnosticsActions.stop = { loading: true };
    } else if (state.action === 'restart' || state.action === 'reload') {
      diagnosticsActions.restart = { loading: true };
    }
  }

  for (const section of localOverlay.subscriptionSections) {
    subscriptionUpdatingSections[section] = true;
  }

  for (const section of localOverlay.latencySections) {
    latencyFetchingSections[section] = true;
    if (
      !latencyProgressSections[section] &&
      currentLatencyProgressSections[section]
    ) {
      latencyProgressSections[section] =
        currentLatencyProgressSections[section];
    }
  }

  for (const key of localOverlay.componentActions) {
    updatesActions[key] = { loading: true };
  }

  for (const action of localOverlay.serviceActions) {
    diagnosticsActions[action] = { loading: true };
  }

  store.set({
    sectionsWidget: {
      ...current.sectionsWidget,
      subscriptionUpdatingSections,
      latencyFetchingSections,
      latencyProgressSections,
    },
    updatesActions,
    diagnosticsActions,
  });
}

export function applyUiStateToStore(uiState: Podkop.UiState) {
  applyServiceState(uiState);
  applyActionState(uiState.actions);
}
