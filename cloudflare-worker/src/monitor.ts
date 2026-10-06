import { FcmMessageOptions, getServiceAccount, groupToTopic, sendFcmTopicNotification } from './fcm';
import { ALL_GROUPS, calendarDate, formatDiffMessage, nextCalendarDate, parseSnapshot, parseUpdateTime,
  PayloadError, ScheduleDay, ScheduleSnapshot } from './schedule';
import type { Env } from './index';

export interface MonitoringReport {
  timestamp: string;
  status: string;
  source: string;
  dryRun: boolean;
  checkedGroups: number;
  changesDetected: string[];
  notificationsSent: string[];
  notificationsPlanned: string[];
  suppressedFlaps: string[];
  errors: string[];
  dtekUpdateStr?: string;
}
interface PendingMessage {
  options: FcmMessageOptions;
  calendarDate: string;
  attempts: number;
  nextAttemptAt: number;
}
interface GroupState {
  dateKey: string;
  calendarDate: string;
  todayHash: string;
  outageMinutes: number;
  version: number;
  source: string;
  dtekUpdateStr: string;
  updatedAt: string;
  lastNotifiedAt?: string;
  pending?: PendingMessage;
}
interface MonitorState {
  schemaVersion: 1;
  groups: Record<string, GroupState>;
  snapshot?: { calendarDate: string; version: number; fingerprint: string };
}
const STORAGE_KEY = 'monitor-v1';

function report(source: string, dryRun: boolean): MonitoringReport {
  return { timestamp: new Date().toISOString(), status: dryRun ? 'dry_run_success' : 'success', source,
    dryRun, checkedGroups: 0, changesDetected: [], notificationsSent: [], notificationsPlanned: [],
    suppressedFlaps: [], errors: [] };
}
function keyFor(group: string, dayType: string): string {
  return `state_${dayType === 'tomorrow' ? 'tomorrow_' : ''}${group}`;
}

/** One global writer: serialize across network awaits as well as storage operations. */
export class ScheduleMonitor {
  private tail: Promise<void> = Promise.resolve();
  constructor(private readonly state: DurableObjectState, private readonly env: Env) {}

  private enqueue<T>(task: () => Promise<T>): Promise<T> {
    const result = this.tail.then(task);
    this.tail = result.then(() => undefined, () => undefined);
    return result;
  }

  async fetch(request: Request): Promise<Response> {
    return this.enqueue(async () => {
      const input = await request.json() as { html: string; source: string; dryRun: boolean };
      const result = report(input.source, input.dryRun);
      try {
        const snapshot = parseSnapshot(input.html);
        result.dtekUpdateStr = snapshot.updateStr;
        const stored = await this.load(snapshot);
        const next = structuredClone(stored);
        const initialized = Object.keys(stored.groups).length > 0 || stored.snapshot !== undefined;
        const today = snapshot.days[0].calendarDate;
        const fingerprint = JSON.stringify(snapshot.days.map(day =>
          [day.calendarDate, day.groups.map(group => [group.group, group.hash])]));
        const latestTodayVersion = Math.max(
          stored.snapshot?.calendarDate === today ? stored.snapshot.version : 0,
          ...Object.values(stored.groups)
            .filter(group => group.calendarDate === today)
            .map(group => group.version),
          0,
        );
        if ((stored.snapshot && stored.snapshot.calendarDate > today) ||
            (latestTodayVersion > 0 && snapshot.updateAt < latestTodayVersion)) {
          result.status = 'stale_snapshot';
          result.checkedGroups = snapshot.days.reduce((sum, day) => sum + day.groups.length, 0);
          return Response.json(result);
        }
        if (stored.snapshot?.calendarDate === today && stored.snapshot.version === snapshot.updateAt &&
            stored.snapshot.fingerprint !== fingerprint) {
          throw new PayloadError('Different snapshots have the same DTEK update time', 'conflicting_version');
        }
        // Absence is a versioned state, not permission to retain an obsolete publication/outbox.
        for (const day of snapshot.days) this.acceptDay(next, day, snapshot, result, initialized);
        if (!snapshot.days.some(day => day.dayType === 'tomorrow')) {
          for (const group of ALL_GROUPS) delete next.groups[keyFor(group, 'tomorrow')];
        }
        if (result.errors.length > 0) {
          // Reject conflicting versions atomically, including changes to other groups.
          result.status = 'conflicting_version';
          result.changesDetected = [];
          result.notificationsPlanned = [];
        } else if (!input.dryRun) {
          // Commit an alarm and the outbox before any external effect.
          next.snapshot = { calendarDate: today, version: snapshot.updateAt, fingerprint };
          await this.persist(next);
          await this.deliver(next, result);
        }
        if (['success', 'dry_run_success'].includes(result.status) && result.checkedGroups > 0 &&
            result.suppressedFlaps.length === result.checkedGroups) result.status = 'stale_snapshot';
      } catch (error) {
        result.status = error instanceof PayloadError ? error.status : 'storage_error';
        result.errors.push(error instanceof Error ? error.message : String(error));
      }
      return Response.json(result);
    });
  }

