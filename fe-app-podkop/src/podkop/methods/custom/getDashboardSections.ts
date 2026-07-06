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

type ItemSettingsValue = string | string[] | undefined;
type ItemSettings = Record<string, ItemSettingsValue>;

type UrlTestConfig = {
  id: string;
  code: string;
  displayName: string;
  settings: ItemSettings;
  pinDashboard: boolean;
  hideAddedOutbounds: boolean;
  showDetectedCountries: boolean;
};

type ChildType =
  | 'connection_url'
  | 'subscription_url'
  | 'section_interface'
  | 'urltest';

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

function childSections(
  configSections: Podkop.ConfigSection[],
  type: ChildType,
) {
  return configSections.filter((section) => section['.type'] === type);
}

function ownedChildSections(
  parent: Podkop.ConfigSection,
  children: Podkop.ConfigSection[],
) {
  return children.filter(
    (section): section is Podkop.ConfigSection =>
      section.section === parent['.name'],
  );
}

function compactSettingsMap(settings: Record<string, ItemSettings>) {
  return Object.keys(settings).length ? JSON.stringify(settings) : undefined;
}

function hydrateConfigSections(configSections: Podkop.ConfigSection[]) {
  const connectionUrls = childSections(configSections, 'connection_url');
  const subscriptionUrls = childSections(
    configSections,
    'subscription_url',
  );
  const interfaces = childSections(configSections, 'section_interface');
  const urltests = childSections(configSections, 'urltest');

  return configSections.map((section) => {
    if (section['.type'] !== 'section') {
      return section;
    }

    const next: Podkop.ConfigSection = { ...section };
    const connectionUrlItems = ownedChildSections(next, connectionUrls);
    const subscriptionUrlItems = ownedChildSections(next, subscriptionUrls);
    const interfaceItems = ownedChildSections(next, interfaces);
    const urltestItems = ownedChildSections(next, urltests);

    if (connectionUrlItems.length) {
      const settings: Record<string, ItemSettings> = {};
      next.selector_proxy_links = connectionUrlItems
        .map((item) => item.url || '')
        .filter(Boolean);
      connectionUrlItems.forEach((item) => {
        if (!item.url) {
          return;
        }
        settings[item.url] = {
          outbound_detour_enabled: item.outbound_detour_enabled,
          outbound_detour_section: item.outbound_detour_section,
          enable_udp_over_tcp: item.enable_udp_over_tcp,
        };
      });
      next.connection_url_settings = compactSettingsMap(settings);
    }

    if (subscriptionUrlItems.length) {
      const settings: Record<string, ItemSettings> = {};
      next.subscription_urls = subscriptionUrlItems
        .map((item) => item.url || '')
        .filter(Boolean);
      subscriptionUrlItems.forEach((item) => {
        if (!item.url) {
          return;
        }
        settings[item.url] = {
          subscription_update_enabled: item.subscription_update_enabled,
          subscription_update_interval: item.subscription_update_interval,
          download_via_proxy_enabled: item.download_via_proxy_enabled,
          download_via_proxy_section: item.download_via_proxy_section,
          auto_user_agent: item.auto_user_agent,
          user_agent: item.user_agent,
          auto_hwid: item.auto_hwid,
          hwid: item.hwid,
          show_dashboard_metadata: item.show_dashboard_metadata,
          include_urltest_groups: item.include_urltest_groups,
          hide_urltest_group_outbounds: item.hide_urltest_group_outbounds,
          hide_detour_outbounds: item.hide_detour_outbounds,
        };
      });
      next.subscription_url_settings = compactSettingsMap(settings);
    }

    if (interfaceItems.length) {
      const settings: Record<string, ItemSettings> = {};
      next.interfaces = interfaceItems
        .map((item) => item.name || '')
        .filter(Boolean);
      interfaceItems.forEach((item) => {
        if (!item.name) {
          return;
        }
        settings[item.name] = {
          domain_resolver_enabled: item.domain_resolver_enabled,
          domain_resolver_dns_type: item.domain_resolver_dns_type,
          domain_resolver_dns_server: item.domain_resolver_dns_server,
        };
      });
      next.interface_settings = compactSettingsMap(settings);
    }

    if (urltestItems.length) {
      const settings: Record<string, ItemSettings> = {};
      next.urltests = urltestItems.map((item) => item['.name']);
      urltestItems.forEach((item) => {
        settings[item['.name']] = {
          display_name: item.name || item.display_name,
          urltest_check_interval: item.check_interval,
          urltest_tolerance: item.tolerance,
          urltest_testing_url: item.testing_url,
          idle_timeout: item.idle_timeout,
          interrupt_exist_connections: item.interrupt_exist_connections,
          pin_dashboard: item.pin_dashboard,
          hide_added_outbounds: item.hide_added_outbounds,
          urltest_filter_mode: item.filter_mode,
          detect_server_country: item.detect_server_country,
          urltest_include_countries: item.include_countries,
          urltest_include_outbounds: item.include_outbounds,
          urltest_include_regex: item.include_regex,
          urltest_exclude_countries: item.exclude_countries,
          urltest_exclude_outbounds: item.exclude_outbounds,
          urltest_exclude_regex: item.exclude_regex,
        };
      });
      next.urltest_settings = compactSettingsMap(settings);
    }

    return next;
  });
}

