#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js" <<'NODE'
const fs = require('fs');
const assert = require('assert');

const source = fs.readFileSync(process.argv[2], 'utf8');
const match = source.match(
  /function configureSectionSection\(sectionRef, options = \{\}\) \{[\s\S]*?\n\}\n\nconst EntryPoint/,
);
assert(match, 'configureSectionSection not found');

const cleanupCalls = [];
function setActionProvidersAvailabilityLoader() {}
function loadSectionTableOptions() {}
function cleanupRemovedChildItems(...args) {
  cleanupCalls.push(args);
}
eval(match[0].slice(0, -'\n\nconst EntryPoint'.length));

const event = {};
const result = {};
let parentArgs;
let parentThis;
const sectionRef = {
  handleRemove(...args) {
    parentArgs = args;
    parentThis = this;
    return result;
  },
};
configureSectionSection(sectionRef);

assert.strictEqual(sectionRef.handleRemove('parent', event), result);
assert.deepStrictEqual(cleanupCalls, [
  ['parent', 'subscription_url', []],
  ['parent', 'section_interface', []],
  ['parent', 'urltest', []],
  ['parent', 'priority_group', []],
]);
assert.deepStrictEqual(parentArgs, ['parent', event]);
assert.strictEqual(parentThis, sectionRef);
assert.match(
  source,
  /typeName === "priority_group"[\s\S]*cleanupPriorityLevelsForGroup\(itemId\)/,
  'priority_group cleanup does not cascade to priority_level',
);

console.log('LuCI section cascade checks passed');
NODE
