import {
  DIAGNOSTICS_CHECKS,
  DIAGNOSTICS_CHECKS_MAP,
} from './checks/contstants';
import { IDiagnosticsChecksStoreItem, StoreType } from '../../services';

export interface DiagnosticsProviderOptions {
  includeZapret?: boolean;
  includeByedpi?: boolean;
}

function createDiagnosticCheck(
  code: DIAGNOSTICS_CHECKS,
  description: string,
): IDiagnosticsChecksStoreItem {
  const meta = DIAGNOSTICS_CHECKS_MAP[code];

  return {
    code,
    title: meta.title,
    order: meta.order,
    description,
    items: [],
    state: 'skipped',
  };
}

export function getDiagnosticsChecks(
  description: string,
  options: DiagnosticsProviderOptions = {},
): Array<IDiagnosticsChecksStoreItem> {
  const checks = [
    DIAGNOSTICS_CHECKS.DNS,
    DIAGNOSTICS_CHECKS.SINGBOX,
    DIAGNOSTICS_CHECKS.INBOUNDS,
    DIAGNOSTICS_CHECKS.NFT,
  ];

  if (options.includeZapret) {
    checks.push(DIAGNOSTICS_CHECKS.ZAPRET);
  }

  if (options.includeByedpi) {
    checks.push(DIAGNOSTICS_CHECKS.BYEDPI);
  }

  checks.push(DIAGNOSTICS_CHECKS.OUTBOUNDS, DIAGNOSTICS_CHECKS.FAKEIP);

  return checks.map((code) => createDiagnosticCheck(code, description));
}

export function getLoadingDiagnosticsChecks(
  options: DiagnosticsProviderOptions = {},
): Pick<StoreType, 'diagnosticsChecks'> {
  return {
    diagnosticsChecks: getDiagnosticsChecks(_('Pending'), options),
  };
}

export const initialDiagnosticStore: Pick<
  StoreType,
  | 'diagnosticsChecks'
  | 'diagnosticsRunAction'
  | 'diagnosticsActions'
  | 'diagnosticsSystemInfo'
  | 'updatesActions'
  | 'updatesChecks'
> = {
  diagnosticsSystemInfo: {
    loading: true,
    loaded: false,
    providerInfoLoaded: false,
    podkop_version: 'loading',
    podkop_latest_version: 'loading',
    luci_app_version: 'loading',
    sing_box_version: 'loading',
    sing_box_extended: 0,
    zapret_version: 'loading',
    zapret_installed: 0,
    byedpi_version: 'loading',
    byedpi_installed: 0,
    openwrt_version: 'loading',
    device_model: 'loading',
  },
  diagnosticsActions: {
    restart: {
      loading: false,
    },
    start: {
      loading: false,
    },
    stop: {
      loading: false,
    },
    enable: {
      loading: false,
    },
    disable: {
      loading: false,
    },
    globalCheck: {
      loading: false,
    },
    viewLogs: {
      loading: false,
    },
    showSingBoxConfig: {
      loading: false,
    },
  },
  diagnosticsRunAction: { loading: false },
  diagnosticsChecks: getDiagnosticsChecks(_('Not running')),
  updatesActions: {
    podkopCheck: { loading: false },
    podkopInstall: { loading: false },
    singBoxCheck: { loading: false },
    singBoxInstall: { loading: false },
    singBoxInstallExtended: { loading: false },
    singBoxInstallStable: { loading: false },
    zapretCheck: { loading: false },
    zapretInstall: { loading: false },
    zapretRemove: { loading: false },
    byedpiCheck: { loading: false },
    byedpiInstall: { loading: false },
    byedpiRemove: { loading: false },
  },
  updatesChecks: {
    podkop: { status: null, latest_version: '', release_url: '' },
    sing_box: { status: null, latest_version: '', release_url: '' },
    zapret: { status: null, latest_version: '', release_url: '' },
    byedpi: { status: null, latest_version: '', release_url: '' },
  },
};