function getManualProxyLinks(section: Podkop.ConfigSection) {
  return getListValues(section.selector_proxy_links);
}

function getConnectionInterfaces(section: Podkop.ConfigSection) {
  const values = getListValues(section.interfaces);
  return values.length ? values : getListValues(section.interface);
}

function getJsonOutbounds(section: Podkop.ConfigSection) {
  const values = getListValues(section.outbound_jsons);
  return values.length ? values : getListValues(section.outbound_json);
}

function isConnectionAction(action: string) {
  return ['connection', 'proxy', 'outbound', 'vpn'].includes(action);
}

function hasSubscriptionSources(section: Podkop.ConfigSection) {
  return getSubscriptionSourceCount(section) > 0;
}

function getSubscriptionSourceCount(section: Podkop.ConfigSection) {
  return getListValues(section.subscription_urls).length;
}

function shouldSortByLatency(section: Podkop.ConfigSection) {
  return section.sort_by_latency === '1';
}

function hasConfiguredUrlTestList(section: Podkop.ConfigSection) {
  return getListValues(section.urltests).length > 0;
}

function getUrlTestIds(section: Podkop.ConfigSection) {
  const values = getListValues(section.urltests);
  return values.length
    ? values
    : section.urltest_enabled === '1'
      ? ['urltest']
      : [];
}

function isUrlTestEnabled(section: Podkop.ConfigSection) {
  return getUrlTestIds(section).length > 0;
}

