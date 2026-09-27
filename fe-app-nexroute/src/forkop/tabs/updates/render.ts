export function render() {
  return E('div', { id: 'updates-status', class: 'fkp_updates-page' }, [
    E('div', {
      id: 'fkp_updates-components',
      class: 'fkp_updates-page__components',
    }),
  ]);
}
