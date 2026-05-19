import { getConfigSections } from './getConfigSections';
import { ClashAPI, Podkop } from '../../types';
import {
  getProxyUrlName,
  isCopyableProxyLink,
  isCopyableProxyOutboundType,
  splitProxyString,
} from '../../../helpers';
import { PodkopShellMethods } from '../shell';

interface IGetDashboardSectionsResponse {
  success: boolean;
  data: Podkop.OutboundGroup[];
}

interface IGetDashboardSectionsOptions {
  includeSubscriptionCopyState?: boolean;
}

type ClashProxyEntry = {
  code: string;
  value: ClashAPI.ProxyBase;
};

function getDisplayName(section: Podkop.ConfigSection) {
  return section.label || section['.name'];
}

function getSectionAction(section: Podkop.ConfigSection) {
  if (section.action) {
    if (section.action === 'proxy') {
      if (section.proxy_config_type === 'interface') {
        return 'vpn';
      }

      if (section.proxy_config_type === 'outbound') {
        return 'outbound';
      }
    }

    return section.action;
  }

  if (section.proxy_config_type === 'interface') {
    return 'vpn';
  }

  if (section.proxy_config_type === 'outbound') {
    return 'outbound';
  }

  switch (section.connection_type) {
    case 'proxy':
      return 'proxy';
    case 'vpn':
      return 'vpn';
    case 'block':
      return 'block';
    case 'exclusion':
      return 'direct';
    default:
      return '';
  }
}

function getListValues(value?: string[] | string) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value.map((item) => `${item}`.trim()).filter(Boolean);
  }

  return `${value}`
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function getManualProxyLinks(section: Podkop.ConfigSection) {
  const selectorLinks = getListValues(section.selector_proxy_links);
  if (selectorLinks.length > 0) {
    return selectorLinks;
  }

  const legacyUrltestLinks = getListValues(section.urltest_proxy_links);
  if (legacyUrltestLinks.length > 0) {
    return legacyUrltestLinks;
  }

  return splitProxyString(section.proxy_string || '');
}

function hasSubscriptionSources(section: Podkop.ConfigSection) {
  return getSubscriptionSourceCount(section) > 0;
}

function getSubscriptionSourceCount(section: Podkop.ConfigSection) {
  const subscriptionUrls = getListValues(section.subscription_urls);
  if (subscriptionUrls.length > 0) {
    return subscriptionUrls.length;
  }

  return (section.subscription_url || '').trim() ? 1 : 0;
}

function getConfiguredProxyConfigType(section: Podkop.ConfigSection) {
  if (!section.proxy_config_type || section.proxy_config_type === 'interface') {
    return undefined;
  }

  return section.proxy_config_type;
}

function isUrlTestEnabled(section: Podkop.ConfigSection) {
  if (section.urltest_enabled) {
    return section.urltest_enabled === '1';
  }

  if (section.urltest_check_interval_disabled === '1') {
    return false;
  }

  return ['urltest', 'subscription'].includes(
    getConfiguredProxyConfigType(section) || '',
  );
}

function shouldUseProxyGroup(section: Podkop.ConfigSection) {
  return (
    getManualProxyLinks(section).length > 0 || hasSubscriptionSources(section)
  );
}

function getSectionProxyConfigType(section: Podkop.ConfigSection) {
  const configuredType = getConfiguredProxyConfigType(section);

  if (configuredType === 'url' && !shouldUseProxyGroup(section)) {
    return configuredType;
  }

  if (hasSubscriptionSources(section)) {
    return 'subscription' as const;
  }

  if (isUrlTestEnabled(section) && shouldUseProxyGroup(section)) {
    return 'urltest' as const;
  }

  if (getManualProxyLinks(section).length > 0) {
    return 'selector' as const;
  }

  return configuredType;
}

function getJsonOutboundDisplayName(section: Podkop.ConfigSection) {
  try {
    const parsedOutbound = JSON.parse(section.outbound_json || '{}');
    return parsedOutbound?.tag ? decodeURIComponent(parsedOutbound.tag) : '';
  } catch (_error) {
    return '';
  }
}

function buildManualLinkByCode(section: Podkop.ConfigSection) {
  const sectionName = section['.name'];

  return new Map(
    getManualProxyLinks(section).map((link, index) => [
      `${sectionName}-${index + 1}-out`,
      link,
    ]),
  );
}

function getProxyEntryByCode(proxies: ClashProxyEntry[]) {
  return new Map(proxies.map((proxy) => [proxy.code, proxy]));
}

