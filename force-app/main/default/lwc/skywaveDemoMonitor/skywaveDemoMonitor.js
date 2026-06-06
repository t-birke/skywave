import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { subscribe, onError } from 'lightning/empApi';
import QRCodeJS from '@salesforce/resourceUrl/QRCodeJS';
import getActiveDemoSession from '@salesforce/apex/Skywave_DemoMonitorController.getActiveDemoSession';
import setActive from '@salesforce/apex/Skywave_DemoMonitorController.setActive';
import advanceState from '@salesforce/apex/Skywave_DemoMonitorController.advanceState';
import searchSessions from '@salesforce/apex/Skywave_DemoMonitorController.searchSessions';
import getOptionImageMap from '@salesforce/apex/Skywave_DemoMonitorController.getOptionImageMap';
import getAirportGeo from '@salesforce/apex/Skywave_DemoMonitorController.getAirportGeo';

const CONSUMER_SITE_URL = 'https://skywave-app-bb0e8666933b.herokuapp.com/';
const STATE_CHANNEL = '/event/Demo_State_Change__e';
const EVENT_CHANNEL = '/event/Demo_Event__e';
// How long a session is considered "active" without a fresh event from it.
// 30 minutes covers a normal demo run; sessions older than this drop off.
const SESSION_TTL_MS = 30 * 60 * 1000;

const STAGES = [
    { value: 'idle', label: 'Idle' },
    { value: 'scan', label: 'Scan' },
    { value: 'survey', label: 'Survey' },
    { value: 'agent_book', label: 'Agent: Book' },
    { value: 'profile', label: 'Profile' },
    { value: 'c360', label: 'C360' },
    { value: 'agent_seat_fail', label: 'Seat (Fail)' },
    { value: 'agent_seat_pass', label: 'Seat (Pass)' },
    { value: 'race', label: 'Race' },
    { value: 'slack', label: 'Slack' },
    { value: 'done', label: 'Done' }
];

const STAGE_LABELS = Object.fromEntries(STAGES.map(s => [s.value, s.label]));

export default class SkywaveDemoMonitor extends LightningElement {
    @track activeId = null;
    @track name = null;
    @track customer = null;
    @track demoDate = null;
    @track currentState = 'idle';
    @track sessions = []; // [{ sessionId, shortId, lastSeen, answers: [{questionKey, answerKey, imageUrl, answerText}] }]
    optionImageMap = {};  // "<questionKey>:<answerKey>" -> Image_Url__c, loaded once on mount
    airportGeo = {};      // "IATA" -> { lat, lon }, loaded once on mount

    get activeCount() { return this.sessions.length; }

    /** Bubbles fed to <c-skywave-world-map>. Each visitor maps to one bubble.
     *  Placement priority: route midpoint > geo location > unplaced. */
    get mapBubbles() {
        return this.sessions.map(s => {
            const label = this._bubbleLabel(s);
            const place = this._placement(s);
            return {
                id: s.sessionId,
                label,
                avatarUrl: s.avatarUrl || null,
                seat: s.seat || null,
                city: s.city || null,
                lat: place ? place.lat : null,
                lon: place ? place.lon : null,
                hasLocation: !!place,
                // Survey thumbs the visitor has answered — rendered as a strip
                // on the bubble. Each is { questionKey, answerKey, answerText, imageUrl }.
                answers: Array.isArray(s.answers) ? s.answers : []
            };
        });
    }

    /** Route polylines fed to <c-skywave-world-map>. */
    get mapRoutes() {
        const routes = [];
        for (const s of this.sessions) {
            if (!s.route || !s.route.legs || !s.route.legs.length) continue;
            const points = this._routePoints(s.route.legs);
            if (points.length < 2) continue;
            routes.push({
                id: s.sessionId + ':route',
                points,
                isConnection: !!s.route.isConnection
            });
        }
        return routes;
    }

