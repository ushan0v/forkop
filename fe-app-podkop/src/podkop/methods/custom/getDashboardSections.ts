import { getConfigSections } from './getConfigSections';
import { ClashAPI, Podkop } from '../../types';
import {
  canUseDirectClashApi,
  getClashHttpUrl,
  getProxyUrlName,
  isCopyableProxyLink,
} from '../../../helpers';
import { getOutboundTagBySection } from '../../runtimeTags';
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

type DashboardSectionCache = {
  version?: number;
  section?: string;
  links?: Record<string, string>;
  linkRefs?: Record<string, unknown>;
  outboundMetadata?: Podkop.GetOutboundMetadata;
  urltestGroups?: Record<string, UrlTestCacheGroup>;
  subscriptionMetadata?:
    | Podkop.SubscriptionMetadata
    | Podkop.SubscriptionMetadata[];
};

type UrlTestCacheGroup = {
  displayName?: string;
  outbounds?: string[];
  url?: string;
  interval?: string;
  tolerance?: string | number;
  idle_timeout?: string;
  interrupt_exist_connections?: boolean;
};

const DASHBOARD_SECTION_CACHE_DIR = '/var/run/podkop-plus/section-cache';

function getDisplayName(section: Podkop.ConfigSection) {
  return section.label || section['.name'];
}

function getSectionAction(section: Podkop.ConfigSection) {
  return section.action || '';
}

function getSettingsSection(configSections: Podkop.ConfigSection[]) {
  return configSections.find((section) => section['.type'] === 'settings');
}

function getClashApiSecret(configSections: Podkop.ConfigSection[]) {
  return getSettingsSection(configSections)?.yacd_secret_key || '';
}

function canFetchClashApiDirectly() {
  return canUseDirectClashApi() && typeof fetch === 'function';
}

async function getClashApiProxies(
  configSections: Podkop.ConfigSection[],
): Promise<Podkop.MethodResponse<ClashAPI.Proxies>> {
  if (canFetchClashApiDirectly()) {
    const secret = getClashApiSecret(configSections);

    try {
      const response = await fetch(`${getClashHttpUrl()}/proxies`, {
        headers: secret ? { Authorization: `Bearer ${secret}` } : undefined,
      });

      if (response.ok) {
        return {
          success: true,
          data: (await response.json()) as ClashAPI.Proxies,
        };
      }
    } catch (_error) {
      // Fall back to rpcd below for controllers unavailable from the browser.
    }
  }

  return PodkopShellMethods.getClashApiProxies();
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
  return getListValues(section.selector_proxy_links);
}

function hasSubscriptionSources(section: Podkop.ConfigSection) {
  return getSubscriptionSourceCount(section) > 0;
}

function getSubscriptionSourceCount(section: Podkop.ConfigSection) {
  return getListValues(section.subscription_urls).length;
}

function isUrlTestEnabled(section: Podkop.ConfigSection) {
  return section.urltest_enabled === '1';
}

function shouldSortByLatency(section: Podkop.ConfigSection) {
  return section.sort_by_latency === '1';
}

function isUrlTestFilteringEnabled(section: Podkop.ConfigSection) {
  return ['exclude', 'include', 'mixed'].includes(
    section.urltest_filter_mode || 'disabled',
  );
}

function shouldHideFilteredUrlTestOutbounds(section: Podkop.ConfigSection) {
  return (
    isUrlTestEnabled(section) &&
    isUrlTestFilteringEnabled(section) &&
    section.urltest_hide_filtered_outbounds === '1'
  );
}

function shouldShowDetectedCountries(section: Podkop.ConfigSection) {
  return (
    isUrlTestEnabled(section) &&
    isUrlTestFilteringEnabled(section) &&
    section.detect_server_country === 'country_is'
  );
}

function shouldUseProxyGroup(section: Podkop.ConfigSection) {
  return (
    getManualProxyLinks(section).length > 0 || hasSubscriptionSources(section)
  );
}

