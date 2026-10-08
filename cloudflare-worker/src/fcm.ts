/**
 * FCM v1 Client for Cloudflare Workers using Web Crypto API.
 * Does not require external npm dependencies or heavy libraries.
 */

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

/**
 * Normalizes outage group name into valid FCM topic name.
 * Example: ('GPV1.1', 'today') -> 'group_gpv1_1'
 * Example: ('GPV1.1', 'tomorrow') -> 'group_gpv1_1_tomorrow'
 */
export function groupToTopic(group: string, dayType: 'today' | 'tomorrow' = 'today'): string {
  const clean = group.replace(/\./g, '_').replace(/-/g, '_').toLowerCase();
  const suffix = dayType === 'tomorrow' ? '_tomorrow' : '';
  return `group_${clean}${suffix}`;
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
  isEmergency?: boolean;
  observedAt?: number;
  expiresAt?: number;
}

/**
 * Dispatches high-priority push notification to a specified FCM topic
 */
export async function sendFcmTopicNotification(
  serviceAccount: ServiceAccount,
  options: FcmMessageOptions
): Promise<{ success: boolean; messageId?: string; error?: string; retryable?: boolean }> {
  try {
    const emergency = options.changeType === 'emergency_alert';
    if (emergency && (typeof options.isEmergency !== 'boolean' ||
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
        topic: options.topic,
        ...(!emergency ? { notification: {
          title: options.title,
          body: options.body,
        } } : {}),
        data: {
          group: options.group,
          type: options.changeType ?? 'schedule_update',
          click_action: 'FLUTTER_NOTIFICATION_CLICK',
          timestamp: Date.now().toString(),
          scheduleHash: options.scheduleHash ?? '',
          outageMinutes: options.outageMinutes !== undefined ? String(options.outageMinutes) : '',
          dayType: options.dayType ?? 'today',
          eventId: options.eventId ?? '',
          targetDate: options.targetDate ?? '',
          ...(emergency ? {
            title: options.title, body: options.body,
            isEmergency: String(options.isEmergency),
            observedAt: String(options.observedAt), expiresAt: String(options.expiresAt),
          } : {}),
        },
        android: {
          priority: 'HIGH',
          ttl: `${ttl}s`,
          ...(emergency ? { collapse_key: 'emergency_status' } : { notification: {
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
            ...(emergency ? { 'apns-push-type': 'background', 'apns-priority': '5' } : {}) },
          payload: { aps: emergency ? { 'content-available': 1 } : { sound: 'default' } },
        },
      },
    };

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
