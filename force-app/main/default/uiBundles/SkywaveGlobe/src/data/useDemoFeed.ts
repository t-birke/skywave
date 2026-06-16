/**
 * Live demo feed over the Heroku relay WebSocket.
 *
 * Why not CometD/Pub/Sub directly? The deployed bundle runs on
 * `*.salesforce.app`, a different registrable domain from `*.my.salesforce.com`
 * where the session cookie lives — so an in-org CometD handshake to
 * `/cometd/` returns `403::Handshake denied` (the browser never sends `sid`,
 * and the bundle gateway injects auth only for the UI-API/GraphQL allowlist,
 * not `/cometd`). Pub/Sub is no escape either: its `Subscribe` RPC is
 * bidirectional-streaming, which gRPC-Web cannot do from a browser.
 *
 * So Pub/Sub runs SERVER-side in the Heroku relay, which subscribes to the
 * Demo_Event__e firehose and fans it out on an isolated `/ws/monitor`
 * broadcast channel (separate from the consumer phones). The globe just opens
 * that WebSocket and folds each event through the SAME visitorReducer.
 *
 * Relay messages:
 *   { type: 'hello', channel: 'monitor' }
 *   { type: 'demo_event', payload: { Type__c, Session_Id__c, Payload_Json__c, Demo_Session_Id__c } }
 *   { type: 'stage_changed', newState }
 */
import { useEffect, useRef, useState } from 'react';
import type { Visitor } from './visitors';
import {
  applyPlatformEvent,
  snapshot,
  SESSION_TTL_MS,
  type VisitorMap,
  type PlatformEventPayload,
} from './visitorReducer';

export type FeedStatus = 'connecting' | 'connected' | 'disconnected' | 'error';

export interface DemoFeed {
  visitors: Visitor[];
  stage: string;
  status: FeedStatus;
}

// Relay WebSocket URL. The bundle runs on a different origin than the relay, so
// this is an ABSOLUTE wss:// URL, not origin-relative. Overridable at build via
// VITE_RELAY_WS_URL; defaults to the known prod relay /ws/monitor channel.
const RELAY_WS_URL =
  (import.meta.env?.VITE_RELAY_WS_URL as string | undefined) ??
  'wss://skywave-app-bb0e8666933b.herokuapp.com/ws/monitor';

// Reconnect backoff (mirrors the consumer site): start 1s, double to 30s cap.
const RECONNECT_MIN_MS = 1000;
const RECONNECT_MAX_MS = 30000;

// Lifecycle logging — filter the console by `[globe-feed]` to see only this.
// Flip VERBOSE to false to quiet the per-event noise once it works.
const LOG = '[globe-feed]';
const VERBOSE = true;
const log = (...a: unknown[]) => console.log(LOG, ...a);
const warn = (...a: unknown[]) => console.warn(LOG, ...a);

interface MonitorMessage {
  type?: string;
  channel?: string;
  payload?: PlatformEventPayload;
  newState?: string;
  demoSessionId?: string;
}

export function useDemoFeed(activeDemoSessionId?: string | null): DemoFeed {
  const [visitors, setVisitors] = useState<Visitor[]>([]);
  const [stage, setStage] = useState<string>('idle');
  const [status, setStatus] = useState<FeedStatus>('connecting');

  // Mutable visitor map keyed by sessionId; flushed to state on each event.
  const bySession = useRef<VisitorMap>(new Map());

  useEffect(() => {
    log('effect mount — relay URL:', RELAY_WS_URL, '| activeSession:', activeDemoSessionId ?? '(none)');

    let unloaded = false;
    let ws: WebSocket | null = null;
    let reconnectDelay = RECONNECT_MIN_MS;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;

    const handleEvent = (payload: PlatformEventPayload) => {
      // Scope to the active demo session if one is set (the reducer also
      // filters, but logging the drop here is clearer).
      if (
        activeDemoSessionId &&
        payload.Demo_Session_Id__c &&
        payload.Demo_Session_Id__c !== activeDemoSessionId
      ) {
        if (VERBOSE) log('event ignored — different demoSession:', payload.Demo_Session_Id__c);
        return;
      }
      const now = Date.now();
      const changed = applyPlatformEvent(bySession.current, payload, now, activeDemoSessionId);
      if (VERBOSE) {
        log('event applied:', payload.Type__c, '| session:', payload.Session_Id__c,
          '| changed:', changed, '| visitorMap size:', bySession.current.size);
      }
      if (changed) setVisitors(snapshot(bySession.current, now, SESSION_TTL_MS));
    };

    const connect = () => {
      if (unloaded) return;
      log('opening WebSocket…');
      setStatus('connecting');
      try {
        ws = new WebSocket(RELAY_WS_URL);
      } catch (err) {
        // A CSP connect-src violation throws synchronously here — surface it.
        warn('WebSocket constructor threw (CSP block?):', err);
        setStatus('error');
        scheduleReconnect();
        return;
      }

      ws.addEventListener('open', () => {
        log('WebSocket OPEN');
        reconnectDelay = RECONNECT_MIN_MS; // reset backoff on success
        if (!unloaded) setStatus('connected');
      });

      ws.addEventListener('message', m => {
        let msg: MonitorMessage;
        try {
          msg = JSON.parse(m.data as string);
        } catch {
          warn('non-JSON message:', m.data);
          return;
        }
        if (VERBOSE) log('msg:', msg.type, msg);
        switch (msg.type) {
          case 'hello':
            log('relay hello — channel:', msg.channel);
            break;
          case 'demo_event':
            if (msg.payload) handleEvent(msg.payload);
            else warn('demo_event without payload:', msg);
            break;
          case 'stage_changed':
            if (
              activeDemoSessionId &&
              msg.demoSessionId &&
              msg.demoSessionId !== activeDemoSessionId
            ) {
              break;
            }
            if (msg.newState) {
              log('stage →', msg.newState);
              setStage(msg.newState);
            }
            break;
          default:
            if (VERBOSE) warn('unknown message type:', msg.type);
        }
      });

      ws.addEventListener('error', e => {
        // The browser hides CSP/handshake detail here for security; the close
        // event's code is usually more informative. Log both.
        warn('WebSocket error event:', e);
      });

      ws.addEventListener('close', e => {
        log('WebSocket CLOSE — code:', e.code, '| reason:', e.reason || '(none)', '| wasClean:', e.wasClean);
        if (!unloaded) {
          setStatus('disconnected');
          scheduleReconnect();
        }
      });
    };

    const scheduleReconnect = () => {
      if (unloaded || reconnectTimer) return;
      const delay = reconnectDelay;
      reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
      log(`reconnecting in ${delay}ms`);
      reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        connect();
      }, delay);
    };

    connect();

    return () => {
      log('effect cleanup — closing WebSocket');
      unloaded = true;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      try {
        ws?.close();
      } catch {
        // ignore teardown races
      }
    };
  }, [activeDemoSessionId]);

  return { visitors, stage, status };
}
