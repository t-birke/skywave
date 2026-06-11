// miaw-identity.js — mints the customerIdentityToken (a signed JWT) that proves
// a website visitor's identity to MIAW User Verification.
//
// Why: the custom chat client calls the *authenticated* access-token endpoint
//   POST /iamessage/api/v2/authorization/authenticated/access-token
// with { authorizationType:"JWT", customerIdentityToken:<this JWT> }. Salesforce
// verifies the JWT against the uploaded Keyset (public JWK) and stores the JWT
// `sub` on MessagingEndUser.MessagingPlatformKey as
//   v2/iamessage/AUTH/{auth_id}/uid:<sub>
// We set sub = deviceId (== Contact.Session_Id__c), so the agent resolves the
// SAME deviceId-keyed Contact the website does. This is the platform's native
// verified-identity rail — no routing attributes, no flow/trigger hacks.
//
// Our bar for "verified" is the proof cookie + an existing Contact (per product
// decision); the route that calls mintIdentityToken is proof-gated.
//
// The signing key is a dedicated RSA-2048 keypair (RS256), SEPARATE from the
// SF JWT-bearer key (sf-auth.js) — different trust domain. Key handling mirrors
// sf-auth.js: PEM directly on Heroku, or a file path for local dev.

import jwt from 'jsonwebtoken';
import fs from 'fs';
import path from 'path';

// The kid MUST match the `kid` of the JWK uploaded to the Salesforce Keyset
// (.secrets/miaw_identity_jwk.json). The token verification fails if they differ.
const KEY_ID = process.env.SF_MIAW_JWT_KID;

// The issuer MUST match the issuer configured on the Salesforce Keyset.
const ISSUER = process.env.SF_MIAW_JWT_ISSUER || 'skywave-heroku';

// "Authorization Token Expiration Time for Verified Users" defaults to 60 min;
// keep the identity token comfortably shorter so a renewal always has a fresh
// one. The client re-fetches on renewal.
const TOKEN_TTL_SECONDS = 50 * 60;

function resolvePrivateKey() {
    // Heroku: SF_MIAW_JWT_PRIVATE_KEY holds the PEM directly.
    // Local dev: SF_MIAW_JWT_PRIVATE_KEY_FILE points at the PEM relative to repo root.
    if (process.env.SF_MIAW_JWT_PRIVATE_KEY) return process.env.SF_MIAW_JWT_PRIVATE_KEY;
    if (process.env.SF_MIAW_JWT_PRIVATE_KEY_FILE) {
        const repoRoot = path.resolve(process.cwd(), '../..');
        return fs.readFileSync(path.resolve(repoRoot, process.env.SF_MIAW_JWT_PRIVATE_KEY_FILE), 'utf8');
    }
    return null;
}

// Returns true iff identity signing is configured (key + kid present). When
// false, the client falls back to the unauthenticated token endpoint so chat
// still works for anonymous / pre-consent visitors.
export function isIdentityConfigured() {
    return Boolean(resolvePrivateKey() && KEY_ID);
}

// Mint a customerIdentityToken for the given deviceId. Throws if not configured
// (callers should check isIdentityConfigured first or treat throw as "no token").
//
// Required claims per the MIAW User Verification spec: sub, iss, exp (body) and
// alg, typ, kid (header). jsonwebtoken sets alg/typ; we set kid + the rest.
export function mintIdentityToken(deviceId) {
    const key = resolvePrivateKey();
    if (!key || !KEY_ID) throw new Error('MIAW identity signing not configured');
    if (!deviceId) throw new Error('deviceId required to mint identity token');
    const now = Math.floor(Date.now() / 1000);
    return jwt.sign(
        {
            sub: deviceId,        // -> MessagingEndUser.MessagingPlatformKey uid:<deviceId>
            iss: ISSUER,
            iat: now,
            exp: now + TOKEN_TTL_SECONDS
        },
        key,
        { algorithm: 'RS256', keyid: KEY_ID }
    );
}
