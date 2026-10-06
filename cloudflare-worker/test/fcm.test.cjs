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
