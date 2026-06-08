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

    // ------- /session/peek: read-only "have we seen this deviceId?" -------
    //
    // Boot-time identity probe. Does NOT mint a Contact, does NOT Set-Cookie
    // unless a valid proof cookie is already present. Returns
    // { contactExists, surveyCompleted, profileCompleted, profile? } so the
    // client can decide whether to show consent / survey / straight to
    // stage-driven render.
    //
    // Why split from /session/init: page-load minting created a placeholder
    // Contact for every visitor, even those who never consent. That's both
    // a privacy smell and noise in CRM/Data Cloud. Now Contact mints only
    // on consent (via /session/init), and page load only peeks.
    const peekSchema = z.object({
        deviceId: z.string().optional()
    });
    router.post('/session/peek', validate(peekSchema), async (req, res) => {
        const { readProofCookie } = await import('./proof-cookie.js');
        const cookieDeviceId = readProofCookie(req);
        const bodyDeviceId = req.body.deviceId && isValidDeviceIdShape(req.body.deviceId)
            ? req.body.deviceId : null;
        const deviceId = cookieDeviceId || bodyDeviceId;
        if (!deviceId) {
            return res.json({
                contactExists: false,
                surveyCompleted: false,
                profileCompleted: false,
                profile: null
            });
        }
        try {
            const data = await apexInvoke('POST', '/skywave/website/resolve', {
                deviceId,
                trackingStatus: 'websdk',
                mintIfMissing: false
            });
            // If the proof cookie was valid, refresh its expiry so a returning
            // visitor's session doesn't lapse. Don't mint a new cookie for a
            // body-supplied deviceId — that's /session/init's job (consent).
            if (cookieDeviceId) setProofCookie(res, cookieDeviceId);
            res.json({
                contactExists: !!data.contactExists,
                surveyCompleted: !!data.surveyCompleted,
                profileCompleted: !!data.profileCompleted,
                profile: data.contactExists ? {
                    firstName: data.firstName || null,
                    lastName: data.lastName || null,
                    email: data.email || null,
                    phone: data.phone || null,
                    homeAirport: data.homeAirport || null,
                    membershipTier: data.membershipTier || null,
                    loyaltyPoints: data.loyaltyPoints || null,
                    memberNumber: data.memberNumber || null,
                    avatarUrl: data.avatarUrl || null
                } : null
            });
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('session/peek failed', status, err.response?.data ?? err.message);
            res.status(status).json({ error: 'peek_failed' });
        }
    });

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
    //
    // Called from the consumer site at consent time (handleConsent) — that's
    // when we want a Contact to exist. Page-load probing uses /session/peek
    // instead so we don't mint placeholders for every drive-by visitor.
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
                surveyCompleted: !!contact.surveyCompleted,
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

    // ------- /airports: static airport network for autocomplete -------
    //
    // Cached process-wide for the lifetime of the dyno. The network is
    // small (~30 airports) and static, so we don't round-trip to SF on
    // every keystroke. Refresh on dyno restart is fine — schedule
    // changes are rare and require a redeploy anyway.
    let airportsCache = null;
    let airportsCachedAt = 0;
    const AIRPORTS_TTL_MS = 60 * 60 * 1000;
    router.get('/airports', async (req, res) => {
        const now = Date.now();
        if (airportsCache && (now - airportsCachedAt) < AIRPORTS_TTL_MS) {
            return res.json(airportsCache);
        }
        try {
            const data = await apexInvoke('GET', '/skywave/website/airports');
            airportsCache = data;
            airportsCachedAt = now;
            res.json(data);
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('/airports failed', status, err.response?.data ?? err.message);
            res.status(status).json({ error: 'airports_failed' });
        }
    });

    // ------- /flights/search: multi-fare-class flight search -------
    //
    // Read-only (no proof required: search is browseable while
    // anonymous, identity is only enforced at booking time). Returns
    // multiple options per O&D, each with all four fare-class prices
    // so the UI can show a price grid without re-searching.
    const searchSchema = z.object({
        origin: z.string().length(3),
        destination: z.string().length(3),
        date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/)
    });
    router.post('/flights/search', validate(searchSchema), async (req, res) => {
        try {
            const data = await apexInvoke('POST', '/skywave/website/flights/search', req.body);
            res.json(data);
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('flights/search failed', status, err.response?.data ?? err.message);
            res.status(status).json(err.response?.data ?? { error: 'search_failed' });
        }
    });

    // ------- POST /bookings: create a confirmed booking -------
    //
    // Identity-bound. Resolves contactId from the proof cookie BEFORE
    // calling the Apex create endpoint — body never carries contactId
    // from the client. The Apex layer creates Booking__c +
    // Booking_Segment__c, marked Confirmed/Paid (website skips the
    // chat path's Pending->Confirmed two-step because there's no
    // payment-widget animation here — clicking "Book" IS the payment).
    const createBookingSchema = z.object({
        flightKey: z.string().min(3).max(40),
        travelDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
        fareClass: z.enum(['Economy', 'Premium Economy', 'Business', 'First']),
        checkedBags: z.number().int().min(0).max(5).optional(),
        seatPreference: z.enum(['Window', 'Aisle', 'No preference']).optional()
    });
    router.post('/bookings', requireProof, validate(createBookingSchema), async (req, res) => {
        try {
            const me = await apexInvoke('POST', '/skywave/website/resolve', {
                deviceId: req.deviceId,
                trackingStatus: 'websdk'
            });
            req.contactId = me.contactId;
            const data = await apexInvoke('POST', '/skywave/website/bookings/create', {
                contactId: me.contactId,
                flightKey: req.body.flightKey,
                travelDate: req.body.travelDate,
                fareClass: req.body.fareClass,
                checkedBags: req.body.checkedBags ?? 0,
                seatPreference: req.body.seatPreference || 'No preference'
            });
            res.json(data);
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('POST /bookings failed', status, err.response?.data ?? err.message);
            res.status(status).json(err.response?.data ?? { error: 'create_booking_failed' });
        }
    });

    // ------- POST /bookings/:code/cancel: cancel a booking -------
    router.post('/bookings/:code/cancel', requireProof, async (req, res) => {
        const code = req.params.code;
        if (!/^[A-Z0-9]{4,12}$/.test(code)) {
            return res.status(400).json({ error: 'invalid_code' });
        }
        try {
            const me = await apexInvoke('POST', '/skywave/website/resolve', {
                deviceId: req.deviceId, trackingStatus: 'websdk'
            });
            req.contactId = me.contactId;
            const data = await apexInvoke('POST', '/skywave/website/bookings/manage/cancel', {
                contactId: me.contactId, bookingCode: code
            });
            res.json(data);
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('cancel booking failed', status, err.response?.data ?? err.message);
            res.status(status).json(err.response?.data ?? { error: 'cancel_failed' });
        }
    });

    // ------- GET /bookings/:code/seatmap?segmentOrder=N: layout + occupancy -------
    //
    // Returns the aircraft's seat layout JSON + the seats already taken by
    // other passengers on the same flight + travel date. Used by the
    // hi-fi seatmap UI on the booking detail page.
    router.get('/bookings/:code/seatmap', requireProof, async (req, res) => {
        const code = req.params.code;
        if (!/^[A-Z0-9]{4,12}$/.test(code)) {
            return res.status(400).json({ error: 'invalid_code' });
        }
        const segmentOrder = parseInt(req.query.segmentOrder, 10);
        if (!Number.isInteger(segmentOrder) || segmentOrder < 1 || segmentOrder > 10) {
            return res.status(400).json({ error: 'invalid_segmentOrder' });
        }
        try {
            const me = await apexInvoke('POST', '/skywave/website/resolve', {
                deviceId: req.deviceId, trackingStatus: 'websdk'
            });
            req.contactId = me.contactId;
            const data = await apexInvoke('POST', '/skywave/website/seatmap', {
                contactId: me.contactId, bookingCode: code, segmentOrder
            });
            res.json(data);
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('seatmap fetch failed', status, err.response?.data ?? err.message);
            res.status(status).json(err.response?.data ?? { error: 'seatmap_failed' });
        }
    });

    // ------- POST /bookings/:code/seat: change seat on a segment -------
    const seatSchema = z.object({
        segmentOrder: z.number().int().min(1).max(10),
        newSeat: z.string().regex(/^\d{1,2}[A-Z]$/i)
    });
    router.post('/bookings/:code/seat', requireProof, validate(seatSchema), async (req, res) => {
        const code = req.params.code;
        if (!/^[A-Z0-9]{4,12}$/.test(code)) {
            return res.status(400).json({ error: 'invalid_code' });
        }
        try {
            const me = await apexInvoke('POST', '/skywave/website/resolve', {
                deviceId: req.deviceId, trackingStatus: 'websdk'
            });
            req.contactId = me.contactId;
            const data = await apexInvoke('POST', '/skywave/website/bookings/manage/seat', {
                contactId: me.contactId, bookingCode: code,
                segmentOrder: req.body.segmentOrder,
                newSeat: req.body.newSeat
            });
            res.json(data);
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('change seat failed', status, err.response?.data ?? err.message);
            res.status(status).json(err.response?.data ?? { error: 'seat_change_failed' });
        }
    });

    // ------- POST /session/abandon: stamp mid-funnel exit + partial survey -------
    //
    // Fired by the consumer site when the visitor X's the demo modal
    // mid-funnel (post-consent, pre-survey-or-pre-profile-complete). On
    // the server side, Skywave_WebsiteAbandon is idempotent:
    //   - Always stamps Skywave_Abandoned_At__c + Skywave_Abandon_Reason__c.
    //   - Only persists partialAnswers if Skywave_Survey_Json__c is currently
    //     empty (visitor never finished). Returning afterwards and finishing
    //     the survey overwrites the partial with the complete record.
    //
    // partialAnswers shape mirrors what the site holds in state.answers:
    //   { "<questionKey>": { questionText, answerText, answerKey } }
    const abandonSchema = z.object({
        reason: z.string().min(1).max(40),
        partialAnswers: z.record(z.object({
            questionText: z.string().min(1).max(500),
            answerText: z.string().min(1).max(500),
            answerKey: z.string().min(1).max(80)
        })).optional()
    });
    router.post('/session/abandon', requireProof, validate(abandonSchema), async (req, res) => {
        try {
            const me = await apexInvoke('POST', '/skywave/website/resolve', {
                deviceId: req.deviceId,
                trackingStatus: 'websdk',
                mintIfMissing: true
            });
            req.contactId = me.contactId;
            const data = await apexInvoke('POST', '/skywave/website/abandon', {
                contactId: me.contactId,
                reason: req.body.reason,
                partialAnswers: req.body.partialAnswers || null
            });
            res.json(data);
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('session/abandon failed', status, err.response?.data ?? err.message);
            res.status(status).json({ error: 'abandon_failed' });
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
                surveyCompleted: !!contact.surveyCompleted,
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
