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
  assert.equal((await call('/check-html', '<html>login</html>')).status, 422);
  assert.equal((await call('/check-html', html(fixture()))).status, 200);
  outcome = { success: false, error: 'FCM unavailable' };
  assert.equal((await call('/check-html', html(fixture('06.10.2026 11:00', 'no')))).status, 503);
  assert.equal((await call('/check-html', html(fixture('06.10.2026 11:00', 'yes')))).status, 409);
  assert.equal((await call('/check-html', 'x'.repeat(MAX_HTML_BYTES + 1))).status, 413);
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
