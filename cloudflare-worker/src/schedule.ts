export const DTEK_URL = 'https://www.dtek-krem.com.ua/ua/shutdowns';
export const MAX_HTML_BYTES = 2 * 1024 * 1024;
export const KYIV_TIME_ZONE = 'Europe/Kyiv';
export const ALL_GROUPS = Array.from({ length: 6 }, (_, i) =>
  [`GPV${i + 1}.1`, `GPV${i + 1}.2`]).flat();

export type DayType = 'today' | 'tomorrow';
export interface GroupSchedule {
  group: string;
  hash: string;
  outageMinutes: number;
}
export interface ScheduleDay {
  dayType: DayType;
  dateKey: string;
  calendarDate: string;
  groups: GroupSchedule[];
}
export interface ScheduleSnapshot {
  updateStr: string;
  updateAt: number;
  days: ScheduleDay[];
}

export class PayloadError extends Error {
  constructor(message: string, public readonly status = 'invalid_schedule') {
    super(message);
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

const kyivFormatter = new Intl.DateTimeFormat('en-CA', {
  timeZone: KYIV_TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
});

function kyivParts(time: number): Record<string, number> {
  return Object.fromEntries(kyivFormatter.formatToParts(new Date(time))
    .filter(p => p.type !== 'literal').map(p => [p.type, Number(p.value)]));
}

export function calendarDate(time = Date.now()): string {
  const p = kyivParts(time);
  return `${p.year}-${String(p.month).padStart(2, '0')}-${String(p.day).padStart(2, '0')}`;
}

export function nextCalendarDate(date: string): string {
  return new Date(Date.parse(`${date}T12:00:00Z`) + 86_400_000).toISOString().slice(0, 10);
}

export function parseUpdateTime(value: string, now = Date.now()): number {
  const m = /^(\d{1,2})\.(\d{1,2})\.(\d{4})[\s,]+(?:[ов]\s+|at\s+)?(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(value.trim());
  if (!m) throw new PayloadError('Missing or invalid DTEK update time (expected DD.MM.YYYY HH:mm)');
  const [, day, month, year, hour, minute, second = '0'] = m;
  const wall = Date.UTC(+year, +month - 1, +day, +hour, +minute, +second);
  const matches: number[] = [];
  // Derive offsets from the time-zone database on both sides of a possible transition.
  const offsets = new Set<number>();
  for (const delta of [-36, 0, 36]) {
    const instant = wall + delta * 3_600_000;
    const p = kyivParts(instant);
    offsets.add(Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - instant);
  }
  for (const offset of offsets) {
    const candidate = wall - offset;
    const p = kyivParts(candidate);
    if (p.year === +year && p.month === +month && p.day === +day &&
        p.hour === +hour && p.minute === +minute && p.second === +second) matches.push(candidate);
  }
  if (matches.length === 0) throw new PayloadError('Invalid Kyiv update time (non-existent local time)');
  if (matches.length === 1) return matches[0];
  // Autumn DST repeated hour: choose the later instant (fold=1) to ensure continuity without failing closed.
  return Math.max(...matches);
}

/** Read only JSON literals; never evaluate JavaScript from a submitted page. */
export function extractFact(html: string): unknown {
  const assignment = /DisconSchedule\.fact\s*=\s*/g;
  let match: RegExpExecArray | null;
  while ((match = assignment.exec(html)) !== null) {
    const start = assignment.lastIndex;
    let quoted = false;
    let escaped = false;
    let depth = 0;
    for (let i = start; i < html.length; i++) {
      const c = html[i];
      if (quoted) {
        if (escaped) escaped = false;
        else if (c === '\\') escaped = true;
        else if (c === '"') {
          quoted = false;
          if (depth === 0) {
            try {
              const text = JSON.parse(html.slice(start, i + 1));
              return typeof text === 'string' ? JSON.parse(text) : text;
            } catch { break; }
          }
        }
      } else if (c === '"') quoted = true;
      else if (c === '{' || c === '[') depth++;
      else if (c === '}' || c === ']') {
        if (--depth === 0) {
          try { return JSON.parse(html.slice(start, i + 1)); } catch { break; }
        }
      } else if (depth === 0) break; // null, a reference or arbitrary code is not a snapshot
    }
  }
  return null;
}

export function isBotChallenge(html: string): boolean {
  return /_Incapsula_Resource|cf-browser-verification|Just a moment\.\.\./.test(html);
}

const statusCodes: Record<string, string> = {
  yes: '0', no: '1', first: '2', second: '3', maybe: '4', mfirst: '4', msecond: '4',
};

function parseGroups(value: unknown, optional: boolean): GroupSchedule[] | null {
  if (optional && (value == null || (isObject(value) && Object.keys(value).length === 0))) return null;
  if (!isObject(value)) throw new PayloadError('Schedule day must contain all 12 groups');
  const groups: GroupSchedule[] = [];
  let placeholders = 0;
  for (const group of ALL_GROUPS) {
    const hours = value[group];
    if (hours == null || (isObject(hours) && Object.keys(hours).length === 0)) {
      placeholders++;
      continue;
    }
    if (!isObject(hours) || Object.keys(hours).length !== 24) {
      throw new PayloadError(`${group}: expected exactly 24 hourly values`);
    }
    let hash = '';
    let outageMinutes = 0;
    for (let hour = 1; hour <= 24; hour++) {
      const raw = hours[String(hour)];
      const status = typeof raw === 'string' ? raw.toLowerCase().trim() : '';
      if (!Object.hasOwn(statusCodes, status)) throw new PayloadError(`${group}: invalid status at hour ${hour}`);
      hash += statusCodes[status];
      outageMinutes += status === 'no' ? 60 : status === 'first' || status === 'second' ? 30 : 0;
    }
    groups.push({ group, hash, outageMinutes });
  }
  if (optional && placeholders === ALL_GROUPS.length) return null;
  if (placeholders !== 0) throw new PayloadError('Incomplete schedule: one or more groups are missing');
  return groups;
}

export function parseSnapshot(html: string, now = Date.now()): ScheduleSnapshot {
  const fact = extractFact(html);
  if (!isObject(fact)) {
    throw new PayloadError(isBotChallenge(html) ? 'DTEK returned a bot challenge' : 'No schedule JSON found',
      isBotChallenge(html) ? 'bot_challenge_detected' : 'no_data_extracted');
  }
  const timestamp = typeof fact.today === 'number' ? fact.today : Number(fact.today);
  if (!Number.isSafeInteger(timestamp) || timestamp <= 0 || Math.abs(timestamp * 1000 - now) > 3 * 86_400_000) {
    throw new PayloadError('Invalid or stale today timestamp', 'stale_snapshot');
  }
  const today = calendarDate(timestamp * 1000);
  if (today !== calendarDate(now)) throw new PayloadError('Snapshot is not for the current Kyiv day', 'stale_snapshot');
  const p = kyivParts(timestamp * 1000);
  if (p.hour !== 0 || p.minute !== 0 || p.second !== 0) throw new PayloadError('today must be Kyiv midnight');
  if (typeof fact.update !== 'string') throw new PayloadError('Missing DTEK update time');
  const updateStr = fact.update.trim();
  const updateAt = parseUpdateTime(updateStr, now);
  if (updateAt > now + 4 * 3600_000) throw new PayloadError('DTEK update time is too far in the future');
  if (!isObject(fact.data)) throw new PayloadError('Missing schedule data');
  const todayGroups = parseGroups(fact.data[String(timestamp)], false)!;
  const days: ScheduleDay[] = [{ dayType: 'today', dateKey: String(timestamp), calendarDate: today, groups: todayGroups }];
  const tomorrow = nextCalendarDate(today);
  let tomorrowKeys = Object.keys(fact.data).filter(k => /^\d+$/.test(k) &&
    Number.isSafeInteger(Number(k)) && Math.abs(Number(k) * 1000 - now) < 3 * 86_400_000 &&
    calendarDate(Number(k) * 1000) === tomorrow);
  if (tomorrowKeys.length === 0) {
    const fallbackKey = String(timestamp + 86400);
    if (fact.data[fallbackKey]) tomorrowKeys = [fallbackKey];
  }
  if (tomorrowKeys.length > 1) throw new PayloadError('Ambiguous tomorrow date');
  if (tomorrowKeys.length === 1) {
    const key = tomorrowKeys[0];
    const t = kyivParts(Number(key) * 1000);
    if (t.hour !== 0 || t.minute !== 0 || t.second !== 0) {
      if (key !== String(timestamp + 86400)) {
        throw new PayloadError('Tomorrow must be Kyiv midnight');
      }
    }
    const groups = parseGroups(fact.data[key], true);
    if (groups) days.push({ dayType: 'tomorrow', dateKey: key, calendarDate: tomorrow, groups });
  }
  return { updateStr, updateAt, days };
}

export function formatDiffMessage(minutes: number, dayType: DayType): string {
  const verb = dayType === 'tomorrow' ? 'стане' : 'стало';
  const hours = Math.abs(minutes) / 60;
  const text = Number.isInteger(hours) ? String(hours) : hours.toFixed(1);
  return minutes === 0 ? `Змінився час відключень на ${dayType === 'today' ? 'сьогодні' : 'завтра'} ⚡`
    : `Світла ${verb} ${minutes > 0 ? 'МЕНШЕ' : 'БІЛЬШЕ'} на ${text} год. ${minutes > 0 ? '😔' : '🎉'}`;
}

/** Enforce byte limits while reading, including chunked uploads without Content-Length. */
export async function readLimitedBody(body: ReadableStream<Uint8Array> | null): Promise<string> {
  if (!body) throw new PayloadError('Empty HTML body');
  const reader = body.getReader();
  const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: false });
  const decode = (value?: Uint8Array, stream = false): string => {
    try { return decoder.decode(value, { stream }); }
    catch { throw new PayloadError('HTML must be valid UTF-8'); }
  };
  let bytes = 0;
  let text = '';
  let timer: ReturnType<typeof setTimeout>;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new PayloadError('HTML upload timed out', 'request_timeout')), 30_000);
  });
  try {
    while (true) {
      const chunk = await Promise.race([reader.read(), deadline]);
      if (chunk.done) break;
      bytes += chunk.value.byteLength;
      if (bytes > MAX_HTML_BYTES) {
        await reader.cancel();
        throw new PayloadError('HTML exceeds 2 MiB', 'payload_too_large');
      }
      text += decode(chunk.value, true);
    }
    return text + decode();
  } catch (error) {
    await reader.cancel().catch(() => undefined);
    throw error;
  } finally { clearTimeout(timer!); reader.releaseLock(); }
}
