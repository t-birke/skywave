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

    // ------- /bookings: visitor's active bookings -------
    //
    // Re-resolves the contactId from the proof cookie (never trusts the
    // body) before calling the bookings endpoint. The Apex layer also
    // re-checks ownership by querying Booking__c WHERE Contact__c =
    // contactId, so a tampered request can't reveal another user's data.
    router.get('/bookings', requireProof, async (req, res) => {
        try {
            const me = await apexInvoke('POST', '/skywave/website/resolve', {
                deviceId: req.deviceId,
                trackingStatus: 'websdk'
            });
            req.contactId = me.contactId;
            const data = await apexInvoke('POST', '/skywave/website/bookings/list', {
                contactId: me.contactId
            });
            res.json(data);
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('/bookings failed', status, err.response?.data ?? err.message);
            res.status(status).json({ error: 'bookings_failed' });
        }
    });

    // ------- PUT /profile: write profile fields -------
    const profileSchema = z.object({
        firstName: z.string().min(2).max(80),
        lastName:  z.string().min(2).max(80),
        email:     z.string().email().max(200),
        phone:     z.string().max(40).optional()
    });
    router.put('/profile', requireProof, validate(profileSchema), async (req, res) => {
        try {
            const me = await apexInvoke('POST', '/skywave/website/resolve', {
                deviceId: req.deviceId,
                trackingStatus: 'websdk'
            });
            req.contactId = me.contactId;
            const r = await apexInvoke('POST', '/skywave/website/profile/save', {
                contactId: me.contactId,
                firstName: req.body.firstName,
                lastName: req.body.lastName,
                email: req.body.email,
                phone: req.body.phone || ''
            });
            res.json(r);
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('PUT /profile failed', status, err.response?.data ?? err.message);
            res.status(status).json({ error: 'profile_save_failed' });
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
