// miaw-ui.js — pixel-exact ECv2 chat UI over the MiawClient transport.
//
// Renders the launch button, panel, header (with End-chat menu + minimize),
// agent-avatar message rows, sender/timestamp labels, centered system lines,
// the launching "hello" state and the dual-ring "Thinking" spinner — all in
// plain DOM, styled by miaw-ui.css to be visually indistinguishable from the
// real ECv2 widget.
//
// The glyphs and the affordance CSS are NOT invented: they were recovered
// verbatim from the live ECv2 `home_view` LWR bundle (icon paths confirmed by
// rendering each to PNG). See docs/ecv2-reference/raw-assets/
// icons-and-affordances.json. The few strings that are deployment-configured
// (button label, placeholder, header title) come from the client screenshots.
//
// No framework, no build step — matches the rest of the consumer site.

import { MiawClient } from './miaw-client.js';
import { renderSeatMapCard } from './miaw-seatmap.js';
import { renderFlightCard, renderPaymentCard, renderProfileCard } from './miaw-cards.js';

// ECv2 icons — path data recovered verbatim from the home_view cwc-icon set.
const svg = (vb, d, extra = '') =>
    `<svg viewBox="${vb}" fill="currentColor" aria-hidden="true"${extra}><path d="${d}"/></svg>`;