    _bubbleLabel(s) {
        if (s.firstName) {
            return s.lastName ? `${s.firstName} ${s.lastName.charAt(0)}.` : s.firstName;
        }
        return s.shortId;
    }

    _placement(s) {
        // Once a route exists, plot the avatar somewhere on the trip line.
        // Direct flights use the geographic centre. Connections use the
        // midpoint of the SECOND leg (hub → destination) — putting it at
        // the hub itself stacks every connecting visitor on JFK.
        // Falls back to the visitor's IP-geo location, else null.
        if (s.route && s.route.legs && s.route.legs.length) {
            const pts = this._routePoints(s.route.legs);
            if (pts.length === 2) {
                return {
                    lat: (pts[0][1] + pts[1][1]) / 2,
                    lon: (pts[0][0] + pts[1][0]) / 2
                };
            }
            if (pts.length >= 3) {
                // pts = [origin, hub, dest]; middle of second leg = midpoint(hub, dest).
                return {
                    lat: (pts[1][1] + pts[2][1]) / 2,
                    lon: (pts[1][0] + pts[2][0]) / 2
                };
            }
        }
        if (typeof s.lat === 'number' && typeof s.lon === 'number') {
            return { lat: s.lat, lon: s.lon };
        }
        return null;
    }

    _routePoints(legs) {
        // legs = [{from:'LAX', to:'JFK'}, {from:'JFK', to:'NBO'}]
        // -> [[lon,lat] for LAX, JFK, NBO] (deduped at the seam)
        const pts = [];
        for (let i = 0; i < legs.length; i++) {
            const from = this.airportGeo[legs[i].from];
            if (i === 0 && from) pts.push([from.lon, from.lat]);
            const to = this.airportGeo[legs[i].to];
            if (to) pts.push([to.lon, to.lat]);
        }
        return pts;
    }

    qrCodeVisible = true;
    qrCodeGenerated = false;
    qrcodeClass = 'qrcode';
    _qrLibLoaded = false;

    @track showSettings = false;

    @track pickerOpen = false;
    @track pickerOptions = [];
    @track pickerInputValue = '';
    _pickerTypeTimer = null;

    toggleSettings() {
        this.showSettings = !this.showSettings;
    }

    get pickerEmpty() { return this.pickerOpen && this.pickerOptions.length === 0; }

    get hasActive() { return !!this.activeId; }

    get currentStateLabel() {
        return STAGE_LABELS[this.currentState] || this.currentState;
    }

    get stageButtons() {
        return STAGES.map(s => ({
            ...s,
            variant: s.value === this.currentState ? 'brand' : 'neutral'
        }));
    }

    async connectedCallback() {
        try {
            await loadScript(this, QRCodeJS);
            this._qrLibLoaded = true;
            this.renderQRCode();
        } catch (e) {
            console.error('QRCodeJS load failed', e);
        }

        try {
            this.optionImageMap = await getOptionImageMap();
        } catch (e) {
            console.error('getOptionImageMap failed', e);
        }

        try {
            this.airportGeo = await getAirportGeo();
        } catch (e) {
            console.error('getAirportGeo failed', e);
        }

        await this.loadActiveSession();
        this.subscribeStateChanges();
    }

    async loadActiveSession() {
        try {
            const data = await getActiveDemoSession();
            this.applySession(data);
        } catch (e) {
            console.error('getActiveDemoSession failed', e);
        }
    }

    applySession(data) {
        // Switching active session resets the bubble set — bubbles are
        // scoped to the currently-active demo run.
        this.sessions = [];
        if (data) {
            this.activeId = data.id;
            this.name = data.name;
            this.customer = data.customer;
            this.demoDate = data.demoDate;
            this.currentState = data.state || 'idle';
            this.pickerInputValue = data.customer || data.name || '';
        } else {
            this.activeId = null;
            this.name = null;
            this.customer = null;
            this.demoDate = null;
            this.currentState = 'idle';
            this.pickerInputValue = '';
        }
    }

