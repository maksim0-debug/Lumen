const { test, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const ts = require('typescript');
const fs = require('node:fs');
global.crypto ??= require('node:crypto').webcrypto;
require.extensions['.ts'] = (module, filename) => module._compile(ts.transpileModule(
  fs.readFileSync(filename, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2022 } }).outputText, filename);
const fcm = require('../src/fcm.ts');
const worker = require('../src/index.ts').default;
const { ALL_GROUPS, calendarDate, parseUpdateTime } = require('../src/schedule.ts');
const originalSend = fcm.sendFcmTopicNotification;
afterEach(() => { fcm.sendFcmTopicNotification = originalSend; });

function environment() {
  const forwarded = [];
  return { forwarded, env: { ADMIN_KEY: 'local-test-key',
    FIREBASE_SERVICE_ACCOUNT: JSON.stringify({ project_id: 'qa',
      private_key: 'fixture', client_email: 'qa@example.com' }),
    SCHEDULE_MONITOR: {
      idFromName: name => name,
      get: () => ({ fetch: async url => {
        forwarded.push(url); return Response.json({ test: true });
      } }),
    } } };
}

test('public schedule API forwards read-only calls without admin authorization', async () => {
  const { env, forwarded } = environment();
  for (const path of ['/api/v1/snapshot', '/api/v1/publications?after=12&limit=32']) {
    const response = await worker.fetch(new Request('https://worker.test' + path), env, {});
    assert.equal(response.status, 200);
    assert.equal(forwarded.at(-1), 'https://monitor.internal' + path);
    const denied = await worker.fetch(new Request('https://worker.test' + path,
      { method: 'POST' }), env, {});
    assert.equal(denied.status, 405);
    assert.equal(denied.headers.get('Allow'), 'GET');
  }
  assert.equal(forwarded.length, 2);
});

test('snapshot diagnostics require authorization and cannot target production topics', async () => {
  const { env, forwarded } = environment();
  let sends = 0; fcm.sendFcmTopicNotification = async () => { sends++; return { success: true }; };
  const unauthorized = await worker.fetch(new Request('https://worker.test/test-snapshot',
    { method: 'POST', body: 'irrelevant' }), env, {});
  assert.equal(unauthorized.status, 401);
  for (const query of ['topic=lumen_schedules_v1', 'topic=group_gpv2_1_v2',
    `topic=lumen_snapshot_qa_${'a'.repeat(32)}&sequence=-1`,
    `topic=lumen_snapshot_qa_${'a'.repeat(32)}&alerts=16777216`]) {
    const rejected = await worker.fetch(new Request('https://worker.test/test-snapshot?' + query,
      { method: 'POST', headers: { 'X-Admin-Key': 'local-test-key' }, body: 'irrelevant' }), env, {});
    assert.equal(rejected.status, 400);
  }
  assert.equal(sends, 0);
  assert.equal(forwarded.length, 0);
});

test('authorized snapshot QA sends all groups without writing the production coordinator', async () => {
  const { env, forwarded } = environment();
  let captured; fcm.sendFcmTopicNotification = async (_, options) => {
    captured = options; return { success: true, messageId: 'qa' };
  };
  const date = calendarDate(), [year, month, day] = date.split('-');
  const clock = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Kyiv',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(Date.now());
  const update = `${day}.${month}.${year} ${clock}`;
  const today = parseUpdateTime(`${day}.${month}.${year} 00:00`) / 1000;
  const fact = { today, update, data: { [today]: Object.fromEntries(ALL_GROUPS.map(group =>
    [group, Object.fromEntries(Array.from({ length: 24 }, (_, i) => [String(i + 1), 'yes']))])) } };
  const topic = `lumen_snapshot_qa_${'b'.repeat(32)}`;
  const response = await worker.fetch(new Request(`https://worker.test/test-snapshot?topic=${topic}&sequence=7&alerts=16`,
    { method: 'POST', headers: { Authorization: 'Bearer local-test-key' },
      body: `<script>DisconSchedule.fact=${JSON.stringify(fact)};</script>` }), env, {});
  assert.equal(response.status, 200);
  assert.equal(captured.snapshotTestTopic, topic);
  assert.equal(captured.snapshot.sequence, 7);
  assert.equal(captured.snapshot.alerts, 16);
  assert.equal(captured.snapshot.sourceVersion, parseUpdateTime(update));
  assert.equal(Object.keys(captured.snapshot.groups).length, 12);
  assert.equal(forwarded.length, 0);
});