function getSectionProxyConfigType(section: Podkop.ConfigSection) {
  if (hasSubscriptionSources(section)) {
    return 'subscription' as const;
  }

  if (isUrlTestEnabled(section) && shouldUseProxyGroup(section)) {
    return 'urltest' as const;
  }

  if (getManualProxyLinks(section).length > 0) {
    return 'selector' as const;
  }

  return undefined;
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
      getOutboundTagBySection(`${sectionName}-${index + 1}`),
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

function isSelectorOutbound(outbound: Podkop.Outbound) {
  return outbound.type?.toLowerCase() === 'selector';
}

function isUrlTestProxyEntry(entry?: ClashProxyEntry) {
  return entry?.value?.type?.toLowerCase() === 'urltest';
}

function getLatencySortValue(outbound: Podkop.Outbound) {
  const latency = Number(outbound.latency);

  return Number.isFinite(latency) && latency > 0
    ? latency
    : Number.POSITIVE_INFINITY;
}

function sortOutboundsForDashboard(
  outbounds: Podkop.Outbound[],
  options: { pinnedCode?: string; sortByLatency?: boolean } = {},
) {
  const pinnedCode = options.pinnedCode || '';
  const sortByLatency = options.sortByLatency === true;

  return outbounds
    .map((outbound, index) => ({ outbound, index }))
    .sort((left, right) => {
      const leftPinned = pinnedCode !== '' && left.outbound.code === pinnedCode;
      const rightPinned =
        pinnedCode !== '' && right.outbound.code === pinnedCode;

      if (leftPinned !== rightPinned) {
        return leftPinned ? -1 : 1;
      }

      if (sortByLatency) {
        const latencyDiff =
          getLatencySortValue(left.outbound) -
          getLatencySortValue(right.outbound);

        if (latencyDiff !== 0) {
          return latencyDiff;
        }
      }

      return left.index - right.index;
    })
    .map((item) => item.outbound);
}

function isSafeSectionName(sectionName: string) {
  return /^[A-Za-z0-9_-]+$/.test(sectionName);
}

function objectMap(value: unknown): Record<string, string> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }

  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .filter(([, item]) => typeof item === 'string')
      .map(([key, item]) => [key, item as string]),
  );
}

async function readDashboardSectionCache(
  sectionName: string,
): Promise<DashboardSectionCache | undefined> {
  if (!isSafeSectionName(sectionName)) {
    return undefined;
  }

  try {
    const raw = await fs.read(
      `${DASHBOARD_SECTION_CACHE_DIR}/${sectionName}.json`,
    );
    const parsed = JSON.parse(raw) as DashboardSectionCache;

    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return undefined;
    }

    return parsed;
  } catch (_error) {
    return undefined;
  }
}

function getUrlTestGroups(dashboardCache?: DashboardSectionCache) {
  const groups = dashboardCache?.urltestGroups;

  if (!groups || typeof groups !== 'object' || Array.isArray(groups)) {
    return {};
  }

  return groups;
}

function getOutboundDisplayName(
  code: string,
  entry: ClashProxyEntry | undefined,
  link: string,
  outboundMetadata?: Podkop.GetOutboundMetadata,
) {
  return (
    getProxyUrlName(link) ||
    outboundMetadata?.names?.[code] ||
    entry?.value?.name ||
    code
  );
}

