import { callBaseMethod } from './callBaseMethod';
import { ClashAPI, Podkop } from '../../types';
import { executeShellCommand } from '../../../helpers';

const SUBSCRIPTION_UPDATE_TIMEOUT_MS = 10 * 60 * 1000;
const SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS = 15000;
const SUBSCRIPTION_UPDATE_POLL_INTERVAL_MS = 1500;
const UI_ACTION_RPC_TIMEOUT_MS = 15000;
const SERVICE_ACTION_TIMEOUT_MS = 2 * 60 * 1000;
const SERVICE_ACTION_POLL_INTERVAL_MS = 1000;
const LATENCY_TEST_TIMEOUT_MS = 30 * 1000;
const LATENCY_TEST_POLL_INTERVAL_MS = 1000;
const COMPONENT_ACTION_TIMEOUT_MS = 10 * 60 * 1000;
const COMPONENT_ACTION_RPC_TIMEOUT_MS = 15000;
const COMPONENT_ACTION_POLL_INTERVAL_MS = 1500;
const COMPONENT_ACTION_SELF_UPDATE_SETTLE_MS = 30000;
const COMPONENT_ACTION_STATE_DIR = '/var/run/podkop-plus/component-actions';

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

function parseJsonObjectOutput<T>(output: string): T | null {
  if (!output) {
    return null;
  }

  try {
    return JSON.parse(output) as T;
  } catch (_error) {
    const jsonMatch = output.match(/(\{[\s\S]*\})\s*$/);

    if (!jsonMatch) {
      return null;
    }

    try {
      return JSON.parse(jsonMatch[1]) as T;
    } catch (_jsonError) {
      return null;
    }
  }
}

function parseComponentActionOutput(output: string) {
  return parseJsonObjectOutput<Podkop.ComponentActionResult>(output);
}

function parseComponentActionResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseComponentActionOutput(response.stdout);
}

function parseComponentActionStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  const parsedResponse = parseComponentActionResult(response);

  if (!parsedResponse) {
    return null;
  }

  return parsedResponse as unknown as Podkop.ComponentActionStartResult;
}

function parseSubscriptionUpdateStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Podkop.SubscriptionUpdateStartResult>(
    response.stdout,
  );
}

function parseSubscriptionUpdateJobState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Podkop.SubscriptionUpdateJobState>(
    response.stdout,
  );
}

function parseUiActionStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Podkop.UiActionStartResult>(response.stdout);
}

function parseServiceActionState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Podkop.ServiceActionState>(response.stdout);
}

function parseLatencyActionState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Podkop.LatencyActionState>(response.stdout);
}

function isComponentActionJobId(jobId: string) {
  return /^[A-Za-z0-9._-]+$/.test(jobId) && jobId !== '.' && jobId !== '..';
}

async function readComponentActionState(jobId: string) {
  if (!isComponentActionJobId(jobId)) {
    return null;
  }

  try {
    return parseComponentActionOutput(
      await fs.read(`${COMPONENT_ACTION_STATE_DIR}/${jobId}.json`),
    );
  } catch (_error) {
    return null;
  }
}

async function readPodkopVersion() {
  const response = await executeShellCommand({
    command: '/usr/bin/podkop-plus',
    args: ['show_version'],
    timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
  });

  if ((response.code ?? 0) !== 0 || !response.stdout) {
    return '';
  }

  return response.stdout.trim();
}

function componentActionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse?: Pick<Podkop.ComponentActionResult, 'message'> | null,
) {
  return {
    success: false,
    error: parsedResponse?.message || response.stderr || _('Failed to execute'),
  } as Podkop.MethodFailureResponse;
}

function uiActionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse?: { message?: string } | null,
  fallback: string = _('Failed to execute'),
) {
  return {
    success: false,
    error: parsedResponse?.message || response.stderr || fallback,
  } as Podkop.MethodFailureResponse;
}

