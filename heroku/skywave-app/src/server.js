// skywave-app: static consumer site + WebSocket relay subscribed to si.
// One Node process, one Heroku dyno.

import express from 'express';
import cookieParser from 'cookie-parser';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import { fileURLToPath } from 'url';
import path from 'path';
import { startPubSubSubscriber } from './pubsub-client.js';
import { register, fanOut, activeCount, startHeartbeat } from './ws-fanout.js';
import { forwardToApex } from './sf-api.js';
import { buildWebsiteRouter } from './website-routes.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 3000;

const app = express();
app.set('trust proxy', 1);  // Heroku terminates TLS one hop in front
app.use(express.json({ limit: '256kb' }));
app.use(cookieParser());
app.use(express.static(path.resolve(__dirname, '../public')));

app.get('/healthz', (_, res) => {
    res.json({ ok: true, activeWs: activeCount() });
});

// Consumer-site config. The SDK is only loaded when SF_INTERACTIONS_SDK_URL
// is set on Heroku — that gets populated once the Web Connector is created
// in si Setup and we know the appId. Until then the consumer site runs
// without the SDK and Apex mints the sessionId.
//
// The four ESW_* values configure the Enhanced Messaging for Web v2 widget.
// They come from the org after the EmbeddedServiceConfig is published; the
// `siteUrl` value is the one returned by the scrt2 config endpoint, NOT the
// path on the underlying CustomSite (scrt2 normalizes vforce suffixes off).
app.get('/api/config', (_, res) => {
    res.json({
        interactionsSdkUrl: process.env.SF_INTERACTIONS_SDK_URL || null,
        // ipinfo.io token for client-side IP geolocation. Free-tier token,
        // exposed to the browser by design (ipinfo scopes it to a domain),
        // but served from a Heroku Config Var so it stays out of the repo
        // per SECRETS.md. Geolocation is skipped if unset.
        ipinfoToken: process.env.IPINFO_TOKEN || null,
        esw: {
            orgId:    process.env.SF_ESW_ORG_ID    || null,
            escName:  process.env.SF_ESW_ESC_NAME  || null,
            siteUrl:  process.env.SF_ESW_SITE_URL  || null,
            scrt2Url: process.env.SF_ESW_SCRT2_URL || null
        }
    });
});

// Phones call the relay; the relay forwards to Apex via the shared sfApi
// module (keep-alive HTTPS, JWT-bearer cached). Phones stay anonymous to
// Salesforce. forwardToApex is the legacy helper kept for the phone-demo
// surface; new website routes use apexInvoke / query / apexInvocable
// directly so handlers can shape responses and audit-log outcomes.
//
// Hardened website surface — proof cookie, helmet, CORS, rate limits,
// audit log, zod validation. Mounted under /api/website/* so the legacy
// /api/* phone-demo routes are untouched.
const allowedOrigin = process.env.SKYWAVE_PUBLIC_ORIGIN || 'http://localhost:3000';
app.use('/api/website', buildWebsiteRouter({ allowedOrigin }));

app.post('/api/session/start',     (req, res) => forwardToApex('POST', '/skywave/session/start',    req.body, res, 'session/start'));
// Note: /api/session/identify is NOT a Heroku route — phones POST
// directly to the skywave_api Force.com Site:
//   https://<orghost>.my.salesforce-sites.com/skywave/services/apexrest/skywave/session/identify
// That endpoint publishes a Skywave_Identify_Session__e PE and a
// trigger handles the MessagingSession update in System Mode. Phase 6
// backlog: rewrite the rest of the endpoints (session/start, survey/answer,
// race/tick, profile) to the same pattern to remove the Heroku-throughput
// bottleneck for 500-phone scale.
app.get('/api/survey/schema',   (_,   res) => forwardToApex('GET',  '/skywave/survey/schema',  null,     res, 'survey/schema'));
app.post('/api/survey/answer',  (req, res) => forwardToApex('POST', '/skywave/survey/answer',  req.body, res, 'survey/answer'));
app.post('/api/race/tick',      (req, res) => forwardToApex('POST', '/skywave/race/tick',      req.body, res, 'race/tick'));
app.post('/api/profile',        (req, res) => forwardToApex('POST', '/skywave/profile',        req.body, res, 'profile'));

const server = createServer(app);

// WebSocket upgrade handling — only accept paths matching /ws/<sessionId>
const wss = new WebSocketServer({ noServer: true });
server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://placeholder');
    // SDK anonymousIds are short hex (e.g. 1db57f8b6d54a786); UUIDs are dashed
    // hex; both fit. Allow alphanumerics + dashes + underscores, 8–64 chars.
    const match = url.pathname.match(/^\/ws\/([A-Za-z0-9_-]{8,64})$/);
    if (!match) {
        socket.destroy();
        return;
    }
    const sessionId = match[1];
    wss.handleUpgrade(req, socket, head, (ws) => {
        register(sessionId, ws);
        ws.send(JSON.stringify({ type: 'hello', sessionId }));
        console.log(`ws connected sessionId=${sessionId} active=${activeCount()}`);
    });
});

// Pub/Sub subscriber → WS fan-out
//
// One PE channel (Demo_State_Change__e) carries two kinds of payload:
//   - stage transitions (New_State__c set) → broadcast or targeted phone
//   - client actions (Client_Action__c set, e.g. profile_created) →
//     targeted at the visitor's deviceId (Target_Session_Id__c).
//
// Splitting via Client_Action__c instead of subscribing to Demo_Event__e
// avoids hauling the entire monitor firehose (survey/booking/seat events)
// through the relay just to hand off the rare profile_created push.
startPubSubSubscriber((ev) => {
    if (ev.clientAction) {
        console.log(`client_action -> ${ev.clientAction} (target=${ev.targetSessionId || '*'})`);
        fanOut({
            type: 'client_action',
            action: ev.clientAction,
            demoSessionId: ev.demoSessionId,
            replayId: ev.replayId
        }, ev.targetSessionId);
        return;
    }
    console.log(`stage_changed -> ${ev.newState} (target=${ev.targetSessionId || '*'})`);
    fanOut({
        type: 'stage_changed',
        newState: ev.newState,
        demoSessionId: ev.demoSessionId,
        replayId: ev.replayId
    }, ev.targetSessionId);
}).catch((err) => {
    console.error('Pub/Sub subscribe failed at startup:', err);
});

// Heroku's router kills idle WebSockets after 55s (H15). Send a ping
// every 30s to keep them alive; sockets that miss a pong get terminated.
startHeartbeat(30000);

server.listen(PORT, () => {
    console.log(`skywave-app listening on :${PORT}`);
});
