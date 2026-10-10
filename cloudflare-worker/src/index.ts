import { DIAGNOSTIC_CLIENT_TOPIC, getServiceAccount, groupToTopic, sendFcmTopicNotification } from './fcm';
import { ALL_GROUPS, DTEK_URL, MAX_HTML_BYTES, PayloadError, readLimitedBody } from './schedule';
import type { MonitoringReport } from './monitor';
import { EMERGENCY_TOPIC } from './emergency';
import { compactSnapshot, SNAPSHOT_TOPIC } from './snapshot';
import { parseSnapshot } from './schedule';
export { ALL_GROUPS } from './schedule';
export { ScheduleMonitor } from './monitor';
export type { MonitoringReport } from './monitor';

const SUCCESS_REPORT_STATUSES = ['success', 'dry_run_success', 'emergency_only'];

export interface Env {
  SCHEDULE_KV: KVNamespace;
  SCHEDULE_MONITOR: DurableObjectNamespace;
  PROJECT_ID?: string;
  FIREBASE_SERVICE_ACCOUNT?: string;
  ADMIN_KEY?: string;
}

async function isAuthorized(request: Request, env: Env): Promise<boolean> {
  const configured = env.ADMIN_KEY?.trim();
  if (!configured) return false;
  const header = request.headers.get('X-Admin-Key') ?? request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '');
  const candidate = (header || new URL(request.url).searchParams.get('key'))?.trim();
  if (!candidate) return false;
  const encoder = new TextEncoder();
  const hashes = await Promise.all([configured, candidate].map(key => crypto.subtle.digest('SHA-256', encoder.encode(key))));
  const expected = new Uint8Array(hashes[0]);
  const actual = new Uint8Array(hashes[1]);
  let mismatch = 0;
  for (let i = 0; i < expected.length; i++) mismatch |= expected[i] ^ actual[i];
  return mismatch === 0;
}

export async function processScheduleHtml(html: string, env: Env, source = 'cron_fetch', dryRun = false, observedAt?: number): Promise<MonitoringReport> {
  if (!env.SCHEDULE_MONITOR) throw new Error('SCHEDULE_MONITOR Durable Object binding is not configured');
  const object = env.SCHEDULE_MONITOR.get(env.SCHEDULE_MONITOR.idFromName('dtek-krem'));
  const response = await object.fetch('https://monitor.internal/process', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ html, source, dryRun, observedAt }),
  });
  if (!response.ok) throw new Error(`Schedule coordinator failed: HTTP ${response.status}`);
  return response.json() as Promise<MonitoringReport>;
}

function errorResponse(error: unknown): Response {
  const status = error instanceof PayloadError ? (error.status === 'payload_too_large' ? 413
    : error.status === 'request_timeout' ? 408 : 400) : 503;
  return Response.json({ error: error instanceof Error ? error.message : 'Request failed' }, { status });
}

function reportResponse(report: MonitoringReport): Response {
  const success = SUCCESS_REPORT_STATUSES.includes(report.status) && report.errors.length === 0;
  const status = success ? 200 : ['stale_snapshot', 'conflicting_version'].includes(report.status) ? 409
    : ['delivery_pending', 'delivery_failed', 'storage_error'].includes(report.status) ? 503 : 422;
  return Response.json(report, { status });
}

async function runMonitoringCheck(env: Env): Promise<MonitoringReport> {
  const startedAt = Date.now();
  const response = await fetch(DTEK_URL, { signal: AbortSignal.timeout(20_000),
    headers: { 'User-Agent': 'Mozilla/5.0', 'Accept-Language': 'uk-UA,uk;q=0.9', 'Cache-Control': 'no-cache, no-store' } });
  if (!response.ok) throw new Error(`DTEK HTTP ${response.status}`);
  const html = await readLimitedBody(response.body);
  const date = Date.parse(response.headers.get('Date') ?? '');
  const age = Number(response.headers.get('Age') ?? 0);
  const observedAt = Math.min(startedAt - (Number.isFinite(age) && age >= 0 ? age * 1000 : 0),
    Number.isFinite(date) ? date : startedAt);
  return processScheduleHtml(html, env, 'cron_fetch', false, observedAt);
}

