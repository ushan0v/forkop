export function render() {
  return E('div', { id: 'diagnostic-status', class: 'fkp_diagnostic-page' }, [
    E('div', { class: 'fkp_diagnostic-page__left-bar' }, [
      E('div', { id: 'fkp_diagnostic-page-run-check' }),
      E('div', {
        class: 'fkp_diagnostic-page__checks',
        id: 'fkp_diagnostic-page-checks',
      }),
    ]),
    E('div', { class: 'fkp_diagnostic-page__right-bar' }, [
      E('div', { id: 'fkp_diagnostic-page-wiki' }),
      E('div', { id: 'fkp_diagnostic-page-actions' }),
      E('div', { id: 'fkp_diagnostic-page-system-info' }),
    ]),
  ]);
}
