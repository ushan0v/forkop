export function isActiveLuciTab(tabId: string) {
  if (typeof document === 'undefined') {
    return false;
  }

  return Boolean(
    document.querySelector(
      `.cbi-tab[data-tab="${tabId}"]:not(.cbi-tab-disabled)`,
    ),
  );
}
