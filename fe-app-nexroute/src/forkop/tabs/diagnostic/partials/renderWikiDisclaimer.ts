import { renderBookOpenTextIcon24 } from '../../../../icons';
import { renderButton } from '../../../../partials';
import { insertIf } from '../../../../helpers';

export function renderWikiDisclaimer(kind: 'default' | 'error' | 'warning') {
  const iconWrap = E('span', {
    class: 'fkp_diagnostic-page__right-bar__wiki__icon',
  });
  iconWrap.appendChild(renderBookOpenTextIcon24());

  const className = [
    'fkp_diagnostic-page__right-bar__wiki',
    ...insertIf(kind === 'error', [
      'fkp_diagnostic-page__right-bar__wiki--error',
    ]),
    ...insertIf(kind === 'warning', [
      'fkp_diagnostic-page__right-bar__wiki--warning',
    ]),
  ].join(' ');

  return E('div', { class: className }, [
    E('div', { class: 'fkp_diagnostic-page__right-bar__wiki__content' }, [
      iconWrap,
      E('div', { class: 'fkp_diagnostic-page__right-bar__wiki__texts' }, [
        E('b', {}, _('Troubleshooting')),
        E('div', {}, _('Do not panic, everything can be fixed, just...')),
      ]),
    ]),
    renderButton({
      classNames: ['cbi-button-save'],
      text: _('Open Project Page'),
      onClick: () =>
        window.open(
          'https://github.com/ushan0v/forkop#readme',
          '_blank',
          'noopener,noreferrer',
        ),
    }),
  ]);
}
