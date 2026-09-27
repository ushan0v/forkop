import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { Forkop } from '../../types';
import { store } from '../store.service';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  subscribeRuntimeUiState,
} from '../runtimeUiState.service';

function createUiState(
  status = 'running & enabled',
  running = 1,
): Forkop.UiState {
  return {
    service: {
      forkop: {
        running,
        enabled: 1,
        status,
        dns_configured: running,
      },
      sing_box: {
        running,
        enabled: 0,
        status: running ? 'running but disabled' : 'stopped & disabled',
      },
    },
    capabilities: {
      sing_box_extended: 1,
      sing_box_tiny: 0,
      sing_box_compressed: 0,
      sing_box_tailscale: 1,
      zapret_installed: 1,
      zapret2_installed: 1,
      byedpi_installed: 0,
      server_inbounds_enabled_count: 0,
    },
    actions: {
      service: [],
      latency: [],
      component: [],
      subscription: [],
    },
  };
}

describe('refreshRuntimeUiState', () => {
  beforeEach(() => {
    store.reset();
    mocks.executeShellCommand.mockReset();
  });

  it('applies current UI state to the shared store', async () => {
    const uiState = createUiState('stopped but enabled', 0);

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await expect(refreshRuntimeUiState({ force: true })).resolves.toEqual(
      uiState,
    );

    expect(mocks.executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/forkop',
      args: ['get_ui_state'],
      timeout: 3000,
    });
    expect(store.get().servicesInfoWidget.data).toMatchObject({
      forkopRunning: 0,
      forkopEnabled: 1,
      forkopStatus: 'stopped but enabled',
    });
  });

  it('coalesces concurrent refreshes into one RPC call', async () => {
    const uiState = createUiState();
    let resolveRpc: (value: {
      stdout: string;
      stderr: string;
      code: number;
    }) => void = () => undefined;

    mocks.executeShellCommand.mockReturnValue(
      new Promise((resolve) => {
        resolveRpc = resolve;
      }),
    );

    const firstRefresh = refreshRuntimeUiState({ force: true });
    const secondRefresh = refreshRuntimeUiState({ force: true });

    expect(mocks.executeShellCommand).toHaveBeenCalledTimes(1);

    resolveRpc({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await expect(Promise.all([firstRefresh, secondRefresh])).resolves.toEqual([
      uiState,
      uiState,
    ]);
  });

  it('notifies subscribers after applying fresh state', async () => {
    const uiState = createUiState('stopped but enabled', 0);
    const listener = vi.fn();
    const unsubscribe = subscribeRuntimeUiState(listener);
    listener.mockClear();

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await refreshRuntimeUiState({ force: true });

    expect(listener).toHaveBeenCalledWith(uiState);

    unsubscribe();
    listener.mockClear();

    await refreshRuntimeUiState({ force: true });

    expect(listener).not.toHaveBeenCalled();
  });

  it('replays cached state to a new subscriber without another RPC', async () => {
    const uiState = createUiState('starting', 0);

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await refreshRuntimeUiState({ force: true });

    const listener = vi.fn();
    const unsubscribe = subscribeRuntimeUiState(listener);

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener).toHaveBeenCalledWith(uiState);
    expect(mocks.executeShellCommand).toHaveBeenCalledTimes(1);

    unsubscribe();
  });

  it('exposes the cached state without another RPC', async () => {
    const uiState = createUiState('running & enabled', 1);

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await refreshRuntimeUiState({ force: true });
    mocks.executeShellCommand.mockClear();

    expect(getCachedRuntimeUiState()).toEqual(uiState);
    expect(mocks.executeShellCommand).not.toHaveBeenCalled();
  });
});
