const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const ts = require('typescript');
const fs = require('node:fs');
require.extensions['.ts'] = (module, filename) => module._compile(ts.transpileModule(
  fs.readFileSync(filename, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, filename);
const fcm = require('../src/fcm.ts');
const { ScheduleMonitor } = require('../src/monitor.ts');
const { ALL_GROUPS, parseSnapshot, parseUpdateTime, readLimitedBody, MAX_HTML_BYTES } = require('../src/schedule.ts');
let now, sent, outcome;
const realNow = Date.now;
beforeEach(() => {
  now = Date.parse('2026-10-06T12:00:00Z'); Date.now = () => now;
  sent = []; outcome = { success: true, messageId: 'test' };
  fcm.sendFcmTopicNotification = async (_, options) => { sent.push(options); return outcome; };
});
process.on('exit', () => { Date.now = realNow; });
function fixture(update = '06.10.2026 10:00', status = 'yes', tomorrow = false) {
  const hours = Object.fromEntries(Array.from({ length: 24 }, (_, i) => [String(i + 1), status]));
  const day = Object.fromEntries(ALL_GROUPS.map(g => [g, { ...hours }]));
  const fact = { today: 1791234000, update, data: { '1791234000': day } };
  // Kyiv midnight, generated explicitly to avoid relying on the test process time zone.
  fact.today = Date.parse('2026-10-05T21:00:00Z') / 1000;
  fact.data = { [fact.today]: day };
  if (tomorrow) fact.data[fact.today + 86400] = structuredClone(day);
  return fact;
}
const html = fact => `<script>DisconSchedule.fact = null; DisconSchedule.fact = ${JSON.stringify(fact)};</script>`;
function setup(legacy = {}) {
  let record, alarm, writes = 0;
  const storage = { get: async () => record && structuredClone(record),
    put: async (_, value) => { record = structuredClone(value); writes++; },
    setAlarm: async value => { alarm = value; }, deleteAlarm: async () => { alarm = undefined; },
    transaction: async task => task(storage) };
  const env = { SCHEDULE_KV: { get: async key => legacy[key] ?? null, put: async () => { throw Error('KV writes forbidden'); } },
    FIREBASE_SERVICE_ACCOUNT: JSON.stringify({ project_id: 'test', client_email: 'test@example.com', private_key: 'test' }) };
  const monitor = new ScheduleMonitor({ storage }, env);
  return { monitor, env, storage, record: () => record, writes: () => writes, alarm: () => alarm,
    send: async (fact, source = 'desktop_bridge', dryRun = false) => (await monitor.fetch(new Request('https://internal/check', {
      method: 'POST', body: JSON.stringify({ html: html(fact), source, dryRun }) }))).json() };
}

async function sendEmergency(s, active, { capturedAt = now, fact = fixture(), dryRun = false } = {}) {
  const notice = `<script id="lumen-emergency" type="application/json">${JSON.stringify({
    schemaVersion: 1, active, observedAt: capturedAt })}</script>`;
  return (await s.monitor.fetch(new Request('https://internal/check', { method: 'POST',
    body: JSON.stringify({ html: (fact ? html(fact) : '') + notice, source: 'test', dryRun }) }))).json();
}

test('emergency baseline alerts once, unchanged schedules do not block independent transitions', async () => {
  const s = setup();
  const first = await sendEmergency(s, true);
  assert.equal(first.emergencyProcessed, true);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].changeType, 'emergency_alert');
  assert.equal(sent[0].isEmergency, true);
  assert.equal(sent[0].targetDate, undefined);
  const baseline = structuredClone(s.record().snapshot);
  now += 1000;
  await sendEmergency(s, true);
  assert.equal(sent.length, 1);
  now += 1000;
  await sendEmergency(s, false);
  assert.equal(s.record().emergency.active, true);
  now += 30000;
  await sendEmergency(s, false);
  assert.equal(sent.length, 2);
  assert.equal(sent[1].isEmergency, false);
  assert.deepEqual(s.record().snapshot, baseline);
  await sendEmergency(s, true, { capturedAt: now - 1 });
  assert.equal(s.record().emergency.active, false);
  assert.equal(sent.length, 2);
});

