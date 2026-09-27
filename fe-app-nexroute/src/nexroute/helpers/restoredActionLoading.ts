export function shouldShowLoadingForRestoredAction(state: {
  running?: boolean;
}) {
  return state.running === true;
}