function buildUrlTestInfo({
  code,
  displayName,
  entry,
  groupCache,
  proxyByCode,
  manualLinkByCode,
  outboundMetadata,
  subscriptionCopyableCodes,
  showDetectedCountries,
}: {
  code: string;
  displayName: string;
  entry: ClashProxyEntry;
  groupCache?: UrlTestCacheGroup;
  proxyByCode: Map<string, ClashProxyEntry>;
  manualLinkByCode: Map<string, string>;
  outboundMetadata?: Podkop.GetOutboundMetadata;
  subscriptionCopyableCodes: Set<string>;
  showDetectedCountries: boolean;
}): Podkop.UrlTestInfo {
  const childCodes = uniqueCodes(
    groupCache?.outbounds?.length
      ? groupCache.outbounds
      : entry.value.all || [],
  );
  const selectedCode = entry.value.now || '';
  const outbounds = childCodes.flatMap((childCode) => {
    const childEntry = proxyByCode.get(childCode);
    const link = manualLinkByCode.get(childCode) || '';
    const canCopyLink =
      isCopyableProxyLink(link) || subscriptionCopyableCodes.has(childCode);

    return [
      {
        code: childCode,
        displayName: getOutboundDisplayName(
          childCode,
          childEntry,
          link,
          outboundMetadata,
        ),
        latency: childEntry?.value?.history?.[0]?.delay || 0,
        type: childEntry?.value?.type || '',
        selected: selectedCode === childCode,
        link,
        canCopyLink,
        country: showDetectedCountries
          ? outboundMetadata?.countries?.[childCode]
          : undefined,
      },
    ];
  });
  const selectedName =
    outbounds.find((outbound) => outbound.code === selectedCode)?.displayName ||
    selectedCode;

  return {
    code,
    displayName: groupCache?.displayName || displayName,
    selectedCode: selectedCode || undefined,
    selectedName: selectedName || undefined,
    url: groupCache?.url,
    interval: groupCache?.interval,
    tolerance: groupCache?.tolerance,
    idleTimeout: groupCache?.idle_timeout,
    interruptExistConnections: groupCache?.interrupt_exist_connections,
    outbounds,
  };
}

function buildProxyGroupOutbounds(
  section: Podkop.ConfigSection,
  proxies: ClashProxyEntry[],
  outboundMetadata?: Podkop.GetOutboundMetadata,
  urltestGroups: Record<string, UrlTestCacheGroup> = {},
  subscriptionCopyableCodes: Set<string> = new Set(),
) {
  const sectionName = section['.name'];
  const proxyByCode = getProxyEntryByCode(proxies);
  const selectorTag = getOutboundTagBySection(sectionName);
  const urltestTag = getOutboundTagBySection(`${sectionName}-urltest`);
  const selector = proxyByCode.get(selectorTag);
  const fallbackUrltest = proxyByCode.get(urltestTag);
  const manualLinkByCode = buildManualLinkByCode(section);
  const selectorCodes = selector?.value?.all ?? [];
  const urltestCodes = fallbackUrltest?.value?.all ?? [];
  const urltestCodeSet = new Set(urltestCodes);
  const showDetectedCountries = shouldShowDetectedCountries(section);
  const hideFilteredUrlTestOutbounds =
    shouldHideFilteredUrlTestOutbounds(section) &&
    Boolean(fallbackUrltest?.code) &&
    urltestCodes.length > 0;
  const builtInUrltestCode = fallbackUrltest?.code || '';
  const fallbackCodes = [builtInUrltestCode, ...urltestCodes];
  const groupCodes = hideFilteredUrlTestOutbounds
    ? (selectorCodes.length ? selectorCodes : fallbackCodes).filter((code) => {
        if (code === builtInUrltestCode || urltestCodeSet.has(code)) {
          return true;
        }

        return isUrlTestProxyEntry(proxyByCode.get(code));
      })
    : selectorCodes.length
      ? selectorCodes
      : fallbackCodes;

  const outbounds = uniqueCodes(groupCodes).flatMap((code) => {
    const item = proxyByCode.get(code);
    if (!item) {
      return [];
    }

    const isFastest = item.code === urltestTag;
    const link = manualLinkByCode.get(item.code) || '';
    const canCopyLink =
      isCopyableProxyLink(link) || subscriptionCopyableCodes.has(item.code);
    const displayName = isFastest
      ? _('Fastest')
      : getOutboundDisplayName(item.code, item, link, outboundMetadata);

    return [
      {
        code: item.code,
        displayName,
        latency: item.value.history?.[0]?.delay || 0,
        type: item.value.type || '',
        selected: selector?.value?.now === item.code,
        link,
        canCopyLink,
        country: showDetectedCountries
          ? outboundMetadata?.countries?.[item.code]
          : undefined,
        urlTestInfo: isUrlTestProxyEntry(item)
          ? buildUrlTestInfo({
              code: item.code,
              displayName,
              entry: item,
              groupCache: urltestGroups[item.code],
              proxyByCode,
              manualLinkByCode,
              outboundMetadata,
              subscriptionCopyableCodes,
              showDetectedCountries,
            })
          : undefined,
      },
    ];
  });

  const sortedOutbounds = sortOutboundsForDashboard(outbounds, {
    pinnedCode: isUrlTestEnabled(section) ? builtInUrltestCode : '',
    sortByLatency: shouldSortByLatency(section),
  });
  const latencyTestCodes = sortedOutbounds
    .filter((outbound) => !isSelectorOutbound(outbound))
    .map((outbound) => outbound.code);

  return {
    selector,
    latencyTestCode: hideFilteredUrlTestOutbounds
      ? fallbackUrltest?.code
      : selector?.code,
    latencyTestCodes:
      latencyTestCodes.length > 0 ? latencyTestCodes : undefined,
    outbounds: sortedOutbounds,
  };
}

