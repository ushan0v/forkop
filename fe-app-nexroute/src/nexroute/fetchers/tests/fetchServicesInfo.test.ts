import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { store } from '../../services/store.service';
import { fetchServicesInfo } from '../fetchServicesInfo';

describe('fetchServicesInfo', () => {
  beforeEach(() => {
    store.reset();
    mocks.executeShellCommand.mockReset();
  });

  it('returns the fast UI state after applying it to the shared store', async () => {
    const uiState = {
      service: {
        forkop: {
          running: 1,
          enabled: 1,
          status: 'restarting',
          dns_configured: 1,
        },
        sing_box: {
          running: 1,
          enabled: 0,
          status: 'running but disabled',
        },
      },
      capabilities: {
        sing_box_extended: 1,
        sing_box_tiny: 0,
        sing_box_tailscale: 1,
        zapret_installed: 1,
        zapret2_installed: 0,
        byedpi_installed: 0,
        server_inbounds_enabled_count: 0,
      },
      actions: {
        service: [
          {
            success: true,
            running: true,
            kind: 'service',
            action: 'restart',
            job_id: 'service-1',
          },
        ],
        latency: [],
        component: [],
        subscription: [],
      },
    };

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await expect(fetchServicesInfo()).resolves.toEqual(uiState);

    const state = store.get();

    expect(state.servicesInfoWidget.data.forkopStatus).toBe('restarting');
    expect(state.diagnosticsActions.restart.loading).toBe(true);
  });

  it('keeps the previous service state when the fallback status fetch fails', async () => {
    store.set({
      servicesInfoWidget: {
        loading: false,
        failed: false,
        data: {
          singbox: 1,
          forkopRunning: 1,
          forkopEnabled: 1,
          forkopStatus: 'running & enabled',
        },
      },
    });

    mocks.executeShellCommand
      .mockResolvedValueOnce({
        stdout: '',
        stderr: 'get_ui_state failed',
        code: 1,
      })
      .mockResolvedValueOnce({
        stdout: '',
        stderr: 'get_status failed',
        code: 1,
      })
      .mockResolvedValueOnce({
        stdout: JSON.stringify({
          running: 0,
          enabled: 0,
          status: 'stopped but disabled',
        }),
        stderr: '',
        code: 0,
      });

    await fetchServicesInfo();

    const state = store.get();

    expect(state.servicesInfoWidget.failed).toBe(true);
    expect(state.servicesInfoWidget.data).toEqual({
      singbox: 0,
      forkopRunning: 1,
      forkopEnabled: 1,
      forkopStatus: 'running & enabled',
    });
  });
});
