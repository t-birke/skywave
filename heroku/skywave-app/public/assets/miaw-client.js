// miaw-client.js — custom MIAW (Messaging for In-App & Web) transport.
//
// Replaces the ECv2 embedded widget on iOS Safari, where the official
// client dies in a redirect loop: the chat session cookie is set on
// *.my.site.com but the host page is *.herokuapp.com — different
// public-suffix domains, so the cookie is third-party and iOS ITP drops
// it (request -> /ESADeployment/login?ec=302 -> loop -> "too many HTTP
// redirects"). We can't share a registrable domain (demo must stay
// transferable) so instead we talk to the scrt2 REST API directly: the
// auth JWT comes back in the response BODY, lives in first-party
// localStorage on THIS origin, and there is nothing for ITP to block.
//
// Contract verified live against si on 2026-06-10 — see
// docs/ecv2-reference/MIAW_REST_SPIKE.md. Schemas are STRICT (extra
// properties 400). This module is transport only — no DOM. The UI layer
// (miaw-ui.js) subscribes to the events emitted here.

const API = '/iamessage/v1';

// localStorage keys are namespaced per (org, deployment) so two demos on
// the same browser don't collide.
function storeKey(orgId, dev, suffix) {
    return `miaw:${orgId}:${dev}:${suffix}`;
}

// The scrt2 accessToken schema only accepts these capabilitiesVersion
// enum values; "260" is current. If Salesforce rotates the supported set
// the token call 400s with the allowed list in the message — bump here.
const CAPABILITIES_VERSION = '260';

function uuid() {
    if (crypto && crypto.randomUUID) return crypto.randomUUID();
    // Fallback for older WebViews: RFC4122-ish v4 from getRandomValues.
    const b = crypto.getRandomValues(new Uint8Array(16));
    b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
    const h = [...b].map((x) => x.toString(16).padStart(2, '0'));
    return `${h.slice(0, 4).join('')}-${h.slice(4, 6).join('')}-${h.slice(6, 8).join('')}-${h.slice(8, 10).join('')}-${h.slice(10).join('')}`
        .replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5');
}

// Minimal event emitter — UI subscribes via on(type, cb).
class Emitter {
    constructor() { this._h = {}; }
    on(type, cb) { (this._h[type] ||= []).push(cb); return () => this.off(type, cb); }
    off(type, cb) { this._h[type] = (this._h[type] || []).filter((f) => f !== cb); }
    emit(type, payload) { (this._h[type] || []).forEach((f) => { try { f(payload); } catch (e) { console.error('[miaw] handler', type, e); } }); }
}

export class MiawClient extends Emitter {
    // config: { orgId(18), developerName, scrt2Url, routingAttributes? }
    constructor(config) {
        super();
        this.cfg = config;
        // SSE needs the 15-char org id (the JWT encodes it; mismatch ->
        // "OrgId in the header and token must match"). Derive it once.
        this.orgId15 = (config.orgId || '').slice(0, 15);
        this.token = null;
        this.conversationId = null;
        this.lastEventId = null;   // for SSE resume after a drop
        this._sse = null;          // AbortController for the active stream
        this._seenEntryIds = new Set();  // de-dupe across SSE + reconnect
        this._stopped = false;
    }

    // --- auth -------------------------------------------------------------

    // Reuse a cached token if present (survives reloads, so a returning
    // visitor keeps their conversation). Mint a fresh one otherwise.
    async ensureToken() {
        if (this.token) return this.token;
        const cached = localStorage.getItem(storeKey(this.cfg.orgId, this.cfg.developerName, 'token'));
        const cachedConv = localStorage.getItem(storeKey(this.cfg.orgId, this.cfg.developerName, 'conv'));
        if (cached) {
            this.token = cached;
            this.conversationId = cachedConv || null;
            return this.token;
        }
        return this.mintToken();
    }

