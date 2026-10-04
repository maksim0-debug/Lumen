import {
  sendFcmTopicNotification,
  ServiceAccount,
  groupToTopic,
  validateServiceAccount,
} from './fcm';

export interface Env {
  SCHEDULE_KV: KVNamespace;
  PROJECT_ID?: string;
  FIREBASE_SERVICE_ACCOUNT?: string;
  ADMIN_KEY?: string;
}

const DTEK_URL = 'https://www.dtek-krem.com.ua/ua/shutdowns';

export const ALL_GROUPS = [
  'GPV1.1',
  'GPV1.2',
  'GPV2.1',
  'GPV2.2',
  'GPV3.1',
  'GPV3.2',
  'GPV4.1',
  'GPV4.2',
  'GPV5.1',
  'GPV5.2',
  'GPV6.1',
  'GPV6.2',
];

interface StoredGroupState {
  dateKey: string;
  todayHash: string;
  outageMinutes: number;
  updatedAt: string;
}

/**
 * Checks if HTML payload is a WAF / anti-bot challenge page
 */
function isBotChallengeHtml(html: string): boolean {
  if (!html) return false;
  return (
    html.includes('_Incapsula_Resource') ||
    html.includes('cf-browser-verification') ||
    html.includes('Just a moment...') ||
    (html.length < 500 && html.includes('robots'))
  );
}

/**
 * Extracts and parses schedule JSON from raw page HTML
 */
