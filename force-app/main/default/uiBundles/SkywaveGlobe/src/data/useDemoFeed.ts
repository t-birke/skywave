/**
 * Live demo feed over the CometD Streaming API.
 *
 * Subscribes to the two Skywave Platform Event channels and reduces them
 * into the Visitor[] + current-stage state the globe renders. Ports the
 * accumulation logic from skywaveDemoMonitor.js's handleDemoEvent, minus the
 * survey-thumbnail resolution (the globe shows avatars, not survey strips).
 *
 * DEV/DEMO transport: the browser talks to same-origin /cometd, which the
 * Vite dev server proxies to the org with a Bearer token injected (see
 * vite.config.ts). No empApi, no Heroku relay, no org metadata deploy.
 */
import { useEffect, useRef, useState } from 'react';
import { CometD } from 'cometd';
import { ReplayExtension } from './cometdReplay';
import type { Visitor, RouteLeg } from './visitors';

const EVENT_CHANNEL = '/event/Demo_Event__e';
const STATE_CHANNEL = '/event/Demo_State_Change__e';
// Session is considered stale without a fresh event for this long (matches
// the LWC's SESSION_TTL_MS).
const SESSION_TTL_MS = 30 * 60 * 1000;

export type FeedStatus = 'connecting' | 'connected' | 'disconnected' | 'error';

export interface DemoFeed {
  visitors: Visitor[];
  stage: string;
  status: FeedStatus;
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

export function useDemoFeed(activeDemoSessionId?: string | null): DemoFeed {
  const [visitors, setVisitors] = useState<Visitor[]>([]);
  const [stage, setStage] = useState<string>('idle');
  const [status, setStatus] = useState<FeedStatus>('connecting');

  // Mutable visitor map keyed by sessionId; flushed to state on each event.
  const bySession = useRef<Map<string, Visitor & { lastSeen: number }>>(new Map());

  useEffect(() => {
    const cometd = new CometD();
    const replay = new ReplayExtension();
    replay.setReplay({ [EVENT_CHANNEL]: -1, [STATE_CHANNEL]: -1 });
    cometd.registerExtension('sfdc-replay', replay);

    const cometdUrl = `${window.location.origin}/cometd/60.0/`;
    cometd.configure({
      // Same-origin; the Vite proxy forwards to the org with the token.
      url: cometdUrl,
      appendMessageTypeToURL: false,
      logLevel: 'warn',
    });
    // Salesforce CometD is long-polling only — and the Vite proxy doesn't
    // tunnel WebSockets to the org. Drop the websocket transport so the
    // client doesn't pick `ws://localhost/...` and hang before handshake.
    cometd.unregisterTransport('websocket');

    let unloaded = false;

    const flush = () => {
      const now = Date.now();
      const live = [...bySession.current.values()].filter(
        v => now - v.lastSeen < SESSION_TTL_MS
      );
      setVisitors(live.map(({ lastSeen: _lastSeen, ...v }) => v));
    };

    const handleEvent = (payload: Record<string, unknown>) => {
      const demoSessionId = payload.Demo_Session_Id__c as string | undefined;
      // Scope to the active demo run if one is set.
      if (
        activeDemoSessionId &&
        demoSessionId &&
        demoSessionId !== activeDemoSessionId
      ) {
        return;
      }
      const sessionId = payload.Session_Id__c as string | undefined;
      if (!sessionId) return;

      const now = Date.now();
      let v = bySession.current.get(sessionId);
      if (!v) {
        v = { sessionId, lastSeen: now, surveyComplete: false };
        bySession.current.set(sessionId, v);
      }
      v.lastSeen = now;

      const inner = parseInner(payload.Payload_Json__c as string);

      switch (payload.Type__c) {
        case 'session_started': {
          const lat = toNumber(inner.lat);
          const lon = toNumber(inner.lon);
          if (lat !== null) v.lat = lat;
          if (lon !== null) v.lon = lon;
          if (inner.city) v.city = inner.city as string;
          break;
        }
        case 'survey_complete': {
          v.surveyComplete = true;
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
      flush();
    };

    cometd.handshake(hs => {
      if (hs.successful) {
        setStatus('connected');
        cometd.subscribe(EVENT_CHANNEL, msg => {
          const data = msg.data as { payload?: Record<string, unknown> };
          if (data?.payload) handleEvent(data.payload);
        });
        cometd.subscribe(STATE_CHANNEL, msg => {
          const data = msg.data as { payload?: Record<string, unknown> };
          const p = data?.payload;
          if (!p) return;
          if (
            activeDemoSessionId &&
            p.Demo_Session_Id__c &&
            p.Demo_Session_Id__c !== activeDemoSessionId
          ) {
            return;
          }
          if (p.New_State__c) setStage(p.New_State__c as string);
        });
      } else if (!unloaded) {
        setStatus('error');
      }
    });

    cometd.addListener('/meta/connect', m => {
      if (!unloaded) setStatus(m.successful ? 'connected' : 'disconnected');
    });

    return () => {
      unloaded = true;
      try {
        cometd.disconnect();
      } catch {
        // ignore teardown races
      }
    };
  }, [activeDemoSessionId]);

  return { visitors, stage, status };
}
