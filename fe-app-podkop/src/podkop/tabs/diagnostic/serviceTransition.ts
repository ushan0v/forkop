type LoadingActionState = {
  loading: boolean;
};

type DiagnosticServiceActions = {
  restart: LoadingActionState;
  start: LoadingActionState;
  stop: LoadingActionState;
  enable: LoadingActionState;
  disable: LoadingActionState;
};

export function isServiceTransitionStatus(status: string) {
  return ['starting', 'stopping', 'restarting', 'reloading'].includes(status);
}

export function getServiceTransition(status: string) {
  return {
    starting: status === 'starting',
    stopping: status === 'stopping',
    restarting: status === 'restarting' || status === 'reloading',
  };
}

export function hasLocalMutatingServiceActionLoading(
  actions: DiagnosticServiceActions,
) {
  return (
    actions.restart.loading ||
    actions.start.loading ||
    actions.stop.loading ||
    actions.enable.loading ||
    actions.disable.loading
  );
}

export function shouldSkipServicesInfoAutoRefresh({
  force,
  localMutatingActionLoading,
}: {
  force: boolean;
  localMutatingActionLoading: boolean;
}) {
  return !force && localMutatingActionLoading;
}

export function shouldShowRestartAction({
  podkopRunning,
  restartLoading,
}: {
  podkopRunning: boolean;
  restartLoading: boolean;
}) {
  return restartLoading || podkopRunning;
}

export function shouldShowStartAction({
  podkopRunning,
  restartLoading,
  startLoading,
  stopLoading,
}: {
  podkopRunning: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopLoading: boolean;
}) {
  return startLoading || (!restartLoading && !podkopRunning && !stopLoading);
}

export function shouldShowStopAction({
  podkopRunning,
  restartLoading,
  startLoading,
  stopLoading,
}: {
  podkopRunning: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopLoading: boolean;
}) {
  return stopLoading || restartLoading || (podkopRunning && !startLoading);
}
