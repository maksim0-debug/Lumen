import { getServiceAccount, groupToTopic, sendFcmTopicNotification } from './fcm';
import { ALL_GROUPS, DTEK_URL, MAX_HTML_BYTES, PayloadError, readLimitedBody } from './schedule';
import type { MonitoringReport } from './monitor';
export { ALL_GROUPS } from './schedule';
export { ScheduleMonitor } from './monitor';
export type { MonitoringReport } from './monitor';

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

export async function processScheduleHtml(html: string, env: Env, source = 'cron_fetch', dryRun = false): Promise<MonitoringReport> {
  if (!env.SCHEDULE_MONITOR) throw new Error('SCHEDULE_MONITOR Durable Object binding is not configured');
  const object = env.SCHEDULE_MONITOR.get(env.SCHEDULE_MONITOR.idFromName('dtek-krem'));
  const response = await object.fetch('https://monitor.internal/process', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ html, source, dryRun }),
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
  const success = report.status === 'success' || report.status === 'dry_run_success';
  const status = success ? 200 : ['stale_snapshot', 'conflicting_version'].includes(report.status) ? 409
    : ['delivery_pending', 'storage_error'].includes(report.status) ? 503 : 422;
  return Response.json(report, { status });
}

async function runMonitoringCheck(env: Env): Promise<MonitoringReport> {
  const response = await fetch(DTEK_URL, { signal: AbortSignal.timeout(20_000),
    headers: { 'User-Agent': 'Mozilla/5.0', 'Accept-Language': 'uk-UA,uk;q=0.9', 'Cache-Control': 'no-cache' } });
  if (!response.ok) throw new Error(`DTEK HTTP ${response.status}`);
  const html = await readLimitedBody(response.body);
  return processScheduleHtml(html, env);
}

export default {
  async scheduled(_event: ScheduledEvent, env: Env, _ctx: ExecutionContext): Promise<void> {
    try {
      const report = await runMonitoringCheck(env);
      console.log('Cron execution result:', JSON.stringify(report));
      // bot_challenge_detected is expected when direct Cloudflare datacenter IP is challenged by DTEK WAF.
      if (!['success', 'stale_snapshot', 'bot_challenge_detected'].includes(report.status)) {
        console.warn(`Cron monitoring non-success status: ${report.status}`);
      }
    } catch (error) {
      // Direct network/fetch errors against DTEK should not crash the scheduled execution.
      console.warn('Cron fetch encountered transient error:', error instanceof Error ? error.message : String(error));
    }
  },
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === '/') return Response.json({ app: 'Lumen Schedule Monitor', interval: '5 minutes',
      endpoints: ['/check', '/check-html', '/test-push'], authorization: 'X-Admin-Key or Bearer token',
      maxHtmlBytes: MAX_HTML_BYTES });
    if (!['/check', '/check-html', '/test-push'].includes(url.pathname)) return new Response('Not Found', { status: 404 });
    if (!await isAuthorized(request, env)) return Response.json({ error: 'Unauthorized' }, { status: 401 });
    const allowed = url.pathname === '/check-html' ? ['POST'] : ['GET', 'POST'];
    if (!allowed.includes(request.method)) return Response.json({ error: 'Method Not Allowed' },
      { status: 405, headers: { Allow: allowed.join(', ') } });
    try {
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
      const group = url.searchParams.get('group')?.trim() ?? 'GPV2.1';
      const dayType = url.searchParams.get('dayType') ?? 'today';
      if (!ALL_GROUPS.includes(group) || !['today', 'tomorrow'].includes(dayType)) {
        return Response.json({ error: 'Invalid group or dayType' }, { status: 400 });
      }
      const account = getServiceAccount(env.FIREBASE_SERVICE_ACCOUNT);
      if (!account) return Response.json({ error: 'Firebase credentials are missing or invalid' }, { status: 503 });
      const topic = groupToTopic(group, dayType as 'today' | 'tomorrow');
      const fcmResult = await sendFcmTopicNotification(account, {
        topic, group, dayType: dayType as 'today' | 'tomorrow', changeType: 'test',
        title: url.searchParams.get('title')?.trim().slice(0, 200) || `Тестове сповіщення Lumen (${group.replace('GPV', 'Група ')})`,
        body: url.searchParams.get('body')?.trim().slice(0, 500) || 'FCM push-інфраструктура працює.',
      });
      return Response.json({ group, dayType, topic, fcmResult }, { status: fcmResult.success ? 200 : 502 });
    } catch (error) { return errorResponse(error); }
  },
};
