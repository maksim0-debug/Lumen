/**
 * FCM v1 Client for Cloudflare Workers using Web Crypto API.
 * Does not require external npm dependencies or heavy libraries.
 */

import { fitsTopicPayload, SNAPSHOT_TOPIC, validateCompactSnapshot } from './snapshot';

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

export const DIAGNOSTIC_CLIENT_TOPIC = 'lumen_diagnostics_v1';

/**
 * Normalizes outage group name into valid FCM topic name.
 * Example: ('GPV1.1', 'today') -> 'group_gpv1_1'
 * Example: ('GPV1.1', 'tomorrow') -> 'group_gpv1_1_tomorrow'
 */
export function groupToTopic(group: string, dayType: 'today' | 'tomorrow' = 'today', versioned = false): string {
  const clean = group.replace(/\./g, '_').replace(/-/g, '_').toLowerCase();
  const suffix = dayType === 'tomorrow' ? '_tomorrow' : '';
  return `group_${clean}${versioned ? '_v2' : ''}${suffix}`;
}

/**
 * Validates and normalizes service account credentials
 */
export function validateServiceAccount(sa: any): ServiceAccount {
  if (!sa || typeof sa !== 'object') {
    throw new Error('Service Account configuration is missing or not an object');
  }
  if (![sa.project_id, sa.client_email, sa.private_key].every(v => typeof v === 'string' && v.trim())) {
    throw new Error('Service Account is missing required fields (project_id, client_email, or private_key)');
  }
  return {
    project_id: String(sa.project_id).trim(),
    client_email: String(sa.client_email).trim(),
    private_key: String(sa.private_key).replace(/\\n/g, '\n').trim(),
  };
}

export function getServiceAccount(value?: string): ServiceAccount | null {
  if (!value) return null;
  try { return validateServiceAccount(JSON.parse(value.replace(/^\uFEFF/, '').trim())); }
  catch { return null; }
}

let cachedAccessToken: string | null = null;
let tokenExpiresAt = 0;
let tokenAccount = '';
let tokenRequest: Promise<string> | null = null;

/**
 * Converts Base64 to Base64URL format
 */
function base64UrlEncode(str: string): string {
  return btoa(str)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

/**
 * Converts ArrayBuffer to Base64URL
 */
function arrayBufferToBase64Url(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return base64UrlEncode(binary);
}

/**
 * Parses PEM formatted PKCS#8 private key into ArrayBuffer
 */
function pemToArrayBuffer(pem: string): ArrayBuffer {
  const cleanPem = pem
    .replace(/-----BEGIN (?:RSA )?PRIVATE KEY-----/g, '')
    .replace(/-----END (?:RSA )?PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '');
  
  const binaryString = atob(cleanPem);
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  return bytes.buffer;
}

/**
 * Generates signed RS256 JWT for Google OAuth2
 */
async function generateGoogleJwt(serviceAccount: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const exp = now + 3600; // 1 hour

  const header = {
    alg: 'RS256',
    typ: 'JWT',
  };

  const claims = {
    iss: serviceAccount.client_email,
    sub: serviceAccount.client_email,
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: exp,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
  };

  const encodedHeader = base64UrlEncode(JSON.stringify(header));
  const encodedClaims = base64UrlEncode(JSON.stringify(claims));
  const unsignedToken = `${encodedHeader}.${encodedClaims}`;

  const keyBuffer = pemToArrayBuffer(serviceAccount.private_key);
  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    keyBuffer,
    {
      name: 'RSASSA-PKCS1-v1_5',
      hash: 'SHA-256',
    },
    false,
    ['sign']
  );

  const encoder = new TextEncoder();
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    cryptoKey,
    encoder.encode(unsignedToken)
  );

  const encodedSignature = arrayBufferToBase64Url(signature);
  return `${unsignedToken}.${encodedSignature}`;
}

/**
 * Obtains or returns cached OAuth2 Bearer token for Google APIs
 */
