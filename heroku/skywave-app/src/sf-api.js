// Single chokepoint for every Salesforce HTTP call from the relay.
//
// Shape:
//   apexInvoke(method, apexPath, body?) -> data           // /services/apexrest/...
//   apexInvocable(name, inputs)         -> Apex invocable // composite/sobjects/Action
//   query(soql)                         -> records[]
//   forwardToApex(method, apexPath, req, res, label)      // existing legacy passthrough
//
// HTTPS keep-alive: shared agent so every call to instanceUrl reuses one TLS
// session. Eliminates ~100ms of TCP+TLS handshake per request after the first.
//
// All routes go through here so we never construct SOQL inline at the route
// layer — the proxy is a thin shaper, not a query builder.

import axios from 'axios';
import https from 'https';
import { getSalesforceToken } from './sf-auth.js';

const keepAliveAgent = new https.Agent({
    keepAlive: true,
    keepAliveMsecs: 30_000,
    maxSockets: 32,
    maxFreeSockets: 8
});

async function authedClient() {
    const { accessToken, instanceUrl } = await getSalesforceToken();
    return {
        instanceUrl,
        config: {
            headers: {
                Authorization: `Bearer ${accessToken}`,
                'Content-Type': 'application/json'
            },
            httpsAgent: keepAliveAgent,
            timeout: 15_000
        }
    };
}

export async function apexInvoke(method, apexPath, body) {
    const { instanceUrl, config } = await authedClient();
    const url = `${instanceUrl}/services/apexrest${apexPath}`;
    const res = method === 'GET'
        ? await axios.get(url, config)
        : await axios.post(url, body || {}, config);
    return res.data;
}

export async function query(soql) {
    const { instanceUrl, config } = await authedClient();
    const url = `${instanceUrl}/services/data/v62.0/query?q=${encodeURIComponent(soql)}`;
    const res = await axios.get(url, config);
    return res.data.records || [];
}

export async function apexInvocable(actionName, inputs) {
    const { instanceUrl, config } = await authedClient();
    const url = `${instanceUrl}/services/data/v62.0/actions/custom/apex/${actionName}`;
    const res = await axios.post(url, { inputs }, config);
    return res.data;
}

// Stream a Salesforce-hosted resource (e.g. a Shepherd file download) through
// the relay using the cached JWT access token. Pipes upstream bytes directly
// to `res` so we don't buffer in Node memory. Forwards Content-Type /
// Content-Length when available; sets Cache-Control: private, max-age=300 so
// the browser caches the image for the demo's lifetime.
export async function pipeFromInstance(sfPath, res) {
    const { instanceUrl, config } = await authedClient();
    const url = `${instanceUrl}${sfPath}`;
    const upstream = await axios.get(url, {
        ...config,
        responseType: 'stream'
    });
    const ct = upstream.headers['content-type'];
    const cl = upstream.headers['content-length'];
    if (ct) res.setHeader('Content-Type', ct);
    if (cl) res.setHeader('Content-Length', cl);
    res.setHeader('Cache-Control', 'private, max-age=300');
    upstream.data.pipe(res);
}

// Legacy passthrough used by the phone-demo endpoints. Kept for backwards
// compat — new website routes call apexInvoke / apexInvocable / query
// directly so the route handler can shape the response and audit-log the
// outcome.
export async function forwardToApex(method, apexPath, body, res, label) {
    try {
        const data = await apexInvoke(method, apexPath, body);
        res.json(data);
    } catch (err) {
        const status = err.response?.status ?? 500;
        const data = err.response?.data ?? { error: err.message };
        console.error(`${label} failed`, status, data);
        res.status(status).json(data);
    }
}
