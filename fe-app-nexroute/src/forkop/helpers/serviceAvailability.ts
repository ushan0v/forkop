export type ServiceAvailability =
  | 'loading'
  | 'running'
  | 'stopped'
  | 'unavailable';

export function getServiceAvailability({
  loading,
  failed,
  running,
}: {
  loading: boolean;
  failed: boolean;
  running: boolean | number;
}): ServiceAvailability {
  if (loading) {
    return 'loading';
  }

  if (failed) {
    return 'unavailable';
  }

  return running ? 'running' : 'stopped';
}
