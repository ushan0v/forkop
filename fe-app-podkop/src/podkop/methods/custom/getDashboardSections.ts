import { getConfigSections } from './getConfigSections';
import { ClashAPI, Podkop } from '../../types';
import { getProxyUrlName, isCopyableProxyLink } from '../../../helpers';
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
  subscriptionMetadata?:
    | Podkop.SubscriptionMetadata
    | Podkop.SubscriptionMetadata[];
};

const DASHBOARD_SECTION_CACHE_DIR = '/var/run/podkop-plus/section-cache';

function getDisplayName(section: Podkop.ConfigSection) {
  return section.label || section['.name'];
}

function getSectionAction(section: Podkop.ConfigSection) {
  return section.action || '';
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

function buildProxyGroupOutbounds(
  section: Podkop.ConfigSection,
  proxies: ClashProxyEntry[],
  outboundMetadata?: Podkop.GetOutboundMetadata,
  subscriptionCopyableCodes: Set<string> = new Set(),
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
    const canCopyLink =
      isCopyableProxyLink(link) || subscriptionCopyableCodes.has(item.code);

    return [
      {
        code: item.code,
        displayName: isFastest
          ? _('Fastest')
          : getProxyUrlName(link) ||
            outboundMetadata?.names?.[item.code] ||
            item.value.name ||
            item.code,
        latency: item.value.history?.[0]?.delay || 0,
        type: item.value.type || '',
        selected: selector?.value?.now === item.code,
        link,
        canCopyLink,
        country: outboundMetadata?.countries?.[item.code],
      },
    ];
  });

  return {
    selector,
    outbounds: sortUrlTestFirst(outbounds),
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
  const clashProxies = await PodkopShellMethods.getClashApiProxies();

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
          const { selector, outbounds } = buildProxyGroupOutbounds(
            section,
            proxies,
            outboundMetadata,
            subscriptionCopyableCodes,
          );

          return {
            withTagSelect: true,
            code: selector?.code || sectionName,
            sectionName,
            displayName,
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
          outbounds: [],
        };
      }),
  );

  return {
    success: true,
    data,
  };
}
