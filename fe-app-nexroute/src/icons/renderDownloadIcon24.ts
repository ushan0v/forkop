import { svgEl } from '../helpers';

export function renderDownloadIcon24() {
  const NS = 'http://www.w3.org/2000/svg';
  return svgEl(
    'svg',
    {
      xmlns: NS,
      viewBox: '0 0 24 24',
      fill: 'none',
      stroke: 'currentColor',
      'stroke-width': '2',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      class: 'lucide lucide-download-icon lucide-download',
    },
    [
      svgEl('path', {
        d: 'M12 15V3',
      }),
      svgEl('path', {
        d: 'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4',
      }),
      svgEl('path', {
        d: 'm7 10 5 5 5-5',
      }),
    ],
  );
}
