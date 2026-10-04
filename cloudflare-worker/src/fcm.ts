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
  if (!sa.project_id || !sa.client_email || !sa.private_key) {
    throw new Error('Service Account is missing required fields (project_id, client_email, or private_key)');
  }
  return {
    project_id: String(sa.project_id).trim(),
    client_email: String(sa.client_email).trim(),
    private_key: String(sa.private_key).replace(/\\n/g, '\n').trim(),
  };
}

let cachedAccessToken: string | null = null;
let tokenExpiresAt = 0;

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
  const now = Date.now();
  if (cachedAccessToken && now < tokenExpiresAt - 60000) {
    return cachedAccessToken;
  }

  const jwt = await generateGoogleJwt(serviceAccount);

  const response = await fetch('https://oauth2.googleapis.com/token', {
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
  cachedAccessToken = data.access_token;
  tokenExpiresAt = now + data.expires_in * 1000;

  return cachedAccessToken;
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
}

/**
 * Dispatches high-priority push notification to a specified FCM topic
 */
export async function sendFcmTopicNotification(
  serviceAccount: ServiceAccount,
  options: FcmMessageOptions
): Promise<{ success: boolean; messageId?: string; error?: string }> {
  try {
    const accessToken = await getGoogleAccessToken(serviceAccount);
    const url = `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`;

    const payload = {
      message: {
        topic: options.topic,
        notification: {
          title: options.title,
          body: options.body,
        },
        data: {
          group: options.group,
          type: options.changeType ?? 'schedule_update',
          click_action: 'FLUTTER_NOTIFICATION_CLICK',
          timestamp: Date.now().toString(),
          scheduleHash: options.scheduleHash ?? '',
          outageMinutes: options.outageMinutes !== undefined ? String(options.outageMinutes) : '',
          dayType: options.dayType ?? 'today',
        },
        android: {
          priority: 'HIGH',
          notification: {
            channel_id: 'schedule_channel',
            notification_priority: 'PRIORITY_HIGH',
            default_sound: true,
            default_vibrate_timings: true,
          },
        },
      },
    };

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      const err = await response.text();
      return { success: false, error: `FCM API ${response.status}: ${err}` };
    }

    const resJson = (await response.json()) as { name?: string };
    return { success: true, messageId: resJson.name };
  } catch (err: any) {
    return { success: false, error: err?.message || String(err) };
  }
}