function metadataMatchesCurrentSource(
  sectionName: string,
  sourceCount: number,
  metadata: Podkop.SubscriptionMetadata,
) {
  const legacyMetadata = metadata as Podkop.SubscriptionMetadata & {
    source_index?: number;
    source_section?: string;
  };
  const sourceIndex = metadata.sourceIndex ?? legacyMetadata.source_index;
  const sourceSection =
    metadata.sourceSection || legacyMetadata.source_section || '';
  const hasSourceIndex = typeof sourceIndex === 'number';
  const hasSourceSection = sourceSection !== '';

  if (!hasSourceIndex && !hasSourceSection) {
    return sourceCount <= 1;
  }

  if (sourceCount > 1 && !hasSourceSection) {
    return false;
  }

  if (hasSourceIndex && (sourceIndex < 1 || sourceIndex > sourceCount)) {
    return false;
  }

  if (hasSourceSection) {
    const expectedSourcePrefix = `${sectionName}-subscription-`;

    if (!sourceSection.startsWith(expectedSourcePrefix)) {
      return false;
    }

    const sourceSectionIndex = Number(
      sourceSection.slice(expectedSourcePrefix.length),
    );

    if (
      !Number.isInteger(sourceSectionIndex) ||
      sourceSectionIndex < 1 ||
      sourceSectionIndex > sourceCount
    ) {
      return false;
    }

    if (hasSourceIndex && sourceIndex !== sourceSectionIndex) {
      return false;
    }
  }

  return true;
}

function getSubscriptionMetadata(
  sectionName: string,
  sourceCount: number,
  dashboardCache?: DashboardSectionCache,
) {
  if (!dashboardCache?.subscriptionMetadata) {
    return undefined;
  }

  const metadataItems = Array.isArray(dashboardCache.subscriptionMetadata)
    ? dashboardCache.subscriptionMetadata
    : [dashboardCache.subscriptionMetadata];
  const visibleMetadataItems = metadataItems.filter(
    (metadata) =>
      metadata &&
      Object.keys(metadata).length > 1 &&
      metadataMatchesCurrentSource(sectionName, sourceCount, metadata),
  );

  if (visibleMetadataItems.length > 0) {
    return visibleMetadataItems;
  }

  return undefined;
}

function getOutboundMetadata(dashboardCache?: DashboardSectionCache) {
  const metadata = dashboardCache?.outboundMetadata;

  if (!metadata || typeof metadata !== 'object') {
    return undefined;
  }

  return {
    names: objectMap(metadata.names),
    countries: objectMap(metadata.countries),
  };
}

