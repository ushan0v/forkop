import { describe, expect, it } from 'vitest';
import {
  getServiceTransition,
  hasLocalMutatingServiceActionLoading,
  isServiceTransitionStatus,
  shouldSkipServicesInfoAutoRefresh,
  shouldShowRestartAction,
  shouldShowStartAction,
  shouldShowStopAction,
} from '../serviceTransition';

const idleActions = {
  restart: { loading: false },
  start: { loading: false },
  stop: { loading: false },
  enable: { loading: false },
  disable: { loading: false },
};

describe('diagnostic service transitions', () => {
  it('treats service transition status as a UI transition', () => {
    expect(isServiceTransitionStatus('starting')).toBe(true);
    expect(isServiceTransitionStatus('reloading')).toBe(true);
    expect(isServiceTransitionStatus('running & enabled')).toBe(false);
  });

  it('maps reload to the restart/reload control state', () => {
    expect(getServiceTransition('reloading')).toEqual({
      starting: false,
      stopping: false,
      restarting: true,
    });
  });

  it('detects only local button loading as local mutation', () => {
    expect(hasLocalMutatingServiceActionLoading(idleActions)).toBe(false);
    expect(
      hasLocalMutatingServiceActionLoading({
        ...idleActions,
        start: { loading: true },
      }),
    ).toBe(true);
  });

  it('does not let backend transition status block polling forever', () => {
    expect(
      shouldSkipServicesInfoAutoRefresh({
        force: false,
        localMutatingActionLoading: false,
      }),
    ).toBe(false);
  });

  it('still lets local button actions suppress non-forced polling', () => {
    expect(
      shouldSkipServicesInfoAutoRefresh({
        force: false,
        localMutatingActionLoading: true,
      }),
    ).toBe(true);
    expect(
      shouldSkipServicesInfoAutoRefresh({
        force: true,
        localMutatingActionLoading: true,
      }),
    ).toBe(false);
  });

  it('shows restart while the service is running even when autostart is disabled', () => {
    expect(
      shouldShowRestartAction({
        podkopRunning: true,
        restartLoading: false,
      }),
    ).toBe(true);
    expect(
      shouldShowRestartAction({
        podkopRunning: false,
        restartLoading: false,
      }),
    ).toBe(false);
    expect(
      shouldShowRestartAction({
        podkopRunning: false,
        restartLoading: true,
      }),
    ).toBe(true);
  });

  it('keeps the lower service action visible while restart is running', () => {
    expect(
      shouldShowStopAction({
        podkopRunning: false,
        restartLoading: true,
        startLoading: false,
        stopLoading: false,
      }),
    ).toBe(true);
    expect(
      shouldShowStartAction({
        podkopRunning: false,
        restartLoading: true,
        startLoading: false,
        stopLoading: false,
      }),
    ).toBe(false);
  });

  it('keeps the normal start and stop visibility outside restart', () => {
    expect(
      shouldShowStartAction({
        podkopRunning: false,
        restartLoading: false,
        startLoading: false,
        stopLoading: false,
      }),
    ).toBe(true);
    expect(
      shouldShowStopAction({
        podkopRunning: false,
        restartLoading: false,
        startLoading: false,
        stopLoading: false,
      }),
    ).toBe(false);
    expect(
      shouldShowStopAction({
        podkopRunning: true,
        restartLoading: false,
        startLoading: false,
        stopLoading: false,
      }),
    ).toBe(true);
  });
});
