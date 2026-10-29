import { renderSectionsPlaceholder, renderWidget } from './partials';
import { E } from '../../../helpers/element';

export function render() {
  return E(
    'div',
    {
      id: 'dashboard-status',
      class: 'fkp_dashboard-page',
    },
    [
      E('div', { class: 'fkp_dashboard-page__content' }, [
        E('div', { class: 'fkp_dashboard-page__widgets-section' }, [
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
            { id: 'dashboard-widget-load' },
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ),
          E(
            'div',
            { id: 'dashboard-widget-core' },
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ),
        ]),
        E('div', { id: 'dashboard-servers-grid' }),
        E('div', { id: 'dashboard-sections-toolbar' }),
        E(
          'div',
          { id: 'dashboard-sections-grid' },
          renderSectionsPlaceholder({ loading: true, failed: false }),
        ),
      ]),
    ],
  );
}
