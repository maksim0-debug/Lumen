import { parse, type DefaultTreeAdapterTypes } from 'parse5';

export const EMERGENCY_TOPIC = 'emergency_alerts';
export const EMERGENCY_MAX_AGE = 15 * 60_000;
const CONFIRMATION_DELAY = 30_000;
const CONFIRMATION_WINDOW = 20 * 60_000;
type Node = DefaultTreeAdapterTypes.Node;
const IGNORED_ELEMENTS = new Set(['script', 'style', 'template', 'noscript']);
export interface EmergencyObservation { active: boolean; observedAt: number }
export interface EmergencyState extends EmergencyObservation {
  changedAt: number;
  seenAt: number;
  cancellationSince?: number;
}

function children(node: Node): Node[] { return 'childNodes' in node ? node.childNodes : []; }
function text(node: Node): string {
  if ('value' in node) return node.value;
  if ('tagName' in node && IGNORED_ELEMENTS.has(node.tagName)) return '';
  return children(node).map(text).join(' ');
}
function elements(root: Node): DefaultTreeAdapterTypes.Element[] {
  const result: DefaultTreeAdapterTypes.Element[] = [];
  const pending = [root];
  while (pending.length) {
    const node = pending.pop()!;
    if ('tagName' in node) result.push(node);
    if (!('tagName' in node) || !IGNORED_ELEMENTS.has(node.tagName)) pending.push(...children(node));
  }
  return result;
}
function attribute(node: DefaultTreeAdapterTypes.Element, name: string): string {
  return node.attrs.find(attr => attr.name === name)?.value ?? '';
}

function statusFromNodes(html: string, nodes: DefaultTreeAdapterTypes.Element[]): boolean | null {
  if (!html || /_Incapsula_Resource|cf-browser-verification|Just a moment\.\.\./.test(html)) return null;
  const notices = nodes.filter(node => attribute(node, 'id') === 'modal-attention' ||
    attribute(node, 'class').split(/\s+/).some(name => ['m-attention', 'modal-attention'].includes(name)));
  const states = new Set<boolean>();
  for (const notice of notices) {
    const normalized = text(notice).toLowerCase().replace(/i/g, 'і').replace(/\s+/g, ' ').trim();
    for (const sentence of normalized.split(/[.!?;]/)) {
      if (/якщо|у разі|можуть|можлив|будуть|не введен|не запроваджен/.test(sentence)) continue;
      if (/екстрені відключення\s+(?:скасовано|скасовані|припинено|не діють|не застосовуються)|(?:скасовано|скасовані|припинено|не діють|не застосовуються)\s+екстрені відключення/.test(sentence)) {
        states.add(false);
        continue;
      }
      if (/(?:введені|введено|запроваджені|запроваджено|застосовуються|діють)\s+екстрені відключення|екстрені відключення\s+(?:введені|введено|запроваджені|запроваджено|діють|застосовуються)/.test(sentence)) states.add(true);
    }
  }
  if (states.size === 1) return [...states][0];
  if (states.size || notices.length) return null;
  return /<html(?:\s|>)/i.test(html) && /<body(?:\s|>)/i.test(html) &&
    /<\/body\s*>/i.test(html) && /<\/html\s*>/i.test(html) &&
    /DisconSchedule\.fact\s*=/.test(html) ? false : null;
}

export function extractEmergencyStatus(html: string): boolean | null {
  return statusFromNodes(html, elements(parse(html)));
}

export function validObservation(value: unknown, now = Date.now()): value is EmergencyObservation {
  if (!value || typeof value !== 'object') return false;
  const observation = value as EmergencyObservation;
  return typeof observation.active === 'boolean' && Number.isSafeInteger(observation.observedAt) &&
    observation.observedAt > 0 && observation.observedAt <= now + 60_000 &&
    now - observation.observedAt <= EMERGENCY_MAX_AGE;
}

/** Canonical bridges explicitly carry their capture time; script-only legacy uploads are unknown. */
export function readEmergencyObservation(html: string, observedAt = Date.now()): EmergencyObservation | undefined {
  const nodes = elements(parse(html));
  const transports = nodes.filter(node => node.tagName === 'script' && attribute(node, 'id') === 'lumen-emergency');
  if (transports.length) {
    if (transports.length !== 1) return undefined;
    try {
      const value: unknown = JSON.parse(children(transports[0]).map(node => 'value' in node ? node.value : '').join(''));
      if (!value || typeof value !== 'object' || (value as { schemaVersion?: unknown }).schemaVersion !== 1) return undefined;
      return validObservation(value) ? value : undefined;
    } catch { return undefined; }
  }
  const active = statusFromNodes(html, nodes);
  const observation = active == null ? undefined : { active, observedAt };
  return validObservation(observation) ? observation : undefined;
}

export function acceptEmergency(previous: EmergencyState | undefined, observation: EmergencyObservation): EmergencyState | undefined {
  if (!validObservation(observation) || (previous && observation.observedAt <= previous.seenAt)) return previous;
  const time = observation.observedAt;
  if (previous?.active && !observation.active) {
    const first = previous.cancellationSince;
    if (first === undefined || time - first > CONFIRMATION_WINDOW) {
      return { ...previous, seenAt: time, cancellationSince: time };
    }
    if (time - first < CONFIRMATION_DELAY) return { ...previous, seenAt: time };
  }
  return { ...observation, seenAt: time,
    changedAt: previous?.active === observation.active ? previous.changedAt : time };
}

export function retryDelay(attempts: number): number {
  return Math.min(15 * 60_000, 30_000 * 2 ** Math.min(attempts - 1, 5));
}
