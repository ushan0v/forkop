import { PodkopShellMethods } from '../methods';
import { logger } from '../services/logger.service';
import { store } from '../services/store.service';
import { applyUiStateToStore } from '../services/uiState.service';
import { Podkop } from '../types';

let latestServicesInfoRequestId = 0;

function getSettledMethodResponse<T>(
  scope: string,
  result: PromiseSettledResult<Podkop.MethodResponse<T>>,
): Podkop.MethodResponse<T> {
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
  const uiState = await PodkopShellMethods.getUiState();

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  if (uiState.success) {
    applyUiStateToStore(uiState.data);
    return uiState.data;
  }

  const [podkopResult, singboxResult] = await Promise.allSettled([
    PodkopShellMethods.getStatus(),
    PodkopShellMethods.getSingBoxStatus(),
  ]);

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  const podkop = getSettledMethodResponse('getStatus', podkopResult);
  const singbox = getSettledMethodResponse('getSingBoxStatus', singboxResult);

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: !podkop.success || !singbox.success,
      data: {
        singbox: singbox.success ? singbox.data.running : 0,
        podkopRunning: podkop.success ? podkop.data.running : 0,
        podkopEnabled: podkop.success ? podkop.data.enabled : 0,
        podkopStatus: podkop.success ? podkop.data.status : '',
      },
    },
  });

  return undefined;
}