function uniqueCodes(codes: string[]) {
  return Array.from(new Set(codes.filter(Boolean)));
}

function isUrlTestOutbound(outbound: Podkop.Outbound) {
  return outbound.type?.toLowerCase() === 'urltest';
}

function sortUrlTestFirst(outbounds: Podkop.Outbound[]) {
  return [
    ...outbounds.filter(isUrlTestOutbound),
    ...outbounds.filter((outbound) => !isUrlTestOutbound(outbound)),
  ];
}

function buildProxyGroupOutbounds(
  section: Podkop.ConfigSection,
  proxies: ClashProxyEntry[],
) {
  const sectionName = section['.name'];
  const proxyByCode = getProxyEntryByCode(proxies);
  const selector = proxyByCode.get(`${sectionName}-out`);
  const fallbackUrltest = proxyByCode.get(`${sectionName}-urltest-out`);
  const manualLinkByCode = buildManualLinkByCode(section);
  const selectorCodes = selector?.value?.all ?? [];
  const groupCodes = selectorCodes.length
    ? selectorCodes
    : [fallbackUrltest?.code || '', ...(fallbackUrltest?.value?.all ?? [])];

  const outbounds = uniqueCodes(groupCodes).flatMap((code) => {
    const item = proxyByCode.get(code);
    if (!item) {
      return [];
    }

    const isFastest = item.code === `${sectionName}-urltest-out`;
    const link = manualLinkByCode.get(item.code) || '';

    return [
      {
        code: item.code,
        displayName: isFastest
          ? _('Fastest')
          : getProxyUrlName(link) || item.value.name || item.code,
        latency: item.value.history?.[0]?.delay || 0,
        type: item.value.type || '',
        selected: selector?.value?.now === item.code,
        link,
        canCopyLink: isCopyableProxyLink(link),
      },
    ];
  });

  return {
    selector,
    outbounds: sortUrlTestFirst(outbounds),
  };
}

const SUBSCRIPTION_LINK_CACHE_TTL_MS = 60 * 1000;
const subscriptionLinkCache = new Map<
  string,
  { canCopyLink: boolean; expiresAt: number }
>();

async function getSubscriptionOutboundLinkStates(sectionName: string) {
  const response = await PodkopShellMethods.getOutboundLinkStates(sectionName);

  if (response.success && response.data) {
    return response.data;
  }

  return {};
}

async function getSubscriptionOutboundCopyState(
  sectionName: string,
  outbound: Podkop.Outbound,
  linkStates?: Podkop.GetOutboundLinkStates,
) {
  if (!outbound.code) {
    return false;
  }

  if (
    linkStates &&
    Object.prototype.hasOwnProperty.call(linkStates, outbound.code)
  ) {
    return Boolean(linkStates[outbound.code]);
  }

  if (!isCopyableProxyOutboundType(outbound.type)) {
    return false;
  }

  const cacheKey = `${sectionName}:${outbound.code}`;
  const cached = subscriptionLinkCache.get(cacheKey);
  const now = Date.now();

  if (cached && cached.expiresAt > now) {
    return cached.canCopyLink;
  }

  const response = await PodkopShellMethods.getOutboundLink(
    sectionName,
    outbound.code,
  );
  const canCopyLink =
    response.success && isCopyableProxyLink(response.data.link);

  subscriptionLinkCache.set(cacheKey, {
    canCopyLink,
    expiresAt: now + SUBSCRIPTION_LINK_CACHE_TTL_MS,
  });

  return canCopyLink;
}

async function markSubscriptionCopyableOutbounds(
  sectionName: string,
  outbounds: Podkop.Outbound[],
  linkStates?: Podkop.GetOutboundLinkStates,
) {
  return Promise.all(
    outbounds.map(async (outbound) => ({
      ...outbound,
      canCopyLink:
        Boolean(outbound.canCopyLink) ||
        isCopyableProxyLink(outbound.link) ||
        (await getSubscriptionOutboundCopyState(
          sectionName,
          outbound,
          linkStates,
        )),
    })),
  );
}

async function getSubscriptionMetadata(sectionName: string) {
  const response =
    await PodkopShellMethods.getSubscriptionMetadata(sectionName);

  if (!response.success || !response.data) {
    return undefined;
  }

  const metadataItems = Array.isArray(response.data)
    ? response.data
    : [response.data];
  const visibleMetadataItems = metadataItems.filter(
    (metadata) => metadata && Object.keys(metadata).length > 1,
  );

  if (visibleMetadataItems.length > 0) {
    return visibleMetadataItems;
  }

  return undefined;
}

