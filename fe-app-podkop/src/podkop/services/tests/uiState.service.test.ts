import { beforeEach, describe, expect, it } from 'vitest';
import { applyUiStateToStore } from '../uiState.service';
import { store } from '../store.service';
import { Podkop } from '../../types';
import {
  clearLocalActionOverlay,
  setLocalComponentAction,
  setLocalLatencyAction,
  setLocalServiceAction,
  setLocalSubscriptionAction,
} from '../localActionOverlay.service';

function createUiState(
  actions: Partial<Podkop.UiState['actions']> = {},
  capabilities: Partial<Podkop.UiState['capabilities']> = {},
): Podkop.UiState {
  return {
    service: {
      podkop: {
        running: 0,
        enabled: 1,
        status: 'starting',
        dns_configured: 0,
      },
      sing_box: {
        running: 0,
        enabled: 1,
        status: 'stopped but enabled',
      },
    },
    capabilities: {
      sing_box_extended: 1,
      sing_box_tiny: 0,
      sing_box_compressed: 0,
      sing_box_tailscale: 1,
      zapret_installed: 1,
      zapret2_installed: 0,
      byedpi_installed: 1,
      server_inbounds_enabled_count: 0,
      ...capabilities,
    },
    actions: {
      service: [],
      latency: [],
      component: [],
      subscription: [],
      ...actions,
    },
  };
}

