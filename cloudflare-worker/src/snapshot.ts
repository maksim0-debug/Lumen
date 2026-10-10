import { ALL_GROUPS, nextCalendarDate, parseUpdateTime, PayloadError, type ScheduleSnapshot } from './schedule';

export const SNAPSHOT_TOPIC = 'lumen_schedules_v1';
export const JOURNAL_LIMIT = 2048;
export interface CompactSnapshot {
  v: 1;
  journalId: string;
  sequence: number;
  todayDate: string;
  tomorrowDate: string;
  sourceVersion: number;
  sourceUpdatedAt: string;
  alerts: number;
  groups: Record<string, [string, string | null]>;
}
export const publicationKey = (sequence: number): string => `publication:${String(sequence).padStart(16, '0')}`;

export function compactSnapshot(value: ScheduleSnapshot, journalId: string, sequence: number): CompactSnapshot {
  const today = value.days[0];
  const tomorrow = value.days.find(day => day.dayType === 'tomorrow');
  return {
    v: 1, journalId, sequence, todayDate: today.calendarDate,
    tomorrowDate: nextCalendarDate(today.calendarDate), sourceVersion: value.updateAt,
    sourceUpdatedAt: value.updateStr, alerts: 0,
    groups: Object.fromEntries(today.groups.map(group => [group.group,
      [group.hash, tomorrow?.groups.find(other => other.group === group.group)?.hash ?? null]])),
  };
}

export function validateCompactSnapshot(value: CompactSnapshot): void {
  if (!value || value.v !== 1 || typeof value.journalId !== 'string' ||
      !/^[a-zA-Z0-9-]{1,64}$/.test(value.journalId) || !Number.isSafeInteger(value.sequence) || value.sequence < 1 ||
      typeof value.todayDate !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value.todayDate) ||
      !Number.isFinite(Date.parse(`${value.todayDate}T00:00:00Z`)) ||
      new Date(`${value.todayDate}T00:00:00Z`).toISOString().slice(0, 10) !== value.todayDate ||
      value.tomorrowDate !== nextCalendarDate(value.todayDate) ||
      !Number.isSafeInteger(value.sourceVersion) || value.sourceVersion < 1 ||
      !Number.isInteger(value.alerts) || value.alerts < 0 || value.alerts > 0xffffff ||
      parseUpdateTime(value.sourceUpdatedAt) !== value.sourceVersion || !value.groups ||
      Object.keys(value.groups).length !== ALL_GROUPS.length) throw new PayloadError('Invalid compact snapshot');
  let published: boolean | undefined;
  for (const group of ALL_GROUPS) {
    const pair = value.groups[group];
    if (!Array.isArray(pair) || pair.length !== 2 || typeof pair[0] !== 'string' || !/^[0-4]{24}$/.test(pair[0]) ||
        (pair[1] !== null && (typeof pair[1] !== 'string' || !/^[0-4]{24}$/.test(pair[1]))) ||
        (published !== undefined && published !== (pair[1] !== null))) throw new PayloadError('Incomplete compact snapshot');
    published = pair[1] !== null;
  }
}

/** FCM topic limits include UTF-8 keys and values. Counting JSON is conservative. */
export function fitsTopicPayload(data: Record<string, string>): boolean {
  return new TextEncoder().encode(JSON.stringify(data)).length <= 2048;
}