export async function getDashboardSections(
  options: IGetDashboardSectionsOptions = {},
): Promise<IGetDashboardSectionsResponse> {
  const includeSubscriptionCopyState =
    options.includeSubscriptionCopyState ?? true;
  const configSections = await getConfigSections();
  const clashProxies = await PodkopShellMethods.getClashApiProxies();

  if (!clashProxies.success) {
    return {
      success: false,
      data: [],
    };
  }

  const proxies = Object.entries(clashProxies.data.proxies).map(
    ([key, value]) => ({
      code: key,
      value,
    }),
  );
  const data = await Promise.all(
    configSections
      .filter(
        (section) =>
          section.enabled !== '0' &&
          ['proxy', 'outbound', 'vpn', 'byedpi'].includes(
            getSectionAction(section),
          ),
      )
      .map(async (section) => {
        const displayName = getDisplayName(section);
        const sectionName = section['.name'];
        const sectionAction = getSectionAction(section);
        const proxyConfigType = getSectionProxyConfigType(section);

        if (sectionAction === 'vpn') {
          const outbound = proxies.find(
            (proxy) => proxy.code === `${sectionName}-out`,
          );

          return {
            withTagSelect: false,
            code: outbound?.code || sectionName,
            sectionName,
            displayName,
            outbounds: [
              {
                code: outbound?.code || sectionName,
                displayName: section.interface || outbound?.value?.name || '',
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
                canCopyLink: false,
              },
            ],
          };
        }

        if (sectionAction === 'byedpi') {
          const outbound = proxies.find(
            (proxy) => proxy.code === `${sectionName}-out`,
          );

          return {
            withTagSelect: false,
            code: outbound?.code || sectionName,
            sectionName,
            displayName,
            outbounds: [
              {
                code: outbound?.code || sectionName,
                displayName: 'ByeDPI',
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
                canCopyLink: false,
              },
            ],
          };
        }

        if (sectionAction === 'outbound') {
          const outbound = proxies.find(
            (proxy) => proxy.code === `${sectionName}-out`,
          );

          return {
            withTagSelect: false,
            code: outbound?.code || sectionName,
            sectionName,
            displayName,
            outbounds: [
              {
                code: outbound?.code || sectionName,
                displayName:
                  getJsonOutboundDisplayName(section) ||
                  outbound?.value?.name ||
                  '',
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
                canCopyLink: false,
              },
            ],
          };
        }

        if (proxyConfigType === 'url' && !shouldUseProxyGroup(section)) {
          const outbound = proxies.find(
            (proxy) => proxy.code === `${sectionName}-out`,
          );

          const activeConfigs = splitProxyString(section.proxy_string || '');
          const link = activeConfigs?.[0] || '';
          const proxyDisplayName =
            getProxyUrlName(link) || outbound?.value?.name || '';

          return {
            withTagSelect: false,
            code: outbound?.code || sectionName,
            sectionName,
            displayName,
            outbounds: [
              {
                code: outbound?.code || sectionName,
                displayName: proxyDisplayName,
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
                link,
                canCopyLink: isCopyableProxyLink(link),
              },
            ],
          };
        }

        if (sectionAction === 'proxy' && shouldUseProxyGroup(section)) {
          const subscriptionSourceCount = getSubscriptionSourceCount(section);
          const subscriptionEnabled = subscriptionSourceCount > 0;
          const { selector, outbounds } = buildProxyGroupOutbounds(
            section,
            proxies,
          );
          const subscriptionMetadata = subscriptionEnabled
            ? await getSubscriptionMetadata(sectionName)
            : undefined;
          const outboundLinkStates = includeSubscriptionCopyState
            ? await getSubscriptionOutboundLinkStates(sectionName)
            : {};

          return {
            withTagSelect: true,
            code: selector?.code || sectionName,
            sectionName,
            displayName,
            proxyConfigType,
            subscriptionSourceCount,
            subscriptionMetadata,
            outbounds: includeSubscriptionCopyState
              ? await markSubscriptionCopyableOutbounds(
                  sectionName,
                  outbounds,
                  outboundLinkStates,
                )
              : outbounds,
          };
        }

        return {
          withTagSelect: false,
          code: sectionName,
          sectionName,
          displayName,
          outbounds: [],
        };
      }),
  );

  return {
    success: true,
    data,
  };
}