function extractJsonFromHtml(html: string): any | null {
  if (isBotChallengeHtml(html)) {
    console.warn('DTEK returned bot verification challenge (WAF)');
    return null;
  }

  const searchStart = 'DisconSchedule.fact';
  let startIndex = html.indexOf(searchStart);
  if (startIndex === -1) return null;

  startIndex = html.indexOf('=', startIndex + searchStart.length);
  if (startIndex === -1) return null;
  startIndex += 1;

  let endIndex = html.indexOf('DisconSchedule.showCurOutage', startIndex);
  if (endIndex === -1) endIndex = html.indexOf('</script>', startIndex);
  if (endIndex === -1) return null;

  let raw = html.substring(startIndex, endIndex).trim();
  if (raw.endsWith(';')) {
    raw = raw.substring(0, raw.length - 1).trim();
  }

  // 1. Try parsing raw directly
  try {
    const direct = JSON.parse(raw);
    if (typeof direct === 'string') {
      try {
        return JSON.parse(direct);
      } catch (_) {
        return JSON.parse(direct.replace(/\\"/g, '"'));
      }
    }
    if (direct && typeof direct === 'object') return direct;
  } catch (_) {}

  // 2. If it was enclosed in quotes: e.g. "{\"data\":...}"
  if (raw.startsWith('"')) {
    const lastQuote = raw.lastIndexOf('"');
    if (lastQuote > 0) {
      try {
        const unquoted = JSON.parse(raw.substring(0, lastQuote + 1));
        if (typeof unquoted === 'string') {
          return JSON.parse(unquoted);
        }
        if (unquoted && typeof unquoted === 'object') return unquoted;
      } catch (_) {}
    }
  }

  // 3. Fallback: extract substring between first { and last }
  const firstBrace = raw.indexOf('{');
  const lastBrace = raw.lastIndexOf('}');
  if (firstBrace !== -1 && lastBrace !== -1 && lastBrace > firstBrace) {
    const candidate = raw.substring(firstBrace, lastBrace + 1);
    try {
      return JSON.parse(candidate);
    } catch (_) {
      try {
        return JSON.parse(candidate.replace(/\\"/g, '"'));
      } catch (err) {
        console.error('Failed to parse extracted JSON object:', err);
      }
    }
  }

  return null;
}

/**
 * Calculates total outage minutes from DTEK hourly status object.
 * Rules matching client app:
 * 'no' = 60 mins
 * 'first' / 'second' = 30 mins
 * 'yes' / 'maybe' = 0 mins
 */
function calculateOutageMinutes(hoursObj: Record<string, any> | null | undefined): number {
  if (!hoursObj || typeof hoursObj !== 'object') return 0;
  let totalMinutes = 0;
  for (const hourKey of Object.keys(hoursObj)) {
    const val = String(hoursObj[hourKey]).toLowerCase().trim();
    if (val === 'no') {
      totalMinutes += 60;
    } else if (val === 'first' || val === 'second') {
      totalMinutes += 30;
    }
  }
  return totalMinutes;
}

/**
 * Computes deterministic 24-character hash of hourly schedule.
 * Matches client Dart DailySchedule.toEncodedString() format:
 * '0' = on ('yes')
 * '1' = off ('no')
 * '2' = semiOn ('first')
 * '3' = semiOff ('second')
 * '4' = maybe ('maybe', 'mfirst', 'msecond')
 * '9' = unknown (default)
 */
function computeDayScheduleHash(hoursObj: Record<string, any> | null | undefined): string {
  if (!hoursObj || typeof hoursObj !== 'object') return 'empty';
  let hash = '';
  for (let hour = 1; hour <= 24; hour++) {
    const rawVal = hoursObj[String(hour)] ?? hoursObj[hour];
    const val = rawVal ? String(rawVal).toLowerCase().trim() : '';
    switch (val) {
      case 'yes':
        hash += '0';
        break;
      case 'no':
        hash += '1';
        break;
      case 'first':
        hash += '2';
        break;
      case 'second':
        hash += '3';
        break;
      case 'maybe':
      case 'mfirst':
      case 'msecond':
        hash += '4';
        break;
      default:
        hash += '9';
        break;
    }
  }
  // If all 24 hours are unknown ('9') or empty placeholder, treat as empty schedule
  if (hash.split('').every((c) => c === '9')) {
    return 'empty';
  }
  return hash;
}

/**
 * Formats difference in outage hours into user-friendly message
 */
function formatDiffMessage(diffMinutes: number, dayLabel = 'сьогодні'): string {
  const willBeWord = dayLabel === 'завтра' ? 'стане' : 'стало';
  if (diffMinutes > 0) {
    const diffHours = diffMinutes / 60;
    const diffStr = diffHours % 1 === 0 ? diffHours.toFixed(0) : diffHours.toFixed(1);
    return `Світла ${willBeWord} МЕНШЕ на ${diffStr} год. 😔`;
  } else if (diffMinutes < 0) {
    const diffHours = Math.abs(diffMinutes) / 60;
    const diffStr = diffHours % 1 === 0 ? diffHours.toFixed(0) : diffHours.toFixed(1);
    return `Світла ${willBeWord} БІЛЬШЕ на ${diffStr} год. 🎉`;
  }
  return `Змінився час відключень на ${dayLabel} ⚡`;
}

/**
 * Main monitoring task logic executed both by Cron triggers and manual test requests
 */
async function runMonitoringCheck(env: Env): Promise<{
  timestamp: string;
  status: string;
  checkedGroups: number;
  changesDetected: string[];
  notificationsSent: string[];
  errors: string[];
}> {
  const report = {
    timestamp: new Date().toISOString(),
    status: 'success',
    checkedGroups: 0,
    changesDetected: [] as string[],
    notificationsSent: [] as string[],
    errors: [] as string[],
  };

  // 1. Validate Firebase Credentials
  let serviceAccount: ServiceAccount | null = null;
  if (env.FIREBASE_SERVICE_ACCOUNT) {
    try {
      const cleanJson = env.FIREBASE_SERVICE_ACCOUNT.replace(/^\uFEFF/, '').trim();
      const parsed = JSON.parse(cleanJson);
      serviceAccount = validateServiceAccount(parsed);
    } catch (e: any) {
      report.errors.push(`Invalid FIREBASE_SERVICE_ACCOUNT: ${e.message}`);
    }
  }

  // 2. Fetch Schedule Page from DTEK
  let html = '';
  try {
    const res = await fetch(DTEK_URL, {
      headers: {
        'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
        Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'uk-UA,uk;q=0.9,en-US;q=0.8,en;q=0.7',
      },
    });

    if (!res.ok) {
      report.status = 'failed_fetch';
      report.errors.push(`DTEK HTTP ${res.status}: ${res.statusText}`);
      return report;
    }

    html = await res.text();
  } catch (e: any) {
    report.status = 'network_error';
    report.errors.push(`Network error fetching DTEK: ${e.message}`);
    return report;
  }

  // 3. Extract Schedule Data
  const factData = extractJsonFromHtml(html);
  if (!factData || typeof factData !== 'object') {
    report.status = 'no_data_extracted';
    report.errors.push('Could not find or parse DisconSchedule.fact in HTML');
    return report;
  }

  const todayTimestamp = factData.today ? String(factData.today) : '';
  if (!todayTimestamp) {
    report.status = 'missing_today_timestamp';
    report.errors.push('DisconSchedule.fact does not contain "today" timestamp');
    return report;
  }

  const dataStore = (factData.data && typeof factData.data === 'object' && !Array.isArray(factData.data))
    ? factData.data
    : {};
  const todayDataMap = dataStore[todayTimestamp] || {};
  const tomorrowTimestamp = String(Number(todayTimestamp) + 86400);
  const tomorrowDataMap = dataStore[tomorrowTimestamp] || null;

  // 4. Check today's schedule for all groups
  for (const group of ALL_GROUPS) {
    report.checkedGroups++;
    const groupHours = todayDataMap[group] ?? null;
    const newHash = computeDayScheduleHash(groupHours);
    const newOutageMinutes = calculateOutageMinutes(groupHours);

    // If DTEK temporarily returns empty/null, skip to avoid corrupting baseline
    if (newHash === 'empty') continue;

    const kvKey = `state_${group}`;
    let prevState: StoredGroupState | null = null;
    const rawPrev = await env.SCHEDULE_KV.get(kvKey);

    if (rawPrev) {
      try {
        prevState = JSON.parse(rawPrev);
      } catch (_) {
        prevState = {
          dateKey: todayTimestamp,
          todayHash: rawPrev,
          outageMinutes: newOutageMinutes,
          updatedAt: new Date().toISOString(),
        };
      }
    }

    const newState: StoredGroupState = {
      dateKey: todayTimestamp,
      todayHash: newHash,
      outageMinutes: newOutageMinutes,
      updatedAt: new Date().toISOString(),
    };

    if (prevState === null) {
      // First run for this group: save baseline without firing false alert
      await env.SCHEDULE_KV.put(kvKey, JSON.stringify(newState));
      continue;
    }

    // New calendar day has arrived (e.g. at 00:00 midnight)
    if (prevState.dateKey !== todayTimestamp) {
      await env.SCHEDULE_KV.put(kvKey, JSON.stringify(newState));
      continue;
    }

    // Actual intra-day schedule change detected for today
    if (prevState.todayHash !== newHash) {
      report.changesDetected.push(group);

      const diffMinutes = newOutageMinutes - (prevState.outageMinutes ?? 0);
      const topic = groupToTopic(group);
      const title = `Графік змінено! (${group.replace('GPV', 'Група ')})`;
      const body = formatDiffMessage(diffMinutes, 'сьогодні');

      if (serviceAccount) {
        const fcmResult = await sendFcmTopicNotification(serviceAccount, {
          topic,
          title,
          body,
          group,
          changeType: 'schedule_updated',
          scheduleHash: newHash,
          outageMinutes: newOutageMinutes,
          dayType: 'today',
        });

        if (fcmResult.success) {
          report.notificationsSent.push(`${group} -> ${topic} (${fcmResult.messageId})`);
          await env.SCHEDULE_KV.put(kvKey, JSON.stringify(newState));
        } else {
          report.errors.push(`FCM error for ${group}: ${fcmResult.error}`);
        }
      } else {
        report.errors.push(`Cannot send push for ${group}: FIREBASE_SERVICE_ACCOUNT not configured`);
        await env.SCHEDULE_KV.put(kvKey, JSON.stringify(newState));
      }
    }
  }

  // 5. Check tomorrow's schedule if published by DTEK
  if (tomorrowDataMap && typeof tomorrowDataMap === 'object') {
    for (const group of ALL_GROUPS) {
      const groupHoursTomorrow = tomorrowDataMap[group] ?? null;
      if (!groupHoursTomorrow) continue;

      const newHashTomorrow = computeDayScheduleHash(groupHoursTomorrow);
      const newOutageMinutesTomorrow = calculateOutageMinutes(groupHoursTomorrow);
      if (newHashTomorrow === 'empty') continue;

      const kvKeyTomorrow = `state_tomorrow_${group}`;
      let prevStateTomorrow: StoredGroupState | null = null;
      const rawPrevTomorrow = await env.SCHEDULE_KV.get(kvKeyTomorrow);

      if (rawPrevTomorrow) {
        try {
          prevStateTomorrow = JSON.parse(rawPrevTomorrow);
        } catch (_) {
          prevStateTomorrow = null;
        }
      }

      const newStateTomorrow: StoredGroupState = {
        dateKey: tomorrowTimestamp,
        todayHash: newHashTomorrow,
        outageMinutes: newOutageMinutesTomorrow,
        updatedAt: new Date().toISOString(),
      };

      if (prevStateTomorrow === null) {
        // Cold start baseline on first deployment: save baseline without firing false alert
        await env.SCHEDULE_KV.put(kvKeyTomorrow, JSON.stringify(newStateTomorrow));
        continue;
      }

      // Check 1: Brand new calendar day appeared for tomorrow (initial publication by DTEK)
      if (prevStateTomorrow.dateKey !== tomorrowTimestamp) {
        report.changesDetected.push(`${group} (tomorrow published)`);
        const topic = groupToTopic(group, 'tomorrow');
        const title = `Опубліковано графік на ЗАВТРА! (${group.replace('GPV', 'Група ')})`;
        const outHours = newOutageMinutesTomorrow / 60;
        const outStr = outHours % 1 === 0 ? outHours.toFixed(0) : outHours.toFixed(1);
        const body =
          newOutageMinutesTomorrow > 0
            ? `Заплановано відключень: ${outStr} год. ⚡`
            : 'Відключень не заплановано 🎉';

        if (serviceAccount) {
          const fcmResult = await sendFcmTopicNotification(serviceAccount, {
            topic,
            title,
            body,
            group,
            changeType: 'tomorrow_published',
            scheduleHash: newHashTomorrow,
            outageMinutes: newOutageMinutesTomorrow,
            dayType: 'tomorrow',
          });

          if (fcmResult.success) {
            report.notificationsSent.push(`${group} (tomorrow published) -> ${topic} (${fcmResult.messageId})`);
            await env.SCHEDULE_KV.put(kvKeyTomorrow, JSON.stringify(newStateTomorrow));
          } else {
            report.errors.push(`FCM error for ${group} (tomorrow published): ${fcmResult.error}`);
          }
        } else {
          await env.SCHEDULE_KV.put(kvKeyTomorrow, JSON.stringify(newStateTomorrow));
        }
        continue;
      }

      // Check 2: Existing tomorrow schedule modified by DTEK
      if (prevStateTomorrow.todayHash !== newHashTomorrow) {
        report.changesDetected.push(`${group} (tomorrow changed)`);

        const diffMinutes = newOutageMinutesTomorrow - (prevStateTomorrow.outageMinutes ?? 0);
        const topic = groupToTopic(group, 'tomorrow');
        const title = `Графік на ЗАВТРА змінено! (${group.replace('GPV', 'Група ')})`;
        const body = formatDiffMessage(diffMinutes, 'завтра');

        if (serviceAccount) {
          const fcmResult = await sendFcmTopicNotification(serviceAccount, {
            topic,
            title,
            body,
            group,
            changeType: 'tomorrow_schedule_updated',
            scheduleHash: newHashTomorrow,
            outageMinutes: newOutageMinutesTomorrow,
            dayType: 'tomorrow',
          });

          if (fcmResult.success) {
            report.notificationsSent.push(`${group} (tomorrow changed) -> ${topic} (${fcmResult.messageId})`);
            await env.SCHEDULE_KV.put(kvKeyTomorrow, JSON.stringify(newStateTomorrow));
          } else {
            report.errors.push(`FCM error for ${group} (tomorrow changed): ${fcmResult.error}`);
          }
        } else {
          await env.SCHEDULE_KV.put(kvKeyTomorrow, JSON.stringify(newStateTomorrow));
        }
      }
    }
  }

  return report;
}

/**
 * Validates request authorization using configured ADMIN_KEY secret
 */
function isAuthorized(request: Request, env: Env): boolean {
  if (!env.ADMIN_KEY) {
    // If ADMIN_KEY is not set, protect endpoints by default
    return false;
  }
  const url = new URL(request.url);
  const keyFromQuery = url.searchParams.get('key')?.trim();
  const keyFromHeader = (
    request.headers.get('X-Admin-Key') ??
    request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '')
  )?.trim();
  const configuredKey = env.ADMIN_KEY.trim();
  return keyFromQuery === configuredKey || keyFromHeader === configuredKey;
}

export default {
  /**
   * Cron Trigger Handler (automatically runs every 5 minutes)
   */
  async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    console.log(`Cron triggered at ${new Date(event.scheduledTime).toISOString()}`);
    const report = await runMonitoringCheck(env);
    console.log('Cron execution result:', JSON.stringify(report));
  },

  /**
   * HTTP Request Handler (for health check and secure administration)
   */
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    // Root status
    if (url.pathname === '/') {
      return new Response(
        JSON.stringify(
          {
            app: 'Lumen Schedule Monitor',
            status: 'operational',
            interval: '5 minutes',
            endpoints: {
              '/check': 'Trigger immediate check of DTEK website (Requires X-Admin-Key header or ?key=)',
              '/test-push?group=GPV2.1&dayType=today': 'Send an instant test push notification (Requires X-Admin-Key header or ?key=)',
            },
          },
          null,
          2
        ),
        { headers: { 'Content-Type': 'application/json; charset=utf-8' } }
      );
    }

    // Manual check trigger (Protected)
    if (url.pathname === '/check') {
      if (!isAuthorized(request, env)) {
        return new Response(
          JSON.stringify({ error: 'Unauthorized. Provide valid X-Admin-Key header or ?key= query parameter.' }),
          { status: 401, headers: { 'Content-Type': 'application/json' } }
        );
      }

      const report = await runMonitoringCheck(env);
      return new Response(JSON.stringify(report, null, 2), {
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
      });
    }

    // Direct test push trigger (Protected)
    if (url.pathname === '/test-push') {
      if (!isAuthorized(request, env)) {
        return new Response(
          JSON.stringify({ error: 'Unauthorized. Provide valid X-Admin-Key header or ?key= query parameter.' }),
          { status: 401, headers: { 'Content-Type': 'application/json' } }
        );
      }

      if (!env.FIREBASE_SERVICE_ACCOUNT) {
        return new Response(
          JSON.stringify({ error: 'FIREBASE_SERVICE_ACCOUNT secret is not configured in Worker' }),
          { status: 500, headers: { 'Content-Type': 'application/json' } }
        );
      }

      const group = url.searchParams.get('group') ?? 'GPV2.1';
      const dayType = (url.searchParams.get('dayType') === 'tomorrow' ? 'tomorrow' : 'today') as 'today' | 'tomorrow';
      const cleanTopic = groupToTopic(group, dayType);

      let serviceAccount: ServiceAccount;
      try {
        const cleanJson = env.FIREBASE_SERVICE_ACCOUNT.replace(/^\uFEFF/, '').trim();
        serviceAccount = validateServiceAccount(JSON.parse(cleanJson));
      } catch (err: any) {
        return new Response(
          JSON.stringify({ error: `Service Account validation error: ${err.message}` }),
          { status: 500, headers: { 'Content-Type': 'application/json' } }
        );
      }

      const testTitle =
        dayType === 'tomorrow'
          ? `Тестове сповіщення Lumen: ЗАВТРА (${group.replace('GPV', 'Група ')})`
          : `Тестове сповіщення Lumen (${group.replace('GPV', 'Група ')})`;

      const fcmResult = await sendFcmTopicNotification(serviceAccount, {
        topic: cleanTopic,
        title: testTitle,
        body: 'FCM push-інфраструктура працює надійно та коректно!',
        group,
        changeType: 'test',
        dayType,
      });

      return new Response(JSON.stringify({ group, dayType, topic: cleanTopic, fcmResult }, null, 2), {
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
      });
    }

    return new Response('Not Found', { status: 404 });
  },
};
