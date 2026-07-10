import { renderSections, renderWidget } from './partials';

export function render() {
  return E(
    'div',
    {
      id: 'dashboard-status',
      class: 'pdk_dashboard-page',
    },
    [
      E(
        'div',
        {
          class: 'pdk_dashboard-page__service-stopped',
          role: 'status',
        },
        _(
          'Podkop Plus service is stopped. Start the service to display the dashboard.',
        ),
      ),
      E('div', { class: 'pdk_dashboard-page__content' }, [
        // Widgets section
        E('div', { class: 'pdk_dashboard-page__widgets-section' }, [
          E(
            'div',
            { id: 'dashboard-widget-traffic' },
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ),
          E(
            'div',
            { id: 'dashboard-widget-traffic-total' },
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ),
          E(
            'div',
            { id: 'dashboard-widget-system-info' },
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ),
          E(
            'div',
            { id: 'dashboard-widget-service-info' },
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ),
        ]),
        // All outbounds
        E(
          'div',
          { id: 'dashboard-sections-grid' },
          renderSections({
            loading: true,
            failed: false,
            section: {
              code: '',
              sectionName: '',
              displayName: '',
              outbounds: [],
              withTagSelect: false,
            },
            onTestLatency: () => {},
            onChooseOutbound: () => {},
            onCopyOutbound: () => {},
            onShowUrlTestInfo: () => {},
            onShowPriorityInfo: () => {},
            onUpdateSubscription: () => {},
            latencyFetching: false,
            latencyProgress: undefined,
            subscriptionUpdating: false,
            selectorSwitchingTag: undefined,
          }),
        ),
      ]),
    ],
  );
}