test('script-only Python/legacy snapshots never imply cancellation', async () => {
  const s = setup(); await sendEmergency(s, true);
  now += 60000;
  await s.send(fixture(), 'python_bridge');
  now += 60000;
  await s.send(fixture(), 'python_bridge');
  assert.equal(s.record().emergency.active, true);
  assert.equal(sent.length, 1);
});

test('source notices switch global to local, preserve text, then immediately clear for stabilization', async () => {
  const s = setup();
  const cases = JSON.parse(fs.readFileSync(require('node:path').join(__dirname, '../../test/fixtures/emergency_status_cases.json'), 'utf8'));
  for (const name of ['full standard screenshot', 'district emergency from screenshot', 'stabilization from screenshot']) {
    now += 1000;
    const example = cases.find(item => item.name === name);
    const response = await s.monitor.fetch(new Request('https://internal/check', { method: 'POST',
      body: JSON.stringify({ html: example.html, source: 'test', observedAt: now }) }));
    const report = await response.json();
    assert.equal(report.emergencyProcessed, true);
    assert.equal(s.record().emergency.active, example.active);
    assert.equal(s.record().emergency.isPossible, example.possible);
    assert.equal(s.record().emergency.cancellationSince, undefined);
    assert.equal(sent.at(-1).isPossible, example.possible);
    assert.equal(sent.at(-1).noticeText, s.record().emergency.noticeText);
    if (name === 'district emergency from screenshot') assert.equal(sent.at(-1).title, 'Можливі екстрені відключення');
  }
  assert.equal(sent.length, 3);
});

test('identical emergency-only replay succeeds without confirming cancellation or duplicating delivery', async () => {
  const s = setup();
  await sendEmergency(s, true, { fact: null });
  const active = structuredClone(s.record().emergency);
  const duplicate = await sendEmergency(s, true, { fact: null });
  assert.equal(duplicate.status, 'emergency_only');
  assert.equal(duplicate.emergencyProcessed, true);
  assert.deepEqual(duplicate.errors, []);
  assert.equal(sent.length, 1);
  assert.deepEqual(s.record().emergency, active);
  const dry = await sendEmergency(s, true, { fact: null, dryRun: true });
  assert.equal(dry.status, 'dry_run_success');
  assert.equal(sent.length, 1);
  now += 1000;
  await sendEmergency(s, false, { fact: null });
  const candidate = structuredClone(s.record().emergency);
  const repeatedCandidate = await sendEmergency(s, false, { fact: null });
  assert.equal(repeatedCandidate.status, 'emergency_only');
  assert.deepEqual(s.record().emergency, candidate);
  assert.equal(s.record().emergency.active, true);
  assert.equal(sent.length, 1);
  const contradictsCandidate = await sendEmergency(s, true, { fact: null });
  assert.equal(contradictsCandidate.emergencyProcessed, false);
  assert.deepEqual(s.record().emergency, candidate);
  const conflicting = await sendEmergency(s, false, { capturedAt: active.observedAt, fact: null });
  assert.equal(conflicting.emergencyProcessed, false);
  assert.equal(conflicting.status, 'no_data_extracted');
  assert.equal(sent.length, 1);
});

test('malformed/stale schedule does not block emergency state or delivery; dry run remains pure', async () => {
  const s = setup(); await s.send(fixture());
  const snapshot = structuredClone(s.record().snapshot);
  assert.equal((await sendEmergency(s, true, { fact: null, dryRun: true })).status, 'dry_run_success');
  assert.equal(s.record().emergency, undefined);
  assert.equal(sent.length, 0);
  const result = await sendEmergency(s, true, { fact: null });
  assert.equal(result.status, 'emergency_only');
  assert.equal(result.scheduleStatus, 'no_data_extracted');
  assert.equal(result.emergencyProcessed, true);
  assert.equal(result.errors.length, 0);
  assert.deepEqual(s.record().snapshot, snapshot);
  now += 1000;
  const stale = await sendEmergency(s, false, { fact: fixture('06.10.2026 09:00') });
  assert.equal(stale.status, 'emergency_only');
  assert.equal(stale.scheduleStatus, 'stale_snapshot');
  assert.equal(s.record().emergency.active, true);
});

