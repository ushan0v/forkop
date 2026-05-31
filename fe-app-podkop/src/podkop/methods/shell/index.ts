import { callBaseMethod } from './callBaseMethod';
import { ClashAPI, Podkop } from '../../types';
import { executeShellCommand } from '../../../helpers';

const SUBSCRIPTION_UPDATE_TIMEOUT_MS = 10 * 60 * 1000;
const SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS = 15000;
const SUBSCRIPTION_UPDATE_POLL_INTERVAL_MS = 1500;
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
  componentAction: async (
    component: Podkop.ComponentName,
    action: Podkop.ComponentAction,
    expectedLatestVersion?: string,
  ) => {
    const startedAt = Date.now();
    let selfUpdateVersionMatchedAt = 0;
    const startResponse = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args: [Podkop.AvailableMethods.COMPONENT_ACTION_ASYNC, component, action],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });

    const parsedStartResponse = parseComponentActionStartResult(startResponse);

    if (
      (startResponse.code ?? 0) !== 0 ||
      !parsedStartResponse?.success ||
      !parsedStartResponse.job_id
    ) {
      return componentActionFailure(startResponse, parsedStartResponse);
    }

    const jobId = parsedStartResponse.job_id;

    while (Date.now() - startedAt < COMPONENT_ACTION_TIMEOUT_MS) {
      await sleep(COMPONENT_ACTION_POLL_INTERVAL_MS);

      const stateResponse = await readComponentActionState(jobId);

      if (stateResponse) {
        if (stateResponse.success === false) {
          return {
            success: false,
            error: stateResponse.message || _('Failed to execute'),
          } as Podkop.MethodFailureResponse;
        }

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

      if (parsedResponse?.success === false) {
        return componentActionFailure(statusResponse, parsedResponse);
      }

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
  subscriptionUpdate: async (section?: string, sourceIndex?: number) => {
    const startedAt = Date.now();
    const startArgs = [
      Podkop.AvailableMethods.SUBSCRIPTION_UPDATE_ASYNC,
      ...(section ? [section] : []),
      ...(section && sourceIndex !== undefined ? [String(sourceIndex)] : []),
    ];
    const startResponse = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args: startArgs,
      timeout: SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS,
    });
    const parsedStartResponse =
      parseSubscriptionUpdateStartResult(startResponse);

    if (
      (startResponse.code ?? 0) !== 0 ||
      !parsedStartResponse?.success ||
      !parsedStartResponse.job_id
    ) {
      return {
        success: false,
        error:
          parsedStartResponse?.message ||
          startResponse.stderr ||
          _('Subscription update failed'),
      } as Podkop.MethodFailureResponse;
    }

    while (Date.now() - startedAt < SUBSCRIPTION_UPDATE_TIMEOUT_MS) {
      await sleep(SUBSCRIPTION_UPDATE_POLL_INTERVAL_MS);

      const statusResponse = await executeShellCommand({
        command: '/usr/bin/podkop-plus',
        args: [
          Podkop.AvailableMethods.SUBSCRIPTION_UPDATE_STATUS,
          parsedStartResponse.job_id,
        ],
        timeout: SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS,
      });
      const stateResponse = parseSubscriptionUpdateJobState(statusResponse);

      if (!stateResponse) {
        if ((statusResponse.code ?? 0) !== 0) {
          return {
            success: false,
            error: statusResponse.stderr || _('Subscription update failed'),
          } as Podkop.MethodFailureResponse;
        }

        continue;
      }

      if (stateResponse.running) {
        continue;
      }

      if (stateResponse.success === false) {
        return {
          success: false,
          error: stateResponse.message || _('Subscription update failed'),
        } as Podkop.MethodFailureResponse;
      }

      return {
        success: true,
        data:
          stateResponse.message ||
          parsedStartResponse.message ||
          _('Subscription update completed'),
      } as Podkop.MethodSuccessResponse<string>;
    }

    return {
      success: false,
      error: _('Operation timed out'),
    } as Podkop.MethodFailureResponse;
  },
};
