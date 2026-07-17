import { afterEach, describe, expect, it, vi } from 'vitest';
import { renderFlagEmojis } from '../renderFlagEmojis';

afterEach(() => vi.unstubAllGlobals());

describe('renderFlagEmojis', () => {
  it('wraps country flags without changing the node name', () => {
    vi.stubGlobal('E', (tag: string, attributes: object, children: string) => ({
      tag,
      attributes,
      children,
    }));

    expect(renderFlagEmojis('🇲🇩 Vless 🚀')).toEqual([
      {
        tag: 'span',
        attributes: { class: 'fkp_dashboard-page__flag-emoji' },
        children: '🇲🇩',
      },
      ' Vless 🚀',
    ]);
  });
});