test('retry survives restart and midnight, but expires at original observation deadline', async () => {
  now = Date.parse('2026-10-06T20:59:50Z');
  const s = setup(); outcome = { success: false, error: 'Unavailable' };
  await sendEmergency(s, true, { fact: null });
  const original = s.record().pendingEmergency.options;
  assert.equal(original.expiresAt, now + 900000);
  assert.ok(s.alarm());
  now += 31000;
  outcome = { success: true };
  await new ScheduleMonitor({ storage: s.storage }, s.env).alarm();
  assert.equal(sent.length, 2);
  assert.equal(sent[1].expiresAt, original.expiresAt);
  assert.equal(s.record().pendingEmergency, undefined);
  now += 1000;
  outcome = { success: false, error: 'Unavailable' };
  await sendEmergency(s, false, { fact: null });
  now += 30000;
  await sendEmergency(s, false, { fact: null });
  assert.ok(s.record().pendingEmergency);
  const count = sent.length;
  now += 900001;
  await new ScheduleMonitor({ storage: s.storage }, s.env).alarm();
  assert.equal(sent.length, count);
  assert.equal(s.record().pendingEmergency, undefined);
  assert.equal(s.alarm(), undefined);
});

test('permanent FCM rejection drops emergency outbox and reports delivery failure', async () => {
  const s = setup(); outcome = { success: false, retryable: false, error: 'FCM API 400' };
  const result = await sendEmergency(s, true);
  assert.equal(result.status, 'delivery_failed');
  assert.equal(s.record().pendingEmergency, undefined);
  assert.equal(s.alarm(), undefined);
});

test('permanent schedule FCM rejection does not retain an unrepairable retry loop', async () => {
  const s = setup(); await s.send(fixture());
  outcome = { success: false, retryable: false, error: 'FCM API 400' };
  assert.equal((await s.send(fixture('06.10.2026 11:00', 'no'))).status, 'delivery_failed');
  assert.ok(Object.values(s.record().groups).every(group => group.pending === undefined));
  assert.equal(s.alarm(), undefined);
  sent = []; outcome = { success: true };
  await s.send(fixture('06.10.2026 12:00', 'first'));
  assert.equal(sent.length, 12);
  assert.ok(sent.every(message => message.body.startsWith('Оновлений графік')));
  assert.ok(Object.values(s.record().groups).every(group => group.deliveryFailed === undefined));
});

