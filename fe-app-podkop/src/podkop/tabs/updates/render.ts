export function render() {
  return E('div', { id: 'updates-status', class: 'pdk_updates-page' }, [
    E('div', {
      id: 'pdk_updates-components',
      class: 'pdk_updates-page__components',
    }),
  ]);
}
