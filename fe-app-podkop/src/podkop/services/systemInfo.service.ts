import { PodkopShellMethods } from '../methods';
import { normalizeSingBoxVariantFields } from '../helpers/singBoxVariant';
import { logger } from './logger.service';
import { store, StoreType } from './store.service';

const UNKNOWN_SYSTEM_INFO: StoreType['diagnosticsSystemInfo'] = {
  loading: false,
  loaded: false,
  providerInfoLoaded: false,
  podkop_version: _('unknown'),
  podkop_latest_version: _('unknown'),
  luci_app_version: _('unknown'),
  sing_box_version: _('unknown'),
  sing_box_extended: 0,
  sing_box_tiny: 0,
  sing_box_compressed: 0,
  sing_box_tailscale: 1,
  zapret_version: _('unknown'),
  zapret_installed: 0,
  zapret2_version: _('unknown'),
  zapret2_installed: 0,
  byedpi_version: _('unknown'),
  byedpi_installed: 0,
  server_inbounds_enabled_count: -1,
  openwrt_version: _('unknown'),
  device_model: _('unknown'),
};

let systemInfoPromise: Promise<StoreType['diagnosticsSystemInfo']> | null =
  null;
let latestSystemInfoRequestId = 0;

function hasLoadedSystemInfo() {
  const systemInfo = store.get().diagnosticsSystemInfo;

  return Boolean(systemInfo.loaded) && !systemInfo.loading;
}

export async function ensureSystemInfo({
  force = false,
  silent = false,
}: {
  force?: boolean;
  silent?: boolean;
} = {}) {
  if (!force && hasLoadedSystemInfo()) {
    return store.get().diagnosticsSystemInfo;
  }

  if (systemInfoPromise && !force) {
    return systemInfoPromise;
  }

  const requestId = ++latestSystemInfoRequestId;
  const currentSystemInfo = store.get().diagnosticsSystemInfo;

  if (!silent) {
    store.set({
      diagnosticsSystemInfo: {
        ...currentSystemInfo,
        loading: true,
      },
    });
  }

  const promise = (async () => {
    try {
      const systemInfo = await PodkopShellMethods.getSystemInfo();

      if (requestId !== latestSystemInfoRequestId) {
        return store.get().diagnosticsSystemInfo;
      }

      if (systemInfo.success) {
        const nextSystemInfo: StoreType['diagnosticsSystemInfo'] = normalizeSingBoxVariantFields({
          ...UNKNOWN_SYSTEM_INFO,
          loading: false,
          loaded: true,
          providerInfoLoaded: true,
          server_inbounds_enabled_count:
            currentSystemInfo.server_inbounds_enabled_count,
          ...systemInfo.data,
        });

        store.set({
          diagnosticsSystemInfo: nextSystemInfo,
        });

        return nextSystemInfo;
      }
    } catch (error) {
      logger.error('[SYSTEM_INFO]', 'ensureSystemInfo failed', error);
    }

    if (requestId === latestSystemInfoRequestId && !silent) {
      const latestSystemInfo = store.get().diagnosticsSystemInfo;
      const nextSystemInfo = {
        ...UNKNOWN_SYSTEM_INFO,
        loading: false,
        loaded: false,
        providerInfoLoaded: latestSystemInfo.providerInfoLoaded,
        zapret_installed: latestSystemInfo.zapret_installed,
        zapret2_installed: latestSystemInfo.zapret2_installed,
        byedpi_installed: latestSystemInfo.byedpi_installed,
        server_inbounds_enabled_count:
          latestSystemInfo.server_inbounds_enabled_count,
      };

      store.set({
        diagnosticsSystemInfo: nextSystemInfo,
      });

      return nextSystemInfo;
    }

    return store.get().diagnosticsSystemInfo;
  })();

  systemInfoPromise = promise;

  try {
    return await promise;
  } finally {
    if (systemInfoPromise === promise) {
      systemInfoPromise = null;
    }
  }
}
