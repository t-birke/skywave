// /api/website/* routes — the cookie-identified, hardened surface for the
// Skywave website (profile, bookings, booking creation, management).
//
// All routes ride on:
//   - strictSameOrigin (CORS)
//   - ipRateLimit + cookieRateLimit
//   - auditLog
// and most also on requireProof — which extracts the deviceId from the
// signed cookie and attaches it to req.deviceId. The single endpoint that
// runs WITHOUT requireProof is /session/init, since that's what mints the
// cookie in the first place.
//
// Every "act on resource X" call additionally re-checks that X belongs to
// the deviceId's Contact (TODO Phase 2+ — the read paths fetch X scoped to
// that Contact, so ownership is implicit by query).

import express from 'express';
import { z } from 'zod';
import {
    PROOF_COOKIE_NAME, isValidDeviceIdShape, newSyntheticDeviceId,
    setProofCookie, requireProof
} from './proof-cookie.js';
import { apexInvoke } from './sf-api.js';
import {
    helmetMiddleware, strictSameOrigin, ipRateLimit, cookieRateLimit,
    auditLog, validate
} from './api-middleware.js';

export function buildWebsiteRouter({ allowedOrigin }) {
    const router = express.Router();

    // Order matters: helmet first, then CORS gate, then audit log so we
    // capture every request (including 403s from CORS), then rate limits.
    router.use(helmetMiddleware());
    router.use(strictSameOrigin(allowedOrigin));
    router.use(auditLog);
    router.use(ipRateLimit);
    router.use(cookieRateLimit);

    // ------- /session/init: mint or refresh skywave_proof -------
    //
    // Body shape:
    //   { deviceId?: string, optedOut?: boolean }
    //
    // Decision tree:
    //   1. If req.cookies.skywave_proof verifies → reuse its deviceId, refresh
    //      cookie expiry. Returns the existing Contact.
    //   2. If body.deviceId is a valid WebSDK shape → seal it,
    //      trackingStatus=websdk.
    //   3. Otherwise → mint synthetic UUID, trackingStatus=synthetic.
    //   4. If body.optedOut === true at any point, trackingStatus=opted_out
    //      (sticky in Salesforce side once set).
    const initSchema = z.object({
        deviceId: z.string().optional(),
        optedOut: z.boolean().optional()
    });
    router.post('/session/init', validate(initSchema), async (req, res) => {
        const { readProofCookie } = await import('./proof-cookie.js');
        let deviceId = readProofCookie(req);
        let trackingStatus;

        if (deviceId) {
            // Existing visitor — reuse, refresh cookie. Tracking status is
            // whatever Salesforce already has on the Contact.
            trackingStatus = req.body.optedOut ? 'opted_out' : null;
        } else if (req.body.deviceId && isValidDeviceIdShape(req.body.deviceId)) {
            deviceId = req.body.deviceId;
            trackingStatus = req.body.optedOut ? 'opted_out' : 'websdk';
        } else {
            deviceId = newSyntheticDeviceId();
            trackingStatus = req.body.optedOut ? 'opted_out' : 'synthetic';
        }

        try {
            const contact = await apexInvoke('POST', '/skywave/website/resolve', {
                deviceId,
                trackingStatus: trackingStatus || 'synthetic'
            });
            setProofCookie(res, deviceId);
            // Don't return the deviceId in the response body — the cookie is
            // the only place the browser ever sees it after this. (The WebSDK
            // cookie is the JS-readable channel for that value.)
            req.deviceId = deviceId;
            req.contactId = contact.contactId;
            res.json({
                ok: true,
                contactId: contact.contactId,
                trackingStatus: contact.trackingStatus,
                profileCompleted: contact.profileCompleted,
                profile: {
                    firstName: contact.firstName || null,
                    lastName: contact.lastName || null,
                    email: contact.email || null,
                    phone: contact.phone || null,
                    homeAirport: contact.homeAirport || null,
                    membershipTier: contact.membershipTier || null,
                    loyaltyPoints: contact.loyaltyPoints || null,
                    memberNumber: contact.memberNumber || null,
                    avatarUrl: contact.avatarUrl || null
                }
            });
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('session/init failed', status, err.response?.data ?? err.message);
            res.status(status).json({ error: 'init_failed' });
        }
    });

    // ------- /me: smoke test for the proof cookie + Apex round-trip -------
    //
    // Resolves the visitor's full profile from the deviceId in the proof
    // cookie. Same Apex endpoint as /session/init — idempotent, reads
    // existing Contact (or creates one if a visitor somehow had a valid
    // proof cookie without a backing Contact, e.g. after an org reset).
    router.get('/me', requireProof, async (req, res) => {
        try {
            const contact = await apexInvoke('POST', '/skywave/website/resolve', {
                deviceId: req.deviceId,
                trackingStatus: 'websdk'  // not changed for existing rows
            });
            req.contactId = contact.contactId;
            res.json({
                contactId: contact.contactId,
                trackingStatus: contact.trackingStatus,
                profileCompleted: contact.profileCompleted,
                profile: {
                    firstName: contact.firstName || null,
                    lastName: contact.lastName || null,
                    email: contact.email || null,
                    phone: contact.phone || null,
                    homeAirport: contact.homeAirport || null,
                    membershipTier: contact.membershipTier || null,
                    loyaltyPoints: contact.loyaltyPoints || null,
                    memberNumber: contact.memberNumber || null,
                    avatarUrl: contact.avatarUrl || null
                }
            });
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('/me failed', status, err.response?.data ?? err.message);
            res.status(status).json({ error: 'me_failed' });
        }
    });

    return router;
}
