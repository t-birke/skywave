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
import type { Visitor } from './visitors';
import {
  applyPlatformEvent,
  snapshot,
  SESSION_TTL_MS,
  type VisitorMap,
  type PlatformEventPayload,
} from './visitorReducer';

const EVENT_CHANNEL = '/event/Demo_Event__e';
const STATE_CHANNEL = '/event/Demo_State_Change__e';

export type FeedStatus = 'connecting' | 'connected' | 'disconnected' | 'error';

export interface DemoFeed {
  visitors: Visitor[];
  stage: string;
  status: FeedStatus;
}

// Lifecycle logging — filter the console by `[globe-feed]` to see only this.
// Flip VERBOSE to false to quiet the per-event/heartbeat noise once it works.
const LOG = '[globe-feed]';
const VERBOSE = true;
const log = (...a: unknown[]) => console.log(LOG, ...a);
const warn = (...a: unknown[]) => console.warn(LOG, ...a);

export function useDemoFeed(activeDemoSessionId?: string | null): DemoFeed {
  const [visitors, setVisitors] = useState<Visitor[]>([]);
  const [stage, setStage] = useState<string>('idle');
  const [status, setStatus] = useState<FeedStatus>('connecting');

  // Mutable visitor map keyed by sessionId; flushed to state on each event.
  const bySession = useRef<VisitorMap>(new Map());

  useEffect(() => {
    const cometdUrl = `${window.location.origin}/cometd/60.0/`;
    log('effect mount — origin:', window.location.origin, '| activeSession:', activeDemoSessionId ?? '(none)');
    log('CometD URL:', cometdUrl);

    const cometd = new CometD();
    const replay = new ReplayExtension();
    replay.setReplay({ [EVENT_CHANNEL]: -1, [STATE_CHANNEL]: -1 });
    cometd.registerExtension('sfdc-replay', replay);

    cometd.configure({
      // Same-origin in-org; in local dev the Vite proxy forwards to the org.
      url: cometdUrl,
      appendMessageTypeToURL: false,
      // 'debug' surfaces the raw Bayeux traffic (handshake/connect/subscribe
      // requests + responses) in the console — invaluable when nothing fires.
      logLevel: 'debug',
    });
    // Salesforce CometD is long-polling only — and the Vite proxy doesn't
    // tunnel WebSockets to the org. Drop the websocket transport so the
    // client doesn't pick `ws://localhost/...` and hang before handshake.
    cometd.unregisterTransport('websocket');
    log('transports after unregister(websocket):', cometd.getTransportTypes());

    let unloaded = false;

    const handleEvent = (payload: PlatformEventPayload) => {
      const now = Date.now();
      const changed = applyPlatformEvent(bySession.current, payload, now, activeDemoSessionId);
      if (VERBOSE) {
        log('event applied:', payload.Type__c, '| session:', payload.Session_Id__c,
          '| demoSession:', payload.Demo_Session_Id__c ?? '(none)',
          '| changed:', changed, '| visitorMap size:', bySession.current.size);
      }
      if (changed) {
        setVisitors(snapshot(bySession.current, now, SESSION_TTL_MS));
      }
    };

    // ---- Meta-channel listeners (register BEFORE handshake) ----------------
    // The catch-all: ANY failed Bayeux message (handshake/connect/subscribe)
    // lands here. If nothing else logs, this is usually where the truth is.
    cometd.addListener('/meta/unsuccessful', m => {
      warn('/meta/unsuccessful:', m);
    });
    cometd.addListener('/meta/handshake', m => {
      log('/meta/handshake:', m.successful ? 'OK' : 'FAILED', m);
    });
    cometd.addListener('/meta/subscribe', m => {
      log('/meta/subscribe:', m.subscription, m.successful ? 'OK' : 'FAILED', m);
    });
    cometd.addListener('/meta/connect', m => {
      if (VERBOSE) log('/meta/connect:', m.successful ? 'OK' : 'FAILED');
      if (!unloaded) setStatus(m.successful ? 'connected' : 'disconnected');
    });

    log('calling handshake()…');
    cometd.handshake(hs => {
      log('handshake callback — successful:', hs.successful, '| clientId:', hs.clientId ?? '(none)');
      if (hs.successful) {
        setStatus('connected');
        log('subscribing to', EVENT_CHANNEL, 'and', STATE_CHANNEL);
        cometd.subscribe(EVENT_CHANNEL, msg => {
          if (VERBOSE) log('raw msg on', EVENT_CHANNEL, msg.data);
          const data = msg.data as { payload?: PlatformEventPayload };
          if (data?.payload) handleEvent(data.payload);
          else warn('event message had no .payload:', msg.data);
        });
        cometd.subscribe(STATE_CHANNEL, msg => {
          if (VERBOSE) log('raw msg on', STATE_CHANNEL, msg.data);
          const data = msg.data as {
            payload?: { Demo_Session_Id__c?: string; New_State__c?: string };
          };
          const p = data?.payload;
          if (!p) return;
          if (
            activeDemoSessionId &&
            p.Demo_Session_Id__c &&
            p.Demo_Session_Id__c !== activeDemoSessionId
          ) {
            log('state change ignored — different demoSession:', p.Demo_Session_Id__c);
            return;
          }
          if (p.New_State__c) {
            log('stage →', p.New_State__c);
            setStage(p.New_State__c as string);
          }
        });
      } else if (!unloaded) {
        // Handshake denied — surface the failureReason the org returns in ext.
        warn('handshake DENIED:', JSON.stringify(hs));
        setStatus('error');
      }
    });

    return () => {
      log('effect cleanup — disconnecting');
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
