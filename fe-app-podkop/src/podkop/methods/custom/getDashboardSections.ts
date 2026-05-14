import { getConfigSections } from './getConfigSections';
import { Podkop } from '../../types';
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

function getDisplayName(section: Podkop.ConfigSection) {
  return section.label || section['.name'];
}

function getSectionAction(section: Podkop.ConfigSection) {
  if (section.action) {
    if (
      section.action === 'proxy' &&
      section.proxy_config_type === 'interface'
    ) {
      return 'vpn';
    }

    return section.action;
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

function getSectionProxyConfigType(section: Podkop.ConfigSection) {
  if (section.proxy_config_type) {
    if (section.proxy_config_type === 'interface') {
      return undefined;
    }

    return section.proxy_config_type;
  }

  return undefined;
}

const SUBSCRIPTION_LINK_CACHE_TTL_MS = 60 * 1000;
const subscriptionLinkCache = new Map<
  string,
  { canCopyLink: boolean; expiresAt: number }
>();

async function getSubscriptionOutboundCopyState(
  sectionName: string,
  outbound: Podkop.Outbound,
) {
  if (!outbound.code || !isCopyableProxyOutboundType(outbound.type)) {
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
) {
  return Promise.all(
    outbounds.map(async (outbound) => ({
      ...outbound,
      canCopyLink: await getSubscriptionOutboundCopyState(
        sectionName,
        outbound,
      ),
    })),
  );
}

export async function getDashboardSections(): Promise<IGetDashboardSectionsResponse> {
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
          ['proxy', 'vpn'].includes(getSectionAction(section)),
      )
      .map(async (section) => {
        const displayName = getDisplayName(section);
        const sectionAction = getSectionAction(section);
        const proxyConfigType = getSectionProxyConfigType(section);

        if (sectionAction === 'vpn') {
          const outbound = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );

          return {
            withTagSelect: false,
            code: outbound?.code || section['.name'],
            sectionName: section['.name'],
            displayName,
            outbounds: [
              {
                code: outbound?.code || section['.name'],
                displayName: section.interface || outbound?.value?.name || '',
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
                canCopyLink: false,
              },
            ],
          };
        }

        if (proxyConfigType === 'url') {
          const outbound = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );

          const activeConfigs = splitProxyString(section.proxy_string || '');
          const link = activeConfigs?.[0] || '';
          const proxyDisplayName =
            getProxyUrlName(link) || outbound?.value?.name || '';

          return {
            withTagSelect: false,
            code: outbound?.code || section['.name'],
            sectionName: section['.name'],
            displayName,
            outbounds: [
              {
                code: outbound?.code || section['.name'],
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

        if (proxyConfigType === 'outbound') {
          const outbound = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );

          let parsedTag = '';
          try {
            const parsedOutbound = JSON.parse(section.outbound_json || '{}');
            parsedTag = parsedOutbound?.tag
              ? decodeURIComponent(parsedOutbound.tag)
              : '';
          } catch (_error) {
            parsedTag = '';
          }

          return {
            withTagSelect: false,
            code: outbound?.code || section['.name'],
            sectionName: section['.name'],
            displayName,
            outbounds: [
              {
                code: outbound?.code || section['.name'],
                displayName: parsedTag || outbound?.value?.name || '',
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
                canCopyLink: false,
              },
            ],
          };
        }

        if (proxyConfigType === 'selector') {
          const selector = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );

          const links = section.selector_proxy_links ?? [];

          const outbounds = links
            .map((link, index) => ({
              link,
              outbound: proxies.find(
                (item) => item.code === `${section['.name']}-${index + 1}-out`,
              ),
            }))
            .map((item) => {
              const link = item.link;

              return {
                code: item?.outbound?.code || '',
                displayName:
                  getProxyUrlName(link) || item?.outbound?.value?.name || '',
                latency: item?.outbound?.value?.history?.[0]?.delay || 0,
                type: item?.outbound?.value?.type || '',
                selected: selector?.value?.now === item?.outbound?.code,
                link,
                canCopyLink: isCopyableProxyLink(link),
              };
            });

          return {
            withTagSelect: true,
            code: selector?.code || section['.name'],
            sectionName: section['.name'],
            displayName,
            outbounds,
          };
        }

        if (proxyConfigType === 'urltest') {
          const selector = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );
          const outbound = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-urltest-out`,
          );

          const outbounds = (outbound?.value?.all ?? [])
            .map((code) => proxies.find((item) => item.code === code))
            .map((item, index) => {
              const link = section.urltest_proxy_links?.[index] || '';

              return {
                code: item?.code || '',
                displayName: getProxyUrlName(link) || item?.value?.name || '',
                latency: item?.value?.history?.[0]?.delay || 0,
                type: item?.value?.type || '',
                selected: selector?.value?.now === item?.code,
                link,
                canCopyLink: isCopyableProxyLink(link),
              };
            });

          return {
            withTagSelect: true,
            code: selector?.code || section['.name'],
            sectionName: section['.name'],
            displayName,
            outbounds: [
              {
                code: outbound?.code || '',
                displayName: _('Fastest'),
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: selector?.value?.now === outbound?.code,
                canCopyLink: false,
              },
              ...outbounds,
            ],
          };
        }

        if (proxyConfigType === 'subscription') {
          const selector = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-out`,
          );
          const fallbackUrltest = proxies.find(
            (proxy) => proxy.code === `${section['.name']}-urltest-out`,
          );

          const selectorOutbounds = (selector?.value?.all ?? []).flatMap(
            (code) => {
              const item = proxies.find((proxy) => proxy.code === code);
              if (!item) {
                return [];
              }

              const isDefaultFastest =
                item.code === `${section['.name']}-urltest-out`;

              return [
                {
                  code: item.code,
                  displayName: isDefaultFastest
                    ? _('Fastest')
                    : item?.value?.name || '',
                  latency: item?.value?.history?.[0]?.delay || 0,
                  type: item?.value?.type || '',
                  selected: selector?.value?.now === item.code,
                  canCopyLink: false,
                },
              ];
            },
          );

          const outbounds = [
            ...selectorOutbounds.filter(
              (item) => item.type?.toLowerCase() === 'urltest',
            ),
            ...selectorOutbounds.filter(
              (item) => item.type?.toLowerCase() !== 'urltest',
            ),
          ];

          if (outbounds.length === 0 && fallbackUrltest) {
            const fallbackOutbounds = (fallbackUrltest?.value?.all ?? [])
              .map((code) => proxies.find((item) => item.code === code))
              .map((item) => ({
                code: item?.code || '',
                displayName: item?.value?.name || '',
                latency: item?.value?.history?.[0]?.delay || 0,
                type: item?.value?.type || '',
                selected: selector?.value?.now === item?.code,
                canCopyLink: false,
              }));

            return {
              withTagSelect: true,
              code: selector?.code || section['.name'],
              sectionName: section['.name'],
              displayName,
              outbounds: [
                {
                  code: fallbackUrltest?.code || '',
                  displayName: _('Fastest'),
                  latency: fallbackUrltest?.value?.history?.[0]?.delay || 0,
                  type: fallbackUrltest?.value?.type || '',
                  selected: selector?.value?.now === fallbackUrltest?.code,
                  canCopyLink: false,
                },
                ...(await markSubscriptionCopyableOutbounds(
                  section['.name'],
                  fallbackOutbounds,
                )),
              ],
            };
          }

          return {
            withTagSelect: true,
            code: selector?.code || section['.name'],
            sectionName: section['.name'],
            displayName,
            outbounds: await markSubscriptionCopyableOutbounds(
              section['.name'],
              outbounds,
            ),
          };
        }

        return {
          withTagSelect: false,
          code: section['.name'],
          sectionName: section['.name'],
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
