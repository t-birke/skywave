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
                onEvent({
                    newState: unwrap(decoded.New_State__c),
                    demoSessionId: unwrap(decoded.Demo_Session_Id__c),
                    targetSessionId: unwrap(decoded.Target_Session_Id__c),
                    replayId: ev.replay_id?.toString('base64')
                });
            } catch (err) {
                console.error('event decode failed', err);
            }
        }
        stream.write({ topic_name: TOPIC, num_requested: BATCH_SIZE });
    });

    stream.on('error', (err) => {
        console.error('Pub/Sub stream error:', err.code, err.details ?? err.message);
        // Reconnect after a backoff so a token refresh / transient error doesn't kill the dyno
        setTimeout(() => startPubSubSubscriber(onEvent).catch(console.error), 5000);
    });

    stream.on('end', () => {
        console.warn('Pub/Sub stream ended; reconnecting in 5s');
        setTimeout(() => startPubSubSubscriber(onEvent).catch(console.error), 5000);
    });

    // Initial subscribe message — replay_preset 1 = LATEST (only new events)
    stream.write({
        topic_name: TOPIC,
        num_requested: BATCH_SIZE,
        replay_preset: 'LATEST'
    });

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