describe('applyUiStateToStore', () => {
  beforeEach(() => {
    clearLocalActionOverlay();
    store.reset();
  });

  it('applies service, capability, and running action state before first render', () => {
    applyUiStateToStore(
      createUiState({
        service: [
          {
            success: true,
            running: true,
            kind: 'service',
            action: 'start',
            job_id: 'service-1',
          },
        ],
        subscription: [
          {
            success: true,
            running: true,
            job_id: 'subscription-1',
            section: 'main',
            message: 'Subscription update is running',
          },
        ],
        latency: [
          {
            success: true,
            running: true,
            kind: 'latency',
            latency_type: 'group',
            section: 'main',
            tag: 'AUTO',
            job_id: 'latency-1',
            progress: {
              completed: 2,
              total: 5,
              failed: 1,
            },
          },
        ],
        component: [
          {
            success: true,
            running: true,
            job_id: 'component-1',
            component: 'zapret',
            action: 'install',
            message: 'Install is running',
            current_version: '',
            latest_version: '',
            changed: false,
          },
        ],
      }),
    );

    const state = store.get();

    expect(state.servicesInfoWidget).toMatchObject({
      loading: false,
      failed: false,
      data: {
        podkopEnabled: 1,
        podkopRunning: 0,
        podkopStatus: 'starting',
      },
    });
    expect(state.diagnosticsSystemInfo).toMatchObject({
      providerInfoLoaded: true,
      sing_box_extended: 1,
      zapret_installed: 1,
      zapret2_installed: 0,
      byedpi_installed: 1,
      server_inbounds_enabled_count: 0,
    });
    expect(state.diagnosticsActions.start.loading).toBe(true);
    expect(state.sectionsWidget.subscriptionUpdatingSections).toEqual({
      main: true,
    });
    expect(state.sectionsWidget.latencyFetchingSections).toEqual({
      main: true,
    });
    expect(state.sectionsWidget.latencyProgressSections).toEqual({
      main: {
        completed: 2,
        total: 5,
        failed: 1,
      },
    });
    expect(state.updatesActions.zapretInstall.loading).toBe(true);
  });

  it('clears finished persisted action flags while preserving local enable actions', () => {
    store.set({
      diagnosticsActions: {
        ...store.get().diagnosticsActions,
        start: { loading: true },
        enable: { loading: true },
      },
      sectionsWidget: {
        ...store.get().sectionsWidget,
        subscriptionUpdatingSections: { main: true },
        latencyFetchingSections: { main: true },
        latencyProgressSections: {
          main: {
            completed: 1,
            total: 2,
            failed: 0,
          },
        },
      },
      updatesActions: {
        ...store.get().updatesActions,
        zapretInstall: { loading: true },
      },
    });

    applyUiStateToStore(createUiState());

    const state = store.get();

    expect(state.diagnosticsActions.start.loading).toBe(false);
    expect(state.diagnosticsActions.enable.loading).toBe(true);
    expect(state.sectionsWidget.subscriptionUpdatingSections).toEqual({});
    expect(state.sectionsWidget.latencyFetchingSections).toEqual({});
    expect(state.sectionsWidget.latencyProgressSections).toEqual({});
    expect(state.updatesActions.zapretInstall.loading).toBe(false);
  });

  it('keeps locally started actions loading until their owner clears them', () => {
    setLocalComponentAction('zapretInstall', true);
    setLocalSubscriptionAction('proxy', true);
    setLocalLatencyAction('gemini', true);
    setLocalServiceAction('restart', true);

    applyUiStateToStore(createUiState());

    expect(store.get().updatesActions.zapretInstall.loading).toBe(true);
    expect(store.get().sectionsWidget.subscriptionUpdatingSections).toEqual({
      proxy: true,
    });
    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({
      gemini: true,
    });
    expect(store.get().diagnosticsActions.restart.loading).toBe(true);

    clearLocalActionOverlay();
    applyUiStateToStore(createUiState());

    expect(store.get().updatesActions.zapretInstall.loading).toBe(false);
    expect(store.get().sectionsWidget.subscriptionUpdatingSections).toEqual({});
    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({});
    expect(store.get().diagnosticsActions.restart.loading).toBe(false);
  });

  it('preserves local latency progress while waiting for runtime progress', () => {
    setLocalLatencyAction('gemini', true);
    store.set({
      sectionsWidget: {
        ...store.get().sectionsWidget,
        latencyFetchingSections: { gemini: true },
        latencyProgressSections: {
          gemini: {
            completed: 0,
            total: 3,
            failed: 0,
          },
        },
      },
    });

    applyUiStateToStore(createUiState());

    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({
      gemini: true,
    });
    expect(store.get().sectionsWidget.latencyProgressSections).toEqual({
      gemini: {
        completed: 0,
        total: 3,
        failed: 0,
      },
    });
  });

  it('preserves latency progress for running runtime actions without progress', () => {
    store.set({
      sectionsWidget: {
        ...store.get().sectionsWidget,
        latencyFetchingSections: { main: true },
        latencyProgressSections: {
          main: {
            completed: 2,
            total: 5,
            failed: 0,
          },
        },
      },
    });

    applyUiStateToStore(
      createUiState({
        latency: [
          {
            success: true,
            running: true,
            kind: 'latency',
            latency_type: 'proxy_list',
            section: 'main',
            tag: '["one","two"]',
            job_id: 'latency-1',
          },
        ],
      }),
    );

    expect(store.get().sectionsWidget.latencyFetchingSections).toEqual({
      main: true,
    });
    expect(store.get().sectionsWidget.latencyProgressSections).toEqual({
      main: {
        completed: 2,
        total: 5,
        failed: 0,
      },
    });
  });

  it('maps a running reload action to the restart control', () => {
    applyUiStateToStore(
      createUiState({
        service: [
          {
            success: true,
            running: true,
            kind: 'service',
            action: 'reload',
            job_id: 'service-reload',
          },
        ],
      }),
    );

    expect(store.get().diagnosticsActions.restart.loading).toBe(true);
  });

  it('does not combine a stale extended version with tiny capabilities', () => {
    store.set({
      diagnosticsSystemInfo: {
        ...store.get().diagnosticsSystemInfo,
        sing_box_version: '1.13.12-extended-2.3.2',
        sing_box_extended: 1,
        sing_box_tiny: 0,
      },
    });

    applyUiStateToStore(
      createUiState(undefined, {
        sing_box_extended: 0,
        sing_box_tiny: 1,
        sing_box_compressed: 0,
        sing_box_tailscale: 0,
      }),
    );

    expect(store.get().diagnosticsSystemInfo).toMatchObject({
      sing_box_version: '1.13.12-extended-2.3.2',
      sing_box_extended: 1,
      sing_box_tiny: 0,
      sing_box_tailscale: 1,
    });
  });

  it('keeps current sing-box variant while a different sing-box install action is running', () => {
    store.set({
      diagnosticsSystemInfo: {
        ...store.get().diagnosticsSystemInfo,
        providerInfoLoaded: true,
        sing_box_version: '1.12.25',
        sing_box_extended: 0,
        sing_box_tiny: 1,
        sing_box_compressed: 0,
        sing_box_tailscale: 1,
        zapret_installed: 0,
        zapret2_installed: 0,
        byedpi_installed: 1,
        server_inbounds_enabled_count: 0,
      },
    });

    applyUiStateToStore(
      createUiState(
        {
          component: [
            {
              success: true,
              running: true,
              job_id: 'sing-box-install',
              component: 'sing_box',
              action: 'install_extended_compressed',
              message: 'Install is running',
              current_version: '',
              latest_version: '',
              changed: false,
            },
          ],
        },
        {
          sing_box_extended: 0,
          sing_box_tiny: 1,
          sing_box_compressed: 0,
          sing_box_tailscale: 0,
          zapret_installed: 1,
          zapret2_installed: 1,
          byedpi_installed: 0,
          server_inbounds_enabled_count: 2,
        },
      ),
    );

    expect(store.get().diagnosticsSystemInfo).toMatchObject({
      providerInfoLoaded: true,
      sing_box_version: '1.12.25',
      sing_box_extended: 0,
      sing_box_tiny: 1,
      sing_box_compressed: 0,
      sing_box_tailscale: 0,
      zapret_installed: 1,
      zapret2_installed: 1,
      byedpi_installed: 0,
      server_inbounds_enabled_count: 2,
    });
    expect(
      store.get().updatesActions.singBoxInstallExtendedCompressed.loading,
    ).toBe(true);
  });

  it('marks the running sing-box install action without pretending it is installed', () => {
    applyUiStateToStore(
      createUiState(
        {
          component: [
            {
              success: true,
              running: true,
              job_id: 'sing-box-install',
              component: 'sing_box',
              action: 'install_extended',
              message: 'Install is running',
              current_version: '',
              latest_version: '',
              changed: false,
            },
          ],
        },
        {
          sing_box_extended: 0,
          sing_box_tiny: 1,
          sing_box_compressed: 0,
          sing_box_tailscale: 0,
        },
      ),
    );

    expect(store.get().diagnosticsSystemInfo).toMatchObject({
      sing_box_extended: 0,
      sing_box_tiny: 1,
      sing_box_compressed: 0,
      sing_box_tailscale: 0,
    });
    expect(store.get().updatesActions.singBoxInstallExtended.loading).toBe(
      true,
    );
  });
});