  private async load(snapshot?: ScheduleSnapshot): Promise<MonitorState> {
    const stored = await this.state.storage.get<MonitorState>(STORAGE_KEY);
    if (stored) {
      if (stored.schemaVersion !== 1 || !stored.groups || typeof stored.groups !== 'object') {
        throw new Error('Unsupported or corrupt monitor state');
      }
      if (stored.snapshot && (!Number.isSafeInteger(stored.snapshot.version) || stored.snapshot.version < 0 ||
          !/^\d{4}-\d{2}-\d{2}$/.test(stored.snapshot.calendarDate) || typeof stored.snapshot.fingerprint !== 'string')) {
        throw new Error('Corrupt snapshot metadata');
      }
      for (const [key, group] of Object.entries(stored.groups)) {
        if (!ALL_GROUPS.some(g => key === keyFor(g, 'today') || key === keyFor(g, 'tomorrow')) ||
            !group || !/^\d+$/.test(group.dateKey) || !/^\d{4}-\d{2}-\d{2}$/.test(group.calendarDate) ||
            !/^[0-4]{24}$/.test(group.todayHash) || !Number.isSafeInteger(group.version) || group.version < 0 ||
            !Number.isFinite(group.outageMinutes) || group.outageMinutes < 0 || group.outageMinutes > 1440 ||
            typeof group.source !== 'string' || typeof group.dtekUpdateStr !== 'string' ||
            typeof group.updatedAt !== 'string') throw new Error('Corrupt group state');
        if (group.pending && (!Number.isSafeInteger(group.pending.attempts) || group.pending.attempts < 0 ||
            !Number.isFinite(group.pending.nextAttemptAt) || !group.pending.options ||
            !['today', 'tomorrow'].includes(group.pending.options.dayType ?? '') ||
            group.pending.calendarDate !== group.calendarDate || group.pending.options.scheduleHash !== group.todayHash ||
            group.pending.options.group !== key.replace(/^state_(tomorrow_)?/, '') ||
            typeof group.pending.options.eventId !== 'string')) throw new Error('Corrupt notification outbox');
      }
      return stored;
    }
    const groups: Record<string, GroupState> = {};
    if (snapshot) {
      // Import KV once; never write it again, eliminating competing KV writers.
      await Promise.all(['today', 'tomorrow'].flatMap(dayType => ALL_GROUPS.map(async group => {
        const key = keyFor(group, dayType);
        const raw = await this.env.SCHEDULE_KV.get(key);
        if (!raw) return;
        let legacy: Record<string, unknown>;
        try { legacy = JSON.parse(raw); } catch { return; }
        if (!legacy || typeof legacy !== 'object' || !/^\d+$/.test(String(legacy.dateKey)) ||
            !/^[0-4]{24}$/.test(String(legacy.todayHash)) ||
            typeof legacy.outageMinutes !== 'number' || legacy.outageMinutes < 0 || legacy.outageMinutes > 1440) return;
        const stamp = Number(legacy.dateKey) * 1000;
        if (!Number.isFinite(stamp) || Math.abs(stamp - Date.now()) > 7 * 86_400_000) return;
        let version = 0;
        const update = typeof legacy.dtekUpdateStr === 'string' ? legacy.dtekUpdateStr : '';
        try { version = parseUpdateTime(update); } catch { /* old deployments had no source timestamp */ }
        groups[key] = { dateKey: String(legacy.dateKey), calendarDate: calendarDate(stamp),
          todayHash: String(legacy.todayHash), outageMinutes: legacy.outageMinutes, version,
          dtekUpdateStr: update, source: 'legacy_kv', updatedAt: String(legacy.updatedAt ?? '') };
      })));
    }
    return { schemaVersion: 1, groups };
  }

