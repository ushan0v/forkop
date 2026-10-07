import {
  renderLoaderCircleIcon24,
  renderCopyIcon24,
  renderLinkIcon24,
  renderInfoIcon24,
  renderClockIcon24,
} from '../../../../icons';
import { isCopyableProxyLink, svgEl } from '../../../../helpers';
import { prettyBytes } from '../../../../helpers/prettyBytes';
import { Forkop } from '../../../types';
import { ForkopShellMethods } from '../../../methods/shell';
import { renderFlagEmojis } from './renderFlagEmojis';

interface IRenderSectionsProps {
  loading: boolean;
  failed: boolean;
  section: Forkop.OutboundGroup;
  onTestLatency: (tag: string | string[]) => void;
  onChooseOutbound: (
    sectionName: string,
    selector: string,
    tag: string,
  ) => void;
  onCopyOutbound: (
    section: Forkop.OutboundGroup,
    outbound: Forkop.Outbound,
  ) => void;
  onShowUrlTestInfo: (outbound: Forkop.Outbound) => void;
  onShowPriorityInfo: (outbound: Forkop.Outbound) => void;
  onUpdateSubscription: (section: Forkop.OutboundGroup) => void;
  latencyFetching: boolean;
  latencyProgress?: Forkop.LatencyActionProgress;
  subscriptionUpdating: boolean;
  selectorSwitchingTag?: string;
}

function renderFailedState() {
  return E(
    'div',
    {
      class: 'fkp_dashboard-page__outbound-section centered',
      style: 'height: 127px',
    },
    E('span', {}, [E('span', {}, _('Dashboard currently unavailable'))]),
  );
}

function renderLoadingState() {
  return E('div', {
    id: 'dashboard-sections-grid-skeleton',
    class: 'fkp_dashboard-page__outbound-section skeleton',
    style: 'height: 127px',
  });
}

function isValidHttpUrl(url?: string) {
  return Boolean(url && /^https?:\/\/\S+$/i.test(url));
}

function formatBytes(value?: number) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    return undefined;
  }

  return prettyBytes(value);
}

