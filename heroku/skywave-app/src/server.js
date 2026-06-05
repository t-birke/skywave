// skywave-app: static consumer site + WebSocket relay subscribed to si.
// One Node process, one Heroku dyno.

import express from 'express';
import axios from 'axios';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import { fileURLToPath } from 'url';
import path from 'path';
import { startPubSubSubscriber } from './pubsub-client.js';
import { register, fanOut, activeCount } from './ws-fanout.js';
import { getSalesforceToken } from './sf-auth.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 3000;

const app = express();
app.use(express.json());
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

// Phones call the relay; the relay forwards to Apex with the integration
// user's JWT-bearer token. Phones stay anonymous to Salesforce.
async function forwardToApex(method, apexPath, body, res, label) {
    try {
        const { accessToken, instanceUrl } = await getSalesforceToken();
        const url = `${instanceUrl}/services/apexrest${apexPath}`;
        const cfg = { headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' } };
        const sf = method === 'GET'
            ? await axios.get(url, cfg)
            : await axios.post(url, body || {}, cfg);
        res.json(sf.data);
    } catch (err) {
        const status = err.response?.status ?? 500;
        const data = err.response?.data ?? { error: err.message };
        console.error(`${label} failed`, status, data);
        res.status(status).json(data);
    }
}

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
startPubSubSubscriber((ev) => {
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

server.listen(PORT, () => {
    console.log(`skywave-app listening on :${PORT}`);
});
