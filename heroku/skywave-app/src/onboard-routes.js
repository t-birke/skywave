// /api/onboard/* — self-service presenter onboarding.
//
// A @salesforce.com colleague opens /request-access, enters name + work email,
// and this route provisions them a System Administrator demo account (via the
// Apex endpoint /skywave/presenter/provision, called as the JWT-bearer admin)
// and emails a set-password link. See Skywave_PresenterProvision.cls.
//
// This surface is deliberately SEPARATE from /api/website/* (which is
// deviceId/proof-cookie scoped for the consumer demo). It needs no cookie —
// the identity is the work email, verified by the fact that the credentials
// email lands in that @salesforce.com mailbox. Guards: strict same-origin,
// server-side domain gate (defense in depth — Apex re-checks), audit log, and
// a tight provisioning-specific rate limit on top of the global IP limit.

import express from 'express';
import { z } from 'zod';
import rateLimit from 'express-rate-limit';
import { apexInvoke } from './sf-api.js';
import {
    helmetMiddleware, strictSameOrigin, ipRateLimit, auditLog, validate
} from './api-middleware.js';

const ALLOWED_DOMAIN = 'salesforce.com';

// Exact-domain check — mirrors the Apex guard. Rejects lookalikes
// (foo@evilsalesforce.com) and subdomains (foo@salesforce.com.evil.com).
function isSalesforceEmail(email) {
    if (typeof email !== 'string') return false;
    const parts = email.split('@');
    return parts.length === 2 && parts[1] === ALLOWED_DOMAIN;
}

export function buildOnboardRouter({ allowedOrigin }) {
    const router = express.Router();

    router.use(helmetMiddleware());
    router.use(strictSameOrigin(allowedOrigin));
    router.use(auditLog);
    router.use(ipRateLimit);

    // Provisioning is expensive (creates a licensed user + sends email), so
    // cap it hard per IP — well below the global 60/min. Keyed on IP; there's
    // no cookie on this surface.
    const provisionLimit = rateLimit({
        windowMs: 10 * 60 * 1000,
        max: 5,
        standardHeaders: true,
        legacyHeaders: false,
        message: { status: 'rate_limited', message: 'Too many requests — please try again in a few minutes.' }
    });

    const requestSchema = z.object({
        firstName: z.string().trim().min(1).max(40),
        lastName:  z.string().trim().min(1).max(80),
        email:     z.string().trim().email().max(240)
    });

    router.post('/request', provisionLimit, validate(requestSchema), async (req, res) => {
        const email = req.body.email.toLowerCase();

        if (!isSalesforceEmail(email)) {
            return res.status(403).json({
                status: 'invalid_domain',
                message: 'Only @salesforce.com email addresses can request a demo account.'
            });
        }

        // Provisioning MUST run as a full-license admin — the default relay
        // integration user (Salesforce Integration license) can't create users.
        // Fail loud if the admin subject isn't configured rather than silently
        // calling Apex as the relay user (which 403s "no access to class").
        const provisionSubject = process.env.SF_PROVISION_USERNAME;
        if (!provisionSubject) {
            console.error('SF_PROVISION_USERNAME is not set — cannot provision presenters');
            return res.status(503).json({
                status: 'not_configured',
                message: 'Account provisioning is temporarily unavailable. Please contact the demo owner.'
            });
        }

        try {
            const data = await apexInvoke('POST', '/skywave/presenter/provision', {
                email,
                firstName: req.body.firstName,
                lastName:  req.body.lastName
            }, { subject: provisionSubject });
            return res.json(data);
        } catch (err) {
            // The Apex endpoint returns a JSON envelope even on 4xx/5xx —
            // relay its status + body so the page can show a real message.
            const status = err.response?.status ?? 502;
            const data = err.response?.data ?? {
                status: 'error',
                message: 'The demo org is unreachable right now — please try again shortly.'
            };
            console.error('presenter/provision failed', status, data);
            return res.status(status).json(data);
        }
    });

    return router;
}