test('initial inactive baseline is quiet; expired capture and duplicate delivery do not send', async () => {
  const s = setup(); await sendEmergency(s, false);
  assert.equal(sent.length, 0);
  now += 1000;
  await sendEmergency(s, true, { capturedAt: now - 900001 });
  assert.equal(s.record().emergency.active, false);
  await Promise.all(Array.from({ length: 5 }, () => sendEmergency(s, true)));
  assert.equal(sent.length, 1);
});
test('baseline then A→B→newer A sends both real changes; old sources cannot revert it', async () => {
  const s = setup(); assert.equal((await s.send(fixture())).status, 'success'); assert.equal(sent.length, 0);
  await s.send(fixture('06.10.2026 11:00', 'no'), 'python_bridge');
  await s.send(fixture('06.10.2026 12:00', 'yes'), 'cron'); assert.equal(sent.length, 24);
  for (const source of ['cron', 'desktop_bridge', 'python_bridge']) {
    assert.equal((await s.send(fixture('06.10.2026 11:00', 'no'), source)).status, 'stale_snapshot');
  }
  assert.equal(sent.length, 24); assert.equal(s.record().groups.state_GPV1_1, undefined);
  assert.equal(s.record().groups['state_GPV1.1'].todayHash, '0'.repeat(24));
});
test('identical hash advances version and prevents old changes; conflict is atomic', async () => {
  const s = setup(); await s.send(fixture()); await s.send(fixture('06.10.2026 12:00'));
  assert.equal((await s.send(fixture('06.10.2026 11:00', 'no'))).status, 'stale_snapshot');
  const before = structuredClone(s.record());
  const conflict = await s.send(fixture('06.10.2026 12:00', 'no'));
  assert.equal(conflict.status, 'conflicting_version'); assert.deepEqual(conflict.notificationsPlanned, []);
  assert.deepEqual(s.record(), before); assert.equal(sent.length, 0);
});
test('concurrent duplicate uploads serialize and send once per group', async () => {
  const s = setup(); await s.send(fixture());
  await Promise.all(Array.from({ length: 5 }, () => s.send(fixture('06.10.2026 11:00', 'no'))));
  assert.equal(sent.length, 12); assert.equal(new Set(sent.map(m => m.eventId)).size, 12);
});
test('failed delivery is durable, retried after restart, never marked notified prematurely', async () => {
  const s = setup(); await s.send(fixture()); outcome = { success: false, error: 'Unavailable' };
  assert.equal((await s.send(fixture('06.10.2026 11:00', 'no'))).status, 'delivery_pending');
  assert.ok(s.record().groups['state_GPV1.1'].pending); assert.equal(s.record().groups['state_GPV1.1'].lastNotifiedAt, undefined);
  assert.ok(s.alarm()); now += 31000; outcome = { success: true, messageId: 'retried' };
  await new ScheduleMonitor({ storage: s.storage }, s.env).alarm();
  assert.equal(s.record().groups['state_GPV1.1'].pending, undefined); assert.ok(s.record().groups['state_GPV1.1'].lastNotifiedAt);
  assert.equal(s.alarm(), undefined);
});
test('missing credentials retain an outbox and report failure', async () => {
  const s = setup(); s.env.FIREBASE_SERVICE_ACCOUNT = ''; await s.send(fixture());
  assert.equal((await s.send(fixture('06.10.2026 11:00', 'no'))).status, 'delivery_pending'); assert.equal(sent.length, 0);
});
test('dry run never writes storage, alarms or sends', async () => {
  const s = setup(); await s.send(fixture()); const count = s.writes();
  const result = await s.send(fixture('06.10.2026 11:00', 'no'), 'test', true);
  assert.equal(result.status, 'dry_run_success'); assert.equal(result.notificationsPlanned.length, 12);
  assert.equal(s.writes(), count); assert.equal(sent.length, 0); assert.equal(s.alarm(), undefined);
});
test('partial, unknown, old calendar and future snapshots never change state', async () => {
  const s = setup(); await s.send(fixture()); const before = structuredClone(s.record());
  for (const mutate of [f => delete f.data[f.today]['GPV6.2'], f => f.data[f.today]['GPV1.1']['24'] = 'wat',
    f => f.today -= 86400, f => f.update = '06.10.2026 23:00', f => f.update = '31.02.2026 10:00']) {
    const f = fixture(); mutate(f); const report = await s.send(f); assert.notEqual(report.status, 'success');
    assert.deepEqual(s.record(), before);
  }
});
test('tomorrow placeholders are optional but partial publication is rejected', () => {
  const f = fixture(); f.data[f.today + 86400] = Object.fromEntries(ALL_GROUPS.map(g => [g, {}]));
  assert.equal(parseSnapshot(html(f)).days.length, 1);
  f.data[f.today + 86400]['GPV1.1'] = f.data[f.today]['GPV1.1']; assert.throws(() => parseSnapshot(html(f)));
});
test('first tomorrow publication alerts after a today-only baseline, but not on cold start', async () => {
  const s = setup(); await s.send(fixture());
  await s.send(fixture('06.10.2026 11:00', 'yes', true));
  assert.equal(sent.length, 12); assert.ok(sent.every(m => m.changeType === 'tomorrow_published'));
  sent = []; await setup().send(fixture('06.10.2026 11:00', 'yes', true)); assert.equal(sent.length, 0);
});
test('calendar rollover does not reuse previous-day anti-flapping hashes', async () => {
  const s = setup(); await s.send(fixture()); await s.send(fixture('06.10.2026 11:00', 'no'));
  now = Date.parse('2026-10-07T12:00:00Z');
  const f = fixture('07.10.2026 10:00'); f.data = { [f.today + 86400]: f.data[f.today] }; f.today += 86400;
  await s.send(f); assert.equal(sent.length, 12);
  f.update = '07.10.2026 11:00'; f.data[f.today]['GPV1.1']['1'] = 'no';
  await s.send(f); assert.equal(sent.length, 13);
});
test('DST calendar uses the actual next midnight, not 86400 seconds, with fallback support', () => {
  now = Date.parse('2026-10-25T12:00:00Z'); const f = fixture('25.10.2026 10:00'); const day = f.data[f.today];
  f.today = Date.parse('2026-10-24T21:00:00Z') / 1000;
  const next = Date.parse('2026-10-25T22:00:00Z') / 1000; f.data = { [f.today]: day, [next]: day };
  assert.equal(parseSnapshot(html(f)).days[1].dateKey, String(next));
  assert.equal(typeof parseUpdateTime('25.10.2026 03:30', now), 'number');
  assert.equal(typeof parseUpdateTime('25.10.2026 о 03:30', now), 'number');
  assert.throws(() => parseUpdateTime('29.03.2026 03:30'), /Invalid Kyiv update time/);

  const fFallback = fixture('25.10.2026 10:00');
  fFallback.today = Date.parse('2026-10-24T21:00:00Z') / 1000;
  fFallback.data = { [fFallback.today]: day, [fFallback.today + 86400]: day };
  assert.equal(parseSnapshot(html(fFallback)).days[1].dateKey, String(fFallback.today + 86400));
});
test('legacy state imports once and ignores old recentHashes', async () => {
  const f = fixture(); const legacy = { 'state_GPV1.1': JSON.stringify({ dateKey: String(f.today), todayHash: '1'.repeat(24),
    outageMinutes: 1440, dtekUpdateStr: '06.10.2026 09:00', recentHashes: ['0'.repeat(24)] }) };
  const s = setup(legacy); await s.send(f); assert.equal(sent.length, 1);
  assert.equal(s.record().groups['state_GPV1.1'].todayHash, '0'.repeat(24));
});
test('chunked byte limits and malformed UTF8 are enforced', async () => {
  await assert.rejects(readLimitedBody(new ReadableStream({ start(c) { c.enqueue(new Uint8Array(MAX_HTML_BYTES + 1)); c.close(); } })), /2 MiB/);
  await assert.rejects(readLimitedBody(new ReadableStream({ start(c) { c.enqueue(new Uint8Array([255])); c.close(); } })), /UTF-8/);
  assert.equal(await readLimitedBody(new Response('Привіт').body), 'Привіт');
});
test('HTTP boundary validates authentication, methods, groups and report status', async () => {
  const worker = require('../src/index.ts').default;
  const s = setup(); s.env.ADMIN_KEY = 'test-key';
  s.env.SCHEDULE_MONITOR = { idFromName: name => name, get: () => ({ fetch: (url, init) => s.monitor.fetch(new Request(url, init)) }) };
  const call = async (path, body, method = 'POST', key = 'test-key') => worker.fetch(new Request(`https://worker.test${path}`, {
    method, headers: { 'X-Admin-Key': key }, ...(method === 'POST' ? { body } : {}) }), s.env, {});
  assert.equal((await call('/check-html', html(fixture()), 'POST', 'wrong')).status, 401);
  assert.equal((await call('/check-html', undefined, 'GET')).status, 405);
  assert.equal((await call('/test-push?group=INVALID', '')).status, 400);
  assert.equal((await call('/test-push?dayType=invalid', '')).status, 400);
  assert.equal((await call('/test-push?audience=invalid', '')).status, 400);
  assert.equal((await call('/check-html', '<html>login</html>')).status, 422);
  assert.equal((await call('/check-html', html(fixture()))).status, 200);
  outcome = { success: false, error: 'FCM unavailable' };
  assert.equal((await call('/check-html', html(fixture('06.10.2026 11:00', 'no')))).status, 503);
  assert.equal((await call('/check-html', html(fixture('06.10.2026 11:00', 'yes')))).status, 409);
  assert.equal((await call('/check-html', 'x'.repeat(MAX_HTML_BYTES + 1))).status, 413);
});

