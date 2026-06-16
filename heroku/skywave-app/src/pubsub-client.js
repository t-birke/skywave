// Pub/Sub API subscriber(s) over gRPC. A closure FACTORY so each topic gets
// fully independent state (schema cache, reconnect timer, status surface) —
// two subscribers can't interfere. The consumer path subscribes to
// Demo_State_Change__e; the globe monitor path subscribes to the Demo_Event__e
// visitor firehose on a SEPARATE instance (see pubsub-monitor.js). Phones never
// touch Demo_Event__e.
//
// Each event is decoded from Avro and handed to onEvent(mapEvent(decoded, replayId)).

import { fileURLToPath } from 'url';
import path from 'path';
import grpc from '@grpc/grpc-js';
import protoLoader from '@grpc/proto-loader';
import avro from 'avro-js';
import { getSalesforceToken } from './sf-auth.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PROTO_PATH = path.resolve(__dirname, '../proto/pubsub_api.proto');
const PUBSUB_ENDPOINT = 'api.pubsub.salesforce.com:7443';
const BATCH_SIZE = 10;
const RECONNECT_BASE_MS = 5_000;
const RECONNECT_MAX_MS = 5 * 60_000;  // cap at 5 min

/**
 * Build an independent Pub/Sub subscriber for one topic.
 *
 * @param {object}   opts
 * @param {string}   opts.topic     e.g. '/event/Demo_State_Change__e'
 * @param {function} opts.mapEvent  (decodedAvro, replayIdBase64) => payload handed to onEvent
 * @returns {{ start: (onEvent:function)=>Promise, getStatus: ()=>object }}
 */
export function createPubSubSubscriber({ topic, mapEvent }) {
    // Per-instance state — lives in this closure, NOT module scope, so each
    // subscriber's reconnect/schema/status is isolated from every other.
    const schemaCache = new Map(); // schemaId -> avro.Type

    // Reconnect state. Without the single-timer dedupe, both `error` and `end`
    // would each schedule a reconnect and we'd get an exponential connection
    // storm that OOMs the dyno (seen May 2026 when the integration user lost a
    // permset and Pub/Sub auth started failing instantly).
    let reconnectTimer = null;
    let reconnectAttempts = 0;

    // Status surface for /api/preflight. `subscribedAt` is set the first time
    // the initial subscribe write succeeds; `lastReplayId` updates on every
    // event; `lastDataAt` is the wall-clock of the most recent decoded event.
    let subscribedAt = null;
    let lastReplayId = null;
    let lastDataAt = null;
    let lastError = null;

    function getStatus() {
        // "connected" = subscribed at least once AND no pending reconnect timer.
        // Both `error` and `end` schedule a reconnect, so a non-null timer means
        // the stream is currently down.
        const connected = subscribedAt != null && reconnectTimer == null;
        return {
            connected,
            topic,
            subscribedAt,
            reconnectAttempts,
            reconnectScheduled: reconnectTimer != null,
            lastReplayId,
            lastDataAt,
            lastError
        };
    }

    function scheduleReconnect(onEvent, reason) {
        if (reconnectTimer) return; // already scheduled — let it run
        const backoff = Math.min(
            RECONNECT_BASE_MS * Math.pow(2, reconnectAttempts),
            RECONNECT_MAX_MS
        );
        reconnectAttempts += 1;
        console.warn(`Pub/Sub[${topic}] reconnect #${reconnectAttempts} in ${backoff}ms (${reason})`);
        reconnectTimer = setTimeout(() => {
            reconnectTimer = null;
            start(onEvent).catch((err) => {
                console.error(`Pub/Sub[${topic}] reconnect failed:`, err.message);
                scheduleReconnect(onEvent, 'reconnect-error');
            });
        }, backoff);
    }

    async function start(onEvent) {
        const packageDefinition = protoLoader.loadSync(PROTO_PATH, {
            keepCase: true,
            longs: String,
            enums: String,
            defaults: true,
            oneofs: true
        });
        const proto = grpc.loadPackageDefinition(packageDefinition).eventbus.v1;

        const { accessToken, instanceUrl } = await getSalesforceToken();
        const tenantId = await fetchTenantId(instanceUrl, accessToken);

        const metadata = new grpc.Metadata();
        metadata.add('accesstoken', accessToken);
        metadata.add('instanceurl', instanceUrl);
        metadata.add('tenantid', tenantId);

        const credentials = grpc.credentials.combineChannelCredentials(
            grpc.credentials.createSsl(),
            grpc.credentials.createFromMetadataGenerator((_, callback) => callback(null, metadata))
        );

        const client = new proto.PubSub(PUBSUB_ENDPOINT, credentials);
        const stream = client.Subscribe();

        stream.on('data', async (msg) => {
            for (const ev of msg.events ?? []) {
                try {
                    const schema = await getSchema(client, ev.event.schema_id, schemaCache);
                    const decoded = schema.fromBuffer(ev.event.payload);
                    const replayId = ev.replay_id?.toString('base64');
                    lastReplayId = replayId;
                    lastDataAt = new Date().toISOString();
                    onEvent(mapEvent(decoded, replayId));
                } catch (err) {
                    console.error(`Pub/Sub[${topic}] event decode failed`, err);
                }
            }
            stream.write({ topic_name: topic, num_requested: BATCH_SIZE });
        });

        // Both `error` and `end` fire when the stream dies. We only want ONE
        // reconnect scheduled at a time — scheduleReconnect dedupes.
        stream.on('error', (err) => {
            console.error(`Pub/Sub[${topic}] stream error:`, err.code, err.details ?? err.message);
            lastError = { code: err.code, message: err.details ?? err.message, at: new Date().toISOString() };
            scheduleReconnect(onEvent, `error: ${err.code}`);
        });
        stream.on('end', () => {
            scheduleReconnect(onEvent, 'stream ended');
        });

        // Initial subscribe — replay_preset LATEST = only new events.
        stream.write({
            topic_name: topic,
            num_requested: BATCH_SIZE,
            replay_preset: 'LATEST'
        });

        reconnectAttempts = 0;
        subscribedAt = new Date().toISOString();
        lastError = null;
        console.log(`subscribed to ${topic}`);
        return stream;
    }

    return { start, getStatus };
}

