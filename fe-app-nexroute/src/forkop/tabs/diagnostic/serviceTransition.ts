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

type ComponentActions = Record<string, LoadingActionState>;

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

export function shouldResetDiagnosticsChecks({
  resetChecks,
  diagnosticsRunLoading,
}: {
  resetChecks: boolean;
  diagnosticsRunLoading: boolean;
}) {
  return resetChecks && !diagnosticsRunLoading;
}

export function shouldDisableDiagnosticRunAction({
  providerInfoLoaded,
  servicesInfoLoading,
  forkopRunning,
  mutatingServiceActionLoading,
}: {
  providerInfoLoaded: boolean;
  servicesInfoLoading: boolean;
  forkopRunning: boolean;
  mutatingServiceActionLoading: boolean;
}) {
  return (
    !providerInfoLoaded ||
    servicesInfoLoading ||
    !forkopRunning ||
    mutatingServiceActionLoading
  );
}

export function hasComponentActionLoading(actions: ComponentActions) {
  return Object.values(actions).some((action) => action.loading);
}

export function getAvailableActionsDisabledState({
  servicesInfoLoading,
  mutatingServiceActionLoading,
  componentActionLoading,
}: {
  servicesInfoLoading: boolean;
  mutatingServiceActionLoading: boolean;
  componentActionLoading: boolean;
}) {
  return {
    serviceControlsDisabled:
      servicesInfoLoading ||
      mutatingServiceActionLoading ||
      componentActionLoading,
    utilityActionsDisabled:
      mutatingServiceActionLoading || componentActionLoading,
    viewLogsDisabled: false,
  };
}

export function shouldShowRestartAction({
  forkopRunning,
  restartLoading,
  startLoading,
  stopLoading,
}: {
  forkopRunning: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopLoading: boolean;
}) {
  return restartLoading || (forkopRunning && !startLoading && !stopLoading);
}

export function shouldShowStartAction({
  forkopRunning,
  restartLoading,
  startLoading,
  stopLoading,
}: {
  forkopRunning: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopLoading: boolean;
}) {
  return startLoading || (!restartLoading && !forkopRunning && !stopLoading);
}

export function shouldShowStopAction({
  forkopRunning,
  restartLoading,
  startLoading,
  stopLoading,
}: {
  forkopRunning: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopLoading: boolean;
}) {
  return stopLoading || restartLoading || (forkopRunning && !startLoading);
}
