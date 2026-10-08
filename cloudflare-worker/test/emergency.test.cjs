const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const ts = require('typescript');
const fs = require('node:fs');
const path = require('node:path');
require.extensions['.ts'] = (module, filename) => module._compile(ts.transpileModule(
  fs.readFileSync(filename, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, filename);
const { extractEmergencyStatus, readEmergencyObservation, acceptEmergency, EMERGENCY_MAX_AGE } = require('../src/emergency.ts');
const cases = JSON.parse(fs.readFileSync(path.join(__dirname, '../../test/fixtures/emergency_status_cases.json'), 'utf8'));
for (const example of cases) test(`emergency parser: ${example.name}`, () => {
  assert.equal(extractEmergencyStatus(example.html), example.active);
});
const realNow = Date.now;
const now = Date.parse('2026-10-08T12:00:00Z');
Date.now = () => now;
after(() => { Date.now = realNow; });
const transport = value => `<script id="lumen-emergency" type="application/json">${JSON.stringify(value)}</script>`;
test('canonical transport validates schema, boolean, capture time, and ambiguity', () => {
  const valid = { schemaVersion: 1, active: true, observedAt: now };
  assert.deepEqual(readEmergencyObservation(transport(valid)), valid);
  for (const invalid of [{ ...valid, schemaVersion: 2 }, { ...valid, active: 'false' },
    { ...valid, observedAt: now - EMERGENCY_MAX_AGE - 1 }, { ...valid, observedAt: now + 60001 }]) {
    assert.equal(readEmergencyObservation(transport(invalid)), undefined);
  }
  assert.equal(readEmergencyObservation(transport(valid) + transport(valid)), undefined);
  assert.equal(readEmergencyObservation('<script>DisconSchedule.fact={};</script>'), undefined);
});
test('cancellation requires independent newer observations; reactivation clears candidate', () => {
  const active = acceptEmergency(undefined, { active: true, observedAt: now - 60000 });
  const candidate = acceptEmergency(active, { active: false, observedAt: now - 59000 });
  assert.equal(candidate.active, true);
  assert.equal(acceptEmergency(candidate, { active: false, observedAt: now - 58000 }).active, true);
  const cancelled = acceptEmergency(candidate, { active: false, observedAt: now - 29000 });
  assert.equal(cancelled.active, false);
  assert.equal(acceptEmergency(cancelled, { active: true, observedAt: now - 30000 }), cancelled);
  const refreshed = acceptEmergency(candidate, { active: true, observedAt: now - 58000 });
  assert.equal(refreshed.cancellationSince, undefined);
  assert.equal(refreshed.changedAt, active.changedAt);
});
