import { callBaseMethod } from './callBaseMethod';
import { ClashAPI, Nexroute } from '../../types';
import { executeShellCommand } from '../../../helpers';
import { isTransientRpcError } from '../../helpers/isTransientRpcError';

const SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS = 15000;
const SUBSCRIPTION_UPDATE_POLL_INTERVAL_MS = 1500;
const UI_ACTION_RPC_TIMEOUT_MS = 15000;
const UI_ACTION_TRANSIENT_RPC_GRACE_MS = 30000;
const SERVICE_ACTION_TIMEOUT_MS = 2 * 60 * 1000;
const SERVICE_ACTION_POLL_INTERVAL_MS = 1000;
const LATENCY_TEST_TIMEOUT_MS = 30 * 1000;
const LATENCY_TEST_POLL_INTERVAL_MS = 1000;
const COMPONENT_ACTION_RPC_TIMEOUT_MS = 15000;
const COMPONENT_ACTION_POLL_INTERVAL_MS = 1500;
const COMPONENT_ACTION_STATUS_REFRESH_INTERVAL_MS = 15000;
const COMPONENT_ACTION_SELF_UPDATE_SETTLE_MS = 30000;
const COMPONENT_ACTION_TRANSIENT_RPC_GRACE_MS = 30000;
const COMPONENT_ACTION_STATE_DIR = '/var/run/nexroute/component-actions';
const GET_UI_STATE_RPC_TIMEOUT_MS = 3000;

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

function translate(message: string) {
  return typeof _ === 'function' ? _(message) : message;
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
  return parseJsonObjectOutput<Nexroute.ComponentActionResult>(output);
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

  return parsedResponse as unknown as Nexroute.ComponentActionStartResult;
}

function parseSubscriptionUpdateStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Nexroute.SubscriptionUpdateStartResult>(
    response.stdout,
  );
}

function parseSubscriptionUpdateJobState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Nexroute.SubscriptionUpdateJobState>(
    response.stdout,
  );
}

function parseUiActionStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Nexroute.UiActionStartResult>(response.stdout);
}

function parseServiceActionState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Nexroute.ServiceActionState>(response.stdout);
}

function parseLatencyActionState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Nexroute.LatencyActionState>(response.stdout);
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

async function readNexrouteVersion() {
  const response = await executeShellCommand({
    command: '/usr/bin/nexroute',
    args: ['show_version'],
    timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
  });

  if ((response.code ?? 0) !== 0 || !response.stdout) {
    return '';
  }

  return response.stdout.trim();
}

async function isComponentActionStillRunning(
  jobId: string,
  component: Nexroute.ComponentName,
  action: Nexroute.ComponentAction,
) {
  const response = await callBaseMethod<Nexroute.UiState>(
    Nexroute.AvailableMethods.GET_UI_STATE,
    [],
    '/usr/bin/nexroute',
    { timeout: GET_UI_STATE_RPC_TIMEOUT_MS },
  );

  return (
    response.success &&
    response.data.actions.component.some(
      (state) =>
        state.job_id === jobId &&
        state.component === component &&
        state.action === action &&
        state.running === true,
    )
  );
}

function componentActionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse?: Pick<Nexroute.ComponentActionResult, 'message'> | null,
) {
  return {
    success: false,
    error: parsedResponse?.message || response.stderr || _('Failed to execute'),
  } as Nexroute.MethodFailureResponse;
}

function uiActionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse?: { message?: string } | null,
  fallback: string = _('Failed to execute'),
) {
  return {
    success: false,
    error: parsedResponse?.message || response.stderr || fallback,
  } as Nexroute.MethodFailureResponse;
}

function createTransientRpcGraceTracker(graceMs: number) {
  let failureStartedAt = 0;

  return {
    reset() {
      failureStartedAt = 0;
    },
    shouldContinue(error?: string) {
      if (!isTransientRpcError(error)) {
        failureStartedAt = 0;
        return false;
      }

      if (!failureStartedAt) {
        failureStartedAt = Date.now();
      }

      return Date.now() - failureStartedAt < graceMs;
    },
  };
}

