/**
 * Shared visitor accumulation — the single reducer used by BOTH the live
 * CometD feed and the historical replay, so they can't drift apart.
 *
 * Both surfaces produce Demo_Event__e-shaped payloads (Type__c, Session_Id__c,
 * Payload_Json__c, Demo_Session_Id__c); this folds each into a keyed visitor
 * map. Live stamps with wall-clock time + a 30-min TTL; replay stamps with the
 * record's CreatedDate and snapshots with no TTL (everyone stays visible).
 */
import type { Visitor, RouteLeg } from './visitors';

export interface TrackedVisitor extends Visitor {
  lastSeen: number;
}
export type VisitorMap = Map<string, TrackedVisitor>;

/** Matches the live feed's stale-out window. */
export const SESSION_TTL_MS = 30 * 60 * 1000;

export interface PlatformEventPayload {
  Type__c?: string;
  Session_Id__c?: string;
  Demo_Session_Id__c?: string;
  Payload_Json__c?: string | null;
}

function parseInner(jsonStr: string | null | undefined): Record<string, unknown> {
  if (!jsonStr) return {};
  try {
    return JSON.parse(jsonStr);
  } catch {
    return {};
  }
}

function toNumber(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  const n = parseFloat(String(v));
  return Number.isFinite(n) ? n : null;
}

/**
 * Fold one Demo_Event__e payload into the visitor map. `stampTime` is the
 * event's wall-clock (live) or CreatedDate (replay). Returns true if the
 * payload was applied (false if filtered out by demo-session scope / no id).
 */
export function applyPlatformEvent(
  map: VisitorMap,
  payload: PlatformEventPayload,
  stampTime: number,
  activeDemoSessionId?: string | null
): boolean {
  const demoSessionId = payload.Demo_Session_Id__c;
  if (activeDemoSessionId && demoSessionId && demoSessionId !== activeDemoSessionId) {
    return false;
  }
  const sessionId = payload.Session_Id__c;
  if (!sessionId) return false;

  let v = map.get(sessionId);
  if (!v) {
    v = { sessionId, lastSeen: stampTime, surveyComplete: false };
    map.set(sessionId, v);
  }
  v.lastSeen = stampTime;

  const inner = parseInner(payload.Payload_Json__c);

  switch (payload.Type__c) {
    case 'session_started':
    case 'survey_complete': {
      if (payload.Type__c === 'survey_complete') v.surveyComplete = true;
      const lat = toNumber(inner.lat);
      const lon = toNumber(inner.lon);
      if (lat !== null) v.lat = lat;
      if (lon !== null) v.lon = lon;
      if (inner.city) v.city = inner.city as string;
      break;
    }
    case 'flight_booked':
      v.route = {
        legs: Array.isArray(inner.legs) ? (inner.legs as RouteLeg[]) : [],
        isConnection: !!inner.isConnection,
      };
      break;
    case 'seat_changed':
      v.seat = (inner.seat as string) || null;
      break;
    case 'profile_created':
      v.firstName = (inner.firstName as string) || null;
      v.lastName = (inner.lastName as string) || null;
      v.avatarUrl = (inner.avatarUrl as string) || null;
      break;
    default:
      break;
  }
  return true;
}

/**
 * Snapshot the map to a plain Visitor[]. `ttlMs = null` keeps everyone
 * (replay); a number drops sessions idle longer than it (live).
 */
export function snapshot(map: VisitorMap, now: number, ttlMs: number | null): Visitor[] {
  const out: Visitor[] = [];
  for (const tracked of map.values()) {
    if (ttlMs !== null && now - tracked.lastSeen >= ttlMs) continue;
    const { lastSeen: _lastSeen, ...v } = tracked;
    out.push(v);
  }
  return out;
}
