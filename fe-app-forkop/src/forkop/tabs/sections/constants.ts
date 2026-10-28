export const RULE_SET_ITEM_SETTINGS_KEY = 'rule_set_settings';

export const ROUTING_ACTIONS = ['connection', 'bypass', 'block'];

// The smallest object the validator and sing-box both accept; the tag becomes the tunnel's name.
export const JSON_ENDPOINT_PLACEHOLDER = [
  '{',
  '  "type": "wireguard",',
  '  "tag": "my-endpoint",',
  '  "address": ["10.0.0.2/32"],',
  '  "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="',
  '}',
].join('\n');

// Groups arrange the section's own servers and draw members from these; a section with none of
// them is left out of the runtime, so it is refused on save.
export const CONNECTION_OUTBOUND_SOURCES = [
  'connection_link',
  'subscription_url',
  'interfaces',
  'tunnels',
  'outbound_jsons',
];