export async function getGoogleAccessToken(serviceAccount: ServiceAccount): Promise<string> {
  const account = `${serviceAccount.project_id}:${serviceAccount.client_email}:${serviceAccount.private_key}`;
  if (tokenAccount !== account) {
    tokenAccount = account;
    cachedAccessToken = null;
    tokenExpiresAt = 0;
    tokenRequest = null;
  }
  const now = Date.now();
  if (cachedAccessToken && now < tokenExpiresAt - 60000) {
    return cachedAccessToken;
  }

  if (tokenRequest) return tokenRequest;
  const currentRequest = requestAccessToken(serviceAccount, account);
  tokenRequest = currentRequest;
  try { return await currentRequest; }
  finally { if (tokenRequest === currentRequest) tokenRequest = null; }
}

async function requestAccessToken(serviceAccount: ServiceAccount, account: string): Promise<string> {
  const jwt = await generateGoogleJwt(serviceAccount);

  const response = await fetch('https://oauth2.googleapis.com/token', {
    signal: AbortSignal.timeout(8_000),
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Google OAuth2 Token Exchange Failed (${response.status}): ${errorText}`);
  }

  const data = (await response.json()) as { access_token: string; expires_in: number };
  if (typeof data.access_token !== 'string' || !data.access_token || !Number.isFinite(data.expires_in) || data.expires_in <= 0) {
    throw new Error('Invalid OAuth2 token response');
  }
  if (tokenAccount === account) {
    cachedAccessToken = data.access_token;
    tokenExpiresAt = Date.now() + data.expires_in * 1000;
  }

  return data.access_token;
}

export interface FcmMessageOptions {
  topic: string;
  title: string;
  body: string;
  group: string;
  changeType?: string;
  scheduleHash?: string;
  outageMinutes?: number;
  dayType?: 'today' | 'tomorrow';
  eventId?: string;
  targetDate?: string;
  sourceVersion?: number;
  deliveredModes?: Array<'legacy' | 'client'>;
  isEmergency?: boolean;
  isPossible?: boolean;
  noticeText?: string;
  observedAt?: number;
  expiresAt?: number;
  testAudience?: 'group' | 'emergency';
  snapshot?: import('./snapshot').CompactSnapshot;
  snapshotTestTopic?: string;
}

/**
 * Dispatches high-priority push notification to a specified FCM topic
 */
interface DeliveryResult {
  success: boolean; messageId?: string; error?: string; retryable?: boolean;
  deliveredModes?: Array<'legacy' | 'client'>;
}

/** Keep old clients working while new clients arbitrate display locally. */
export async function sendFcmTopicNotification(
  serviceAccount: ServiceAccount, options: FcmMessageOptions,
): Promise<DeliveryResult> {
  const schedule = ['schedule_updated', 'tomorrow_schedule_updated', 'tomorrow_published'].includes(options.changeType ?? '');
  if (!schedule) return sendFcmMessage(serviceAccount, options);
  const sourceVersion = options.sourceVersion ?? Number(options.eventId?.split(':')[2]);
  if (!Number.isSafeInteger(sourceVersion) || sourceVersion <= 0 ||
      !/^GPV[1-6]\.[12]$/.test(options.group) || !/^[0-4]{24}$/.test(options.scheduleHash ?? '') ||
      !/^\d{4}-\d{2}-\d{2}$/.test(options.targetDate ?? '') ||
      options.eventId !== `${options.group}:${options.targetDate}:${sourceVersion}:${options.scheduleHash}`) {
    return { success: false, error: 'Invalid schedule event', retryable: false };
  }
  if (options.snapshot) {
    try { validateCompactSnapshot(options.snapshot); }
    catch { return { success: false, error: 'Invalid compact snapshot', retryable: false }; }
    if (options.snapshot.sourceVersion !== sourceVersion ||
        options.snapshot[options.dayType === 'tomorrow' ? 'tomorrowDate' : 'todayDate'] !== options.targetDate ||
        options.snapshot.groups[options.group]?.[options.dayType === 'tomorrow' ? 1 : 0] !== options.scheduleHash) {
      return { success: false, error: 'Event does not match its snapshot', retryable: false };
    }
  }
  const deliveredModes = [...(options.deliveredModes ?? [])];
  const missing = (['legacy', 'client'] as const).filter(mode => !deliveredModes.includes(mode));
  const results = await Promise.all(missing.map(async mode => ({ mode, result: await sendFcmMessage(
    serviceAccount, { ...options, sourceVersion }, mode === 'client') })));
  for (const { mode, result } of results) if (result.success) deliveredModes.push(mode);
  const failed = results.filter(({ result }) => !result.success);
  return failed.length ? { success: false, deliveredModes,
    error: failed.map(({ mode, result }) => `${mode}: ${result.error}`).join('; '),
    retryable: failed.some(({ result }) => result.retryable !== false),
  } : { success: true, deliveredModes, messageId: results.map(({ result }) => result.messageId).filter(Boolean).join(',') || options.eventId };
}

async function sendFcmMessage(
  serviceAccount: ServiceAccount,
  options: FcmMessageOptions,
  clientSchedule = false,
): Promise<DeliveryResult> {
  try {
    const emergency = options.changeType === 'emergency_alert';
    const diagnostic = options.changeType === 'test';
    const snapshotSync = options.changeType === 'schedule_snapshot';
    if (options.snapshotTestTopic && (!snapshotSync ||
        !/^lumen_snapshot_qa_[a-f0-9]{32}$/.test(options.snapshotTestTopic))) {
      return { success: false, error: 'Invalid isolated snapshot target', retryable: false };
    }
    const dataOnly = emergency || diagnostic || clientSchedule || snapshotSync;
    if (options.snapshot) {
      try { validateCompactSnapshot(options.snapshot); }
      catch { return { success: false, error: 'Invalid compact snapshot', retryable: false }; }
    }
    if (snapshotSync && (!options.snapshot || options.topic !== SNAPSHOT_TOPIC)) {
      return { success: false, error: 'Invalid snapshot sync', retryable: false };
    }
    if (diagnostic && !['group', 'emergency'].includes(options.testAudience ?? '')) {
      return { success: false, error: 'Invalid test audience', retryable: false };
    }
    if (diagnostic && !/^[a-zA-Z0-9_.~%-]{1,900}$/.test(options.topic)) {
      return { success: false, error: 'Invalid test topic', retryable: false };
    }
    if (emergency && (typeof options.isEmergency !== 'boolean' ||
        (options.isPossible !== undefined && (typeof options.isPossible !== 'boolean' || (options.isPossible && !options.isEmergency))) ||
        (options.noticeText !== undefined && typeof options.noticeText !== 'string') ||
        !Number.isSafeInteger(options.observedAt) || !Number.isSafeInteger(options.expiresAt) ||
        options.observedAt! <= 0 || options.observedAt! > Date.now() + 60_000 ||
        options.expiresAt! <= options.observedAt! || options.expiresAt! - options.observedAt! > 900_000)) {
      return { success: false, error: 'Invalid emergency event', retryable: false };
    }
    const ttl = emergency && options.expiresAt !== undefined
      ? Math.floor((options.expiresAt - Date.now()) / 1000) : 900;
    if (ttl <= 0) return { success: false, error: 'Emergency event expired', retryable: false };
    const accessToken = await getGoogleAccessToken(serviceAccount);
    const url = `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`;

    const payload = {
      message: {
        // Only updated clients can consume diagnostics without schedule side
        // effects. Retain the real channel subscription as part of the check.
        ...(diagnostic ? {
          condition: `${options.testAudience === 'group'
            ? `('${options.topic}' in topics || '${groupToTopic(options.group, options.dayType, true)}' in topics)`
            : `'${options.topic}' in topics`} && '${DIAGNOSTIC_CLIENT_TOPIC}' in topics`,
        } : { topic: options.snapshotTestTopic ?? (clientSchedule ? groupToTopic(options.group, options.dayType, true) : options.topic) }),
        ...(!dataOnly ? { notification: {
          title: options.title,
          body: options.body,
        } } : {}),
        data: {
          group: options.group,
          type: options.changeType ?? 'schedule_update',
          click_action: 'FLUTTER_NOTIFICATION_CLICK',
          timestamp: Date.now().toString(),
          eventId: options.eventId ?? '',
          ...(!diagnostic ? {
            scheduleHash: options.scheduleHash ?? '',
            outageMinutes: options.outageMinutes !== undefined ? String(options.outageMinutes) : '',
            dayType: options.dayType ?? 'today',
            targetDate: options.targetDate ?? '',
            ...(options.sourceVersion !== undefined ? {
              sourceVersion: String(options.sourceVersion), schemaVersion: '2',
            } : {}),
          } : {
            testAudience: options.testAudience!,
            ...(options.testAudience === 'group' ? { dayType: options.dayType ?? 'today' } : {}),
          }),
          ...(dataOnly ? { title: options.title, body: options.body } : {}),
          ...(emergency ? {
            isEmergency: String(options.isEmergency),
            isPossible: String(options.isPossible ?? false),
            ...(options.noticeText && new TextEncoder().encode(options.noticeText).length <= 2000
              ? { noticeText: options.noticeText } : {}),
            observedAt: String(options.observedAt), expiresAt: String(options.expiresAt),
          } : {}),
        },
        android: {
          priority: snapshotSync && !options.snapshotTestTopic ? 'NORMAL' : 'HIGH',
          ttl: `${ttl}s`,
          ...(dataOnly ? (snapshotSync ? { collapse_key: 'schedule_snapshot' } : emergency ? { collapse_key: 'emergency_status' } : {}) : { notification: {
            // Re-delivery after an uncertain acknowledgement replaces the same system notification.
            ...(options.eventId ? { tag: options.eventId } : {}),
            channel_id: 'schedule_channel',
            notification_priority: 'PRIORITY_HIGH',
            default_sound: true,
            default_vibrate_timings: true,
          } }),
        },
        apns: {
          headers: { 'apns-expiration': String(Math.floor(Date.now() / 1000) + ttl),
            ...(dataOnly ? { 'apns-push-type': 'background', 'apns-priority': '5' } : {}) },
          payload: { aps: dataOnly ? { 'content-available': 1 } : { sound: 'default' } },
        },
      },
    };

    // Legacy clients keep their original payload. Updated clients can consume
    // a frozen full publication without contacting DTEK.
    if ((clientSchedule || snapshotSync) && options.snapshot) {
      const data: Record<string, string> = payload.message.data;
      data.snapshot = JSON.stringify(options.snapshot);
      if (!fitsTopicPayload(data)) {
        delete data.snapshot;
        data.snapshotSequence = String(options.snapshot.sequence);
        data.snapshotJournal = options.snapshot.journalId;
      }
    }
    if (!fitsTopicPayload(payload.message.data) && emergency) {
      delete payload.message.data.noticeText;
    }
    if (!fitsTopicPayload(payload.message.data)) {
      return { success: false, error: 'Topic payload exceeds 2048 bytes', retryable: false };
    }

    const response = await fetch(url, {
      signal: AbortSignal.timeout(8_000),
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      if (response.status === 401) { cachedAccessToken = null; tokenExpiresAt = 0; }
      const err = await response.text();
      return { success: false, error: `FCM API ${response.status}: ${err}`,
        retryable: response.status === 401 || response.status === 429 || response.status >= 500 };
    }

    const resJson = (await response.json()) as { name?: string };
    if (typeof resJson.name !== 'string' || !resJson.name) {
      return { success: false, error: 'FCM returned no message acknowledgement' };
    }
    return { success: true, messageId: resJson.name };
  } catch (err: any) {
    return { success: false, error: err?.message || String(err) };
  }
}
