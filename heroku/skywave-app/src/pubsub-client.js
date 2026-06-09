// Subscribes to /event/Demo_State_Change__e on si via the Pub/Sub API.
// Each event is decoded from Avro and handed to onEvent({newState,
// demoSessionId, targetSessionId, replayId}).

import { fileURLToPath } from 'url';
import path from 'path';
import grpc from '@grpc/grpc-js';
import protoLoader from '@grpc/proto-loader';
import avro from 'avro-js';
import { getSalesforceToken } from './sf-auth.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PROTO_PATH = path.resolve(__dirname, '../proto/pubsub_api.proto');
const PUBSUB_ENDPOINT = 'api.pubsub.salesforce.com:7443';
const TOPIC = '/event/Demo_State_Change__e';
const BATCH_SIZE = 10;

let schemaCache = new Map(); // schemaId -> avro.Type

// Reconnect state lives at module scope so each retry uses a single
// scheduled timer. Without this, both `error` and `end` events would
// each schedule their own reconnect and we'd get an exponential
// connection storm that exhausts memory (seen May 2026 when the
// integration user lost a permset and Pub/Sub auth started failing
// instantly — hundreds of reconnects per second OOM'd the dyno).
let reconnectTimer = null;
let reconnectAttempts = 0;
const RECONNECT_BASE_MS = 5_000;
const RECONNECT_MAX_MS = 5 * 60_000;  // cap at 5 min

// Status surface for /api/preflight. `subscribedAt` is set the first time the
// initial subscribe write succeeds; `lastReplayId` is updated on every event;
// `lastDataAt` is the wall-clock of the most recent decoded event.
let subscribedAt = null;
let lastReplayId = null;
let lastDataAt = null;
let lastError = null;

export function getSubscriberStatus() {
    // "connected" = we successfully subscribed at least once AND there is no
    // pending reconnect timer. Both `error` and `end` schedule a reconnect, so
    // a non-null timer means the stream is currently down.
    const connected = subscribedAt != null && reconnectTimer == null;
    return {
        connected,
        topic: TOPIC,
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
    console.warn(`Pub/Sub reconnect #${reconnectAttempts} in ${backoff}ms (${reason})`);
    reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        startPubSubSubscriber(onEvent).catch((err) => {
            console.error('Pub/Sub reconnect failed:', err.message);
            scheduleReconnect(onEvent, 'reconnect-error');
        });
    }, backoff);
}

export async function startPubSubSubscriber(onEvent) {
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
                const schema = await getSchema(client, ev.event.schema_id);
                const decoded = schema.fromBuffer(ev.event.payload);
                const replayId = ev.replay_id?.toString('base64');
                lastReplayId = replayId;
                lastDataAt = new Date().toISOString();
                onEvent({
                    newState: unwrap(decoded.New_State__c),
                    clientAction: unwrap(decoded.Client_Action__c),
                    demoSessionId: unwrap(decoded.Demo_Session_Id__c),
                    targetSessionId: unwrap(decoded.Target_Session_Id__c),
                    replayId
                });
            } catch (err) {
                console.error('event decode failed', err);
            }
        }
        stream.write({ topic_name: TOPIC, num_requested: BATCH_SIZE });
    });

    // Both `error` and `end` fire when the stream dies. We only want ONE
    // reconnect attempt scheduled at a time — scheduleReconnect dedupes.
    stream.on('error', (err) => {
        console.error('Pub/Sub stream error:', err.code, err.details ?? err.message);
        lastError = { code: err.code, message: err.details ?? err.message, at: new Date().toISOString() };
        scheduleReconnect(onEvent, `error: ${err.code}`);
    });
    stream.on('end', () => {
        scheduleReconnect(onEvent, 'stream ended');
    });

    // Initial subscribe message — replay_preset 1 = LATEST (only new events)
    stream.write({
        topic_name: TOPIC,
        num_requested: BATCH_SIZE,
        replay_preset: 'LATEST'
    });

    // Connection succeeded; reset the retry counter and stamp subscribedAt.
    reconnectAttempts = 0;
    subscribedAt = new Date().toISOString();
    lastError = null;

    console.log(`subscribed to ${TOPIC}`);
    return stream;
}

async function fetchTenantId(instanceUrl, accessToken) {
    const { default: axios } = await import('axios');
    const { data } = await axios.get(`${instanceUrl}/services/oauth2/userinfo`, {
        headers: { Authorization: `Bearer ${accessToken}` }
    });
    return data.organization_id;
}

// Avro encodes optional/union fields as { typeName: value } or null.
// Salesforce nillable fields come back as { string: "survey" } or null.
function unwrap(v) {
    if (v == null) return null;
    if (typeof v === 'object') {
        const keys = Object.keys(v);
        if (keys.length === 1) return v[keys[0]];
    }
    return v;
}

function getSchema(client, schemaId) {
    if (schemaCache.has(schemaId)) return Promise.resolve(schemaCache.get(schemaId));
    return new Promise((resolve, reject) => {
        client.GetSchema({ schema_id: schemaId }, (err, res) => {
            if (err) return reject(err);
            const type = avro.parse(res.schema_json);
            schemaCache.set(schemaId, type);
            resolve(type);
        });
    });
}