export default {
  async scheduled(_event: ScheduledEvent, env: Env, _ctx: ExecutionContext): Promise<void> {
    try {
      const report = await runMonitoringCheck(env);
      console.log('Cron execution result:', JSON.stringify(report));
      // bot_challenge_detected is expected when direct Cloudflare datacenter IP is challenged by DTEK WAF.
      const success = SUCCESS_REPORT_STATUSES.includes(report.status) && report.errors.length === 0;
      const expectedFailure = ['stale_snapshot', 'bot_challenge_detected'].includes(report.status);
      if (!success && !expectedFailure) {
        console.warn(`Cron monitoring non-success status: ${report.status}`);
      }
    } catch (error) {
      // Direct network/fetch errors against DTEK should not crash the scheduled execution.
      console.warn('Cron fetch encountered transient error:', error instanceof Error ? error.message : String(error));
    }
  },
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (['/api/v1/snapshot', '/api/v1/publications'].includes(url.pathname)) {
      if (request.method !== 'GET') return new Response('Method Not Allowed', { status: 405, headers: { Allow: 'GET' } });
      const object = env.SCHEDULE_MONITOR.get(env.SCHEDULE_MONITOR.idFromName('dtek-krem'));
      try { return await object.fetch(`https://monitor.internal${url.pathname}${url.search}`); }
      catch { return Response.json({ error: 'Schedule service unavailable' }, { status: 503 }); }
    }
    if (url.pathname === '/') return Response.json({ app: 'Lumen Schedule Monitor', interval: '5 minutes',
      endpoints: ['/check', '/check-html', '/test-push', '/test-snapshot', '/api/v1/snapshot', '/api/v1/publications'],
      authorization: 'X-Admin-Key or Bearer token for administrative endpoints',
      maxHtmlBytes: MAX_HTML_BYTES });
    if (!['/check', '/check-html', '/test-push', '/test-snapshot'].includes(url.pathname)) return new Response('Not Found', { status: 404 });
    if (!await isAuthorized(request, env)) return Response.json({ error: 'Unauthorized' }, { status: 401 });
    const allowed = ['/check-html', '/test-snapshot'].includes(url.pathname) ? ['POST'] : ['GET', 'POST'];
    if (!allowed.includes(request.method)) return Response.json({ error: 'Method Not Allowed' },
      { status: 405, headers: { Allow: allowed.join(', ') } });
    try {
      if (url.pathname === '/test-snapshot') {
        const topic = url.searchParams.get('topic') ?? '';
        const sequence = Number(url.searchParams.get('sequence') ?? '1');
        const alerts = Number(url.searchParams.get('alerts') ?? '0');
        if (!/^lumen_snapshot_qa_[a-f0-9]{32}$/.test(topic) || !Number.isSafeInteger(sequence) || sequence < 1 ||
            !Number.isInteger(alerts) || alerts < 0 || alerts > 0xffffff) {
          return Response.json({ error: 'Invalid isolated snapshot test' }, { status: 400 });
        }
        const snapshot = compactSnapshot(parseSnapshot(await readLimitedBody(request.body)),
          topic.slice('lumen_snapshot_qa_'.length), sequence);
        snapshot.alerts = alerts;
        const account = getServiceAccount(env.FIREBASE_SERVICE_ACCOUNT);
        if (!account) return Response.json({ error: 'Firebase credentials unavailable' }, { status: 503 });
        const outcome = await sendFcmTopicNotification(account, {
          topic: SNAPSHOT_TOPIC, snapshotTestTopic: topic, group: 'ALL', changeType: 'schedule_snapshot',
          title: '', body: '', snapshot, eventId: `${snapshot.journalId}:${sequence}`,
        });
        return Response.json({ outcome, sequence }, { status: outcome.success ? 200 : 502 });
      }
      if (url.pathname === '/check') return reportResponse(await runMonitoringCheck(env));
      if (url.pathname === '/check-html') {
        const declared = request.headers.get('Content-Length');
        if (declared && (!/^\d+$/.test(declared) || Number(declared) > MAX_HTML_BYTES)) {
          throw new PayloadError('Invalid or oversized Content-Length', 'payload_too_large');
        }
        const html = await readLimitedBody(request.body);
        const dryRun = url.searchParams.get('dryRun') === 'true' || request.headers.get('X-Dry-Run') === 'true';
        const source = url.searchParams.get('source')?.trim() || 'macro_post';
        if (!/^[a-zA-Z0-9_-]{1,64}$/.test(source)) return Response.json({ error: 'Invalid source' }, { status: 400 });
        return reportResponse(await processScheduleHtml(html, env, source, dryRun));
      }
      const audience = url.searchParams.get('audience') ?? 'group';
      if (!['group', 'emergency'].includes(audience)) {
        return Response.json({ error: 'Invalid audience' }, { status: 400 });
      }
      const emergencyTest = audience === 'emergency';
      // Emergency diagnostics have no schedule group or operational status.
      const group = emergencyTest ? 'EMERGENCY' : url.searchParams.get('group')?.trim() ?? 'GPV2.1';
      const dayType = emergencyTest ? undefined : url.searchParams.get('dayType') ?? 'today';
      if (!emergencyTest && (!ALL_GROUPS.includes(group) || !['today', 'tomorrow'].includes(dayType!))) {
        return Response.json({ error: 'Invalid group or dayType' }, { status: 400 });
      }
      const account = getServiceAccount(env.FIREBASE_SERVICE_ACCOUNT);
      if (!account) return Response.json({ error: 'Firebase credentials are missing or invalid' }, { status: 503 });
      const topic = emergencyTest ? EMERGENCY_TOPIC : groupToTopic(group, dayType as 'today' | 'tomorrow');
      const fcmResult = await sendFcmTopicNotification(account, {
        topic, group, dayType: dayType as 'today' | 'tomorrow' | undefined, changeType: 'test',
        testAudience: emergencyTest ? 'emergency' : 'group',
        title: emergencyTest ? 'Lumen: тест каналу екстрених відключень'
          : url.searchParams.get('title')?.trim().slice(0, 200) || `Тестове сповіщення Lumen (${group.replace('GPV', 'Група ')})`,
        body: emergencyTest ? 'Це тестове повідомлення. Статус відключень і графіки не змінено.'
          : url.searchParams.get('body')?.trim().slice(0, 500) || 'FCM push-інфраструктура працює.',
        eventId: `${topic}:test:${crypto.randomUUID()}`,
      });
      const ignoredParameters = emergencyTest
        ? ['group', 'dayType', 'title', 'body'].filter(name => url.searchParams.has(name)) : [];
      return Response.json({ audience, topic, requiredClientTopic: DIAGNOSTIC_CLIENT_TOPIC, fcmResult,
        ...(!emergencyTest ? { group, dayType } : {}),
        ...(ignoredParameters.length ? { ignoredParameters } : {}),
      }, { status: fcmResult.success ? 200 : 502 });
    } catch (error) { return errorResponse(error); }
  },
};
