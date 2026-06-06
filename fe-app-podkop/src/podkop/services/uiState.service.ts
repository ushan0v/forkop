import { getComponentActionKey } from '../helpers/getComponentActionKey';
import type { Podkop } from '../types';
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

function applyServiceState(uiState: Podkop.UiState) {
  const currentSystemInfo = store.get().diagnosticsSystemInfo;

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
    diagnosticsSystemInfo: {
      ...currentSystemInfo,
      providerInfoLoaded: true,
      sing_box_extended: uiState.capabilities.sing_box_extended,
      zapret_installed: uiState.capabilities.zapret_installed,
      zapret2_installed: uiState.capabilities.zapret2_installed,
      byedpi_installed: uiState.capabilities.byedpi_installed,
      server_inbounds_enabled_count:
        uiState.capabilities.server_inbounds_enabled_count,
    },
  });
}

function applyActionState(actions: UiActionMap = {}) {
  const current = store.get();
  const subscriptionUpdatingSections: Record<string, boolean> = {};
  const latencyFetchingSections: Record<string, boolean> = {};
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

  store.set({
    sectionsWidget: {
      ...current.sectionsWidget,
      subscriptionUpdatingSections,
      latencyFetchingSections,
    },
    updatesActions,
    diagnosticsActions,
  });
}

export function applyUiStateToStore(uiState: Podkop.UiState) {
  applyServiceState(uiState);
  applyActionState(uiState.actions);
}
