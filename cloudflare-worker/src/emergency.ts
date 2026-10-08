import { parse, type DefaultTreeAdapterTypes } from 'parse5';

export const EMERGENCY_TOPIC = 'emergency_alerts';
export const EMERGENCY_MAX_AGE = 15 * 60_000;
const CONFIRMATION_DELAY = 30_000;
const CONFIRMATION_WINDOW = 20 * 60_000;
type Node = DefaultTreeAdapterTypes.Node;
const IGNORED_ELEMENTS = new Set(['script', 'style', 'template', 'noscript']);
export interface EmergencyObservation { active: boolean; observedAt: number; confirmed?: boolean; isPossible?: boolean; noticeText?: string }
export interface EmergencyState extends EmergencyObservation {
  changedAt: number;
  seenAt: number;
  cancellationSince?: number;
}

function children(node: Node): Node[] { return 'childNodes' in node ? node.childNodes : []; }
function text(node: Node): string {
  if ('value' in node) return node.value;
  if ('tagName' in node && (IGNORED_ELEMENTS.has(node.tagName) || ['button', 'svg'].includes(node.tagName))) return '';
  const content = children(node).map(text).join('');
  return 'tagName' in node && ['p', 'div', 'br', 'li', 'h2', 'h3', 'h4', 'h5', 'h6'].includes(node.tagName) ? `${content}\n` : content;
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

const EMERGENCY = /(?:екстрен[а-яіїєґ]*|аварійн[а-яіїєґ]*)(?:\s+(?:відключен|вимкнен|знеструмлен)[а-яіїєґ]*)?/;
const CANCELLATION_WORDS = /(?:скасован[а-яіїєґ]*|скасовано|відмінен[а-яіїєґ]*|відмінено|припинен[а-яіїєґ]*|припинено|не діють|не застосовуються|не застосовують|не вводяться|не запроваджуються|не введен[а-яіїєґ]*|не запроваджен[а-яіїєґ]*|немає|відсутн[а-яіїєґ]*)/.source;
const CANCELLATION_FILLER = /(?:(?:електроенергії|вже|були|наразі|більше)\s+)*/.source;
const CANCELLED = new RegExp(`${CANCELLATION_WORDS}\\s+${CANCELLATION_FILLER}${EMERGENCY.source}|${EMERGENCY.source}\\s+${CANCELLATION_FILLER}${CANCELLATION_WORDS}`);
const HYPOTHETICAL = /якщо|у разі|уникн|запобіг|не допуст|недопущ|будуть/;
const STANDARD = /(?:введені|введено|запроваджені|запроваджено|застосовуються|діють)\s+екстрені відключення|екстрені відключення\s+(?:введені|введено|запроваджені|запроваджено|діють|застосовуються)/;
const LOCAL = /район|частин|окрем|громад|населен|вулиц|адрес|локаль/;

const WHOLE = /(?:всій|усій|всю|усю)\s+област|(?:всіх|усіх)\s+(?:район|громад)/;
const UNCERTAIN = /можлив|можуть|може/;

function statusFromNodes(html: string, nodes: DefaultTreeAdapterTypes.Element[], observedAt: number): EmergencyObservation | undefined {
  if (!html || /_Incapsula_Resource|cf-browser-verification|Just a moment\.\.\./.test(html)) return undefined;
  const notices = nodes.filter(node => attribute(node, 'id') === 'modal-attention' ||
    attribute(node, 'class').split(/\s+/).some(name => ['m-attention', 'modal-attention'].includes(name)));
  const states = new Set<boolean>();
  const texts = new Set<string>();
  let isPossible = false;
  for (const notice of notices) {
    const source = text(notice).split('\n').map(line => line.replace(/\s+/g, ' ').trim()).filter(Boolean).join('\n\n');
    if (!source) continue;
    texts.add(source);
    const normalized = source.toLowerCase().replace(/i/g, 'і').replace(/\s+/g, ' ');
    let hasEmergency = false;
    for (const part of normalized.split(/[.!?;]/)) {
      const sentence = part.replace(new RegExp(CANCELLED.source, 'g'), '');
      if (!EMERGENCY.test(sentence) || HYPOTHETICAL.test(sentence)) continue;
      hasEmergency = true;
      isPossible ||= !STANDARD.test(sentence) || UNCERTAIN.test(sentence) || (LOCAL.test(sentence) && !WHOLE.test(sentence));
    }
    if (hasEmergency) states.add(true);
    else states.add(false);
  }
  if (states.size === 1) {
    const active = [...states][0];
    return { active, observedAt, confirmed: true, isPossible: active && isPossible, noticeText: [...texts].join('\n\n') };
  }
  if (states.size || notices.length) return undefined;
  return /<html(?:\s|>)/i.test(html) && /<body(?:\s|>)/i.test(html) &&
    /<\/body\s*>/i.test(html) && /<\/html\s*>/i.test(html) &&
    /DisconSchedule\.fact\s*=/.test(html) ? { active: false, observedAt, confirmed: true } : undefined;
}

export function extractEmergencyStatus(html: string): boolean | null {
  return statusFromNodes(html, elements(parse(html)), 1)?.active ?? null;
}

export function validObservation(value: unknown, now = Date.now()): value is EmergencyObservation {
  if (!value || typeof value !== 'object') return false;
  const observation = value as EmergencyObservation;
  return (observation.confirmed === undefined || typeof observation.confirmed === 'boolean') &&
    (observation.isPossible === undefined || (typeof observation.isPossible === 'boolean' && (!observation.isPossible || observation.active))) &&
    (observation.noticeText === undefined || typeof observation.noticeText === 'string') &&
    typeof observation.active === 'boolean' && Number.isSafeInteger(observation.observedAt) &&
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
  const observation = statusFromNodes(html, nodes, observedAt);
  return validObservation(observation) ? observation : undefined;
}

export function acceptEmergency(previous: EmergencyState | undefined, observation: EmergencyObservation): EmergencyState | undefined {
  if (!validObservation(observation) || (previous && observation.observedAt <= previous.seenAt)) return previous;
  const time = observation.observedAt;
  if (previous?.active && !observation.active && !observation.confirmed) {
    const first = previous.cancellationSince;
    if (first === undefined || time - first > CONFIRMATION_WINDOW) {
      return { ...previous, seenAt: time, cancellationSince: time };
    }
    if (time - first < CONFIRMATION_DELAY) return { ...previous, seenAt: time };
  }
  return { ...observation, seenAt: time,
    changedAt: previous?.active === observation.active && (previous.isPossible ?? false) === (observation.isPossible ?? false) ? previous.changedAt : time };
}

export function retryDelay(attempts: number): number {
  return Math.min(15 * 60_000, 30_000 * 2 ** Math.min(attempts - 1, 5));
}