test('emergency topic test sends an explicit informational alert without mutating monitor state', async () => {
  const worker = require('../src/index.ts').default;
  const s = setup();
  s.env.ADMIN_KEY = 'test-key';
  const response = await worker.fetch(new Request('https://worker.test/test-push?audience=emergency&title=Misleading', {
    headers: { 'X-Admin-Key': 'test-key' },
  }), s.env, {});
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.topic, 'emergency_alerts');
  assert.equal(result.audience, 'emergency');
  assert.equal(result.requiredClientTopic, 'lumen_diagnostics_v1');
  assert.equal(result.group, undefined);
  assert.equal(result.dayType, undefined);
  assert.deepEqual(result.ignoredParameters, ['title']);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].changeType, 'test');
  assert.equal(sent[0].group, 'EMERGENCY');
  assert.equal(sent[0].dayType, undefined);
  assert.equal(sent[0].testAudience, 'emergency');
  assert.equal(sent[0].isEmergency, undefined);
  assert.match(sent[0].title, /тест каналу/);
  assert.match(sent[0].body, /Статус відключень і графіки не змінено/);
  assert.equal(s.record(), undefined);
  assert.equal(s.writes(), 0);
});

test('emergency tests ignore schedule selectors explicitly and group tests retain their targeting', async () => {
  const worker = require('../src/index.ts').default;
  const s = setup(); s.env.ADMIN_KEY = 'test-key';
  const call = query => worker.fetch(new Request(`https://worker.test/test-push?${query}`, {
    method: 'POST', headers: { 'X-Admin-Key': 'test-key' },
  }), s.env, {});
  const emergency = await call('audience=emergency&group=all&dayType=invalid&title=Misleading&body=Misleading');
  assert.equal(emergency.status, 200);
  assert.deepEqual((await emergency.json()).ignoredParameters, ['group', 'dayType', 'title', 'body']);
  assert.equal(sent[0].group, 'EMERGENCY');
  assert.match(sent[0].title, /тест каналу/);
  assert.match(sent[0].body, /тестове повідомлення/);
  assert.equal((await call('audience=emergency&group=')).status, 200);
  const group = await call('audience=group&group=GPV1.1&dayType=tomorrow&title=Custom&body=Body');
  assert.equal(group.status, 200);
  const result = await group.json();
  assert.equal(result.audience, 'group');
  assert.equal(result.group, 'GPV1.1');
  assert.equal(result.dayType, 'tomorrow');
  assert.equal(result.ignoredParameters, undefined);
  assert.equal(sent[2].topic, 'group_gpv1_1_tomorrow');
  assert.equal(sent[2].testAudience, 'group');
  assert.equal(sent[2].title, 'Custom');
  assert.equal(sent[2].body, 'Body');
  assert.equal(s.writes(), 0);
});

