import type { Nexroute } from '../../types';

export function shouldApplyCompletedComponentActionResult(
  result: Pick<Nexroute.ComponentActionResult, 'action'>,
  notify: boolean,
) {
  return result.action !== 'check_update' || notify;
}
