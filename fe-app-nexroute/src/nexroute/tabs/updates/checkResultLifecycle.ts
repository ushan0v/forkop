import type { Nexroute } from '../../types';

export function shouldPreserveCompletedCheckResultOnNextMount({
  action,
  mounted,
}: {
  action: Nexroute.ComponentAction;
  mounted: boolean;
}) {
  return action === 'check_update' && !mounted;
}

export function shouldResetCheckResultsOnMount({
  anyActionLoading,
  preserveCheckResultsOnNextMount,
  persistentCacheEnabled = false,
}: {
  anyActionLoading: boolean;
  preserveCheckResultsOnNextMount: boolean;
  persistentCacheEnabled?: boolean;
}) {
  return (
    !persistentCacheEnabled &&
    !anyActionLoading &&
    !preserveCheckResultsOnNextMount
  );
}

export function shouldRefreshComponentStateBeforeRender(
  uiState?: Pick<Nexroute.UiState, 'actions'>,
) {
  return Boolean(
    uiState?.actions.component.some((state) => state.running === true),
  );
}

export function shouldExposeCheckResults({
  mounted,
  cacheResolved,
}: {
  mounted: boolean;
  cacheResolved: boolean;
}) {
  return mounted && cacheResolved;
}
