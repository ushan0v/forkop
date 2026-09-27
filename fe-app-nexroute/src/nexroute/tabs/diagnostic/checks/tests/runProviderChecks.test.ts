import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  getZapretStatus: vi.fn(),
  getZapret2Status: vi.fn(),
  getByedpiStatus: vi.fn(),
  updateCheckStore: vi.fn(),
}));

vi.mock('../../../../methods', () => ({
  ForkopShellMethods: {
    getZapretStatus: mocks.getZapretStatus,
    getZapret2Status: mocks.getZapret2Status,
    getByedpiStatus: mocks.getByedpiStatus,
  },
}));

vi.mock('../updateCheckStore', () => ({
  updateCheckStore: mocks.updateCheckStore,
}));

import { runByedpiCheck } from '../runByedpiCheck';
import { runZapret2Check } from '../runZapret2Check';
import { runZapretCheck } from '../runZapretCheck';

const zapretOkData = {
  provider_available: true,
  package_installed: true,
  enabled_rule_count: 1,
  expected_process_count: 1,
  running_process_count: 1,
  supervisor_process_count: 1,
  queue_overlap: false,
  queue_base: 200,
  queue_range_end: 200,
  standalone_service_running: false,
  outbounds_configured: true,
  routes_configured: false,
  ready: false,
};

describe('provider diagnostics checks', () => {
  beforeEach(() => {
    mocks.getZapretStatus.mockReset();
    mocks.getZapret2Status.mockReset();
    mocks.getByedpiStatus.mockReset();
    mocks.updateCheckStore.mockReset();
  });

  it('shows Zapret provider path and does not fail on hidden route status', async () => {
    mocks.getZapretStatus.mockResolvedValue({
      success: true,
      data: {
        ...zapretOkData,
        provider_path: '/usr/bin/nfqws',
      },
    });

    await expect(runZapretCheck()).resolves.toBeUndefined();

    const result = mocks.updateCheckStore.mock.calls.slice(-1)[0]?.[0];

    expect(result).toMatchObject({
      state: 'success',
      description: 'Checks passed',
    });
    expect(result.items).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          key: 'Zapret provider binary is available',
          value: '/usr/bin/nfqws',
        }),
        expect.objectContaining({
          state: 'success',
          key: 'Zapret sing-box outbound is configured',
        }),
      ]),
    );
    expect(
      result.items.some((item: { key: string }) =>
        item.key.includes('route rules'),
      ),
    ).toBe(false);
  });

  it('keeps Zapret outbound failures visible and red', async () => {
    mocks.getZapretStatus.mockResolvedValue({
      success: true,
      data: {
        ...zapretOkData,
        provider_path: '/usr/bin/nfqws',
        outbounds_configured: false,
      },
    });

    await expect(runZapretCheck()).resolves.toBeUndefined();

    const result = mocks.updateCheckStore.mock.calls.slice(-1)[0]?.[0];

    expect(result).toMatchObject({
      state: 'error',
      description: 'Checks failed',
    });
    expect(result.items).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          state: 'error',
          key: 'Zapret sing-box outbound is not configured',
        }),
      ]),
    );
  });

  it('removes Zapret2 route checks while keeping provider path visible', async () => {
    mocks.getZapret2Status.mockResolvedValue({
      success: true,
      data: {
        ...zapretOkData,
        provider_path: '/usr/bin/nfqws2',
      },
    });

    await expect(runZapret2Check()).resolves.toBeUndefined();

    const result = mocks.updateCheckStore.mock.calls.slice(-1)[0]?.[0];

    expect(result).toMatchObject({
      state: 'success',
      description: 'Checks passed',
    });
    expect(result.items).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          key: 'Zapret2 provider binary is available',
          value: '/usr/bin/nfqws2',
        }),
        expect.objectContaining({
          state: 'success',
          key: 'Zapret2 sing-box outbound is configured',
        }),
      ]),
    );
    expect(
      result.items.some((item: { key: string }) =>
        item.key.includes('route rules'),
      ),
    ).toBe(false);
  });

  it('removes ByeDPI route checks from the visible and aggregate status', async () => {
    mocks.getByedpiStatus.mockResolvedValue({
      success: true,
      data: {
        provider_available: true,
        package_installed: true,
        enabled_rule_count: 1,
        expected_process_count: 1,
        running_process_count: 1,
        supervisor_process_count: 1,
        restart_count: 0,
        runtime_unstable: false,
        standalone_service_enabled: false,
        standalone_service_running: false,
        listen_address: '127.0.0.1',
        port_base: 1080,
        outbounds_configured: true,
        routes_configured: false,
        ready: false,
      },
    });

    await expect(runByedpiCheck()).resolves.toBeUndefined();

    const result = mocks.updateCheckStore.mock.calls.slice(-1)[0]?.[0];

    expect(result).toMatchObject({
      state: 'success',
      description: 'Checks passed',
    });
    expect(
      result.items.some((item: { key: string }) =>
        item.key.includes('route rules'),
      ),
    ).toBe(false);
  });
});
