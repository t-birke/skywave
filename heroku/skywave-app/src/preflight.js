// /api/preflight — relay self-report for the Skywave Demo Preflight tab.
//
// One JSON document, one Apex callout. Surfaces things only the dyno can
// see: the resolved ESW_*/SDK config (so the org can diff against its own
// published values), the Pub/Sub subscriber state, dyno uptime + a
// cycleSoon flag (Heroku cycles dynos ~daily and exposes no schedule API),
// the live WebSocket count, and an optional loopback push probe (?e2e=1).
//
// Guarded by a shared-secret header so the public internet can't enumerate
// relay internals. Key comes from process.env.PREFLIGHT_KEY (Heroku Config
// Var); Apex sends it via the Skywave_Preflight__mdt record.

import { getSubscriberStatus } from './pubsub-client.js';
import { register, fanOut, activeCount } from './ws-fanout.js';

const DYNO_CYCLE_WARN_HOURS = 22;  // Heroku cycles dynos ~24h apart

function requireKey(req, res) {
    const expected = process.env.PREFLIGHT_KEY;
    if (!expected) {
        res.status(503).json({ error: 'PREFLIGHT_KEY not configured on dyno' });
        return false;
    }
    const got = req.get('x-preflight-key');
    if (got !== expected) {
        res.status(401).json({ error: 'bad x-preflight-key' });
        return false;
    }
    return true;
}

function configReport() {
    // Mirror the env reads in /api/config so the diff is apples-to-apples.
    return {
        publicOrigin: process.env.SKYWAVE_PUBLIC_ORIGIN || null,
        interactionsSdkUrl: process.env.SF_INTERACTIONS_SDK_URL || null,
        ipinfoToken: process.env.IPINFO_TOKEN ? 'set' : null,  // never leak the token itself
        esw: {
            orgId:    process.env.SF_ESW_ORG_ID    || null,
            escName:  process.env.SF_ESW_ESC_NAME  || null,
            siteUrl:  process.env.SF_ESW_SITE_URL  || null,
            scrt2Url: process.env.SF_ESW_SCRT2_URL || null
        }
    };
}

function dynoReport() {
    const uptimeSec = Math.floor(process.uptime());
    const uptimeHours = uptimeSec / 3600;
    return {
        uptimeSec,
        bootedAt: new Date(Date.now() - uptimeSec * 1000).toISOString(),
        cycleSoon: uptimeHours >= DYNO_CYCLE_WARN_HOURS,
        cycleWarnHours: DYNO_CYCLE_WARN_HOURS,
        nodeVersion: process.version,
        memoryMb: Math.round(process.memoryUsage().rss / 1024 / 1024)
    };
}

// Loopback probe: register a fake socket under a synthetic id, fanOut to
// that id, assert the message arrives, unregister. Exercises the same
// in-memory fan-out path the real subscriber drives, with no network hop
// and no risk of leaving stale state in the sockets map.
async function loopbackProbe() {
    const t0 = Date.now();
    const sid = `__preflight_${t0}_${Math.random().toString(36).slice(2, 8)}`;

    let received = null;
    const handlers = {};
    const fakeWs = {
        readyState: 1,           // matches ws.OPEN (1) used by fanOut
        OPEN: 1,
        isAlive: true,
        send: (msg) => { received = msg; },
        on: (ev, fn) => { handlers[ev] = fn; },
        terminate: () => {}
    };

    register(sid, fakeWs);
    try {
        const probe = { type: 'preflight_probe', nonce: sid };
        fanOut(probe, sid);
        if (received == null) {
            return { ok: false, reason: 'fanOut did not deliver to registered sid' };
        }
        const got = JSON.parse(received);
        if (got.nonce !== sid) {
            return { ok: false, reason: 'payload nonce mismatch' };
        }
        return { ok: true, deliveredMs: Date.now() - t0 };
    } finally {
        // Simulate close so register's close-handler removes the entry.
        if (handlers.close) handlers.close();
    }
}

export function buildPreflightRouter(express) {
    const router = express.Router();

    router.get('/', async (req, res) => {
        if (!requireKey(req, res)) return;

        const report = {
            ok: true,
            generatedAt: new Date().toISOString(),
            config: configReport(),
            pubsub: getSubscriberStatus(),
            dyno: dynoReport(),
            ws: { activeCount: activeCount() }
        };

        if (req.query.e2e === '1') {
            try {
                report.roundtrip = await loopbackProbe();
            } catch (err) {
                report.roundtrip = { ok: false, reason: err.message };
            }
            if (!report.roundtrip.ok) report.ok = false;
        }

        res.json(report);
    });

    return router;
}