  private acceptDay(stored: MonitorState, day: ScheduleDay, snapshot: ScheduleSnapshot, result: MonitoringReport, initialized: boolean): void {
    for (const schedule of day.groups) {
      const { group, hash, outageMinutes } = schedule;
      const key = keyFor(group, day.dayType);
      const direct = stored.groups[key];
      const rollover = day.dayType === 'today' ? stored.groups[keyFor(group, 'tomorrow')] : undefined;
      const previous = rollover?.calendarDate === day.calendarDate &&
        (direct?.calendarDate !== day.calendarDate || rollover.version > direct.version) ? rollover : direct;
      result.checkedGroups++;
      if (previous && (previous.calendarDate > day.calendarDate ||
          (previous.calendarDate === day.calendarDate && previous.version > snapshot.updateAt))) {
        result.suppressedFlaps.push(`${group} (${day.dayType}): older DTEK version ignored`);
        continue;
      }
      const sameDay = previous?.calendarDate === day.calendarDate;
      if (sameDay && previous.version === snapshot.updateAt && previous.todayHash !== hash) {
        result.errors.push(`${group} (${day.dayType}): different schedules have the same DTEK update time`);
        continue;
      }
      const changed = previous !== undefined ? (sameDay ? previous.todayHash !== hash : day.dayType === 'tomorrow')
        : initialized && day.dayType === 'tomorrow';
      const next: GroupState = { dateKey: day.dateKey, calendarDate: day.calendarDate, todayHash: hash,
        outageMinutes, version: snapshot.updateAt, source: result.source, dtekUpdateStr: snapshot.updateStr,
        updatedAt: result.timestamp, lastNotifiedAt: sameDay ? previous?.lastNotifiedAt : undefined,
        pending: sameDay && previous === direct && previous?.todayHash === hash ? previous.pending : undefined };
      if (changed) {
        const published = !sameDay;
        const name = group.replace('GPV', 'Група ');
        const label = `${group} (${day.dayType}${published ? ' published' : ''})`;
        result.changesDetected.push(label);
        result.notificationsPlanned.push(label);
        const outHours = outageMinutes / 60;
        const options: FcmMessageOptions = {
          topic: groupToTopic(group, day.dayType), group, dayType: day.dayType,
          title: published ? `Опубліковано графік на ЗАВТРА! (${name})`
            : `Графік${day.dayType === 'tomorrow' ? ' на ЗАВТРА' : ''} змінено! (${name})`,
          body: published ? (outageMinutes > 0 ? `Заплановано відключень: ${outHours} год. ⚡` : 'Відключень не заплановано 🎉')
            : previous!.pending ? `Оновлений графік${day.dayType === 'tomorrow' ? ' на завтра' : ''}: відключень ${outHours} год. ⚡`
              : formatDiffMessage(outageMinutes - previous!.outageMinutes, day.dayType),
          changeType: published ? 'tomorrow_published' : day.dayType === 'tomorrow' ? 'tomorrow_schedule_updated' : 'schedule_updated',
          scheduleHash: hash, outageMinutes,
          eventId: `${group}:${day.calendarDate}:${snapshot.updateAt}:${hash}`,
          targetDate: day.calendarDate,
        };
        next.pending = { options, calendarDate: day.calendarDate, attempts: 0, nextAttemptAt: Date.now() };
      }
      stored.groups[key] = next;
    }
  }

  private async persist(stored: MonitorState): Promise<void> {
    const pending = Object.values(stored.groups).flatMap(g => g.pending ? [g.pending.nextAttemptAt] : []);
    await this.state.storage.transaction(async transaction => {
      await transaction.put(STORAGE_KEY, stored);
      if (pending.length > 0) await transaction.setAlarm(Math.max(Date.now() + 1000, Math.min(...pending)));
      else await transaction.deleteAlarm();
    });
  }

  private async deliver(stored: MonitorState, result: MonitoringReport): Promise<void> {
    const account = getServiceAccount(this.env.FIREBASE_SERVICE_ACCOUNT);
    const pending = Object.entries(stored.groups).filter(([, g]) => g.pending);
    for (let start = 0; start < pending.length; start += 4) {
      await Promise.all(pending.slice(start, start + 4).map(async ([, group]) => {
        const message = group.pending!;
        const today = calendarDate();
        const expected = message.options.dayType === 'tomorrow' ? nextCalendarDate(today) : today;
        if (message.calendarDate !== expected) { delete group.pending; return; }
        if (message.nextAttemptAt > Date.now()) return;
        const outcome = account ? await sendFcmTopicNotification(account, message.options)
          : { success: false, error: 'FIREBASE_SERVICE_ACCOUNT is missing or invalid' };
        if (outcome.success) {
          result.notificationsSent.push(`${message.options.group} -> ${message.options.topic} (${outcome.messageId})`);
          group.lastNotifiedAt = new Date().toISOString();
          delete group.pending;
        } else {
          result.errors.push(`${message.options.group}: ${outcome.error}`);
          message.attempts++;
          message.nextAttemptAt = Date.now() + Math.min(15 * 60_000, 30_000 * 2 ** Math.min(message.attempts - 1, 5));
        }
      }));
    }
    await this.persist(stored);
    if (Object.values(stored.groups).some(g => g.pending)) result.status = 'delivery_pending';
  }

  async alarm(): Promise<void> {
    await this.enqueue(async () => {
      const stored = await this.load();
      await this.deliver(stored, report('retry_alarm', false));
    });
  }
}
