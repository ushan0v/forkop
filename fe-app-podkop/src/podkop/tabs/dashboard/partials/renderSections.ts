import {
  renderLoaderCircleIcon24,
  renderCopyIcon24,
  renderLinkIcon24,
  renderRotateCcwIcon24,
} from '../../../../icons';
import { isCopyableProxyLink } from '../../../../helpers';
import { prettyBytes } from '../../../../helpers/prettyBytes';
import { Podkop } from '../../../types';

interface IRenderSectionsProps {
  loading: boolean;
  failed: boolean;
  section: Podkop.OutboundGroup;
  onTestLatency: (tag: string) => void;
  onChooseOutbound: (selector: string, tag: string) => void;
  onCopyOutbound: (
    section: Podkop.OutboundGroup,
    outbound: Podkop.Outbound,
  ) => void;
  onUpdateSubscription: (section: Podkop.OutboundGroup) => void;
  latencyFetching: boolean;
  subscriptionUpdating: boolean;
}

function renderFailedState() {
  return E(
    'div',
    {
      class: 'pdk_dashboard-page__outbound-section centered',
      style: 'height: 127px',
    },
    E('span', {}, [E('span', {}, _('Dashboard currently unavailable'))]),
  );
}

function renderLoadingState() {
  return E('div', {
    id: 'dashboard-sections-grid-skeleton',
    class: 'pdk_dashboard-page__outbound-section skeleton',
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
      class: 'btn pdk_dashboard-page__subscription-meta__action',
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
  metadata: Podkop.SubscriptionMetadata | undefined,
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

  return E('div', { class: 'pdk_dashboard-page__subscription-meta' }, [
    E('div', { class: 'pdk_dashboard-page__subscription-meta__main' }, [
      E(
        'div',
        { class: 'pdk_dashboard-page__subscription-meta__heading' },
        _('Subscription info:'),
      ),
      title
        ? E(
            'div',
            { class: 'pdk_dashboard-page__subscription-meta__title' },
            title,
          )
        : '',
      rows.length
        ? E(
            'div',
            { class: 'pdk_dashboard-page__subscription-meta__facts' },
            rows.map((row) =>
              E(
                'div',
                { class: 'pdk_dashboard-page__subscription-meta__fact' },
                [
                  E(
                    'span',
                    {
                      class: 'pdk_dashboard-page__subscription-meta__fact-key',
                    },
                    row.label,
                  ),
                  E(
                    'span',
                    {
                      class:
                        'pdk_dashboard-page__subscription-meta__fact-value',
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
            { class: 'pdk_dashboard-page__subscription-meta__actions' },
            actions,
          )
        : '',
    ]),
    metadata.announce
      ? E(
          'blockquote',
          { class: 'pdk_dashboard-page__subscription-meta__announce' },
          metadata.announce,
        )
      : '',
  ]);
}

function renderSubscriptionUpdateAction(
  section: Podkop.OutboundGroup,
  subscriptionUpdating: boolean,
  onUpdateSubscription: (section: Podkop.OutboundGroup) => void,
) {
  if (!section.subscriptionSourceCount) {
    return undefined;
  }

  return E(
    'button',
    {
      type: 'button',
      class: 'btn pdk_dashboard-page__outbound-section__subscription-update',
      title: _('Update subscriptions'),
      'aria-label': _('Update subscriptions'),
      disabled: subscriptionUpdating ? true : undefined,
      click: (event: MouseEvent) => {
        event.stopPropagation();
        if (subscriptionUpdating) {
          return;
        }

        onUpdateSubscription(section);
      },
    },
    subscriptionUpdating ? renderLoaderCircleIcon24() : renderRotateCcwIcon24(),
  );
}

export function renderDefaultState({
  section,
  onChooseOutbound,
  onCopyOutbound,
  onTestLatency,
  onUpdateSubscription,
  latencyFetching,
  subscriptionUpdating,
}: IRenderSectionsProps) {
  function testLatency() {
    if (section.withTagSelect) {
      return onTestLatency(section.code);
    }

    if (section.outbounds.length) {
      return onTestLatency(section.outbounds[0].code);
    }
  }

  function renderOutbound(outbound: Podkop.Outbound) {
    function getLatencyClass() {
      if (!outbound.latency) {
        return 'pdk_dashboard-page__outbound-grid__item__latency--empty';
      }

      if (outbound.latency < 800) {
        return 'pdk_dashboard-page__outbound-grid__item__latency--green';
      }

      if (outbound.latency < 1500) {
        return 'pdk_dashboard-page__outbound-grid__item__latency--yellow';
      }

      return 'pdk_dashboard-page__outbound-grid__item__latency--red';
    }

    const canCopyLink =
      Boolean(outbound.canCopyLink) || isCopyableProxyLink(outbound.link);

    return E(
      'div',
      {
        class: `pdk_dashboard-page__outbound-grid__item ${outbound.selected ? 'pdk_dashboard-page__outbound-grid__item--active' : ''} ${section.withTagSelect ? 'pdk_dashboard-page__outbound-grid__item--selectable' : ''}`,
        click: () =>
          section.withTagSelect &&
          onChooseOutbound(section.code, outbound.code),
      },
      [
        E('div', { class: 'pdk_dashboard-page__outbound-grid__item__header' }, [
          E('b', {}, outbound.displayName),
          ...(canCopyLink
            ? [
                E(
                  'button',
                  {
                    type: 'button',
                    class:
                      'btn pdk_dashboard-page__outbound-grid__item__copy-button',
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
        ]),
        E('div', { class: 'pdk_dashboard-page__outbound-grid__item__footer' }, [
          E(
            'div',
            { class: 'pdk_dashboard-page__outbound-grid__item__type' },
            outbound.type,
          ),
          E(
            'div',
            { class: getLatencyClass() },
            outbound.latency ? `${outbound.latency}ms` : 'N/A',
          ),
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

  return E('div', { class: 'pdk_dashboard-page__outbound-section' }, [
    // Title with test latency
    E('div', { class: 'pdk_dashboard-page__outbound-section__title-section' }, [
      E(
        'div',
        {
          class: 'pdk_dashboard-page__outbound-section__title-section__title',
        },
        section.displayName,
      ),
      E(
        'div',
        {
          class: 'pdk_dashboard-page__outbound-section__title-section__actions',
        },
        [
          ...(subscriptionUpdateAction ? [subscriptionUpdateAction] : []),
          latencyFetching
            ? E('div', {
                class: 'skeleton',
                style: 'width: 99px; height: 28px',
              })
            : E(
                'button',
                {
                  class: 'btn dashboard-sections-grid-item-test-latency',
                  click: () => testLatency(),
                },
                _('Test latency'),
              ),
        ],
      ),
    ]),
    E('div', { class: 'pdk_dashboard-page__outbound-grid' }, [
      ...metadataNodes,
      ...section.outbounds.map((outbound) => renderOutbound(outbound)),
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