    async openPicker() {
        this.pickerOpen = true;
        await this.refreshPickerOptions('');
    }

    closePickerSoon() {
        // Delay so the mousedown on a list item fires first.
        setTimeout(() => { this.pickerOpen = false; }, 150);
    }

    handlePickerType(event) {
        const term = event.target.value;
        this.pickerInputValue = term;
        clearTimeout(this._pickerTypeTimer);
        this._pickerTypeTimer = setTimeout(() => this.refreshPickerOptions(term), 150);
    }

    async refreshPickerOptions(term) {
        try {
            this.pickerOptions = await searchSessions({ term: term || '' });
        } catch (e) {
            console.error('searchSessions failed', e);
            this.pickerOptions = [];
        }
    }

    async handlePickerSelect(event) {
        const newId = event.currentTarget.dataset.id;
        this.pickerOpen = false;
        if (!newId || newId === this.activeId) return;
        try {
            const data = await setActive({ sessionId: newId });
            this.applySession(data);
        } catch (e) {
            console.error('setActive failed', e);
        }
    }

    subscribeStateChanges() {
        const stateCb = (msg) => {
            const payload = msg?.data?.payload || {};
            if (payload.Demo_Session_Id__c && payload.Demo_Session_Id__c !== this.activeId) return;
            this.currentState = payload.New_State__c || this.currentState;
        };
        subscribe(STATE_CHANNEL, -1, stateCb).catch((e) => console.error('state sub failed', e));

        // Replay -1 = LATEST; we don't backfill missed bubbles on first paint.
        const eventCb = (msg) => {
            const payload = msg?.data?.payload || {};
            if (payload.Demo_Session_Id__c && payload.Demo_Session_Id__c !== this.activeId) return;
            this.handleDemoEvent(payload);
        };
        subscribe(EVENT_CHANNEL, -1, eventCb).catch((e) => console.error('event sub failed', e));

        onError((err) => console.error('empApi error', err));
    }

    handleDemoEvent(payload) {
        const sessionId = payload.Session_Id__c;
        if (!sessionId) return;
        const now = Date.now();
        let existing = this.sessions.find(s => s.sessionId === sessionId);

        if (!existing) {
            existing = {
                sessionId,
                shortId: sessionId.slice(-8),
                lastSeen: now,
                answers: [],
                surveyComplete: false,
                // Map-related state. All optional; absent = bubble lives in
                // the "no location" row beneath the map.
                lat: null,
                lon: null,
                city: null,
                homeAirport: null,
                route: null,        // { legs:[{from,to}], isConnection }
                seat: null,
                firstName: null,
                lastName: null,
                avatarUrl: null
            };
            this.sessions = [
                ...this.sessions.filter(s => now - s.lastSeen < SESSION_TTL_MS),
                existing
            ];
        }

        existing.lastSeen = now;
        const inner = this._parseInner(payload.Payload_Json__c);

        switch (payload.Type__c) {
            case 'session_started':
                // Earliest event — fired right after the visitor accepts
                // consent. If the consumer site already resolved IP geo by
                // then, we get coordinates here and the bubble appears on
                // the map immediately. If not, we'll get them on
                // survey_complete instead (no regression).
                {
                    const lat = this._toNumber(inner.lat);
                    const lon = this._toNumber(inner.lon);
                    if (lat !== null) existing.lat = lat;
                    if (lon !== null) existing.lon = lon;
                }
                if (inner.city) existing.city = inner.city;
                if (inner.homeAirport) existing.homeAirport = inner.homeAirport;
                break;
            case 'survey_answer':
                this.appendSurveyAnswer(existing, payload);
                break;
            case 'survey_complete':
                existing.surveyComplete = true;
                {
                    const lat = this._toNumber(inner.lat);
                    const lon = this._toNumber(inner.lon);
                    if (lat !== null) existing.lat = lat;
                    if (lon !== null) existing.lon = lon;
                }
                if (inner.city) existing.city = inner.city;
                if (inner.homeAirport) existing.homeAirport = inner.homeAirport;
                break;
            case 'flight_booked':
                // Once a route is set, the bubble's plotted position is the
                // route midpoint (handled in mapBubbles getter), so the avatar
                // visually "moves" onto the trip line.
                existing.route = {
                    legs: Array.isArray(inner.legs) ? inner.legs : [],
                    isConnection: !!inner.isConnection,
                    bookingCode: inner.bookingCode || null
                };
                break;
            case 'seat_changed':
                existing.seat = inner.seat || null;
                break;
            case 'profile_created':
                existing.firstName = inner.firstName || null;
                existing.lastName = inner.lastName || null;
                existing.avatarUrl = inner.avatarUrl || null;
                break;
            default:
                break;
        }

        // Force tracked-array refresh
        this.sessions = [...this.sessions];
    }

