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

// Phones POST here; we forward to Apex with the integration user's token.
// Lets the phone stay anonymous to Salesforce — the relay holds the JWT.
app.post('/api/session/start', async (req, res) => {
    try {
        const { accessToken, instanceUrl } = await getSalesforceToken();
        const sf = await axios.post(
            `${instanceUrl}/services/apexrest/skywave/session/start`,
            req.body || {},
            { headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' } }
        );
        res.json(sf.data);
    } catch (err) {
        const status = err.response?.status ?? 500;
        const data = err.response?.data ?? { error: err.message };
        console.error('session/start failed', status, data);
        res.status(status).json(data);
    }
});

const server = createServer(app);

// WebSocket upgrade handling — only accept paths matching /ws/<sessionId>
const wss = new WebSocketServer({ noServer: true });
server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://placeholder');
    const match = url.pathname.match(/^\/ws\/([0-9a-fA-F-]{8,64})$/);
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
