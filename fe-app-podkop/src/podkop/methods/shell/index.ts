import { callBaseMethod } from './callBaseMethod';
import { ClashAPI, Podkop } from '../../types';
import { executeShellCommand } from '../../../helpers';

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
  getSubscriptionMetadata: async (section: string) =>
    callBaseMethod<Podkop.SubscriptionMetadata | Podkop.SubscriptionMetadata[]>(
      Podkop.AvailableMethods.GET_SUBSCRIPTION_METADATA,
      [section],
    ),
  checkSingBox: async () =>
    callBaseMethod<Podkop.SingBoxCheckResult>(
      Podkop.AvailableMethods.CHECK_SING_BOX,
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
  subscriptionUpdate: async (section?: string, sourceIndex?: number) => {
    const args = [
      Podkop.AvailableMethods.SUBSCRIPTION_UPDATE,
      ...(section ? [section] : []),
      ...(section && sourceIndex ? [String(sourceIndex)] : []),
    ];
    const response = await executeShellCommand({
      command: '/usr/bin/podkop-plus',
      args,
      timeout: 120000,
    });

    if (response.stderr || (response.code && response.code !== 0)) {
      return {
        success: false,
        error: response.stderr || _('Subscription update failed'),
      } as Podkop.MethodFailureResponse;
    }

    return {
      success: true,
      data: response.stdout,
    } as Podkop.MethodSuccessResponse<string>;
  },
};
