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
        podkop: {
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

    expect(state.servicesInfoWidget.data.podkopStatus).toBe('restarting');
    expect(state.diagnosticsActions.restart.loading).toBe(true);
  });
});