    _parseInner(jsonStr) {
        if (!jsonStr) return {};
        try { return JSON.parse(jsonStr); }
        catch (e) { return {}; }
    }

    /** Apex Decimal -> JSON sometimes serializes as a number, sometimes a
     *  string. Both shapes need to land as JS Number. Returns null on garbage. */
    _toNumber(v) {
        if (v === null || v === undefined) return null;
        if (typeof v === 'number') return Number.isFinite(v) ? v : null;
        const n = parseFloat(v);
        return Number.isFinite(n) ? n : null;
    }

    appendSurveyAnswer(session, payload) {
        let inner = {};
        try { inner = payload.Payload_Json__c ? JSON.parse(payload.Payload_Json__c) : {}; }
        catch (e) { console.warn('survey_answer payload parse failed', e); }

        const questionKey = inner.questionKey;
        const answerKey = inner.answerKey;
        if (!questionKey || !answerKey) return;

        // Idempotency — if this question was already answered, replace the
        // earlier thumb. Lets a phone re-answer (re-renders fire) without
        // accumulating duplicates.
        const dedupeKey = `${questionKey}:${answerKey}`;
        const imageUrl = this.optionImageMap[dedupeKey] || null;
        const existingIdx = (session.answers || []).findIndex(a => a.questionKey === questionKey);

        const next = {
            questionKey,
            answerKey,
            answerText: inner.answerText || answerKey,
            imageUrl
        };
        if (existingIdx >= 0) {
            session.answers[existingIdx] = next;
        } else {
            session.answers = [...(session.answers || []), next];
        }
    }

    renderQRCode() {
        if (!this._qrLibLoaded) return;
        const container = this.template.querySelector('.qrcodecontainer');
        if (!container) {
            setTimeout(() => this.renderQRCode(), 100);
            return;
        }
        container.innerHTML = '';
        // eslint-disable-next-line no-undef, new-cap
        new QRCode(container, {
            text: CONSUMER_SITE_URL,
            width: 512,
            height: 512,
            colorDark: '#0b1d3a',
            colorLight: '#ffffff',
            // eslint-disable-next-line no-undef
            correctLevel: QRCode.CorrectLevel.H
        });
        this.qrCodeGenerated = true;
    }

    toggleQrCodeVisibility() {
        this.qrCodeVisible = !this.qrCodeVisible;
        if (this.qrCodeVisible) {
            this.qrCodeGenerated = false;
            setTimeout(() => this.renderQRCode(), 100);
        }
    }

    toggleenlarge() {
        this.qrcodeClass = this.qrcodeClass === 'qrcode' ? 'qrcode enlarged' : 'qrcode';
    }

    async handleStageClick(event) {
        const newState = event.target.dataset.state;
        if (!newState || newState === this.currentState || !this.activeId) return;
        // Optimistic — Pub/Sub catch-up will reconcile.
        this.currentState = newState;
        try {
            await advanceState({ sessionId: this.activeId, newState });
        } catch (e) {
            console.error('advanceState failed', e);
            this.loadActiveSession();
        }
    }
}