const BUBBLE_ICON = svg('0 0 20 20', 'M10 1.25C14.8325 1.25 18.75 5.16751 18.75 10C18.75 11.3951 18.4213 12.7154 17.8389 13.8877L18.7217 17.5137C18.8042 17.8528 18.7038 18.2103 18.457 18.457C18.2103 18.7038 17.8528 18.8042 17.5137 18.7217L13.8877 17.8389C12.7154 18.4213 11.3951 18.75 10 18.75C5.16751 18.75 1.25 14.8325 1.25 10C1.25 5.16751 5.16751 1.25 10 1.25ZM10 3.25C6.27208 3.25 3.25 6.27208 3.25 10C3.25 13.7279 6.27208 16.75 10 16.75C11.1896 16.75 12.3049 16.4434 13.2734 15.9053L13.3574 15.8633C13.5573 15.7757 13.7814 15.7556 13.9951 15.8076L16.3896 16.3896L15.8076 13.9951C15.7482 13.7508 15.7832 13.4932 15.9053 13.2734C16.4434 12.3049 16.75 11.1896 16.75 10C16.75 6.27208 13.7279 3.25 10 3.25Z');
const CHEVRON_ICON = svg('0 0 24 24', 'M20.5928 6.79321C20.9832 6.40283 21.6163 6.40291 22.0068 6.79321C22.3971 7.18373 22.3972 7.81681 22.0068 8.20728L12.707 17.5071C12.5196 17.6946 12.2651 17.8 12 17.8C11.7349 17.8 11.4805 17.6945 11.293 17.5071L1.99316 8.20728C1.60264 7.81675 1.60264 7.18373 1.99316 6.79321C2.3837 6.40277 3.01673 6.40272 3.40723 6.79321L12 15.386L20.5928 6.79321Z');
const KEBAB_ICON = svg('0 0 24 24', 'M12 7 a2 2 0 1 1 0 -4 a2 2 0 1 1 0 4 M12 14 a2 2 0 1 1 0 -4 a2 2 0 1 1 0 4 M12 21 a2 2 0 1 1 0 -4 a2 2 0 1 1 0 4');
const AGENT_AVATAR_ICON = svg('0 0 24 24', 'M11.9995 2.2998C13.4906 2.2998 14.8778 2.83477 15.8941 3.84961C16.9139 4.86819 17.4995 6.30962 17.4995 8.00781C17.4994 9.80895 16.7593 11.3685 15.7329 12.4746C15.5854 12.6336 15.4291 12.7839 15.2671 12.9268C15.2696 12.9274 15.2725 12.9281 15.2749 12.9287L15.2222 12.9658C14.9193 13.228 14.5943 13.4595 14.2544 13.6533L12.9946 14.5508C12.6513 14.5178 12.3176 14.5 12.0005 14.5C10.588 14.5 8.84981 14.8141 7.35793 15.5557C5.87619 16.2925 4.70604 17.4118 4.23293 19.0088C4.18702 19.1643 4.22002 19.3008 4.34133 19.4326C4.47777 19.5806 4.71784 19.7002 5.00051 19.7002H16.2173C16.2783 19.9704 16.343 20.3175 16.4107 20.7715C16.4637 21.1271 16.5777 21.4348 16.73 21.7002H5.00051C4.17915 21.7002 3.39853 21.3607 2.86965 20.7861C2.32598 20.1951 2.0484 19.3437 2.31594 18.4404C2.99008 16.1647 4.644 14.6717 6.46828 13.7646C7.19793 13.402 7.96599 13.1265 8.73195 12.9268C8.57 12.7839 8.41363 12.6335 8.26613 12.4746C7.23973 11.3685 6.49964 9.80893 6.49953 8.00781C6.49953 6.30963 7.0852 4.86819 8.105 3.84961C9.12122 2.83476 10.5084 2.29982 11.9995 2.2998ZM18.9995 11.5C19.2059 11.5 19.4686 11.6189 19.5669 11.8877L19.5982 12.0127L19.6802 12.5195C19.8732 13.6247 20.0901 14.1921 20.4487 14.5508C20.8586 14.9606 21.5409 15.1858 22.9868 15.4014C23.344 15.4546 23.4995 15.7641 23.4995 16C23.4995 16.2359 23.3441 16.5454 22.9868 16.5986C21.5409 16.8141 20.8586 17.0393 20.4487 17.4492C20.0389 17.8591 19.8137 18.5413 19.5982 19.9873C19.5449 20.3445 19.2354 20.5 18.9995 20.5C18.7636 20.4999 18.4541 20.3444 18.4009 19.9873C18.1854 18.5413 17.9602 17.8591 17.5503 17.4492C17.1404 17.0394 16.4582 16.8141 15.0122 16.5986C14.6551 16.5453 14.4995 16.2359 14.4995 16C14.4995 15.7641 14.6551 15.4547 15.0122 15.4014L15.5191 15.3193C16.6242 15.1263 17.1916 14.9094 17.5503 14.5508C17.9602 14.1409 18.1854 13.4587 18.4009 12.0127L18.4321 11.8877C18.5304 11.619 18.7932 11.5001 18.9995 11.5ZM11.9995 4.2998C10.9908 4.29982 10.1278 4.65685 9.51906 5.26465C8.91405 5.86886 8.49953 6.78219 8.49953 8.00781C8.49964 9.24856 9.00966 10.3349 9.73293 11.1143C10.4746 11.9133 11.3506 12.2998 11.9995 12.2998C12.6485 12.2998 13.5244 11.9133 14.2661 11.1143C14.9894 10.3349 15.4994 9.24857 15.4995 8.00781C15.4995 6.78217 15.085 5.86886 14.48 5.26465C13.8712 4.65686 13.0083 4.2998 11.9995 4.2998Z');
// Composer send button — the ECv2 "arrowup" glyph (recovered verbatim from
// the home_view named-icon registry, PNG-confirmed). It renders as a white
// arrow on the circular blue button, i.e. the encircled up-arrow that ECv2
// shows INSIDE the input pill once you start typing. (NOT the voice waveform.)
const SEND_ICON = '<svg viewBox="0 0 520 520" fill="currentColor" aria-hidden="true"><path d="M414 210c8-8 8-19 0-27L264 36a20 20 0 0 0-28 0L86 183c-8 8-8 19 0 27l28 27c8 8 20 8 28 0l47-46c8-8 22-2 22 9v270c0 10 9 20 20 20h40c11 0 20-11 20-20V200c0-12 14-17 22-9l47 46c8 8 20 8 28 0z"/></svg>';

// Map config branding[] -> our CSS custom properties.
const BRANDING_TO_VAR = {
    headerBackground: '--miaw-header-bg',
    headerForeground: '--miaw-header-fg',
    chatButton: '--miaw-button-bg',
    userMessageBackground: '--miaw-user-bg',
    userMessageText: '--miaw-user-fg',
    agentMessageBackground: '--miaw-agent-bg',
    agentMessageText: '--miaw-agent-fg',
    agentMessageLink: '--miaw-agent-link',
    primaryButtonBackground: '--miaw-primary-btn-bg',
    primaryButtonText: '--miaw-primary-btn-fg',
    inputOutline: '--miaw-input-outline',
    primaryText: '--miaw-primary-text',
    secondaryText: '--miaw-secondary-text',
    alert: '--miaw-alert'
};