test('cron accepts emergency-only success but warns on report errors and delivery failures', async () => {
  const worker = require('../src/index.ts').default;
  const originalFetch = global.fetch;
  const originalWarn = console.warn;
  const originalLog = console.log;
  const warnings = [];
  let status = 'emergency_only';
  let errors = [];
  global.fetch = async () => new Response('<div id="modal-attention">Введені екстрені відключення</div>');
  console.warn = (...args) => warnings.push(args.join(' '));
  console.log = () => {};
  const env = { SCHEDULE_MONITOR: {
    idFromName: name => name,
    get: () => ({ fetch: async () => Response.json({ status, errors }) }),
  } };
  try {
    for (const expected of ['success', 'dry_run_success', 'emergency_only', 'stale_snapshot', 'bot_challenge_detected']) {
      status = expected;
      errors = ['stale_snapshot', 'bot_challenge_detected'].includes(expected) ? ['Expected upstream response'] : [];
      await worker.scheduled({}, env, {});
    }
    assert.deepEqual(warnings, []);
    errors = ['Emergency delivery failed'];
    status = 'emergency_only';
    await worker.scheduled({}, env, {});
    assert.equal(warnings.length, 1);
    errors = [];
    status = 'delivery_pending';
    await worker.scheduled({}, env, {});
    assert.equal(warnings.length, 2);
  } finally {
    global.fetch = originalFetch;
    console.warn = originalWarn;
    console.log = originalLog;
  }
});

