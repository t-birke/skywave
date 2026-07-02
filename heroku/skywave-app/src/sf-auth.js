// JWT-bearer flow into si. Caches the access token until it nears expiry
// (Salesforce JWT tokens last ~12h by default), then refreshes silently.

import jwt from 'jsonwebtoken';
import axios from 'axios';
import fs from 'fs';
import path from 'path';

const TOKEN_LIFETIME_SECONDS = 60 * 60 * 2; // 2h is plenty; not the SF max

// One cached token per JWT subject. Almost everything authenticates as the
// minimal SF_USERNAME integration user; presenter provisioning authenticates
// as a full-license admin (SF_PROVISION_USERNAME) because creating Users +
// resetting passwords requires "Manage Users", which a Salesforce Integration
// license can never hold. Both subjects are authorized on the SAME connected
// app (isAdminApproved=true + each assigned the app via a permset), so they
// share one private key and differ only in the `sub` claim.
const tokenCache = new Map();

function resolvePrivateKey() {
    // Heroku: SF_JWT_PRIVATE_KEY contains the PEM directly.
    // Local dev: SF_JWT_PRIVATE_KEY_FILE points at secrets/jwt.key relative to repo root.
    if (process.env.SF_JWT_PRIVATE_KEY) return process.env.SF_JWT_PRIVATE_KEY;
    if (process.env.SF_JWT_PRIVATE_KEY_FILE) {
        const repoRoot = path.resolve(process.cwd(), '../..');
        return fs.readFileSync(path.resolve(repoRoot, process.env.SF_JWT_PRIVATE_KEY_FILE), 'utf8');
    }
    return null;
}

// subject defaults to the standard relay integration user (SF_USERNAME). Pass
// an explicit username to mint a token for a different JWT subject (e.g. the
// provisioning admin).
export async function getSalesforceToken(subject) {
    const now = Math.floor(Date.now() / 1000);
    const sub = subject || process.env.SF_USERNAME;

    const cached = tokenCache.get(sub);
    if (cached && cached.expiresAt > now + 60) {
        return cached;
    }

    const { SF_LOGIN_URL, SF_CLIENT_ID } = process.env;
    const SF_JWT_PRIVATE_KEY = resolvePrivateKey();
    for (const [k, v] of Object.entries({ SF_LOGIN_URL, sub, SF_CLIENT_ID, SF_JWT_PRIVATE_KEY })) {
        if (!v) throw new Error(`Missing: ${k === 'sub' ? 'SF_USERNAME/subject' : k}`);
    }

    const claims = {
        iss: SF_CLIENT_ID,
        sub,
        aud: SF_LOGIN_URL,
        exp: now + 180
    };
    const assertion = jwt.sign(claims, SF_JWT_PRIVATE_KEY, { algorithm: 'RS256' });

    const params = new URLSearchParams();
    params.append('grant_type', 'urn:ietf:params:oauth:grant-type:jwt-bearer');
    params.append('assertion', assertion);

    const { data } = await axios.post(`${SF_LOGIN_URL}/services/oauth2/token`, params);

    const token = {
        accessToken: data.access_token,
        instanceUrl: data.instance_url,
        expiresAt: now + TOKEN_LIFETIME_SECONDS
    };
    tokenCache.set(sub, token);
    return token;
}
