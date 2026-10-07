import { svgEl } from '../helpers';

export function renderClockIcon24() {
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
      class: 'lucide lucide-clock',
    },
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('polyline', { points: '12 6 12 12 16 14' }),
    ],
  );
}
