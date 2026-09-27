import { GlobalStyles } from '../styles';

const NEXROUTE_GLOBAL_STYLES_ID = 'nexroute-global-styles';

export function injectGlobalStyles() {
  if (document.getElementById(NEXROUTE_GLOBAL_STYLES_ID)) {
    return;
  }

  document.head.insertAdjacentHTML(
    'beforeend',
    `
        <style id="${NEXROUTE_GLOBAL_STYLES_ID}">
          ${GlobalStyles}
        </style>
    `,
  );
}
