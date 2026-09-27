const RESERVED_RUNTIME_TAGS = new Set([
  'dns-server',
  'fakeip-server',
  'bootstrap-dns-server',
  'fakeip-dns-rule-tag',
  'fakeip-ruleset-dns-rule-tag',
  'service-fakeip-dns-rule-tag',
  'tproxy-in',
  'tproxy6-in',
  'dns-in',
  'service-mixed-in',
  'direct-out',
  'bypass-out',
]);

export function allocateRuntimeTag(base: string, postfix: string): string {
  let suffix = 1;
  let candidate = `${base}-${postfix}`;

  while (RESERVED_RUNTIME_TAGS.has(candidate)) {
    candidate = `${base}-${postfix}-${suffix}`;
    suffix += 1;
  }

  return candidate;
}

export function getOutboundTagBySection(sectionName: string): string {
  return allocateRuntimeTag(sectionName, 'out');
}
