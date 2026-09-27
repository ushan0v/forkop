import { describe, expect, it } from 'vitest';

import { shouldApplyCompletedComponentActionResult } from '../componentActionCompletion';

describe('shouldApplyCompletedComponentActionResult', () => {
  it('does not restore completed check results that were already handled before reload', () => {
    expect(
      shouldApplyCompletedComponentActionResult(
        { action: 'check_update' },
        false,
      ),
    ).toBe(false);
  });

  it('applies completed check results when this UI still owns the pending notification', () => {
    expect(
      shouldApplyCompletedComponentActionResult(
        { action: 'check_update' },
        true,
      ),
    ).toBe(true);
  });

  it('always applies completed mutating actions because they reflect real system state', () => {
    expect(
      shouldApplyCompletedComponentActionResult({ action: 'install' }, false),
    ).toBe(true);
    expect(
      shouldApplyCompletedComponentActionResult({ action: 'remove' }, false),
    ).toBe(true);
  });
});
