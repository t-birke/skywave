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

export function useDemoFeed(activeDemoSessionId?: string | null): DemoFeed {
  const [visitors, setVisitors] = useState<Visitor[]>([]);
  const [stage, setStage] = useState<string>('idle');
  const [status, setStatus] = useState<FeedStatus>('connecting');

  // Mutable visitor map keyed by sessionId; flushed to state on each event.
  const bySession = useRef<VisitorMap>(new Map());

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

    const handleEvent = (payload: PlatformEventPayload) => {
      const now = Date.now();
      if (applyPlatformEvent(bySession.current, payload, now, activeDemoSessionId)) {
        setVisitors(snapshot(bySession.current, now, SESSION_TTL_MS));
      }
    };

    cometd.handshake(hs => {
      if (hs.successful) {
        setStatus('connected');
        cometd.subscribe(EVENT_CHANNEL, msg => {
          const data = msg.data as { payload?: PlatformEventPayload };
          if (data?.payload) handleEvent(data.payload);
        });
        cometd.subscribe(STATE_CHANNEL, msg => {
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
