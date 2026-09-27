import { GlobalStyles } from '../styles';

const FORKOP_GLOBAL_STYLES_ID = 'forkop-global-styles';

export function injectGlobalStyles() {
  if (document.getElementById(FORKOP_GLOBAL_STYLES_ID)) {
    return;
  }

  document.head.insertAdjacentHTML(
    'beforeend',
    `
        <style id="${FORKOP_GLOBAL_STYLES_ID}">
          ${GlobalStyles}
        </style>
    `,
  );
}
