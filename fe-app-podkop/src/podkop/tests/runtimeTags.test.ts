import { describe, expect, it } from 'vitest';

import { getOutboundTagBySection } from '../runtimeTags';

describe('runtimeTags', () => {
  it('uses the same direct section collision format as the backend generator', () => {
    expect(getOutboundTagBySection('proxy')).toBe('proxy-out');
    expect(getOutboundTagBySection('direct')).toBe('direct-out-1');
    expect(getOutboundTagBySection('direct-1')).toBe('direct-1-out');
  });
});
