import { NexrouteShellMethods } from '../methods';
import { logger } from '../services/logger.service';
import { store } from '../services/store.service';
import { refreshRuntimeUiState } from '../services/runtimeUiState.service';
import { Nexroute } from '../types';

let latestServicesInfoRequestId = 0;

function getSettledMethodResponse<T>(
  scope: string,
  result: PromiseSettledResult<Nexroute.MethodResponse<T>>,
): Nexroute.MethodResponse<T> {
  if (result.status === 'fulfilled') {
    return result.value;
  }

  logger.error('[SERVICES_INFO]', `${scope} failed`, result.reason);

  return {
    success: false,
    error: result.reason instanceof Error ? result.reason.message : '',
  };
}

export async function fetchServicesInfo() {
  const requestId = ++latestServicesInfoRequestId;
  const uiState = await refreshRuntimeUiState({ force: true });

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  if (uiState) {
    return uiState;
  }

  const [nexrouteResult, singboxResult] = await Promise.allSettled([
    NexrouteShellMethods.getStatus(),
    NexrouteShellMethods.getSingBoxStatus(),
  ]);

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  const nexroute = getSettledMethodResponse('getStatus', nexrouteResult);
  const singbox = getSettledMethodResponse('getSingBoxStatus', singboxResult);
  const previousData = store.get().servicesInfoWidget.data;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: !nexroute.success || !singbox.success,
      data: {
        singbox: singbox.success ? singbox.data.running : previousData.singbox,
        nexrouteRunning: nexroute.success
          ? nexroute.data.running
          : previousData.nexrouteRunning,
        nexrouteEnabled: nexroute.success
          ? nexroute.data.enabled
          : previousData.nexrouteEnabled,
        nexrouteStatus: nexroute.success
          ? nexroute.data.status
          : previousData.nexrouteStatus,
      },
    },
  });

  return undefined;
}