function formatDate(seconds?: number) {
  if (
    typeof seconds !== 'number' ||
    !Number.isFinite(seconds) ||
    seconds <= 0
  ) {
    return undefined;
  }

  const date = new Date(seconds * 1000);
  if (Number.isNaN(date.getTime())) {
    return undefined;
  }

  return date.toLocaleDateString(undefined, {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
}

function renderMetadataAction(label: string, url?: string) {
  if (!isValidHttpUrl(url)) {
    return undefined;
  }

  return E(
    'a',
    {
      class: 'btn fkp_dashboard-page__subscription-meta__action',
      href: url,
      target: '_blank',
      rel: 'noopener noreferrer',
      title: label,
      'aria-label': label,
    },
    renderLinkIcon24(),
  );
}

function renderSubscriptionMetadata(
  metadata: Forkop.SubscriptionMetadata | undefined,
) {
  if (!metadata || Object.keys(metadata).length <= 1) {
    return undefined;
  }

  const title = metadata.title || metadata.fileName;
  const traffic = metadata.traffic;
  const used = formatBytes(traffic?.used) || '0 B';
  const total = traffic?.isUnlimited
    ? '∞'
    : formatBytes(traffic?.total) || '0 B';
  const expire = formatDate(metadata.expire);
  const refillDate = formatDate(metadata.refillDate);

  const rows = [
    traffic
      ? {
          label: _('Traffic'),
          value: `${used} / ${total}`,
        }
      : undefined,
    expire ? { label: _('Expires'), value: expire } : undefined,
    refillDate ? { label: _('Refill'), value: refillDate } : undefined,
  ].filter(Boolean) as { label: string; value: string }[];

  const actions = [
    renderMetadataAction('Profile', metadata.webPageUrl),
    renderMetadataAction('Support', metadata.supportUrl),
    renderMetadataAction('More details', metadata.announceUrl),
  ].filter(Boolean) as HTMLElement[];

  return E('div', { class: 'fkp_dashboard-page__subscription-meta' }, [
    E('div', { class: 'fkp_dashboard-page__subscription-meta__main' }, [
      E(
        'div',
        { class: 'fkp_dashboard-page__subscription-meta__heading' },
        _('Subscription info:'),
      ),
      title
        ? E(
            'div',
            { class: 'fkp_dashboard-page__subscription-meta__title' },
            title,
          )
        : '',
      rows.length
        ? E(
            'div',
            { class: 'fkp_dashboard-page__subscription-meta__facts' },
            rows.map((row) =>
              E(
                'div',
                { class: 'fkp_dashboard-page__subscription-meta__fact' },
                [
                  E(
                    'span',
                    {
                      class: 'fkp_dashboard-page__subscription-meta__fact-key',
                    },
                    row.label,
                  ),
                  E(
                    'span',
                    {
                      class:
                        'fkp_dashboard-page__subscription-meta__fact-value',
                    },
                    row.value,
                  ),
                ],
              ),
            ),
          )
        : '',
      actions.length
        ? E(
            'div',
            { class: 'fkp_dashboard-page__subscription-meta__actions' },
            actions,
          )
        : '',
    ]),
    metadata.announce
      ? E(
          'blockquote',
          { class: 'fkp_dashboard-page__subscription-meta__announce' },
          metadata.announce,
        )
      : '',
  ]);
}

function renderSubscriptionUpdateAction(
  section: Forkop.OutboundGroup,
  subscriptionUpdating: boolean,
  onUpdateSubscription: (section: Forkop.OutboundGroup) => void,
) {
  if (!section.subscriptionSourceCount) {
    return undefined;
  }

  return E(
    'button',
    {
      type: 'button',
      class: 'btn fkp_dashboard-page__outbound-section__subscription-update',
      'aria-label': _('Update subscriptions'),
      disabled: subscriptionUpdating ? true : undefined,
      click: (event: MouseEvent) => {
        event.preventDefault();
        event.stopPropagation();
        if (subscriptionUpdating) {
          return;
        }

        onUpdateSubscription(section);
      },
    },
    subscriptionUpdating
      ? [renderLoaderCircleIcon24(), _('Update subscriptions')]
      : _('Update subscriptions'),
  );
}

export function getLatencyTestLabel(
  latencyProgress?: Forkop.LatencyActionProgress,
) {
  const total = Math.trunc(Number(latencyProgress?.total ?? 0));
  if (!Number.isFinite(total) || total <= 0) {
    return _('Test latency');
  }

  const completedValue = Number(latencyProgress?.completed ?? 0);
  const completed = Number.isFinite(completedValue)
    ? Math.trunc(completedValue)
    : 0;

  return `${_('Test latency')}: ${Math.min(
    Math.max(0, completed),
    total,
  )}/${total}`;
}

function renderDefaultState({
  section,
  onChooseOutbound,
  onCopyOutbound,
  onShowUrlTestInfo,
  onShowPriorityInfo,
  onTestLatency,
  onUpdateSubscription,
  latencyFetching,
  latencyProgress,
  subscriptionUpdating,
  selectorSwitchingTag,
}: IRenderSectionsProps) {
  function testLatency() {
    if (section.withTagSelect) {
      return onTestLatency(
        section.latencyTestCodes?.length
          ? section.latencyTestCodes
          : section.latencyTestCode || section.code,
      );
    }

    if (section.outbounds.length) {
      return onTestLatency(section.outbounds[0].code);
    }
  }

  function renderOutbound(outbound: Forkop.Outbound, index = 0) {
    function getLatencyClass() {
      if (!outbound.latency) {
        return 'fkp_dashboard-page__outbound-grid__item__latency--empty';
      }

      if (outbound.latency < 800) {
        return 'fkp_dashboard-page__outbound-grid__item__latency--green';
      }

      if (outbound.latency < 1500) {
        return 'fkp_dashboard-page__outbound-grid__item__latency--yellow';
      }

      return 'fkp_dashboard-page__outbound-grid__item__latency--red';
    }

    let latencyBadge: HTMLElement | null = null;
    let pinging = false;

    const onSinglePing = async (event?: MouseEvent) => {
      if (event) {
        event.stopPropagation();
        event.preventDefault();
      }
      if (pinging || latencyFetching || !outbound.code) return;
      pinging = true;
      if (latencyBadge) {
        latencyBadge.className =
          'fkp_dashboard-page__outbound-grid__item__latency fkp_dashboard-page__outbound-grid__item__latency--empty fkp_dashboard-page__outbound-grid__item__latency--busy';
        latencyBadge.replaceChildren(
          E(
            'span',
            { style: 'display: inline-flex; width: 14px; height: 14px;' },
            [renderLoaderCircleIcon24()],
          ),
        );
      }
      try {
        const res = await ForkopShellMethods.getClashApiProxyLatency(
          outbound.code,
          '4000',
        );
        if (
          res &&
          res.success &&
          res.data &&
          typeof (res.data as { delay?: number }).delay === 'number' &&
          !(res.data as { message?: string }).message
        ) {
          outbound.latency = (res.data as { delay: number }).delay;
          if (latencyBadge) {
            latencyBadge.className = `fkp_dashboard-page__outbound-grid__item__latency ${getLatencyClass()}`;
            latencyBadge.textContent = `${outbound.latency}ms`;
          }
        } else {
          outbound.latency = 0;
          if (latencyBadge) {
            latencyBadge.className =
              'fkp_dashboard-page__outbound-grid__item__latency fkp_dashboard-page__outbound-grid__item__latency--empty';
            latencyBadge.textContent = 'N/A';
          }
        }
      } catch (_e) {
        outbound.latency = 0;
        if (latencyBadge) {
          latencyBadge.className =
            'fkp_dashboard-page__outbound-grid__item__latency fkp_dashboard-page__outbound-grid__item__latency--empty';
          latencyBadge.textContent = 'N/A';
        }
      } finally {
        pinging = false;
        if (latencyBadge && !latencyFetching) {
          latencyBadge.classList.remove(
            'fkp_dashboard-page__outbound-grid__item__latency--busy',
          );
        }
      }
    };

    const completedCount = Number(latencyProgress?.completed ?? 0);
    const hasFinished = Boolean(outbound.latency && outbound.latency > 0);
    const isPinging = Boolean(
      latencyFetching && !hasFinished && index < completedCount + 25,
    );
    const isQueued = Boolean(
      latencyFetching && !hasFinished && index >= completedCount + 25,
    );
    const isBusy = isPinging || isQueued || pinging;

    let badgeContent: string | HTMLElement[] = outbound.latency
      ? `${outbound.latency}ms`
      : 'N/A';
    if (isPinging) {
      badgeContent = [
        E(
          'span',
          { style: 'display: inline-flex; width: 14px; height: 14px;' },
          [renderLoaderCircleIcon24()],
        ),
      ];
    } else if (isQueued) {
      badgeContent = [
        E(
          'span',
          {
            style:
              'display: inline-flex; width: 14px; height: 14px; opacity: 0.5;',
          },
          [renderClockIcon24()],
        ),
      ];
    }

    const badgeClasses = [
      'fkp_dashboard-page__outbound-grid__item__latency',
      isBusy
        ? 'fkp_dashboard-page__outbound-grid__item__latency--empty'
        : getLatencyClass(),
      isBusy || latencyFetching
        ? 'fkp_dashboard-page__outbound-grid__item__latency--busy'
        : '',
    ]
      .filter(Boolean)
      .join(' ');

    latencyBadge = E(
      'div',
      {
        class: badgeClasses,
        title: isPinging
          ? _('Testing latency...')
          : isQueued
            ? _('In queue...')
            : latencyFetching
              ? _('Testing latency...')
              : _('Click to test latency'),
        click: onSinglePing,
      },
      badgeContent,
    );

    const canCopyLink =
      Boolean(outbound.canCopyLink) || isCopyableProxyLink(outbound.link);
    const selectorSwitching = Boolean(selectorSwitchingTag);
    const outboundSwitching = selectorSwitchingTag === outbound.code;
    const canChooseOutbound =
      section.withTagSelect &&
      outbound.runtimeAvailable !== false &&
      !selectorSwitching &&
      !outbound.selected;
    const className = [
      'fkp_dashboard-page__outbound-grid__item',
      outbound.selected
        ? 'fkp_dashboard-page__outbound-grid__item--active'
        : '',
      canChooseOutbound
        ? 'fkp_dashboard-page__outbound-grid__item--selectable'
        : '',
      section.withTagSelect && !canChooseOutbound
        ? 'fkp_dashboard-page__outbound-grid__item--disabled'
        : '',
      outboundSwitching
        ? 'fkp_dashboard-page__outbound-grid__item--switching'
        : '',
    ]
      .filter(Boolean)
      .join(' ');
    return E(
      'div',
      {
        class: className,
        'aria-busy': outboundSwitching ? 'true' : undefined,
        'aria-disabled':
          section.withTagSelect && !canChooseOutbound ? 'true' : undefined,
        click: () =>
          canChooseOutbound &&
          onChooseOutbound(section.sectionName, section.code, outbound.code),
      },
      [
        ...(outboundSwitching
          ? [
              svgEl(
                'svg',
                { class: 'fkp_dashboard-page__outbound-grid__item__snake' },
                [
                  svgEl('rect', {
                    width: '100%',
                    height: '100%',
                    fill: 'none',
                    rx: 4,
                    ry: 4,
                    pathLength: 100,
                  }),
                ],
              ),
            ]
          : []),
        E('div', { class: 'fkp_dashboard-page__outbound-grid__item__header' }, [
          E('b', {}, renderFlagEmojis(outbound.displayName)),
          E(
            'div',
            {
              style:
                'display: flex; gap: 4px; align-items: center; flex: 0 0 auto;',
            },
            [
              ...(canCopyLink
                ? [
                    E(
                      'button',
                      {
                        type: 'button',
                        class:
                          'btn fkp_dashboard-page__outbound-grid__item__copy-button',
                        title: _('Copy proxy link'),
                        'aria-label': _('Copy proxy link'),
                        click: (event: MouseEvent) => {
                          event.stopPropagation();
                          onCopyOutbound(section, outbound);
                        },
                      },
                      renderCopyIcon24(),
                    ),
                  ]
                : []),
              ...(outbound.urlTestInfo
                ? [
                    E(
                      'button',
                      {
                        type: 'button',
                        class:
                          'btn fkp_dashboard-page__outbound-grid__item__copy-button',
                        title: _('URLTest details'),
                        'aria-label': _('URLTest details'),
                        click: (event: MouseEvent) => {
                          event.stopPropagation();
                          onShowUrlTestInfo(outbound);
                        },
                      },
                      renderInfoIcon24(),
                    ),
                  ]
                : []),
              ...(outbound.priorityInfo
                ? [
                    E(
                      'button',
                      {
                        type: 'button',
                        class:
                          'btn fkp_dashboard-page__outbound-grid__item__copy-button',
                        title: _('Priority details'),
                        'aria-label': _('Priority details'),
                        click: (event: MouseEvent) => {
                          event.stopPropagation();
                          onShowPriorityInfo(outbound);
                        },
                      },
                      renderInfoIcon24(),
                    ),
                  ]
                : []),
            ],
          ),
        ]),
        E('div', { class: 'fkp_dashboard-page__outbound-grid__item__footer' }, [
          E(
            'div',
            { class: 'fkp_dashboard-page__outbound-grid__item__type' },
            [outbound.type].filter(Boolean),
          ),
          latencyBadge,
        ]),
      ],
    );
  }

  const metadataNodes = (section.subscriptionMetadata || [])
    .map((metadata) => renderSubscriptionMetadata(metadata))
    .filter(Boolean) as HTMLElement[];
  const subscriptionUpdateAction = renderSubscriptionUpdateAction(
    section,
    subscriptionUpdating,
    onUpdateSubscription,
  );

  return E('div', { class: 'fkp_dashboard-page__outbound-section' }, [
    // Title with test latency
    E('div', { class: 'fkp_dashboard-page__outbound-section__title-section' }, [
      E(
        'div',
        {
          class: 'fkp_dashboard-page__outbound-section__title-section__title',
        },
        section.displayName,
      ),
      E(
        'div',
        {
          class: 'fkp_dashboard-page__outbound-section__title-section__actions',
        },
        [
          ...(subscriptionUpdateAction ? [subscriptionUpdateAction] : []),
          E(
            'button',
            {
              type: 'button',
              class: 'btn dashboard-sections-grid-item-test-latency',
              'data-latency-section': section.sectionName,
              disabled: latencyFetching ? true : undefined,
              click: (event: MouseEvent) => {
                event.preventDefault();
                event.stopPropagation();
                if (latencyFetching) {
                  return;
                }

                testLatency();
              },
            },
            latencyFetching
              ? [
                  renderLoaderCircleIcon24(),
                  E(
                    'span',
                    {
                      class: 'dashboard-sections-grid-item-test-latency__label',
                    },
                    getLatencyTestLabel(latencyProgress),
                  ),
                ]
              : E(
                  'span',
                  {
                    class: 'dashboard-sections-grid-item-test-latency__label',
                  },
                  _('Test latency'),
                ),
          ),
        ],
      ),
    ]),
    E('div', { class: 'fkp_dashboard-page__outbound-grid' }, [
      ...metadataNodes,
      ...section.outbounds.map((outbound, index) =>
        renderOutbound(outbound, index),
      ),
    ]),
  ]);
}

export function renderSections(props: IRenderSectionsProps) {
  if (props.failed) {
    return renderFailedState();
  }

  if (props.loading) {
    return renderLoadingState();
  }

  return renderDefaultState(props);
}
