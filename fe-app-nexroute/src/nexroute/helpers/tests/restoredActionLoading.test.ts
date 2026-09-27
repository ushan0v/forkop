import { describe, expect, it } from 'vitest';

import { shouldShowLoadingForRestoredAction } from '../restoredActionLoading';

describe('restored action loading', () => {
  it('shows loading only for actions that are still running', () => {
    expect(shouldShowLoadingForRestoredAction({ running: true })).toBe(true);
    expect(shouldShowLoadingForRestoredAction({ running: false })).toBe(false);
    expect(shouldShowLoadingForRestoredAction({})).toBe(false);
  });
});