test('old full snapshot cannot fill a missing tomorrow after a newer today-only snapshot', async () => {
  const s = setup(); await s.send(fixture('06.10.2026 12:00'));
  assert.equal((await s.send(fixture('06.10.2026 11:00', 'no', true))).status, 'stale_snapshot');
  assert.equal(s.record().groups['state_tomorrow_GPV1.1'], undefined); assert.equal(sent.length, 0);
});
test('withdrawal cancels pending tomorrow and equal-version publication conflicts atomically', async () => {
  const s = setup(); await s.send(fixture()); outcome = { success: false, error: 'offline' };
  await s.send(fixture('06.10.2026 11:00', 'yes', true));
  assert.ok(s.record().groups['state_tomorrow_GPV1.1'].pending);
  await s.send(fixture('06.10.2026 12:00'));
  assert.equal(s.record().groups['state_tomorrow_GPV1.1'], undefined);
  outcome = { success: true, messageId: 'ok' }; sent = []; now += 31000; await s.monitor.alarm();
  assert.equal(sent.length, 0);
  assert.equal((await s.send(fixture('06.10.2026 12:00', 'yes', true))).status, 'conflicting_version');
  await s.send(fixture('06.10.2026 13:00', 'yes', true)); assert.equal(sent.length, 12);
});
test('midnight retains target-date watermark and detects changes from published tomorrow', async () => {
  now = Date.parse('2026-10-06T20:30:00Z'); const s = setup(); await s.send(fixture('06.10.2026 23:00', 'yes', true));
  now = Date.parse('2026-10-07T00:00:00Z');
  const next = fixture('06.10.2026 22:00', 'no');
  next.data = { [next.today + 86400]: next.data[next.today] }; next.today += 86400;
  assert.equal((await s.send(next)).status, 'stale_snapshot');
  next.update = '07.10.2026 02:00';
  assert.equal((await s.send(next)).status, 'success');
  assert.equal(sent.length, 12); assert.ok(sent.every(m => m.dayType === 'today'));
});
test('non-midnight tomorrow keys and duplicate date keys are rejected', () => {
  const f = fixture(); f.data[f.today + 86400 + 3600] = f.data[f.today];
  assert.throws(() => parseSnapshot(html(f)), /midnight/);
  f.data[f.today + 86400] = f.data[f.today];
  assert.throws(() => parseSnapshot(html(f)), /Ambiguous/);
});

test('calendar rollback cannot replace a newer-day baseline even with the same source time', async () => {
  now = Date.parse('2026-10-06T21:05:00Z');
  const s = setup(); const next = fixture('07.10.2026 00:00');
  next.data = { [next.today + 86400]: next.data[next.today] }; next.today += 86400;
  assert.equal((await s.send(next)).status, 'success');
  const before = structuredClone(s.record()); now = Date.parse('2026-10-06T20:55:00Z');
  assert.equal((await s.send(fixture('07.10.2026 00:00', 'no'))).status, 'stale_snapshot');
  assert.deepEqual(s.record(), before);
});
