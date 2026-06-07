// Hardening middleware stack for the /api/website/* surface.
//
//   - helmet: HSTS, X-Frame-Options, no-sniff, referrer policy, sane CSP for
//     the static site
//   - CORS: strict same-origin (the website and the API share an origin on
//     Heroku, so cross-origin requests are rejected)
//   - rate limit: dual buckets (IP + cookie) so a noisy IP doesn't lock out
//     a legit cookie and vice versa
//   - audit log: structured single-line JSON per request, capturing the
//     identity bound to the call (deviceId), IP, route, status, latency
//   - zod helper: validate(req.body, schema) → either {ok, data} or sends
//     400 itself
//
// All applied via app.use() on the /api/website/* path scope so the legacy
// phone-demo endpoints are untouched.

import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import { readProofCookie } from './proof-cookie.js';

export function helmetMiddleware() {
    return helmet({
        contentSecurityPolicy: {
            useDefaults: true,
            directives: {
                'default-src': ["'self'"],
                // Inline style/script kept open for the existing static site;
                // tighten in a follow-up after the site is fully migrated to
                // external assets.
                'script-src': ["'self'", "'unsafe-inline'", 'https:'],
                'style-src': ["'self'", "'unsafe-inline'", 'https:'],
                'img-src': ["'self'", 'data:', 'https:'],
                'connect-src': ["'self'", 'https:', 'wss:'],
                'frame-src': ["'self'", 'https:']
            }
        },
        crossOriginEmbedderPolicy: false  // chat iframe still loads cross-origin
    });
}

// Strict same-origin: only the configured website host may call /api/website/*.
// Browsers automatically include Origin on cross-origin XHR/fetch; we reject
// anything that doesn't match. Server-to-server calls (no Origin) are also
// rejected for /api/website/* — there's no legitimate path that needs them.
export function strictSameOrigin(allowedOrigin) {
    return (req, res, next) => {
        const origin = req.headers.origin;
        if (!origin) {
            // Same-origin form GETs/HEADs from the page itself don't send Origin
            // — allow only safe methods in that case.
            if (req.method === 'GET' || req.method === 'HEAD') return next();
            return res.status(403).json({ error: 'origin_required' });
        }
        if (origin !== allowedOrigin) {
            return res.status(403).json({ error: 'cross_origin_blocked' });
        }
        next();
    };
}

// IP rate limit — 60 req/min per IP across the whole /api/website/* surface.
export const ipRateLimit = rateLimit({
    windowMs: 60 * 1000,
    max: 60,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'rate_limited_ip' }
});

// Cookie rate limit — 30 req/min per deviceId. Tighter than IP because a single
// browser shouldn't be hitting the API more than that under realistic use.
export const cookieRateLimit = rateLimit({
    windowMs: 60 * 1000,
    max: 30,
    standardHeaders: true,
    legacyHeaders: false,
    keyGenerator: (req) => readProofCookie(req) || `noproof:${req.ip}`,
    message: { error: 'rate_limited_cookie' }
});

// Single-line JSON audit log per request.
export function auditLog(req, res, next) {
    const start = Date.now();
    res.on('finish', () => {
        const entry = {
            t: new Date().toISOString(),
            ip: req.ip,
            method: req.method,
            path: req.originalUrl,
            status: res.statusCode,
            ms: Date.now() - start,
            // deviceId only logged if the proof was valid for this request —
            // we never log the raw cookie value.
            deviceId: req.deviceId || null,
            contactId: req.contactId || null
        };
        // Single line so log aggregators can parse easily.
        console.log('AUDIT', JSON.stringify(entry));
    });
    next();
}

// zod helper: validate(schema)(req, res, next) — places parsed body on req.body
// or returns 400 with the issue path.
export function validate(schema) {
    return (req, res, next) => {
        const r = schema.safeParse(req.body);
        if (!r.success) {
            return res.status(400).json({
                error: 'invalid_body',
                issues: r.error.issues.map(i => ({ path: i.path.join('.'), message: i.message }))
            });
        }
        req.body = r.data;
        next();
    };
}