function getSubscriptionCopyableCodes(dashboardCache?: DashboardSectionCache) {
  const legacyLinks = objectMap(dashboardCache?.links);
  const linkRefs = dashboardCache?.linkRefs;
  const codes = new Set(
    Object.entries(legacyLinks)
      .filter(([, link]) => isCopyableProxyLink(link))
      .map(([code]) => code),
  );

  if (linkRefs && typeof linkRefs === 'object' && !Array.isArray(linkRefs)) {
    Object.keys(linkRefs).forEach((code) => codes.add(code));
  }

  return codes;
}

export async function getDashboardSections(
  options: IGetDashboardSectionsOptions = {},
): Promise<IGetDashboardSectionsResponse> {
  const includeSubscriptionCopyState =
    options.includeSubscriptionCopyState ?? true;
  const configSections = await getConfigSections();
  const clashProxies = await getClashApiProxies(configSections);

  if (!clashProxies.success || !clashProxies.data?.proxies) {
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
          ['proxy', 'outbound', 'vpn'].includes(getSectionAction(section)),
      )
      .map(async (section) => {
        const displayName = getDisplayName(section);
        const sectionName = section['.name'];
        const sectionAction = getSectionAction(section);
        const proxyConfigType = getSectionProxyConfigType(section);

        if (sectionAction === 'vpn') {
          const outboundTag = getOutboundTagBySection(sectionName);
          const outbound = proxies.find((proxy) => proxy.code === outboundTag);

          return {
            withTagSelect: false,
            code: outbound?.code || sectionName,
            sectionName,
            displayName,
            action: sectionAction,
            latencyTestTimeout: '10000',
            outbounds: [
              {
                code: outbound?.code || sectionName,
                displayName: section.interface || outbound?.value?.name || '',
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
                canCopyLink: false,
                runtimeAvailable: Boolean(outbound),
              },
            ],
          };
        }

        if (sectionAction === 'outbound') {
          const outboundTag = getOutboundTagBySection(sectionName);
          const outbound = proxies.find((proxy) => proxy.code === outboundTag);

          return {
            withTagSelect: false,
            code: outbound?.code || sectionName,
            sectionName,
            displayName,
            action: sectionAction,
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

        if (sectionAction === 'proxy' && shouldUseProxyGroup(section)) {
          const subscriptionSourceCount = getSubscriptionSourceCount(section);
          const subscriptionEnabled = subscriptionSourceCount > 0;
          const dashboardCache = await readDashboardSectionCache(sectionName);
          const outboundMetadata = getOutboundMetadata(dashboardCache);
          const subscriptionMetadata = subscriptionEnabled
            ? getSubscriptionMetadata(
                sectionName,
                subscriptionSourceCount,
                dashboardCache,
              )
            : undefined;
          const subscriptionCopyableCodes = includeSubscriptionCopyState
            ? getSubscriptionCopyableCodes(dashboardCache)
            : new Set<string>();
          const urltestGroups = getUrlTestGroups(dashboardCache);
          const { selector, latencyTestCode, latencyTestCodes, outbounds } =
            buildProxyGroupOutbounds(
              section,
              proxies,
              outboundMetadata,
              urltestGroups,
              subscriptionCopyableCodes,
            );

          return {
            withTagSelect: true,
            code: selector?.code || sectionName,
            sectionName,
            displayName,
            action: sectionAction,
            latencyTestCode,
            latencyTestCodes,
            proxyConfigType,
            subscriptionSourceCount,
            subscriptionMetadata,
            outbounds,
          };
        }

        return {
          withTagSelect: false,
          code: sectionName,
          sectionName,
          displayName,
          action: sectionAction,
          outbounds: [],
        };
      }),
  );

  return {
    success: true,
    data,
  };
}
