const { test, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const ts = require('typescript');
const fs = require('node:fs');
const { webcrypto } = require('node:crypto');
global.crypto ??= webcrypto;
require.extensions['.ts'] = (module, filename) => module._compile(ts.transpileModule(
  fs.readFileSync(filename, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, filename);
const realFetch = global.fetch;
let fcm, account, oauthCalls, fcmCalls, messages, status;
beforeEach(async () => {
  delete require.cache[require.resolve('../src/fcm.ts')]; fcm = require('../src/fcm.ts');
  const key = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
  account = { project_id: 'test', client_email: 'test@example.com', private_key: '-----BEGIN PRIVATE KEY-----\n' +
    Buffer.from(await crypto.subtle.exportKey('pkcs8', key.privateKey)).toString('base64') + '\n-----END PRIVATE KEY-----' };
  oauthCalls = 0; fcmCalls = 0; messages = []; status = 200;
  global.fetch = async (url, options) => {
    assert.ok(options.signal);
    if (String(url).includes('oauth2')) { oauthCalls++; return Response.json({ access_token: 'token', expires_in: 3600 }); }
    fcmCalls++; messages.push(JSON.parse(options.body));
    return status === 200 ? Response.json({ name: 'projects/test/messages/test' }) : new Response('failed', { status });
  };
});
after(() => { global.fetch = realFetch; });
const options = { topic: 'group_gpv1_1', group: 'GPV1.1', title: 'test', body: 'test', eventId: 'event', targetDate: '2026-10-06' };
test('parallel FCM sends share one OAuth exchange and retain event metadata', async () => {
  const results = await Promise.all(Array.from({ length: 12 }, () => fcm.sendFcmTopicNotification(account, options)));
  assert.ok(results.every(r => r.success)); assert.equal(oauthCalls, 1); assert.equal(fcmCalls, 12);
  assert.equal(messages[0].message.data.eventId, 'event'); assert.equal(messages[0].message.android.notification.tag, 'event');
  assert.equal(messages[0].message.android.ttl, '900s');
});
test('401 invalidates cached access token before retry', async () => {
  status = 401; assert.equal((await fcm.sendFcmTopicNotification(account, options)).success, false);
  status = 200; assert.equal((await fcm.sendFcmTopicNotification(account, options)).success, true); assert.equal(oauthCalls, 2);
});
test('HTTP 200 without FCM acknowledgement is not accepted', async () => {
  global.fetch = async url => String(url).includes('oauth2') ? Response.json({ access_token: 'token', expires_in: 3600 }) : Response.json({});
  assert.equal((await fcm.sendFcmTopicNotification(account, options)).success, false);
});
test('malformed service accounts and OAuth responses fail explicitly', async () => {
  assert.equal(fcm.getServiceAccount('{'), null);
  assert.equal(fcm.getServiceAccount(JSON.stringify({ project_id: {}, private_key: 'k', client_email: 'e' })), null);
  global.fetch = async () => Response.json({ expires_in: 3600 });
  assert.equal((await fcm.sendFcmTopicNotification(account, options)).success, false);
});

test('emergency delivery is data-only with explicit status and remaining TTL', async () => {
  const observedAt = Date.now() - 30000;
  const emergency = { ...options, group: 'EMERGENCY', topic: 'emergency_alerts',
    changeType: 'emergency_alert', isEmergency: false, observedAt, expiresAt: observedAt + 900000 };
  assert.equal((await fcm.sendFcmTopicNotification(account, emergency)).success, true);
  const message = messages[0].message;
  assert.equal(message.notification, undefined);
  assert.equal(message.android.notification, undefined);
  assert.equal(message.data.isEmergency, 'false');
  assert.equal(message.data.observedAt, String(observedAt));
  assert.equal(message.data.expiresAt, String(emergency.expiresAt));
  assert.equal(message.data.title, 'test');
  assert.ok(parseInt(message.android.ttl) <= 870 && parseInt(message.android.ttl) >= 860);
  assert.equal(message.android.priority, 'HIGH');
  assert.equal(message.android.collapse_key, 'emergency_status');
});

test('expired and incomplete emergency envelopes are rejected before network access', async () => {
  for (const extra of [{}, { isEmergency: true, observedAt: Date.now() - 900001, expiresAt: Date.now() - 1 },
    { isEmergency: false, observedAt: Date.now(), expiresAt: Date.now() + 1000000 }]) {
    const result = await fcm.sendFcmTopicNotification(account, { ...options, changeType: 'emergency_alert', ...extra });
    assert.equal(result.success, false);
    assert.equal(result.retryable, false);
  }
  assert.equal(oauthCalls, 0);
  assert.equal(fcmCalls, 0);
});

test('local emergency pushes retain full text within FCM byte budget', async () => {
  const observedAt = Date.now();
  const noticeText = 'Аварійні відключення у Бучанському районі.\n\nЕнергетики працюють.';
  const emergency = { ...options, group: 'EMERGENCY', topic: 'emergency_alerts',
    changeType: 'emergency_alert', isEmergency: true, isPossible: true, noticeText,
    observedAt, expiresAt: observedAt + 900000 };
  assert.equal((await fcm.sendFcmTopicNotification(account, emergency)).success, true);
  assert.equal(messages[0].message.data.isPossible, 'true');
  assert.equal(messages[0].message.data.noticeText, noticeText);
  assert.equal((await fcm.sendFcmTopicNotification(account, { ...emergency, noticeText: 'я'.repeat(2001) })).success, true);
  assert.equal(messages[1].message.data.noticeText, undefined);
  assert.ok(Buffer.byteLength(JSON.stringify(messages[1].message)) < 4096);
});

test('diagnostic pushes are data-only and never carry operational status or schedule mutations', async () => {
  for (const audience of ['emergency', 'group']) {
    const result = await fcm.sendFcmTopicNotification(account, {
      ...options, changeType: 'test', testAudience: audience,
      topic: audience === 'emergency' ? 'emergency_alerts' : 'group_gpv1_1_tomorrow',
      group: audience === 'emergency' ? 'EMERGENCY' : 'GPV1.1', dayType: 'tomorrow',
    });
    assert.equal(result.success, true);
    const message = messages.at(-1).message;
    assert.equal(message.topic, undefined);
    assert.equal(message.condition,
      audience === 'emergency' ? "'emergency_alerts' in topics && 'lumen_diagnostics_v1' in topics"
        : "('group_gpv1_1_tomorrow' in topics || 'group_gpv1_1_v2_tomorrow' in topics) && 'lumen_diagnostics_v1' in topics");
    assert.equal(message.notification, undefined);
    assert.equal(message.android.notification, undefined);
    assert.equal(message.android.collapse_key, undefined);
    assert.equal(message.data.type, 'test');
    assert.equal(message.data.testAudience, audience);
    assert.equal(message.data.title, 'test');
    assert.equal(message.data.body, 'test');
    assert.equal(message.data.eventId, 'event');
    assert.equal(message.data.isEmergency, undefined);
    assert.equal(message.data.observedAt, undefined);
    assert.equal(message.data.expiresAt, undefined);
    assert.equal(message.data.scheduleHash, undefined);
    assert.equal(message.data.outageMinutes, undefined);
    assert.equal(message.data.targetDate, undefined);
    assert.equal(message.data.dayType, audience === 'group' ? 'tomorrow' : undefined);
    assert.equal(message.apns.headers['apns-push-type'], 'background');
    assert.equal(message.apns.payload.aps['content-available'], 1);
  }
});

test('diagnostic envelopes require an explicit audience before network access', async () => {
  const result = await fcm.sendFcmTopicNotification(account, { ...options, changeType: 'test' });
  assert.equal(result.success, false);
  assert.equal(result.retryable, false);
  assert.equal(oauthCalls, 0);
  assert.equal(fcmCalls, 0);
  const injection = await fcm.sendFcmTopicNotification(account, {
    ...options, changeType: 'test', testAudience: 'group', topic: "invalid' || 'other",
  });
  assert.equal(injection.success, false);
  assert.equal(oauthCalls, 0);
  assert.equal(fcmCalls, 0);
});

test('permanent and transient FCM failures have different retry policies', async () => {
  for (const code of [400, 403, 404, 401, 429, 500, 503]) {
    status = code;
    const result = await fcm.sendFcmTopicNotification(account, options);
    assert.equal(result.retryable, [401, 429, 500, 503].includes(code));
  }
});

const scheduleOptions = () => ({ ...options, group: 'GPV2.1', topic: 'group_gpv2_1',
  changeType: 'schedule_updated', scheduleHash: '011111000000000000000000',
  targetDate: '2026-10-09', sourceVersion: 1791498120000,
  eventId: 'GPV2.1:2026-10-09:1791498120000:011111000000000000000000',
  title: 'Графік змінено! (Група 2.1)', body: 'Світла стало БІЛЬШЕ на 1 год. 🎉',
});

test('schedule delivery preserves legacy display and provides data-only v2 to a disjoint topic', async () => {
  const result = await fcm.sendFcmTopicNotification(account, scheduleOptions());
  assert.equal(result.success, true);
  assert.deepEqual(result.deliveredModes.sort(), ['client', 'legacy']);
  assert.equal(oauthCalls, 1);
  assert.equal(fcmCalls, 2);
  const legacy = messages.find(p => p.message.topic === 'group_gpv2_1').message;
  const client = messages.find(p => p.message.topic === 'group_gpv2_1_v2').message;
  assert.ok(legacy.notification);
  assert.equal(client.notification, undefined);
  assert.equal(client.android.notification, undefined);
  assert.equal(client.android.collapse_key, undefined);
  assert.equal(client.data.sourceVersion, '1791498120000');
  assert.equal(client.data.schemaVersion, '2');
  assert.equal(client.data.eventId, legacy.data.eventId);
  assert.equal(client.data.title, scheduleOptions().title);
  assert.equal(client.data.body, scheduleOptions().body);
  assert.equal(client.android.priority, 'HIGH');
  assert.ok(Buffer.byteLength(JSON.stringify(client)) < 4096);
});

test('partial schedule delivery retries only the unacknowledged audience', async () => {
  const originalFetch = global.fetch;
  global.fetch = async (url, args) => {
    if (String(url).includes('messages:send') && JSON.parse(args.body).message.topic.endsWith('_v2')) {
      return new Response('transient', { status: 503 });
    }
    return originalFetch(url, args);
  };
  const first = await fcm.sendFcmTopicNotification(account, scheduleOptions());
  assert.equal(first.success, false);
  assert.equal(first.retryable, true);
  assert.deepEqual(first.deliveredModes, ['legacy']);
  global.fetch = originalFetch;
  const second = await fcm.sendFcmTopicNotification(account, {
    ...scheduleOptions(), deliveredModes: first.deliveredModes,
  });
  assert.equal(second.success, true);
  assert.deepEqual(second.deliveredModes.sort(), ['client', 'legacy']);
  assert.equal(messages.filter(p => p.message.topic === 'group_gpv2_1').length, 1);
});

test('legacy pending schedule outboxes derive original source version from event ID', async () => {
  const opts = scheduleOptions(); delete opts.sourceVersion;
  assert.equal((await fcm.sendFcmTopicNotification(account, opts)).success, true);
  assert.ok(messages.every(p => p.message.data.sourceVersion === '1791498120000'));
});

test('tomorrow uses a separate v2 topic and incomplete schedule envelopes do not send', async () => {
  const opts = { ...scheduleOptions(), dayType: 'tomorrow', topic: 'group_gpv2_1_tomorrow',
    changeType: 'tomorrow_schedule_updated' };
  assert.equal((await fcm.sendFcmTopicNotification(account, opts)).success, true);
  assert.equal(messages[1].message.topic, 'group_gpv2_1_v2_tomorrow');
  const before = fcmCalls;
  for (const field of [{ scheduleHash: 'bad' }, { eventId: 'bad' }, { sourceVersion: 0 }, { group: 'GPV9.1' }]) {
    const result = await fcm.sendFcmTopicNotification(account, { ...opts, ...field });
    assert.equal(result.success, false);
    assert.equal(result.retryable, false);
  }
  assert.equal(fcmCalls, before);
});
