import { describe, expect, it } from 'vitest';
import { getPodkopVersionRow } from '../helpers/getPodkopVersionRow';
import type { StoreType } from '../../../services/store.service';

function makeDiagnosticsSystemInfo(
  patch: Partial<StoreType['diagnosticsSystemInfo']> = {},
): StoreType['diagnosticsSystemInfo'] {
  return {
    loading: false,
    podkop_version: '0.7.16-4',
    podkop_latest_version: '0.7.16-4',
    luci_app_version: '0.7.16-4',
    sing_box_version: '1.12.0',
    zapret_version: 'not installed',
    zapret_installed: 0,
    byedpi_version: 'not installed',
    byedpi_installed: 0,
    openwrt_version: 'OpenWrt 25.12',
    device_model: 'Test Router',
    ...patch,
  };
}

describe('getPodkopVersionRow', () => {
  it('returns Latest when versions differ only by leading v', () => {
    const row = getPodkopVersionRow(
      makeDiagnosticsSystemInfo({
        podkop_version: 'v0.7.16-4',
        podkop_latest_version: '0.7.16-4',
      }),
    );

    expect(row).toEqual({
      key: 'Podkop Plus',
      value: 'v0.7.16-4',
      tag: {
        label: 'Latest',
        kind: 'success',
      },
    });
  });

  it('returns Latest when latest uses OpenWrt package release suffix', () => {
    const row = getPodkopVersionRow(
      makeDiagnosticsSystemInfo({
        podkop_version: '0.7.17-4',
        podkop_latest_version: '0.7.17-r4',
      }),
    );

    expect(row).toEqual({
      key: 'Podkop Plus',
      value: '0.7.17-4',
      tag: {
        label: 'Latest',
        kind: 'success',
      },
    });
  });

  it('normalizes OpenWrt package release suffix for display', () => {
    const row = getPodkopVersionRow(
      makeDiagnosticsSystemInfo({
        podkop_version: '0.7.17-r4',
        podkop_latest_version: '0.7.17-4',
      }),
    );

    expect(row).toEqual({
      key: 'Podkop Plus',
      value: '0.7.17-4',
      tag: {
        label: 'Latest',
        kind: 'success',
      },
    });
  });

  it('returns Outdated when the current fork release is older', () => {
    const row = getPodkopVersionRow(
      makeDiagnosticsSystemInfo({
        podkop_version: '0.7.16-3',
        podkop_latest_version: '0.7.16-4',
      }),
    );

    expect(row).toEqual({
      key: 'Podkop Plus',
      value: '0.7.16-3',
      tag: {
        label: 'Outdated',
        kind: 'warning',
      },
    });
  });

  it('returns Dev when the current fork release is newer than latest', () => {
    const row = getPodkopVersionRow(
      makeDiagnosticsSystemInfo({
        podkop_version: '0.7.16-5',
        podkop_latest_version: '0.7.16-4',
      }),
    );

    expect(row).toEqual({
      key: 'Podkop Plus',
      value: '0.7.16-5',
      tag: {
        label: 'Dev',
        kind: 'neutral',
      },
    });
  });

  it('returns Check unavailable when latest version is unknown', () => {
    const row = getPodkopVersionRow(
      makeDiagnosticsSystemInfo({
        podkop_latest_version: 'unknown',
      }),
    );

    expect(row).toEqual({
      key: 'Podkop Plus',
      value: '0.7.16-4',
      tag: {
        label: 'Check unavailable',
        kind: 'neutral',
      },
    });
  });

  it('returns Dev for placeholder builds', () => {
    const row = getPodkopVersionRow(
      makeDiagnosticsSystemInfo({
        podkop_version: '__COMPILED_VERSION_VARIABLE__',
      }),
    );

    expect(row).toEqual({
      key: 'Podkop Plus',
      value: 'dev',
      tag: {
        label: 'Dev',
        kind: 'neutral',
      },
    });
  });
});
