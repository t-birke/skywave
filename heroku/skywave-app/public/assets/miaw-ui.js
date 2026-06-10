// miaw-ui.js — pixel-exact ECv2 chat UI over the MiawClient transport.
//
// Renders the launch button, panel, header, message bubbles, typing
// indicator and composer in plain DOM, styled by miaw-ui.css to be visually
// indistinguishable from the real ECv2 widget. Subscribes to MiawClient
// events and renders custom Lightning type cards (the seatmap) inline.
//
// No framework, no build step — matches the rest of the consumer site.

import { MiawClient } from './miaw-client.js';
import { renderSeatMapCard } from './miaw-seatmap.js';
import { renderFlightCard, renderPaymentCard, renderProfileCard } from './miaw-cards.js';

const SEND_ICON = '<svg viewBox="0 0 24 24"><path d="M2 21l21-9L2 3v7l15 2-15 2v7z"/></svg>';
const CHAT_ICON = '<svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>';

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
    // opts: { orgId, developerName, scrt2Url, deviceId, title?,
    //         onConversationOpened?, onSeatConfirm? }
    constructor(opts) {
        this.opts = opts;
        this.title = opts.title || 'Chat';
        this.open = false;
        this.typingEl = null;
        this.progressEl = null;
        this.client = new MiawClient({
            orgId: opts.orgId,
            developerName: opts.developerName,
            scrt2Url: opts.scrt2Url,
            routingAttributes: opts.deviceId ? { Session_ID: opts.deviceId } : undefined
        });
        this._bindClient();
    }

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
                ${CHAT_ICON}<span>Let's chat</span>
            </button>
            <section class="miaw-panel" role="dialog" aria-label="Chat window">
                <header class="miaw-header">
                    <span class="miaw-title"></span>
                    <button class="miaw-close" type="button" aria-label="Minimize chat">&#x2014;</button>
                </header>
                <div class="miaw-messages" aria-live="polite"></div>
                <footer class="miaw-footer">
                    <textarea class="miaw-input" rows="1" placeholder="Type a message…" aria-label="Message"></textarea>
                    <button class="miaw-send" type="button" aria-label="Send" disabled>${SEND_ICON}</button>
                </footer>
            </section>`;
        parent.appendChild(root);

        this.root = root;
        this.fab = root.querySelector('.miaw-fab');
        this.panel = root.querySelector('.miaw-panel');
        this.messages = root.querySelector('.miaw-messages');
        this.input = root.querySelector('.miaw-input');
        this.sendBtn = root.querySelector('.miaw-send');
        root.querySelector('.miaw-title').textContent = this.title;

        this.fab.addEventListener('click', () => this.show());
        root.querySelector('.miaw-close').addEventListener('click', () => this.hide());
        this.sendBtn.addEventListener('click', () => this._onSend());
        this.input.addEventListener('input', () => this._autoGrow());
        this.input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); this._onSend(); }
        });
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
            try {
                await this.client.startStream();
                await this.client.openConversation();
            } catch (e) {
                console.error('[miaw-ui] start failed', e);
                this._started = false;  // allow a retry on next open
                this._systemLine('Sorry — chat is unavailable right now.');
                return;
            }
            // Non-fatal backfill (resumed conversations); ignore failures.
            this.client.loadEntries().catch(() => {});
        }
        setTimeout(() => this.input.focus(), 350);
    }

    hide() {
        this.open = false;
        this.panel.classList.remove('open');
        this.fab.style.display = 'inline-flex';
    }

    // ---- send ------------------------------------------------------------

    async _onSend() {
        const text = this.input.value.trim();
        if (!text) return;
        this.input.value = '';
        this._autoGrow();
        this.sendBtn.disabled = true;
        try { await this.client.sendText(text); }
        catch (e) { console.error('[miaw-ui] send failed', e); this._systemLine('Message failed to send.'); }
    }

    _autoGrow() {
        const el = this.input;
        el.style.height = 'auto';
        el.style.height = Math.min(el.scrollHeight, 96) + 'px';
        this.sendBtn.disabled = el.value.trim().length === 0;
    }

    // ---- transport events ------------------------------------------------

    _bindClient() {
        this.client.on('message', (m) => this._renderMessage(m));
        this.client.on('clt', (c) => this._renderClt(c));
        this.client.on('typing', (t) => this._setTyping(t.active));
        this.client.on('progress', (p) => this._setProgress(p.text));
        this.client.on('conversationOpened', (e) => {
            this.opts.onConversationOpened?.(e.conversationId);
        });
    }

    _renderMessage(m) {
        this._clearTyping();
        this._clearProgress();
        if (m.text == null && m.raw) return;  // unsupported types: skip silently
        const el = document.createElement('div');
        el.className = `miaw-msg ${m.direction === 'outbound' ? 'outbound' : 'inbound'}`;
        // Linkify lightly; agent text is plain. (RichText would be sanitized
        // upstream; keep it simple and safe here with textContent.)
        el.textContent = m.text || '';
        this.messages.appendChild(el);
        this._scrollToEnd();
    }

    _renderClt(c) {
        this._clearTyping();
        this._clearProgress();
        // Optional lead-in text from the ExperienceType message.
        if (c.message) this._renderMessage({ direction: 'inbound', text: c.message });
        // Route each action-output value to the matching card renderer. We
        // key on the action name in `type` (copilotActionOutput/<action>_<id>)
        // — payment + profile share the `formData` output field, so the field
        // name alone can't disambiguate.
        (c.values || []).forEach((v) => {
            const type = v.type || '';
            const val = v.value || {};
            const card = document.createElement('div');
            card.className = 'miaw-card';

            if (type.includes('present_seat_map') && val.seatMapData?.seatMapJSON) {
                renderSeatMapCard(card, val.seatMapData.seatMapJSON, {
                    onConfirm: (sel) => this._cardAction(() => this.opts.onSeatConfirm?.(sel), 'seat change confirmed'),
                    onAbort: () => this.client.sendText('seat change aborted')
                });
            } else if (type.includes('search_flights') && val.flightResult?.flightsJSON) {
                renderFlightCard(card, val.flightResult.flightsJSON, {
                    // Flight pick is a pure cue — the agent drives the booking.
                    onBook: (flightNumber) => this.client.sendText(`Book flight ${flightNumber}`)
                });
            } else if (type.includes('present_payment_form') && val.formData?.paymentStateJSON) {
                renderPaymentCard(card, val.formData.paymentStateJSON, {
                    onPay: (sel) => this._cardAction(() => this.opts.onPay?.(sel), 'Payment completed')
                });
            } else if (type.includes('present_profile_form') && val.formData?.formStateJSON) {
                renderProfileCard(card, val.formData.formStateJSON, {
                    onSave: (data) => this._cardAction(() => this.opts.onSaveProfile?.(data), 'Profile created')
                });
            } else {
                // Unknown CLT — show its lead-in only; don't crash the demo.
                card.remove();
                return;
            }
            this.messages.appendChild(card);
        });
        this._scrollToEnd();
    }

    // Shared card-action runner: perform the upstream write (through the
    // host app's proof-cookie'd Heroku->Apex path), then cue the agent —
    // exactly the verify-only cue pattern the LWCs used. Rethrows so the
    // card can show its own error state.
    async _cardAction(upstream, cue) {
        if (upstream) await upstream();
        await this.client.sendText(cue);
    }

    // ---- typing / progress ----------------------------------------------

    _setTyping(active) {
        if (!active) { this._clearTyping(); return; }
        if (this.typingEl) return;
        const el = document.createElement('div');
        el.className = 'miaw-typing';
        el.innerHTML = '<span class="dot"></span><span class="dot"></span><span class="dot"></span>';
        this.messages.appendChild(el);
        // After the pop-in finishes, switch to the gentle looping bob.
        setTimeout(() => el.classList.add('settled'), 450);
        this.typingEl = el;
        this._scrollToEnd();
    }
    _clearTyping() { if (this.typingEl) { this.typingEl.remove(); this.typingEl = null; } }

    _setProgress(text) {
        this._clearProgress();
        const el = document.createElement('div');
        el.className = 'miaw-progress';
        el.textContent = text;
        this.messages.appendChild(el);
        this.progressEl = el;
        this._scrollToEnd();
    }
    _clearProgress() { if (this.progressEl) { this.progressEl.remove(); this.progressEl = null; } }

    _systemLine(text) {
        const el = document.createElement('div');
        el.className = 'miaw-progress';
        el.textContent = text;
        this.messages.appendChild(el);
        this._scrollToEnd();
    }

    _scrollToEnd() {
        // Next frame so layout settles before scrolling.
        requestAnimationFrame(() => { this.messages.scrollTop = this.messages.scrollHeight; });
    }
}