export class MiawUI {
    // opts: { orgId, developerName, scrt2Url, deviceId,
    //         title?, onConversationOpened?, onSeatConfirm?, onPay?, onSaveProfile? }
    constructor(opts) {
        this.opts = opts;
        this.title = opts.title || 'Chat';
        this.open = false;
        this.typingEl = null;
        this.busyEl = null;
        this.welcomeEl = null;
        this.menuOpen = false;
        this._lastDir = null;          // for avatar grouping (consecutive inbound)
        this._systemHeaderShown = false;
        // Agent-ready gate: the composer is locked from open until the agent's
        // FIRST message (the welcome) actually lands. The bot session isn't
        // listening yet during the join->welcome lag, so anything typed in that
        // window is dropped on the platform — we prevent it and show why.
        this._agentReady = false;
        this._agentReadyTimer = null;
        // Identity handshake gate: the FIRST user message waits until the
        // org confirms (via the WS 'chat_ready' client_action) that this
        // device's Contact carries the ConvId — so the agent's turn-1
        // resolve_session matches this Contact, not the demo seed. Resolved
        // by markChatReady(); a safety timeout prevents hanging if the event
        // is missed (worst case: the legacy race, no worse than before).
        this._chatReady = new Promise((resolve) => { this._resolveChatReady = resolve; });
        this._firstMessageSent = false;
        this.client = new MiawClient({
            orgId: opts.orgId,
            developerName: opts.developerName,
            scrt2Url: opts.scrt2Url,
            // deviceId rides the conversation as Session_ID; the chat_start
            // bridge stamps it onto the Contact for agent resolution.
            routingAttributes: opts.deviceId ? { Session_ID: opts.deviceId } : undefined
        });
        this._bindClient();
        this._onDocClick = (e) => {
            if (this.menuOpen && this.menu && !this.menu.contains(e.target) && e.target !== this.menuBtn && !this.menuBtn.contains(e.target)) {
                this._closeMenu();
            }
        };
    }

    // Called by the host when the WS 'chat_ready' arrives (Contact stamped).
    markChatReady() { this._resolveChatReady?.(); }

    // ---- lifecycle -------------------------------------------------------

    async mount(parent = document.body) {
        this._injectStyles();
        await this._applyBranding();      // colors before first paint
        this._buildDom(parent);
    }

    _injectStyles() {
        [['miaw-ui-css', '/assets/miaw-ui.css'],
         ['miaw-cards-css', '/assets/miaw-cards.css']].forEach(([id, href]) => {
            if (document.getElementById(id)) return;
            const link = document.createElement('link');
            link.id = id; link.rel = 'stylesheet'; link.href = href;
            document.head.appendChild(link);
        });
    }

    // Pull branding[] from the config endpoint and set CSS vars so the
    // palette tracks Setup exactly like the real client.
    async _applyBranding() {
        try {
            const url = `${this.opts.scrt2Url}/embeddedservice/v1/embedded-service-config`
                + `?orgId=${this.opts.orgId}&esConfigName=${this.opts.developerName}&language=en_US`;
            const res = await fetch(url);
            if (!res.ok) return;
            const cfg = (await res.json()).embeddedServiceConfig || {};
            const root = document.documentElement;
            (cfg.branding || []).forEach(({ n, v }) => {
                if (!v || v === 'None') return;
                const cssVar = BRANDING_TO_VAR[n];
                if (cssVar) root.style.setProperty(cssVar, v);
            });
            if (cfg.name) this.title = this.title === 'Chat' ? (cfg.name.replace(/_/g, ' ')) : this.title;
        } catch (e) { console.warn('[miaw-ui] branding fetch failed', e); }
    }