function shouldUseProxyGroup(section: Podkop.ConfigSection) {
  return (
    getManualProxyLinks(section).length > 0 ||
    hasSubscriptionSources(section) ||
    getConnectionInterfaces(section).length > 0 ||
    getJsonOutbounds(section).length > 0
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

  if (getJsonOutbounds(section).length > 0) {
    return 'outbound' as const;
  }

  if (getConnectionInterfaces(section).length > 0) {
    return 'interface' as const;
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

function getLatencySortValue(outbound: { latency: number }) {
  const latency = Number(outbound.latency);

  return Number.isFinite(latency) && latency > 0
    ? latency
    : Number.POSITIVE_INFINITY;
}

function sortOutboundsForDashboard(
  outbounds: Podkop.Outbound[],
  options: {
    pinnedCode?: string;
    pinnedCodes?: string[];
    sortByLatency?: boolean;
  } = {},
) {
  const pinnedCodes = [
    ...(options.pinnedCode ? [options.pinnedCode] : []),
    ...(options.pinnedCodes || []),
  ].filter(Boolean);
  const pinnedRank = new Map(
    pinnedCodes.map((code, index) => [code, index] as const),
  );
  const sortByLatency = options.sortByLatency === true;

  return outbounds
    .map((outbound, index) => ({ outbound, index }))
    .sort((left, right) => {
      const leftPinned = pinnedRank.has(left.outbound.code);
      const rightPinned = pinnedRank.has(right.outbound.code);

      if (leftPinned !== rightPinned) {
        return leftPinned ? -1 : 1;
      }

      if (leftPinned && rightPinned) {
        const rankDiff =
          (pinnedRank.get(left.outbound.code) ?? 0) -
          (pinnedRank.get(right.outbound.code) ?? 0);

        if (rankDiff !== 0) {
          return rankDiff;
        }
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

function sortUrlTestMembers(outbounds: Podkop.UrlTestMember[]) {
  return outbounds
    .map((outbound, index) => ({ outbound, index }))
    .sort((left, right) => {
      if (left.outbound.selected !== right.outbound.selected) {
        return left.outbound.selected ? -1 : 1;
      }

      const latencyDiff =
        getLatencySortValue(left.outbound) -
        getLatencySortValue(right.outbound);

      if (latencyDiff !== 0) {
        return latencyDiff;
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

function itemSettingsMap(value?: string): Record<string, ItemSettings> {
  if (!value) {
    return {};
  }

  try {
    const parsed = JSON.parse(value) as unknown;

    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return {};
    }

    return Object.fromEntries(
      Object.entries(parsed as Record<string, unknown>).filter(
        ([, item]) => item && typeof item === 'object' && !Array.isArray(item),
      ),
    ) as Record<string, ItemSettings>;
  } catch (_error) {
    return {};
  }
}

function itemSettingString(
  settings: ItemSettings | undefined,
  key: string,
  fallback = '',
) {
  const value = settings?.[key];
  return typeof value === 'string' ? value : fallback;
}

function itemSettingBoolean(
  settings: ItemSettings | undefined,
  key: string,
  fallback: boolean,
) {
  const value = settings?.[key];
  if (value === undefined || value === null || value === '') {
    return fallback;
  }

  return value === '1' || value === 'true';
}

function isUrlTestFilteringEnabled(settings: ItemSettings | undefined) {
  return ['exclude', 'include', 'mixed'].includes(
    itemSettingString(settings, 'urltest_filter_mode', 'disabled'),
  );
}

function getUrlTestTag(sectionName: string, id: string) {
  return getOutboundTagBySection(
    id === 'urltest'
      ? `${sectionName}-urltest`
      : `${sectionName}-urltest-${id}`,
  );
}

function getUrlTestDisplayName(
  section: Podkop.ConfigSection,
  id: string,
  settings: ItemSettings | undefined,
) {
  return itemSettingString(
    settings,
    'display_name',
    id === 'urltest' && !hasConfiguredUrlTestList(section) ? _('Fastest') : id,
  );
}

function getUrlTestConfigs(section: Podkop.ConfigSection): UrlTestConfig[] {
  const settingsMap = itemSettingsMap(section.urltest_settings);
  const sectionName = section['.name'];

  return getUrlTestIds(section).map((id) => {
    const settings = settingsMap[id] || {};
    const filteringEnabled = isUrlTestFilteringEnabled(settings);

    return {
      id,
      code: getUrlTestTag(sectionName, id),
      displayName: getUrlTestDisplayName(section, id, settings),
      settings,
      pinDashboard: itemSettingBoolean(settings, 'pin_dashboard', true),
      hideAddedOutbounds: itemSettingBoolean(
        settings,
        'hide_added_outbounds',
        false,
      ),
      showDetectedCountries:
        filteringEnabled &&
        itemSettingString(settings, 'detect_server_country', 'flag_emoji') ===
          'country_is',
    };
  });
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
  const outbounds = sortUrlTestMembers(
    childCodes.flatMap((childCode) => {
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
    }),
  );
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
    idleTimeout: groupCache?.idle_timeout || '30m',
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
  const selector = proxyByCode.get(selectorTag);
  const urlTestConfigs = getUrlTestConfigs(section);
  const urlTestConfigByCode = new Map(
    urlTestConfigs.map((config) => [config.code, config]),
  );
  const urlTestEntries = urlTestConfigs
    .map((config) => ({
      config,
      entry: proxyByCode.get(config.code),
    }))
    .filter((item): item is { config: UrlTestConfig; entry: ClashProxyEntry } =>
      Boolean(item.entry),
    );
  const manualLinkByCode = buildManualLinkByCode(section);
  const selectorCodes = selector?.value?.all ?? [];
  const urlTestCodes = urlTestEntries.map(({ config }) => config.code);
  const urlTestCodeSet = new Set(urlTestCodes);
  const hideAddedCodeSet = new Set<string>();
  urlTestEntries.forEach(({ config, entry }) => {
    if (!config.hideAddedOutbounds) {
      return;
    }

    (entry.value.all || []).forEach((code) => hideAddedCodeSet.add(code));
  });
  const showDetectedCountries = urlTestConfigs.some(
    (config) => config.showDetectedCountries,
  );
  const builtInUrltestCode = urlTestCodes[0] || '';
  const fallbackCodes = uniqueCodes([
    ...urlTestCodes,
    ...urlTestEntries.flatMap(({ entry }) => entry.value.all || []),
  ]);
  const groupCodes = (
    selectorCodes.length ? selectorCodes : fallbackCodes
  ).filter((code) => {
    if (!hideAddedCodeSet.has(code)) {
      return true;
    }

    return (
      urlTestCodeSet.has(code) || isUrlTestProxyEntry(proxyByCode.get(code))
    );
  });

  const outbounds = uniqueCodes(groupCodes).flatMap((code) => {
    const item = proxyByCode.get(code);
    if (!item) {
      return [];
    }

    const urlTestConfig = urlTestConfigByCode.get(item.code);
    const link = manualLinkByCode.get(item.code) || '';
    const canCopyLink =
      isCopyableProxyLink(link) || subscriptionCopyableCodes.has(item.code);
    const displayName =
      urlTestConfig?.displayName ||
      getOutboundDisplayName(item.code, item, link, outboundMetadata);

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
              showDetectedCountries:
                urlTestConfig?.showDetectedCountries || showDetectedCountries,
            })
          : undefined,
      },
    ];
  });

  const sortedOutbounds = sortOutboundsForDashboard(outbounds, {
    pinnedCodes: urlTestEntries
      .filter(({ config }) => config.pinDashboard)
      .map(({ config }) => config.code),
    sortByLatency: shouldSortByLatency(section),
  });
  const latencyTestCodes = sortedOutbounds
    .filter((outbound) => !isSelectorOutbound(outbound))
    .map((outbound) => outbound.code);

  return {
    selector,
    latencyTestCode: selector?.code || builtInUrltestCode,
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

function getSubscriptionMetadataSourceIndex(
  sectionName: string,
  sourceCount: number,
  metadata: Podkop.SubscriptionMetadata,
) {
  const legacyMetadata = metadata as Podkop.SubscriptionMetadata & {
    source_index?: number;
    source_section?: string;
  };
  const sourceIndex = metadata.sourceIndex ?? legacyMetadata.source_index;

  if (typeof sourceIndex === 'number') {
    return sourceIndex;
  }

  const sourceSection =
    metadata.sourceSection || legacyMetadata.source_section || '';
  const expectedSourcePrefix = `${sectionName}-subscription-`;

  if (sourceSection.startsWith(expectedSourcePrefix)) {
    const parsed = Number(sourceSection.slice(expectedSourcePrefix.length));
    return Number.isInteger(parsed) ? parsed : undefined;
  }

  return sourceCount <= 1 ? 1 : undefined;
}

function isSubscriptionMetadataVisible(
  section: Podkop.ConfigSection,
  sourceCount: number,
  metadata: Podkop.SubscriptionMetadata,
) {
  const sourceIndex = getSubscriptionMetadataSourceIndex(
    section['.name'],
    sourceCount,
    metadata,
  );

  if (!sourceIndex || sourceIndex < 1 || sourceIndex > sourceCount) {
    return true;
  }

  const sourceEntry = getListValues(section.subscription_urls)[sourceIndex - 1];
  const settings = itemSettingsMap(section.subscription_url_settings)[
    sourceEntry
  ];

  return settings?.show_dashboard_metadata !== '0';
}

function getSubscriptionMetadata(
  section: Podkop.ConfigSection,
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
      metadataMatchesCurrentSource(section['.name'], sourceCount, metadata) &&
      isSubscriptionMetadataVisible(section, sourceCount, metadata),
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
  const configSections = hydrateConfigSections(await getConfigSections());
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
          isConnectionAction(getSectionAction(section)),
      )
      .map(async (section) => {
        const displayName = getDisplayName(section);
        const sectionName = section['.name'];
        const sectionAction = getSectionAction(section);
        const proxyConfigType = getSectionProxyConfigType(section);

        if (isConnectionAction(sectionAction) && shouldUseProxyGroup(section)) {
          const subscriptionSourceCount = getSubscriptionSourceCount(section);
          const subscriptionEnabled = subscriptionSourceCount > 0;
          const dashboardCache = await readDashboardSectionCache(sectionName);
          const outboundMetadata = getOutboundMetadata(dashboardCache);
          const subscriptionMetadata = subscriptionEnabled
            ? getSubscriptionMetadata(
                section,
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