// ── Consumer-path subscriber: Demo_State_Change__e ──────────────────────────
// Preserved as the original named exports so server.js + preflight.js need no
// changes. Carries stage transitions (New_State__c) + client actions
// (Client_Action__c, e.g. profile_created targeted at a deviceId).
const consumer = createPubSubSubscriber({
    topic: '/event/Demo_State_Change__e',
    mapEvent: (decoded, replayId) => ({
        newState: unwrap(decoded.New_State__c),
        clientAction: unwrap(decoded.Client_Action__c),
        demoSessionId: unwrap(decoded.Demo_Session_Id__c),
        targetSessionId: unwrap(decoded.Target_Session_Id__c),
        replayId
    })
});

export const startPubSubSubscriber = consumer.start;
export const getSubscriberStatus = consumer.getStatus;

async function fetchTenantId(instanceUrl, accessToken) {
    const { default: axios } = await import('axios');
    const { data } = await axios.get(`${instanceUrl}/services/oauth2/userinfo`, {
        headers: { Authorization: `Bearer ${accessToken}` }
    });
    return data.organization_id;
}

// Avro encodes optional/union fields as { typeName: value } or null.
// Salesforce nillable fields come back as { string: "survey" } or null.
export function unwrap(v) {
    if (v == null) return null;
    if (typeof v === 'object') {
        const keys = Object.keys(v);
        if (keys.length === 1) return v[keys[0]];
    }
    return v;
}

function getSchema(client, schemaId, cache) {
    if (cache.has(schemaId)) return Promise.resolve(cache.get(schemaId));
    return new Promise((resolve, reject) => {
        client.GetSchema({ schema_id: schemaId }, (err, res) => {
            if (err) return reject(err);
            const type = avro.parse(res.schema_json);
            cache.set(schemaId, type);
            resolve(type);
        });
    });
}
