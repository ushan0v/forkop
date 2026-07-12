import { describe, expect, it } from 'vitest';

import {
  shouldPreserveCompletedCheckResultOnNextMount,
  shouldExposeCheckResults,
  shouldRefreshComponentStateBeforeRender,
  shouldResetCheckResultsOnMount,
} from '../checkResultLifecycle';

describe('updates check result lifecycle', () => {
  it('preserves a check result that completed while the Components tab was hidden', () => {
    expect(
      shouldPreserveCompletedCheckResultOnNextMount({
        action: 'check_update',
        mounted: false,
      }),
    ).toBe(true);

    expect(
      shouldResetCheckResultsOnMount({
        anyActionLoading: false,
        preserveCheckResultsOnNextMount: true,
      }),
    ).toBe(false);
  });

  it('resets check results on the next ordinary reopen', () => {
    expect(
      shouldResetCheckResultsOnMount({
        anyActionLoading: false,
        preserveCheckResultsOnNextMount: false,
      }),
    ).toBe(true);
  });

  it('does not reset while an action is still loading', () => {
    expect(
      shouldResetCheckResultsOnMount({
        anyActionLoading: true,
        preserveCheckResultsOnNextMount: false,
      }),
    ).toBe(false);
  });

  it('keeps cached results on every reopen when automatic checks are enabled', () => {
    expect(
      shouldResetCheckResultsOnMount({
        anyActionLoading: false,
        preserveCheckResultsOnNextMount: false,
        persistentCacheEnabled: true,
      }),
    ).toBe(false);
  });

  it('requires a fresh state read before rendering cached running component actions', () => {
    expect(
      shouldRefreshComponentStateBeforeRender({
        actions: {
          service: [],
          latency: [],
          subscription: [],
          component: [
            {
              success: true,
              running: true,
              component: 'zapret',
              action: 'check_update',
              message: 'Component action is running',
              job_id: 'job-1',
              current_version: '',
              latest_version: '',
              changed: false,
            },
          ],
        },
      }),
    ).toBe(true);
  });

  it('exposes check results immediately on remount once cache state is resolved', () => {
    expect(
      shouldExposeCheckResults({
        mounted: true,
        cacheResolved: false,
      }),
    ).toBe(false);

    expect(
      shouldExposeCheckResults({
        mounted: true,
        cacheResolved: true,
      }),
    ).toBe(true);

    expect(
      shouldExposeCheckResults({
        mounted: false,
        cacheResolved: true,
      }),
    ).toBe(false);

    expect(
      shouldExposeCheckResults({
        mounted: true,
        cacheResolved: true,
      }),
    ).toBe(true);
  });
});