    _buildDom(parent) {
        const root = document.createElement('div');
        root.className = 'miaw-root';
        root.innerHTML = `
            <button class="miaw-fab" type="button" aria-label="Open chat">
                <span class="miaw-fab__icon">${BUBBLE_ICON}</span>
                <span class="miaw-fab__text">Ask Me Anything</span>
            </button>
            <section class="miaw-panel" role="dialog" aria-label="Chat window">
                <header class="miaw-header">
                    <span class="miaw-header__brand">
                        <span class="miaw-header__icon">${BUBBLE_ICON}</span>
                        <span class="miaw-title"></span>
                    </span>
                    <span class="miaw-header__actions">
                        <button class="miaw-iconbtn miaw-menu-btn" type="button" aria-label="Conversation options" aria-haspopup="true">${KEBAB_ICON}</button>
                        <button class="miaw-iconbtn miaw-min-btn" type="button" aria-label="Minimize chat">${CHEVRON_ICON}</button>
                    </span>
                    <div class="miaw-menu" role="menu" hidden>
                        <button class="miaw-menu__item" type="button" role="menuitem" data-act="end">End chat</button>
                    </div>
                </header>
                <div class="miaw-body">
                    <div class="miaw-messages" aria-live="polite"></div>
                    <div class="miaw-welcome" hidden>
                        <div class="miaw-welcome__hi">Hello</div>
                    </div>
                </div>
                <footer class="miaw-footer">
                    <div class="miaw-composer">
                        <textarea class="miaw-input" rows="1" placeholder="Type your message..." aria-label="Message"></textarea>
                        <button class="miaw-send" type="button" aria-label="Send" hidden>${SEND_ICON}</button>
                    </div>
                </footer>
            </section>`;
        parent.appendChild(root);

        this.root = root;
        this.fab = root.querySelector('.miaw-fab');
        this.panel = root.querySelector('.miaw-panel');
        this.body = root.querySelector('.miaw-body');
        this.messages = root.querySelector('.miaw-messages');
        this.welcome = root.querySelector('.miaw-welcome');
        this.menu = root.querySelector('.miaw-menu');
        this.menuBtn = root.querySelector('.miaw-menu-btn');
        this.input = root.querySelector('.miaw-input');
        this.sendBtn = root.querySelector('.miaw-send');
        root.querySelector('.miaw-title').textContent = this.title;

        this.fab.addEventListener('click', () => this.show());
        root.querySelector('.miaw-min-btn').addEventListener('click', () => this.hide());
        this.menuBtn.addEventListener('click', (e) => { e.stopPropagation(); this._toggleMenu(); });
        this.menu.querySelector('[data-act="end"]').addEventListener('click', () => this._endChat());
        this.sendBtn.addEventListener('click', () => this._onSend());
        this.input.addEventListener('input', () => this._autoGrow());
        this.input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); this._onSend(); }
        });
    }

    // ---- header menu -----------------------------------------------------

    _toggleMenu() { this.menuOpen ? this._closeMenu() : this._openMenu(); }
    _openMenu() {
        this.menuOpen = true;
        this.menu.hidden = false;
        this.menuBtn.setAttribute('aria-expanded', 'true');
        document.addEventListener('click', this._onDocClick, true);
    }
    _closeMenu() {
        this.menuOpen = false;
        if (this.menu) this.menu.hidden = true;
        this.menuBtn?.setAttribute('aria-expanded', 'false');
        document.removeEventListener('click', this._onDocClick, true);
    }

    async _endChat() {
        this._closeMenu();
        try { await this.client.end(); } catch (e) { /* best-effort */ }
        // Reset to a clean closed state so reopening starts a fresh chat.
        this.hide();
        this.messages.innerHTML = '';
        this._started = false;
        this._systemHeaderShown = false;
        this._lastDir = null;
        this.typingEl = this.busyEl = null;
        this._firstMessageSent = false;
        this._chatReady = new Promise((resolve) => { this._resolveChatReady = resolve; });
        // Reset the agent-ready gate so a reopened chat re-locks until its
        // fresh welcome lands.
        clearTimeout(this._agentReadyTimer);
        this._agentReadyTimer = null;
        this._agentReady = false;
        this.input.disabled = false;
        this.input.placeholder = 'Type your message...';
    }

    // ---- show / hide -----------------------------------------------------

    async show() {
        this.open = true;
        this.fab.style.display = 'none';
        this.panel.classList.add('open');
        // First open: boot the conversation + stream. ONLY these two are
        // essential — if they fail, chat genuinely can't work. Backfill is
        // best-effort and must never gate startup (it already swallows its
        // own errors, but keep it out of the fatal path too).
        if (!this._started) {
            this._started = true;
            this._showWelcome();   // pulsing "hello" while we connect
            try {
                await this.client.startStream();
                await this.client.openConversation();
            } catch (e) {
                console.error('[miaw-ui] start failed', e);
                this._started = false;  // allow a retry on next open
                this._dismissWelcome();
                this._systemLine('Sorry — chat is unavailable right now.');
                return;
            }
            // ECv2-style session header at the very top of the transcript.
            this._renderSystemHeader();
            // Lock the composer until the agent's first message lands — see
            // _lockComposer. (A resumed conversation that backfills prior
            // messages will release the gate as those replay through 'message'.)
            this._lockComposer();
            // Non-fatal backfill (resumed conversations); ignore failures.
            this.client.loadEntries().catch(() => {});
        }
        // Focus only when the agent is ready; otherwise the lock owns the field.
        if (this._agentReady) setTimeout(() => this.input.focus(), 350);
    }

    hide() {
        this.open = false;
        this._closeMenu();
        this.panel.classList.remove('open');
        this.fab.style.display = 'inline-flex';
    }

    // ---- agent-ready gate -----------------------------------------------

    // Lock the composer between "agent joined" and the agent's first message.
    // The bot isn't listening during that lag, so early input is lost — we
    // disable the field, swap the placeholder, and show the bottom-left
    // spinner with "Agent is getting ready". A safety timeout releases the
    // gate so a missed/failed welcome can never strand the user.
    _lockComposer() {
        this._agentReady = false;
        this.input.disabled = true;
        this.input.placeholder = 'Agent is getting ready…';
        this.sendBtn.hidden = true;
        this._setBusy('Agent is getting ready');
        clearTimeout(this._agentReadyTimer);
        this._agentReadyTimer = setTimeout(() => this._releaseAgentGate(), 30000);
    }

    // Open the composer the instant the agent is actually live (first inbound
    // message or CLT card). Idempotent — backfill/typing can call it freely.
    _releaseAgentGate() {
        clearTimeout(this._agentReadyTimer);
        this._agentReadyTimer = null;
        if (this._agentReady) return;
        this._agentReady = true;
        this.input.disabled = false;
        this.input.placeholder = 'Type your message...';
        if (this.open) setTimeout(() => this.input.focus(), 50);
    }

    // ---- send ------------------------------------------------------------

    async _onSend() {
        // Re-entrancy guard. iOS Safari can fire the send twice for one tap
        // (touch + synthesized click, or keyboard "Go" + button), which —
        // even with the input-clear below — can double-send if both reads
        // land before the clear. A simple in-flight flag is the robust fix.
        if (this._sending) return;
        // Composer is gated until the agent's first message — drop any send
        // that races the lock (belt-and-suspenders; the field is also disabled).
        if (!this._agentReady) return;
        const text = this.input.value.trim();
        if (!text) return;
        // iOS Safari can deliver a second send for one tap AFTER the first
        // fully resolves (touch + the ~300ms-delayed synthesized click), by
        // which point _sending is already back to false. Guard on the exact
        // text within a short window too, so a duplicate first message can't
        // slip through. (Legitimate repeat sends of the same text >1.5s apart
        // still go through.)
        const now = (performance && performance.now) ? performance.now() : 0;
        if (this._lastSentText === text && (now - (this._lastSentAt || 0)) < 1500) return;
        this._lastSentText = text;
        this._lastSentAt = now;
        this._sending = true;
        this.input.value = '';
        this._autoGrow();        // empties -> hides the send button (ECv2 behavior)
        try {
            // Gate the FIRST message on the identity handshake so the agent
            // resolves this device's Contact (not the demo seed). Subsequent
            // messages send immediately. Safety timeout (4s) avoids hanging
            // if the chat_ready event is missed.
            if (!this._firstMessageSent) {
                await Promise.race([
                    this._chatReady,
                    new Promise((r) => setTimeout(r, 4000))
                ]);
                this._firstMessageSent = true;
            }
            await this.client.sendText(text);
        }
        catch (e) { console.error('[miaw-ui] send failed', e); this._systemLine('Message failed to send.'); }
        finally { this._sending = false; }
    }

    _autoGrow() {
        const el = this.input;
        el.style.height = 'auto';
        el.style.height = Math.min(el.scrollHeight, 96) + 'px';
        // ECv2 shows the send affordance INSIDE the pill only once there's
        // text; with an empty field the placeholder occupies the full width.
        this.sendBtn.hidden = el.value.trim().length === 0;
    }

    // ---- transport events ------------------------------------------------

    _bindClient() {
        this.client.on('message', (m) => this._renderMessage(m));
        this.client.on('clt', (c) => this._renderClt(c));
        this.client.on('typing', (t) => this._setTyping(t.active));
        this.client.on('progress', (p) => this._setBusy(p.text));
        this.client.on('conversationOpened', (e) => {
            this.opts.onConversationOpened?.(e.conversationId);
        });
    }

    // Format a timestamp like ECv2's metadata line: "5:12 PM".
    _fmtTime(ts) {
        const d = ts ? new Date(ts) : new Date();
        try { return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }); }
        catch (_) { return ''; }
    }

    _renderMessage(m) {
        this._clearTyping();
        this._clearBusy();
        this._dismissWelcome();
        if (m.text == null && m.raw) return;  // unsupported types: skip silently
        const inbound = m.direction !== 'outbound';
        // The agent's first inbound message means the bot is live — open the
        // composer (no-op if already open, e.g. on later messages/backfill).
        if (inbound) this._releaseAgentGate();

        const row = document.createElement('div');
        row.className = `miaw-row ${inbound ? 'inbound' : 'outbound'}`;

        // Agent avatar to the LEFT of inbound bubbles. Grouped: the avatar
        // shows only on the first of a run of consecutive agent messages; the
        // spacer keeps later bubbles aligned (matches ECv2 grouping).
        if (inbound) {
            const av = document.createElement('span');
            av.className = 'miaw-avatar';
            if (this._lastDir !== 'inbound') av.innerHTML = AGENT_AVATAR_ICON;
            row.appendChild(av);
        }

        const col = document.createElement('div');
        col.className = 'miaw-col';
        const bubble = document.createElement('div');
        bubble.className = `miaw-msg ${inbound ? 'inbound' : 'outbound'}`;
        bubble.textContent = m.text || '';
        col.appendChild(bubble);

        // Sender · time (inbound) / Sent · time (outbound) metadata line.
        const meta = document.createElement('div');
        meta.className = 'miaw-meta';
        const time = this._fmtTime(m.timestamp);
        meta.textContent = inbound
            ? `${m.senderDisplayName || this.title}${time ? ' · ' + time : ''}`
            : `Sent${time ? ' · ' + time : ''}`;
        col.appendChild(meta);

        row.appendChild(col);
        this.messages.appendChild(row);
        this._lastDir = inbound ? 'inbound' : 'outbound';
        this._scrollToEnd();
    }

    _renderClt(c) {
        this._clearTyping();
        this._clearBusy();
        this._dismissWelcome();
        this._releaseAgentGate();   // a card is live agent output — open the composer
        // Optional lead-in text from the ExperienceType message.
        if (c.message) this._renderMessage({ direction: 'inbound', text: c.message, senderDisplayName: c.senderDisplayName, timestamp: c.timestamp });
        // Route each action-output value to the matching card renderer. We
        // key on the action name in `type` (copilotActionOutput/<action>_<id>)
        // — payment + profile share the `formData` output field, so the field
        // name alone can't disambiguate.
        // historical=true: this card was replayed from the transcript on
        // reload. Render it in its final, non-interactive "done" state (we
        // assume the action succeeded) so re-tapping can't re-fire the action.
        const done = c.historical === true;
        (c.values || []).forEach((v) => {
            const type = v.type || '';
            const val = v.value || {};
            const card = document.createElement('div');
            card.className = 'miaw-card';

            if (type.includes('present_seat_map') && val.seatMapData?.seatMapJSON) {
                renderSeatMapCard(card, val.seatMapData.seatMapJSON, {
                    // Change ONLY in onConfirm; cue from onComplete (after the
                    // change + animation) so the agent never verifies early.
                    onConfirm: (sel) => this.opts.onSeatConfirm?.(sel),
                    onComplete: () => this.client.sendText('seat change confirmed'),
                    onAbort: () => this.client.sendText('seat change aborted')
                }, { done });
            } else if (type.includes('search_flights') && val.flightResult?.flightsJSON) {
                renderFlightCard(card, val.flightResult.flightsJSON, {
                    // Flight pick is a pure cue — the agent drives the booking.
                    onBook: (flightNumber) => this.client.sendText(`Book flight ${flightNumber}`)
                }, { done });
            } else if (type.includes('present_payment_form') && val.formData?.paymentStateJSON) {
                renderPaymentCard(card, val.formData.paymentStateJSON, {
                    // onPay charges ONLY (must resolve before the card shows
                    // completed). The cue is sent from onComplete — after BOTH
                    // the charge and the animation finish — so the agent's
                    // confirm_booking never runs while the card is still
                    // "Processing…" (the early-cue bug).
                    onPay: (sel) => this.opts.onPay?.(sel),
                    onComplete: () => this.client.sendText('Payment completed')
                }, { done });
            } else if (type.includes('present_profile_form') && val.formData?.formStateJSON) {
                renderProfileCard(card, val.formData.formStateJSON, {
                    // Save ONLY in onSave; cue from onComplete (after success).
                    onSave: (data) => this.opts.onSaveProfile?.(data),
                    onComplete: () => this.client.sendText('Profile created')
                }, { done });
            } else {
                // Unknown CLT — show its lead-in only; don't crash the demo.
                card.remove();
                return;
            }
            this.messages.appendChild(card);
        });
        // A full-width card breaks the avatar group: the next agent message
        // should show its avatar again.
        this._lastDir = null;
        this._scrollToEnd();
    }

    // ---- system lines ----------------------------------------------------

    // ECv2 opens every conversation with centered status lines: a routing
    // note ("Switched to text") and the agent-joined block + "Just now".
    _renderSystemHeader() {
        if (this._systemHeaderShown) return;
        this._systemHeaderShown = true;
        this._systemLine('Switched to text');
        const block = document.createElement('div');
        block.className = 'miaw-sysblock';
        const joined = document.createElement('div');
        joined.className = 'miaw-sysline';
        joined.textContent = `${this.title} joined`;
        const when = document.createElement('div');
        when.className = 'miaw-sysline';
        when.textContent = 'Just now';
        block.appendChild(joined);
        block.appendChild(when);
        this.messages.appendChild(block);
    }

    _systemLine(text) {
        const el = document.createElement('div');
        el.className = 'miaw-sysline';
        el.textContent = text;
        this.messages.appendChild(el);
        this._scrollToEnd();
    }

    // ---- launching welcome ----------------------------------------------

    _showWelcome() { if (this.welcome) this.welcome.hidden = false; }
    _dismissWelcome() { if (this.welcome) this.welcome.hidden = true; }

    // ---- typing / "Thinking" --------------------------------------------

    // The chatbot typing/progress indicator: ECv2's dual counter-rotating
    // rings + a label ("Thinking", or the action progress text). Lives as the
    // last item in the transcript, so it sits just above the composer.
    _setTyping(active) { active ? this._setBusy('Thinking') : this._clearBusy(); }

    _setBusy(text) {
        this._dismissWelcome();
        if (!this.busyEl) {
            const el = document.createElement('div');
            el.className = 'miaw-thinking';
            el.innerHTML =
                '<span class="miaw-spinner"><span class="miaw-spinner__outer"></span><span class="miaw-spinner__inner"></span></span>'
                + '<span class="miaw-thinking__label"></span>';
            // Pinned bottom-left of the body (above the composer), NOT in the
            // scrolling message flow — matches ECv2's positioned
            // .spinner-container (left:0; z-index:50). On a short transcript it
            // stays at the bottom instead of floating up under the last message.
            this.body.appendChild(el);
            this.busyEl = el;
        }
        this.busyEl.querySelector('.miaw-thinking__label').textContent = text || 'Thinking';
        this._scrollToEnd();
    }
    _clearBusy() { if (this.busyEl) { this.busyEl.remove(); this.busyEl = null; } }
    _clearTyping() { if (this.typingEl) { this.typingEl.remove(); this.typingEl = null; } }

    _scrollToEnd() {
        // Next frame so layout settles before scrolling.
        requestAnimationFrame(() => { this.messages.scrollTop = this.messages.scrollHeight; });
    }
}
