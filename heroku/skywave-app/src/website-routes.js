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
import { apexInvoke, pipeFromInstance } from './sf-api.js';
import {
    helmetMiddleware, strictSameOrigin, ipRateLimit, cookieRateLimit,
    auditLog, validate
} from './api-middleware.js';

// Rewrite an Apex-supplied Shepherd path (e.g.
// "/sfc/servlet.shepherd/version/download/068g8000003L9z3AAC") into the
// proxy path the browser actually fetches from this dyno. Returns null
// for any other shape — including null — so the JSON field stays null
// when the visitor has no avatar.
const SHEPHERD_RE = /^\/sfc\/servlet\.shepherd\/version\/download\/([A-Za-z0-9]{15,18})$/;
function avatarProxyUrl(rawAvatarUrl) {
    if (!rawAvatarUrl) return null;
    const m = SHEPHERD_RE.exec(rawAvatarUrl);
    return m ? `/api/website/avatar/${m[1]}` : null;
}

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
                    avatarUrl: avatarProxyUrl(contact.avatarUrl)
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
                    avatarUrl: avatarProxyUrl(contact.avatarUrl)
                }
            });
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('/me failed', status, err.response?.data ?? err.message);
            res.status(status).json({ error: 'me_failed' });
        }
    });

    // ------- /avatar/:cvId: stream the visitor's avatar bytes -------
    //
    // Browsers fetch this from <img src>, so the request rides on the
    // browser's session cookies. requireProof gates it on a valid proof
    // cookie. Ownership check: we re-resolve the visitor's Contact and
    // confirm Apex would currently hand back this exact ContentVersion id
    // as their avatar — that way one visitor can't enumerate other people's
    // ContentVersions through the proxy.
    router.get('/avatar/:cvId', requireProof, async (req, res) => {
        const cvId = req.params.cvId;
        if (!/^[A-Za-z0-9]{15,18}$/.test(cvId)) {
            return res.status(400).json({ error: 'invalid_cvId' });
        }
        try {
            const me = await apexInvoke('POST', '/skywave/website/resolve', {
                deviceId: req.deviceId,
                trackingStatus: 'websdk'
            });
            req.contactId = me.contactId;
            const expected = avatarProxyUrl(me.avatarUrl);
            if (expected !== `/api/website/avatar/${cvId}`) {
                return res.status(404).json({ error: 'avatar_not_found' });
            }
            // Shepherd path (/sfc/servlet.shepherd/...) is a UI endpoint that
            // requires session-cookie auth — Bearer token returns the SF login
            // redirect HTML. The REST sobjects/VersionData endpoint is the
            // Bearer-friendly equivalent and streams the raw bytes.
            await pipeFromInstance(`/services/data/v62.0/sobjects/ContentVersion/${cvId}/VersionData`, res);
        } catch (err) {
            const status = err.response?.status ?? 500;
            console.error('/avatar fetch failed', status, err.response?.data ?? err.message);
            if (!res.headersSent) {
                res.status(status).json({ error: 'avatar_fetch_failed' });
            } else {
                res.end();
            }
        }
    });

    return router;
}