export const PodkopShellMethods = {
  checkDNSAvailable: async () =>
    callBaseMethod<Podkop.DnsCheckResult>(
      Podkop.AvailableMethods.CHECK_DNS_AVAILABLE,
    ),
  checkFakeIP: async () =>
    callBaseMethod<Podkop.FakeIPCheckResult>(
      Podkop.AvailableMethods.CHECK_FAKEIP,
    ),
  checkNftRules: async () =>
    callBaseMethod<Podkop.NftRulesCheckResult>(
      Podkop.AvailableMethods.CHECK_NFT_RULES,
    ),
  checkZapretRuntime: async () =>
    callBaseMethod<Podkop.ZapretCheckResult>(
      Podkop.AvailableMethods.CHECK_ZAPRET_RUNTIME,
    ),
  checkZapret2Runtime: async () =>
    callBaseMethod<Podkop.Zapret2CheckResult>(
      Podkop.AvailableMethods.CHECK_ZAPRET2_RUNTIME,
    ),
  checkByedpiRuntime: async () =>
    callBaseMethod<Podkop.ByedpiCheckResult>(
      Podkop.AvailableMethods.CHECK_BYEDPI_RUNTIME,
    ),
  checkInboundsConfig: async () =>
    callBaseMethod<Podkop.InboundsConfigCheckResult>(
      Podkop.AvailableMethods.CHECK_INBOUNDS_CONFIG,
    ),
  getStatus: async () =>
    callBaseMethod<Podkop.GetStatus>(Podkop.AvailableMethods.GET_STATUS),
  getOutboundLink: async (section: string, tag: string) =>
    callBaseMethod<Podkop.GetOutboundLink>(
      Podkop.AvailableMethods.GET_OUTBOUND_LINK,
      [section, tag],
    ),
  getOutboundLinkStates: async (section: string) =>
    callBaseMethod<Podkop.GetOutboundLinkStates>(
      Podkop.AvailableMethods.GET_OUTBOUND_LINK_STATES,
      [section],
    ),
  getOutboundMetadata: async (section: string) =>
    callBaseMethod<Podkop.GetOutboundMetadata>(
      Podkop.AvailableMethods.GET_OUTBOUND_METADATA,
      [section],
    ),
  getSubscriptionMetadata: async (section: string) =>
    callBaseMethod<Podkop.SubscriptionMetadata | Podkop.SubscriptionMetadata[]>(
      Podkop.AvailableMethods.GET_SUBSCRIPTION_METADATA,
      [section],
    ),
  checkSingBox: async () =>
    callBaseMethod<Podkop.SingBoxCheckResult>(
      Podkop.AvailableMethods.CHECK_SING_BOX,
    ),
  checkInbounds: async () =>
    callBaseMethod<Podkop.InboundsCheckResult>(
      Podkop.AvailableMethods.CHECK_INBOUNDS,
    ),
  getSingBoxStatus: async () =>
    callBaseMethod<Podkop.GetSingBoxStatus>(
      Podkop.AvailableMethods.GET_SING_BOX_STATUS,
    ),
  getZapretStatus: async () =>
    callBaseMethod<Podkop.GetZapretStatus>(
      Podkop.AvailableMethods.GET_ZAPRET_STATUS,
    ),
  getZapret2Status: async () =>
    callBaseMethod<Podkop.GetZapret2Status>(
      Podkop.AvailableMethods.GET_ZAPRET2_STATUS,
    ),
  getByedpiStatus: async () =>
    callBaseMethod<Podkop.GetByedpiStatus>(
      Podkop.AvailableMethods.GET_BYEDPI_STATUS,
    ),
  getClashApiProxies: async () =>
    callBaseMethod<ClashAPI.Proxies>(Podkop.AvailableMethods.CLASH_API, [
      Podkop.AvailableClashAPIMethods.GET_PROXIES,
    ]),
  getClashApiConnections: async () =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.CLASH_API, [
      Podkop.AvailableClashAPIMethods.GET_CONNECTIONS,
    ]),
  getClashApiProxyLatency: async (tag: string) =>
    callBaseMethod<Podkop.GetClashApiProxyLatency>(
      Podkop.AvailableMethods.CLASH_API,
      [Podkop.AvailableClashAPIMethods.GET_PROXY_LATENCY, tag, '5000'],
    ),
  getClashApiGroupLatency: async (tag: string) =>
    callBaseMethod<Podkop.GetClashApiGroupLatency>(
      Podkop.AvailableMethods.CLASH_API,
      [Podkop.AvailableClashAPIMethods.GET_GROUP_LATENCY, tag, '10000'],
    ),
  setClashApiGroupProxy: async (group: string, proxy: string) =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.CLASH_API, [
      Podkop.AvailableClashAPIMethods.SET_GROUP_PROXY,
      group,
      proxy,
    ]),
  closeClashApiConnection: async (connectionId: string) =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.CLASH_API, [
      Podkop.AvailableClashAPIMethods.CLOSE_CONNECTION,
      connectionId,
    ]),
  closeAllClashApiConnections: async () =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.CLASH_API, [
      Podkop.AvailableClashAPIMethods.CLOSE_ALL_CONNECTIONS,
    ]),
  restart: async () =>
    callBaseMethod<unknown>(
      Podkop.AvailableMethods.RESTART,
      [],
      '/etc/init.d/podkop-plus',
    ),
  start: async () =>
    callBaseMethod<unknown>(
      Podkop.AvailableMethods.START,
      [],
      '/etc/init.d/podkop-plus',
    ),
  stop: async () =>
    callBaseMethod<unknown>(
      Podkop.AvailableMethods.STOP,
      [],
      '/etc/init.d/podkop-plus',
    ),
  enable: async () =>
    callBaseMethod<unknown>(
      Podkop.AvailableMethods.ENABLE,
      [],
      '/etc/init.d/podkop-plus',
    ),
  disable: async () =>
    callBaseMethod<unknown>(
      Podkop.AvailableMethods.DISABLE,
      [],
      '/etc/init.d/podkop-plus',
    ),
  globalCheck: async () =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.GLOBAL_CHECK),
  showSingBoxConfig: async () =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.SHOW_SING_BOX_CONFIG),
  checkLogs: async () =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.CHECK_LOGS),
  checkSingBoxLogs: async () =>
    callBaseMethod<unknown>(Podkop.AvailableMethods.CHECK_SING_BOX_LOGS),
  getSystemInfo: async () =>
    callBaseMethod<Podkop.GetSystemInfo>(
      Podkop.AvailableMethods.GET_SYSTEM_INFO,
    ),
  getServerCapabilities: async () =>
    callBaseMethod<Podkop.GetServerCapabilities>(
      Podkop.AvailableMethods.GET_SERVER_CAPABILITIES,
    ),
  getUiCapabilities: async () =>
    callBaseMethod<Podkop.GetUiCapabilities>(
      Podkop.AvailableMethods.GET_UI_CAPABILITIES,
    ),
  getUiState: async () =>
    callBaseMethod<Podkop.UiState>(Podkop.AvailableMethods.GET_UI_STATE),
  serviceActionStart: async (action: Podkop.ServiceAction) => {
    const response = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args: [Podkop.AvailableMethods.SERVICE_ACTION_ASYNC, action],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Service action failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Podkop.MethodSuccessResponse<Podkop.UiActionStartResult>;
  },
  serviceActionStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args: [Podkop.AvailableMethods.SERVICE_ACTION_STATUS, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseServiceActionState(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Service action failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Podkop.MethodSuccessResponse<Podkop.ServiceActionState>;
  },
  waitServiceActionJob: async (jobId: string, startedAt = Date.now()) => {
    while (Date.now() - startedAt < SERVICE_ACTION_TIMEOUT_MS) {
      await sleep(SERVICE_ACTION_POLL_INTERVAL_MS);

      const response = await PodkopShellMethods.serviceActionStatus(jobId);

      if (!response.success) {
        return response;
      }

      if (response.data.running) {
        continue;
      }

      return response;
    }

    return {
      success: false,
      error: _('Operation timed out'),
    } as Podkop.MethodFailureResponse;
  },
  serviceAction: async (action: Podkop.ServiceAction) => {
    const startResponse = await PodkopShellMethods.serviceActionStart(action);

    if (!startResponse.success) {
      return startResponse;
    }

    return PodkopShellMethods.waitServiceActionJob(
      startResponse.data.job_id,
    ).then((response) => {
      if (!response.success) {
        return response;
      }

      if (response.data.success === false) {
        return {
          success: false,
          error: response.data.message || _('Service action failed'),
        } as Podkop.MethodFailureResponse;
      }

      return response;
    });
  },
  latencyTestStart: async (
    latencyType: Podkop.LatencyActionState['latency_type'],
    section: string,
    tag: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args: [
        Podkop.AvailableMethods.LATENCY_TEST_ASYNC,
        latencyType,
        section,
        tag,
      ],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Latency test failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Podkop.MethodSuccessResponse<Podkop.UiActionStartResult>;
  },
  latencyTestStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args: [Podkop.AvailableMethods.LATENCY_TEST_STATUS, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseLatencyActionState(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Latency test failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Podkop.MethodSuccessResponse<Podkop.LatencyActionState>;
  },
  waitLatencyTestJob: async (jobId: string, startedAt = Date.now()) => {
    while (Date.now() - startedAt < LATENCY_TEST_TIMEOUT_MS) {
      await sleep(LATENCY_TEST_POLL_INTERVAL_MS);

      const response = await PodkopShellMethods.latencyTestStatus(jobId);

      if (!response.success) {
        return response;
      }

      if (response.data.running) {
        continue;
      }

      return response;
    }

    return {
      success: false,
      error: _('Operation timed out'),
    } as Podkop.MethodFailureResponse;
  },
  latencyTest: async (
    latencyType: Podkop.LatencyActionState['latency_type'],
    section: string,
    tag: string,
  ) => {
    const startResponse = await PodkopShellMethods.latencyTestStart(
      latencyType,
      section,
      tag,
    );

    if (!startResponse.success) {
      return startResponse;
    }

    return PodkopShellMethods.waitLatencyTestJob(startResponse.data.job_id);
  },
  uiActionAck: async (
    kind: 'service' | 'latency' | 'component' | 'subscription',
    jobId: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args: [Podkop.AvailableMethods.UI_ACTION_ACK, kind, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse?.success) {
      return uiActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Podkop.MethodSuccessResponse<Podkop.UiActionStartResult>;
  },
  componentActionStart: async (
    component: Podkop.ComponentName,
    action: Podkop.ComponentAction,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args: [Podkop.AvailableMethods.COMPONENT_ACTION_ASYNC, component, action],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseComponentActionStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return componentActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Podkop.MethodSuccessResponse<Podkop.ComponentActionStartResult>;
  },
  componentActionStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args: [Podkop.AvailableMethods.COMPONENT_ACTION_STATUS, jobId],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseComponentActionResult(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return componentActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Podkop.MethodSuccessResponse<Podkop.ComponentActionResult>;
  },
  waitComponentActionJob: async (
    jobId: string,
    component: Podkop.ComponentName,
    action: Podkop.ComponentAction,
    expectedLatestVersion?: string,
    startedAt = Date.now(),
  ) => {
    let selfUpdateVersionMatchedAt = 0;

    while (Date.now() - startedAt < COMPONENT_ACTION_TIMEOUT_MS) {
      await sleep(COMPONENT_ACTION_POLL_INTERVAL_MS);

      const stateResponse = await readComponentActionState(jobId);

      if (stateResponse) {
        if (stateResponse.running) {
          continue;
        }

        return {
          success: true,
          data: stateResponse,
        } as Podkop.MethodSuccessResponse<Podkop.ComponentActionResult>;
      }

      const statusResponse = await executeShellCommand({
        command: '/usr/bin/podkop-plus',
        args: [Podkop.AvailableMethods.COMPONENT_ACTION_STATUS, jobId],
        timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
      });
      const parsedResponse = parseComponentActionResult(statusResponse);

      if ((statusResponse.code ?? 0) !== 0 || !parsedResponse) {
        if (component === 'podkop' && action === 'install') {
          const installedVersion = expectedLatestVersion
            ? await readPodkopVersion()
            : '';

          if (
            expectedLatestVersion &&
            installedVersion === expectedLatestVersion
          ) {
            if (!selfUpdateVersionMatchedAt) {
              selfUpdateVersionMatchedAt = Date.now();
            }

            if (
              Date.now() - selfUpdateVersionMatchedAt >=
              COMPONENT_ACTION_SELF_UPDATE_SETTLE_MS
            ) {
              return {
                success: true,
                data: {
                  success: true,
                  component,
                  action,
                  message: _('Podkop Plus has been installed'),
                  current_version: installedVersion,
                  latest_version: expectedLatestVersion,
                  changed: true,
                  status: 'latest',
                },
              } as Podkop.MethodSuccessResponse<Podkop.ComponentActionResult>;
            }
          }

          continue;
        }

        return componentActionFailure(statusResponse);
      }

      if (parsedResponse.running) {
        continue;
      }

      return {
        success: true,
        data: parsedResponse,
      } as Podkop.MethodSuccessResponse<Podkop.ComponentActionResult>;
    }

    return {
      success: false,
      error: _('Operation timed out'),
    } as Podkop.MethodFailureResponse;
  },
  componentAction: async (
    component: Podkop.ComponentName,
    action: Podkop.ComponentAction,
    expectedLatestVersion?: string,
  ) => {
    const startResponse = await PodkopShellMethods.componentActionStart(
      component,
      action,
    );

    if (!startResponse.success) {
      return startResponse;
    }

    return PodkopShellMethods.waitComponentActionJob(
      startResponse.data.job_id,
      component,
      action,
      expectedLatestVersion,
    ).then((response) => {
      if (!response.success) {
        return response;
      }

      if (response.data.success === false) {
        return {
          success: false,
          error: response.data.message || _('Failed to execute'),
        } as Podkop.MethodFailureResponse;
      }

      return response;
    });
  },
  subscriptionUpdateStart: async (section?: string, sourceIndex?: number) => {
    const startArgs = [
      Podkop.AvailableMethods.SUBSCRIPTION_UPDATE_ASYNC,
      ...(section ? [section] : []),
      ...(section && sourceIndex !== undefined ? [String(sourceIndex)] : []),
    ];
    const response = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args: startArgs,
      timeout: SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseSubscriptionUpdateStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return {
        success: false,
        error:
          parsedResponse?.message ||
          response.stderr ||
          _('Subscription update failed'),
      } as Podkop.MethodFailureResponse;
    }

    return {
      success: true,
      data: parsedResponse,
    } as Podkop.MethodSuccessResponse<Podkop.SubscriptionUpdateStartResult>;
  },
  subscriptionUpdateStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args: [Podkop.AvailableMethods.SUBSCRIPTION_UPDATE_STATUS, jobId],
      timeout: SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseSubscriptionUpdateJobState(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return {
        success: false,
        error: response.stderr || _('Subscription update failed'),
      } as Podkop.MethodFailureResponse;
    }

    return {
      success: true,
      data: parsedResponse,
    } as Podkop.MethodSuccessResponse<Podkop.SubscriptionUpdateJobState>;
  },
  waitSubscriptionUpdateJob: async (jobId: string, startedAt = Date.now()) => {
    while (Date.now() - startedAt < SUBSCRIPTION_UPDATE_TIMEOUT_MS) {
      await sleep(SUBSCRIPTION_UPDATE_POLL_INTERVAL_MS);

      const response = await PodkopShellMethods.subscriptionUpdateStatus(jobId);

      if (!response.success) {
        return response;
      }

      if (response.data.running) {
        continue;
      }

      return response;
    }

    return {
      success: false,
      error: _('Operation timed out'),
    } as Podkop.MethodFailureResponse;
  },
  subscriptionUpdate: async (section?: string, sourceIndex?: number) => {
    const startResponse = await PodkopShellMethods.subscriptionUpdateStart(
      section,
      sourceIndex,
    );

    if (!startResponse.success) {
      return startResponse;
    }

    const response = await PodkopShellMethods.waitSubscriptionUpdateJob(
      startResponse.data.job_id,
    );

    if (!response.success) {
      return response;
    }

    if (response.data.success === false) {
      return {
        success: false,
        error: response.data.message || _('Subscription update failed'),
      } as Podkop.MethodFailureResponse;
    }

    return {
      success: true,
      data:
        response.data.message ||
        startResponse.data.message ||
        _('Subscription update completed'),
    } as Podkop.MethodSuccessResponse<string>;
  },
};
