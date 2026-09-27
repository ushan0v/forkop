function getWindowLocation(): Location | undefined {
  return typeof window !== 'undefined' ? window.location : undefined;
}

export function canUseDirectClashApi(): boolean {
  const location = getWindowLocation();

  return (
    typeof location?.hostname === 'string' &&
    location.hostname !== '' &&
    location.protocol !== 'https:'
  );
}

export function getClashWsUrl(): string {
  const { hostname } = window.location;

  return `ws://${hostname}:9090`;
}

export function getClashHttpUrl(): string {
  const { hostname } = window.location;

  return `http://${hostname}:9090`;
}

export function getClashUIUrl(): string {
  const { hostname } = window.location;

  return `http://${hostname}:9090/ui`;
}