    async mintToken() {
        const res = await fetch(`${this.cfg.scrt2Url}${API}/authorization/unauthenticated/accessToken`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            // STRICT: developerName (not esDeveloperName), no platform key.
            body: JSON.stringify({
                orgId: this.cfg.orgId,
                developerName: this.cfg.developerName,
                capabilitiesVersion: CAPABILITIES_VERSION
            })
        });
        if (!res.ok) throw new Error(`accessToken ${res.status}: ${await res.text()}`);
        const j = await res.json();
        this.token = j.accessToken;
        if (j.lastEventId != null) this.lastEventId = String(j.lastEventId);
        localStorage.setItem(storeKey(this.cfg.orgId, this.cfg.developerName, 'token'), this.token);
        return this.token;
    }

    _authHeaders(json = true) {
        const h = { Authorization: `Bearer ${this.token}` };
        if (json) h['Content-Type'] = 'application/json';
        return h;
    }

    // --- conversation -----------------------------------------------------

    // Create the conversation. The CLIENT generates the id (a UUID); the
    // platform maps it to an internal MessagingSession.ConversationId that
    // the agent's identity resolution keys on (see identity wiring in the
    // UI layer). routingAttributes carries Session_ID for routing.
    async openConversation() {
        await this.ensureToken();
        if (this.conversationId) return this.conversationId;
        const id = uuid();
        const res = await fetch(`${this.cfg.scrt2Url}${API}/conversation`, {
            method: 'POST',
            headers: this._authHeaders(),
            // STRICT: no esDeveloperName here.
            body: JSON.stringify({
                conversationId: id,
                ...(this.cfg.routingAttributes ? { routingAttributes: this.cfg.routingAttributes } : {})
            })
        });
        // A cached token whose conversation already exists 409s — treat as
        // already-open. A stale/expired token 401s — re-mint once.
        if (res.status === 401) {
            this.token = null;
            localStorage.removeItem(storeKey(this.cfg.orgId, this.cfg.developerName, 'token'));
            await this.mintToken();
            return this.openConversation();
        }
        if (!res.ok && res.status !== 409) {
            throw new Error(`createConversation ${res.status}: ${await res.text()}`);
        }
        this.conversationId = id;
        localStorage.setItem(storeKey(this.cfg.orgId, this.cfg.developerName, 'conv'), id);
        this.emit('conversationOpened', { conversationId: id });
        return id;
    }

    // Send a plain-text message. STRICT: messageType + id are TOP-LEVEL.
    async sendText(text) {
        if (!this.conversationId) await this.openConversation();
        const id = uuid();
        const res = await fetch(`${this.cfg.scrt2Url}${API}/conversation/${this.conversationId}/message`, {
            method: 'POST',
            headers: this._authHeaders(),
            body: JSON.stringify({
                messageType: 'StaticContentMessage',
                id,
                staticContent: { formatType: 'Text', text },
                isNewMessagingSession: false
            })
        });
        if (!res.ok) throw new Error(`sendMessage ${res.status}: ${await res.text()}`);
        // Echo our own message immediately so the UI feels responsive; the
        // SSE round-trip will also carry it (de-duped by id).
        this._seenEntryIds.add(id);
        this.emit('message', {
            id, direction: 'outbound', formatType: 'Text', text,
            sender: 'EndUser', timestamp: Date.now()
        });
        return id;
    }

    // Backfill prior entries (e.g. resumed conversation). Best-effort and
    // NEVER throws — a fresh conversation has nothing to backfill, and a
    // transport hiccup here must not block chat startup. The endpoint is a
    // POST (with a JSON body), not a GET — a GET returns 405.
    async loadEntries() {
        if (!this.conversationId) return [];
        try {
            const res = await fetch(`${this.cfg.scrt2Url}${API}/queries/conversation/${this.conversationId}/entries`, {
                method: 'POST', headers: this._authHeaders(), body: '{}'
            });
            if (!res.ok) { console.warn('[miaw] loadEntries', res.status); return []; }
            const j = await res.json();
            const entries = j.conversationEntries || j.entries || [];
            entries.forEach((e) => this._dispatchEntry(e));
            return entries;
        } catch (e) {
            console.warn('[miaw] loadEntries failed (non-fatal)', e?.message || e);
            return [];
        }
    }

    async end() {
        this._stopped = true;
        this._closeSse();
        if (this.conversationId) {
            try {
                await fetch(`${this.cfg.scrt2Url}${API}/conversation/${this.conversationId}`, {
                    method: 'DELETE', headers: this._authHeaders(false)
                });
            } catch (e) { /* best-effort */ }
        }
        localStorage.removeItem(storeKey(this.cfg.orgId, this.cfg.developerName, 'token'));
        localStorage.removeItem(storeKey(this.cfg.orgId, this.cfg.developerName, 'conv'));
        this.token = null; this.conversationId = null;
        this.emit('ended', {});
    }

    // --- SSE --------------------------------------------------------------

    // The receive channel. EventSource can't set the Authorization /
    // X-Org-Id headers the endpoint requires, so we stream via fetch +
    // ReadableStream and parse the text/event-stream frames ourselves,
    // with auto-reconnect (resuming from lastEventId).
    async startStream() {
        await this.ensureToken();
        this._stopped = false;
        this._connectSse();
    }

    _closeSse() {
        if (this._sse) { try { this._sse.abort(); } catch (_) {} this._sse = null; }
    }

    async _connectSse() {
        this._closeSse();
        const ctrl = new AbortController();
        this._sse = ctrl;
        const headers = {
            Authorization: `Bearer ${this.token}`,
            Accept: 'text/event-stream',
            'X-Org-Id': this.orgId15
        };
        if (this.lastEventId) headers['Last-Event-Id'] = this.lastEventId;
        try {
            const res = await fetch(`${this.cfg.scrt2Url}/eventrouter/v1/sse`, {
                method: 'GET', headers, signal: ctrl.signal
            });
            if (res.status === 401) {
                // Token expired mid-stream — re-mint and reconnect.
                this.token = null;
                localStorage.removeItem(storeKey(this.cfg.orgId, this.cfg.developerName, 'token'));
                await this.mintToken();
                return this._scheduleReconnect();
            }
            if (!res.ok || !res.body) throw new Error(`sse ${res.status}`);
            this.emit('streamOpen', {});
            await this._readStream(res.body);
        } catch (e) {
            if (this._stopped || ctrl.signal.aborted) return;
            console.warn('[miaw] SSE error, reconnecting', e?.message || e);
        }
        this._scheduleReconnect();
    }

    _scheduleReconnect() {
        if (this._stopped) return;
        // Fixed short backoff — the demo wants fast recovery, not gentle.
        setTimeout(() => { if (!this._stopped) this._connectSse(); }, 1500);
    }

    async _readStream(body) {
        const reader = body.getReader();
        const dec = new TextDecoder();
        let buf = '';
        for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            buf += dec.decode(value, { stream: true });
            // SSE frames are separated by a blank line.
            let idx;
            while ((idx = buf.indexOf('\n\n')) !== -1) {
                const frame = buf.slice(0, idx);
                buf = buf.slice(idx + 2);
                this._handleFrame(frame);
            }
        }
    }

    _handleFrame(frame) {
        let event = 'message', data = '', id = null;
        frame.split('\n').forEach((line) => {
            if (line.startsWith('event:')) event = line.slice(6).trim();
            else if (line.startsWith('data:')) data += line.slice(5).trim();
            else if (line.startsWith('id:')) id = line.slice(3).trim();
        });
        if (id) this.lastEventId = id;
        if (event === 'ping' || !data) return;
        let parsed;
        try { parsed = JSON.parse(data); } catch (_) { return; }
        this._routeEvent(event, parsed);
    }

    // Map scrt2 SSE event types to clean UI events.
    _routeEvent(event, data) {
        const ce = data.conversationEntry;
        switch (event) {
            case 'CONVERSATION_MESSAGE':
                if (ce) this._dispatchEntry(ce);
                break;
            case 'CONVERSATION_TYPING_STARTED_INDICATOR':
                this.emit('typing', { active: true });
                break;
            case 'CONVERSATION_TYPING_STOPPED_INDICATOR':
                this.emit('typing', { active: false });
                break;
            case 'CONVERSATION_PROGRESS_INDICATOR': {
                const pj = this._payload(ce);
                const msg = pj?.progressIndicator?.progressMessage?.text;
                if (msg) this.emit('progress', { text: msg });
                break;
            }
            case 'CONVERSATION_STREAMING_TOKEN':
                // Partial token stream for incremental text rendering.
                this.emit('streamingToken', { data });
                break;
            default:
                break;
        }
    }

    _payload(ce) {
        if (!ce) return null;
        const raw = ce.entryPayload;
        if (!raw) return null;
        try { return typeof raw === 'string' ? JSON.parse(raw) : raw; } catch (_) { return null; }
    }

    // Turn one conversationEntry into a normalized 'message' or 'clt' event.
    _dispatchEntry(ce) {
        const entryId = ce.identifier || ce.id;
        if (entryId && this._seenEntryIds.has(entryId)) return;
        if (entryId) this._seenEntryIds.add(entryId);

        const pj = this._payload(ce);
        if (!pj) return;
        const am = pj.abstractMessage || pj;
        const sc = am.staticContent || {};
        const sender = ce.sender?.role || pj.sender?.role || 'Chatbot';
        const direction = sender === 'EndUser' ? 'outbound' : 'inbound';
        const base = {
            id: entryId,
            direction,
            sender,
            senderDisplayName: ce.senderDisplayName,
            timestamp: ce.clientTimestamp || pj.timestamp || Date.now()
        };

        // Custom Lightning type cards (seatmap, booking cards) arrive as
        // formatType:"ExperienceType" carrying values[] keyed by
        // type:"copilotActionOutput/<action>". The raw action output is
        // right there — re-render it in our own UI, no ESW runtime.
        if (sc.formatType === 'ExperienceType') {
            this.emit('clt', {
                ...base,
                message: sc.message || '',
                values: sc.values || []
            });
            return;
        }

        // Plain text / rich text.
        if (sc.formatType === 'Text' || sc.formatType === 'RichText') {
            this.emit('message', { ...base, formatType: sc.formatType, text: sc.text || '' });
            return;
        }

        // Anything else (attachments, choices) — pass through raw so the UI
        // can decide. Keeps us forward-compatible without silently dropping.
        this.emit('message', { ...base, formatType: sc.formatType || 'Unknown', raw: sc });
    }
}
