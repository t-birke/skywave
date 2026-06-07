// skywave_proof — HMAC-signed httpOnly cookie that seals the WebSDK deviceId
// (or a synthetic UUID when WebSDK is absent).
//
// Threat model:
//   - JS *can* read the WebSDK cookie (the SDK has to). An XSS that exfiltrates
//     it cannot act on it because the matching skywave_proof is httpOnly and
//     unreachable from JS.
//   - An attacker who scrapes a deviceId from elsewhere (Data Cloud export,
//     log spill) cannot mint a valid signature without our HMAC key.
//   - Cookie is bound to deviceId only, not IP/UA, because demo visitors move
//     between phone wifi/LTE during a session.
//
// Format: base64url(deviceId).base64url(hmac_sha256(deviceId, key))
// Versioned with a leading "v1." so we can rotate later without breaking
// in-flight cookies.

import crypto from 'crypto';

const COOKIE_NAME = 'skywave_proof';
const VERSION = 'v1';
const MAX_AGE_SECONDS = 60 * 60 * 24 * 30; // 30 days

function key() {
    const k = process.env.SKYWAVE_PROOF_KEY;
    if (!k || k.length < 32) {
        throw new Error('SKYWAVE_PROOF_KEY missing or too short (need >=32 chars)');
    }
    return k;
}

function b64url(buf) {
    return Buffer.from(buf).toString('base64')
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function b64urlDecode(s) {
    s = s.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    return Buffer.from(s, 'base64').toString('utf8');
}

function sign(deviceId) {
    const h = crypto.createHmac('sha256', key()).update(deviceId).digest();
    return b64url(h);
}

// Constant-time compare of two base64url-encoded strings.
function ctEq(a, b) {
    const ab = Buffer.from(a);
    const bb = Buffer.from(b);
    if (ab.length !== bb.length) return false;
    return crypto.timingSafeEqual(ab, bb);
}

export function mintProof(deviceId) {
    if (!deviceId || typeof deviceId !== 'string') {
        throw new Error('deviceId required');
    }
    return `${VERSION}.${b64url(deviceId)}.${sign(deviceId)}`;
}

// Returns deviceId on valid signature, null otherwise.
export function verifyProof(value) {
    if (!value || typeof value !== 'string') return null;
    const parts = value.split('.');
    if (parts.length !== 3) return null;
    const [v, encDeviceId, sig] = parts;
    if (v !== VERSION) return null;
    let deviceId;
    try { deviceId = b64urlDecode(encDeviceId); } catch { return null; }
    if (!ctEq(sig, sign(deviceId))) return null;
    return deviceId;
}

// deviceId shape: SDK anonymousIds are short hex (e.g. 16 hex chars), or our
// own UUIDs are dashed hex. We allow [A-Za-z0-9_-] 8..64 to cover both, with
// the same regex used by the WebSocket route (server.js).
const DEVICE_ID_RE = /^[A-Za-z0-9_-]{8,64}$/;

export function isValidDeviceIdShape(s) {
    return typeof s === 'string' && DEVICE_ID_RE.test(s);
}

export function newSyntheticDeviceId() {
    // 32 hex chars — distinguishable from SDK shape but still passes the regex.
    return crypto.randomBytes(16).toString('hex');
}

export function setProofCookie(res, deviceId) {
    const value = mintProof(deviceId);
    res.cookie(COOKIE_NAME, value, {
        httpOnly: true,
        secure: process.env.NODE_ENV !== 'development',
        sameSite: 'strict',
        maxAge: MAX_AGE_SECONDS * 1000,
        path: '/'
    });
    return value;
}

export function readProofCookie(req) {
    const raw = req.cookies?.[COOKIE_NAME];
    return verifyProof(raw);
}

// Express middleware: requires a valid proof cookie on the request.
// On success, attaches req.deviceId. On failure, returns 401.
export function requireProof(req, res, next) {
    const deviceId = readProofCookie(req);
    if (!deviceId) {
        return res.status(401).json({ error: 'no_proof' });
    }
    req.deviceId = deviceId;
    next();
}

export const PROOF_COOKIE_NAME = COOKIE_NAME;
