import { PodkopShellMethods } from '../methods';
import { logger, store } from '../services';
import { Podkop } from '../types';

let latestServicesInfoRequestId = 0;
let latestPodkopStatusRequestId = 0;

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
        podkopLifecycleState: podkop.success
          ? podkop.data.lifecycle_state || 'unknown'
          : 'unknown',
        podkopLifecycleAction: podkop.success
          ? podkop.data.lifecycle_action || 'none'
          : 'none',
        podkopLifecycleBusy: podkop.success
          ? podkop.data.lifecycle_busy || 0
          : 0,
      },
    },
  });
}

export async function fetchPodkopStatus() {
  const requestId = ++latestPodkopStatusRequestId;
  const podkop = await PodkopShellMethods.getStatus();

  if (requestId !== latestPodkopStatusRequestId) {
    return podkop.success ? podkop.data : null;
  }

  const previous = store.get().servicesInfoWidget;
  const previousData = previous.data;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: !podkop.success,
      data: {
        ...previousData,
        podkopRunning: podkop.success
          ? podkop.data.running
          : previousData.podkopRunning,
        podkopEnabled: podkop.success
          ? podkop.data.enabled
          : previousData.podkopEnabled,
        podkopStatus: podkop.success
          ? podkop.data.status
          : previousData.podkopStatus || 'unknown',
        podkopLifecycleState: podkop.success
          ? podkop.data.lifecycle_state || 'unknown'
          : 'unknown',
        podkopLifecycleAction: podkop.success
          ? podkop.data.lifecycle_action || 'none'
          : 'none',
        podkopLifecycleBusy: podkop.success
          ? podkop.data.lifecycle_busy || 0
          : 0,
      },
    },
  });

  return podkop.success ? podkop.data : null;
}