export const NexrouteShellMethods = {
  checkDNSAvailable: async () =>
    callBaseMethod<Nexroute.DnsCheckResult>(
      Nexroute.AvailableMethods.CHECK_DNS_AVAILABLE,
    ),
  checkFakeIP: async () =>
    callBaseMethod<Nexroute.FakeIPCheckResult>(
      Nexroute.AvailableMethods.CHECK_FAKEIP,
    ),
  checkNftRules: async () =>
    callBaseMethod<Nexroute.NftRulesCheckResult>(
      Nexroute.AvailableMethods.CHECK_NFT_RULES,
    ),
  checkZapretRuntime: async () =>
    callBaseMethod<Nexroute.ZapretCheckResult>(
      Nexroute.AvailableMethods.CHECK_ZAPRET_RUNTIME,
    ),
  checkZapret2Runtime: async () =>
    callBaseMethod<Nexroute.Zapret2CheckResult>(
      Nexroute.AvailableMethods.CHECK_ZAPRET2_RUNTIME,
    ),
  checkByedpiRuntime: async () =>
    callBaseMethod<Nexroute.ByedpiCheckResult>(
      Nexroute.AvailableMethods.CHECK_BYEDPI_RUNTIME,
    ),
  checkInboundsConfig: async () =>
    callBaseMethod<Nexroute.InboundsConfigCheckResult>(
      Nexroute.AvailableMethods.CHECK_INBOUNDS_CONFIG,
    ),
  getStatus: async () =>
    callBaseMethod<Nexroute.GetStatus>(Nexroute.AvailableMethods.GET_STATUS),
  getOutboundMetadata: async (section: string) =>
    callBaseMethod<Nexroute.GetOutboundMetadata>(
      Nexroute.AvailableMethods.GET_OUTBOUND_METADATA,
      [section],
    ),
  getSubscriptionMetadata: async (section: string) =>
    callBaseMethod<
      Nexroute.SubscriptionMetadata | Nexroute.SubscriptionMetadata[]
    >(Nexroute.AvailableMethods.GET_SUBSCRIPTION_METADATA, [section]),
  checkSingBox: async () =>
    callBaseMethod<Nexroute.SingBoxCheckResult>(
      Nexroute.AvailableMethods.CHECK_SING_BOX,
    ),
  checkInbounds: async () =>
    callBaseMethod<Nexroute.InboundsCheckResult>(
      Nexroute.AvailableMethods.CHECK_INBOUNDS,
    ),
  getSingBoxStatus: async () =>
    callBaseMethod<Nexroute.GetSingBoxStatus>(
      Nexroute.AvailableMethods.GET_SING_BOX_STATUS,
    ),
  getZapretStatus: async () =>
    callBaseMethod<Nexroute.GetZapretStatus>(
      Nexroute.AvailableMethods.GET_ZAPRET_STATUS,
    ),
  getZapret2Status: async () =>
    callBaseMethod<Nexroute.GetZapret2Status>(
      Nexroute.AvailableMethods.GET_ZAPRET2_STATUS,
    ),
  getByedpiStatus: async () =>
    callBaseMethod<Nexroute.GetByedpiStatus>(
      Nexroute.AvailableMethods.GET_BYEDPI_STATUS,
    ),
  getClashApiProxies: async () =>
    callBaseMethod<ClashAPI.Proxies>(Nexroute.AvailableMethods.CLASH_API, [
      Nexroute.AvailableClashAPIMethods.GET_PROXIES,
    ]),
  getClashApiConnections: async () =>
    callBaseMethod<unknown>(Nexroute.AvailableMethods.CLASH_API, [
      Nexroute.AvailableClashAPIMethods.GET_CONNECTIONS,
    ]),
  getClashApiProxyLatency: async (tag: string, timeout = '5000') =>
    callBaseMethod<Nexroute.GetClashApiProxyLatency>(
      Nexroute.AvailableMethods.CLASH_API,
      [Nexroute.AvailableClashAPIMethods.GET_PROXY_LATENCY, tag, timeout],
    ),
  getClashApiProxyLatencies: async (tags: string[]) =>
    callBaseMethod<Nexroute.GetClashApiProxyLatencies>(
      Nexroute.AvailableMethods.CLASH_API,
      [
        Nexroute.AvailableClashAPIMethods.GET_PROXY_LATENCIES,
        JSON.stringify(tags),
        '5000',
      ],
    ),
  getClashApiGroupLatency: async (tag: string) =>
    callBaseMethod<Nexroute.GetClashApiGroupLatency>(
      Nexroute.AvailableMethods.CLASH_API,
      [Nexroute.AvailableClashAPIMethods.GET_GROUP_LATENCY, tag, '10000'],
    ),
  setClashApiGroupProxy: async (group: string, proxy: string) =>
    callBaseMethod<unknown>(Nexroute.AvailableMethods.CLASH_API, [
      Nexroute.AvailableClashAPIMethods.SET_GROUP_PROXY,
      group,
      proxy,
    ]),
  closeClashApiConnection: async (connectionId: string) =>
    callBaseMethod<unknown>(Nexroute.AvailableMethods.CLASH_API, [
      Nexroute.AvailableClashAPIMethods.CLOSE_CONNECTION,
      connectionId,
    ]),
  closeAllClashApiConnections: async () =>
    callBaseMethod<unknown>(Nexroute.AvailableMethods.CLASH_API, [
      Nexroute.AvailableClashAPIMethods.CLOSE_ALL_CONNECTIONS,
    ]),
  enable: async () =>
    callBaseMethod<unknown>(
      Nexroute.AvailableMethods.ENABLE,
      [],
      '/etc/init.d/nexroute',
    ),
  disable: async () =>
    callBaseMethod<unknown>(
      Nexroute.AvailableMethods.DISABLE,
      [],
      '/etc/init.d/nexroute',
    ),
  globalCheck: async (masked = true) =>
    callBaseMethod<unknown>(Nexroute.AvailableMethods.GLOBAL_CHECK, [
      masked ? 'masked' : 'raw',
    ]),
  showSingBoxConfig: async (masked = true) =>
    callBaseMethod<unknown>(Nexroute.AvailableMethods.SHOW_SING_BOX_CONFIG, [
      masked ? 'masked' : 'raw',
    ]),
  checkLogs: async () =>
    callBaseMethod<unknown>(Nexroute.AvailableMethods.CHECK_LOGS),
  checkSingBoxLogs: async () =>
    callBaseMethod<unknown>(Nexroute.AvailableMethods.CHECK_SING_BOX_LOGS),
  getSystemInfo: async () =>
    callBaseMethod<Nexroute.GetSystemInfo>(
      Nexroute.AvailableMethods.GET_SYSTEM_INFO,
    ),
  getServerCapabilities: async () =>
    callBaseMethod<Nexroute.GetServerCapabilities>(
      Nexroute.AvailableMethods.GET_SERVER_CAPABILITIES,
    ),
  getUiCapabilities: async () =>
    callBaseMethod<Nexroute.GetUiCapabilities>(
      Nexroute.AvailableMethods.GET_UI_CAPABILITIES,
    ),
  getUiState: async () =>
    callBaseMethod<Nexroute.UiState>(
      Nexroute.AvailableMethods.GET_UI_STATE,
      [],
      '/usr/bin/nexroute',
      { timeout: GET_UI_STATE_RPC_TIMEOUT_MS },
    ),
  serviceActionStart: async (action: Nexroute.ServiceAction) => {
    const response = await executeShellCommand({
      command: '/usr/bin/nexroute',
      args: [Nexroute.AvailableMethods.SERVICE_ACTION_ASYNC, action],
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
    } as Nexroute.MethodSuccessResponse<Nexroute.UiActionStartResult>;
  },
  serviceActionStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/nexroute',
      args: [Nexroute.AvailableMethods.SERVICE_ACTION_STATUS, jobId],
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
    } as Nexroute.MethodSuccessResponse<Nexroute.ServiceActionState>;
  },
  waitServiceActionJob: async (jobId: string, startedAt = Date.now()) => {
    while (Date.now() - startedAt < SERVICE_ACTION_TIMEOUT_MS) {
      await sleep(SERVICE_ACTION_POLL_INTERVAL_MS);

      const response = await NexrouteShellMethods.serviceActionStatus(jobId);

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
    } as Nexroute.MethodFailureResponse;
  },
  latencyTestStart: async (
    latencyType: Nexroute.LatencyActionState['latency_type'],
    section: string,
    tag: string,
    timeout?: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/nexroute',
      args: [
        Nexroute.AvailableMethods.LATENCY_TEST_ASYNC,
        latencyType,
        section,
        tag,
        ...(timeout ? [timeout] : []),
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
    } as Nexroute.MethodSuccessResponse<Nexroute.UiActionStartResult>;
  },
  latencyTestStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/nexroute',
      args: [Nexroute.AvailableMethods.LATENCY_TEST_STATUS, jobId],
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
    } as Nexroute.MethodSuccessResponse<Nexroute.LatencyActionState>;
  },
  waitLatencyTestJob: async (jobId: string, startedAt = Date.now()) => {
    const transientRpc = createTransientRpcGraceTracker(
      UI_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    while (Date.now() - startedAt < LATENCY_TEST_TIMEOUT_MS) {
      await sleep(LATENCY_TEST_POLL_INTERVAL_MS);

      const response = await NexrouteShellMethods.latencyTestStatus(jobId);

      if (!response.success) {
        if (transientRpc.shouldContinue(response.error)) {
          continue;
        }

        return response;
      }

      transientRpc.reset();
      if (response.data.running) {
        continue;
      }

      return response;
    }

    return {
      success: false,
      error: _('Operation timed out'),
    } as Nexroute.MethodFailureResponse;
  },
  uiActionAck: async (
    kind: 'service' | 'latency' | 'component' | 'subscription',
    jobId: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/nexroute',
      args: [Nexroute.AvailableMethods.UI_ACTION_ACK, kind, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse?.success) {
      return uiActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Nexroute.MethodSuccessResponse<Nexroute.UiActionStartResult>;
  },
  componentActionStart: async (
    component: Nexroute.ComponentName,
    action: Nexroute.ComponentAction,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/nexroute',
      args: [
        Nexroute.AvailableMethods.COMPONENT_ACTION_ASYNC,
        component,
        action,
      ],
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
    } as Nexroute.MethodSuccessResponse<Nexroute.ComponentActionStartResult>;
  },
  componentActionStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/nexroute',
      args: [Nexroute.AvailableMethods.COMPONENT_ACTION_STATUS, jobId],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseComponentActionResult(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return componentActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Nexroute.MethodSuccessResponse<Nexroute.ComponentActionResult>;
  },
  componentUpdateCheckCache: async () =>
    callBaseMethod<Nexroute.ComponentUpdateCheckCache>(
      Nexroute.AvailableMethods.COMPONENT_UPDATE_CHECK_CACHE,
    ),
  waitComponentActionJob: async (
    jobId: string,
    component: Nexroute.ComponentName,
    action: Nexroute.ComponentAction,
    expectedLatestVersion?: string,
  ) => {
    let selfUpdateVersionMatchedAt = 0;
    let lastStatusRefreshAt = 0;
    const transientRpc = createTransientRpcGraceTracker(
      COMPONENT_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    while (true) {
      await sleep(COMPONENT_ACTION_POLL_INTERVAL_MS);

      const stateResponse = await readComponentActionState(jobId);

      if (stateResponse) {
        if (!stateResponse.running) {
          transientRpc.reset();
          return {
            success: true,
            data: stateResponse,
          } as Nexroute.MethodSuccessResponse<Nexroute.ComponentActionResult>;
        }

        if (
          Date.now() - lastStatusRefreshAt <
          COMPONENT_ACTION_STATUS_REFRESH_INTERVAL_MS
        ) {
          continue;
        }
      }

      lastStatusRefreshAt = Date.now();
      const statusResponse = await executeShellCommand({
        command: '/usr/bin/nexroute',
        args: [Nexroute.AvailableMethods.COMPONENT_ACTION_STATUS, jobId],
        timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
      });
      const parsedResponse = parseComponentActionResult(statusResponse);

      if ((statusResponse.code ?? 0) !== 0 || !parsedResponse) {
        if (stateResponse?.running) {
          transientRpc.reset();
          continue;
        }

        if (await isComponentActionStillRunning(jobId, component, action)) {
          transientRpc.reset();
          continue;
        }

        const failure = componentActionFailure(statusResponse, parsedResponse);

        if (transientRpc.shouldContinue(failure.error)) {
          continue;
        }

        if (component === 'nexroute' && action === 'install') {
          const installedVersion = expectedLatestVersion
            ? await readNexrouteVersion()
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
                  message: translate('Nexroute has been installed'),
                  current_version: installedVersion,
                  latest_version: expectedLatestVersion,
                  changed: true,
                  status: 'latest',
                },
              } as Nexroute.MethodSuccessResponse<Nexroute.ComponentActionResult>;
            }
          }

          continue;
        }

        return failure;
      }

      transientRpc.reset();
      if (parsedResponse.running) {
        continue;
      }

      return {
        success: true,
        data: parsedResponse,
      } as Nexroute.MethodSuccessResponse<Nexroute.ComponentActionResult>;
    }
  },
  subscriptionUpdateStart: async (section?: string, sourceIndex?: number) => {
    const startArgs = [
      Nexroute.AvailableMethods.SUBSCRIPTION_UPDATE_ASYNC,
      ...(section ? [section] : []),
      ...(section && sourceIndex !== undefined ? [String(sourceIndex)] : []),
    ];
    const response = await executeShellCommand({
      command: '/usr/bin/nexroute',
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
      } as Nexroute.MethodFailureResponse;
    }

    return {
      success: true,
      data: parsedResponse,
    } as Nexroute.MethodSuccessResponse<Nexroute.SubscriptionUpdateStartResult>;
  },
  subscriptionUpdateStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/nexroute',
      args: [Nexroute.AvailableMethods.SUBSCRIPTION_UPDATE_STATUS, jobId],
      timeout: SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseSubscriptionUpdateJobState(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return {
        success: false,
        error: response.stderr || _('Subscription update failed'),
      } as Nexroute.MethodFailureResponse;
    }

    return {
      success: true,
      data: parsedResponse,
    } as Nexroute.MethodSuccessResponse<Nexroute.SubscriptionUpdateJobState>;
  },
  waitSubscriptionUpdateJob: async (jobId: string) => {
    const transientRpc = createTransientRpcGraceTracker(
      UI_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    while (true) {
      await sleep(SUBSCRIPTION_UPDATE_POLL_INTERVAL_MS);

      const response =
        await NexrouteShellMethods.subscriptionUpdateStatus(jobId);

      if (!response.success) {
        if (transientRpc.shouldContinue(response.error)) {
          continue;
        }

        return response;
      }

      transientRpc.reset();
      if (response.data.running) {
        continue;
      }

      return response;
    }
  },
};
