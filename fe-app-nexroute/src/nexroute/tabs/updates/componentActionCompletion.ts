import type { Forkop } from '../../types';

export function shouldApplyCompletedComponentActionResult(
  result: Pick<Forkop.ComponentActionResult, 'action'>,
  notify: boolean,
) {
  return result.action !== 'check_update' || notify;
}
