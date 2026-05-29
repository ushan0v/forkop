const RESERVED_RUNTIME_TAGS = new Set([
  'dns-server',
  'fakeip-server',
  'bootstrap-dns-server',
  'fakeip-dns-rule-tag',
  'fakeip-ruleset-dns-rule-tag',
  'service-fakeip-dns-rule-tag',
  'tproxy-in',
  'dns-in',
  'service-mixed-in',
  'direct-out',
]);

function hasReservedNumberedParent(base: string, postfix: string): boolean {
  const match = base.match(/^(.*)-\d+$/);

  return Boolean(match && RESERVED_RUNTIME_TAGS.has(`${match[1]}-${postfix}`));
}

export function allocateRuntimeTag(base: string, postfix: string): string {
  let suffix = hasReservedNumberedParent(base, postfix) ? 1 : 0;
  let candidate =
    suffix > 0 ? `${base}-${suffix}-${postfix}` : `${base}-${postfix}`;

  while (RESERVED_RUNTIME_TAGS.has(candidate)) {
    suffix += 1;
    candidate = `${base}-${suffix}-${postfix}`;
  }

  return candidate;
}

export function getOutboundTagBySection(sectionName: string): string {
  return allocateRuntimeTag(sectionName, 'out');
}
