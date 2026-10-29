import { E } from '../../../../helpers/element';
import { prettyBytes } from '../../../../helpers/prettyBytes';
import { protocolLabel } from '../../servers/protocols';
import type { ServerClientView, ServerView } from '../serverActivity';

interface IRenderServersProps {
  server: ServerView;
  // False until the core has answered with its connections, or after it stops answering.
  live: boolean;
}

function renderClient(client: ServerClientView, live: boolean) {
  const online = live && client.online;
  const speed =
    online && client.up !== null && client.down !== null
      ? `↓ ${prettyBytes(client.down)}/s  ↑ ${prettyBytes(client.up)}/s`
      : '';

  return E(
    'div',
    {
      class: [
        'fkp_dashboard-page__outbound-grid__item',
        online ? 'fkp_dashboard-page__outbound-grid__item--active' : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    [
      E('div', { class: 'fkp_dashboard-page__outbound-grid__item__header' }, [
        E('b', {}, client.name),
        E(
          'span',
          {
            class: `fkp_dashboard-page__server-client__status${online ? ' fkp_dashboard-page__server-client__status--online' : ''}`,
          },
          live ? (online ? _('Online') : _('Offline')) : '—',
        ),
      ]),
      E('div', { class: 'fkp_dashboard-page__outbound-grid__item__footer' }, [
        E(
          'div',
          { class: 'fkp_dashboard-page__outbound-grid__item__type' },
          online ? client.addresses.join(', ') : '',
        ),
        E('div', { class: 'fkp_dashboard-page__server-client__speed' }, speed),
      ]),
    ],
  );
}

export function renderServers({ server, live }: IRenderServersProps) {
  const online = server.clients.filter((client) => client.online).length;
  const details = [protocolLabel(server.protocol), server.port]
    .filter(Boolean)
    .join(' · ');

  return E('div', { class: 'fkp_dashboard-page__outbound-section' }, [
    E('div', { class: 'fkp_dashboard-page__outbound-section__title-section' }, [
      E('div', { class: 'fkp_dashboard-page__outbound-section__heading' }, [
        E(
          'div',
          {
            class: 'fkp_dashboard-page__outbound-section__title-section__title',
          },
          server.tag,
        ),
        ...(details
          ? [
              E(
                'span',
                { class: 'fkp_dashboard-page__outbound-section__current' },
                details,
              ),
            ]
          : []),
      ]),
      ...(live && server.clients.length
        ? [
            E(
              'span',
              { class: 'fkp_dashboard-page__server-client__status' },
              `${_('Online')}: ${online} / ${server.clients.length}`,
            ),
          ]
        : []),
    ]),
    server.clients.length
      ? E(
          'div',
          { class: 'fkp_dashboard-page__outbound-grid' },
          server.clients.map((client) => renderClient(client, live)),
        )
      : E(
          'div',
          { class: 'fkp_dashboard-page__server-client__empty' },
          _('No connected clients'),
        ),
  ]);
}
