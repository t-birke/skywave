import { LightningElement, api } from "lwc";
import {
    dispatchMessagingEvent,
    assignMessagingEventHandler,
    MESSAGING_EVENT
} from "lightningsnapin/eventStore";

/**
 * Sample utterances shown as tappable "conversation starters". Each `text` is
 * sent verbatim to the agent via configuration.util.sendTextMessage(text) — the
 * agent handles routing (destinations, booking, seat change, profile update).
 */
const UTTERANCES = [
    { id: "u1", text: "Where can I fly to?" },
    { id: "u2", text: "Book a flight from SFO to NYC tomorrow in business" },
    { id: "u3", text: "Change my seat" },
    { id: "u4", text: "Update my profile" }
];

// The header target gets NO first-bot-message event (confirmed against the
// platform source): PARTICIPANT_JOINED and conversationStatus "OPEN" both fire
// at bot JOIN — a beat BEFORE the welcome bubble renders. So we reveal a short
// settle after the bot goes live (lets the welcome land), and — belt and
// suspenders — reveal immediately if the host-page
// onEmbeddedMessagingFirstBotMessageSent event happens to reach this iframe.
// SAFETY_MS guarantees the loader never strands the visitor if no "bot live"
// signal ever arrives (e.g. a conversation that only starts on first input).
const SETTLE_MS = 1000;
const SAFETY_MS = 20000;
const HOST_FIRST_BOT_EVENT = "onEmbeddedMessagingFirstBotMessageSent";

/**
 * Custom conversation-window header for Skywave's Embedded Messaging (ECv2).
 *
 *   loading → branded spinner until the bot is live (see reveal gate above).
 *   ready   → top bar + a greeting/"suggested prompts" panel of utterance chips.
 *
 * The panel (`_expanded`) auto-collapses to the slim top bar once the visitor
 * sends a message, and can be re-opened/hidden anytime via the header toggle.
 */
export default class SkywaveChatHeader extends LightningElement {
    /** Deployment configuration data (channel, util methods, auth mode). */
    @api configuration = {};

    _conversationStatus;
    /** Conversation status: NOT_STARTED | OPEN | CLOSED. */
    @api
    get conversationStatus() {
        return this._conversationStatus;
    }
    set conversationStatus(value) {
        this._conversationStatus = value;
        if (value === "OPEN") {
            this._scheduleReveal(SETTLE_MS); // bot is live — reveal after settle
        } else if (value === "CLOSED") {
            this._expanded = false;
        }
    }

    /** Render phase: 'loading' | 'ready'. */
    _phase = "loading";
    /** Whether the greeting + chips panel is shown (vs. the slim bar). */
    _expanded = false;
    /** True once the visitor has sent a starter — softens the heading. */
    _usedOnce = false;
    /** Whether to render the back button (toggled by the runtime). */
    showBackButton = false;

    utterances = UTTERANCES;
    _settleTimer;
    _safetyTimer;
    _onHostFirstBot;

    // ---- render getters --------------------------------------------------
    get isLoading() {
        return this._phase === "loading";
    }
    get showPanel() {
        return this._phase === "ready" && this._expanded;
    }
    get showSuggestionsToggle() {
        return this._phase === "ready";
    }
    get suggestionsToggleIcon() {
        return this._expanded ? "utility:chevronup" : "utility:chevrondown";
    }
    get suggestionsToggleLabel() {
        return this._expanded
            ? "Hide suggested prompts"
            : "Show suggested prompts";
    }
    /** First view shows the big "Hello," greeting; later re-opens are subtle. */
    get isFirstGreeting() {
        return !this._usedOnce;
    }
    /** Auth mode "Auth" = verified user, "UnAuth" = guest. */
    get isAuthenticatedContext() {
        return (
            this.configuration?.embeddedServiceMessagingChannel?.authMode ===
            "Auth"
        );
    }
    /** Show the close (X) button whenever the conversation isn't live. */
    get showCloseButton() {
        return this._conversationStatus && this._conversationStatus !== "OPEN";
    }

    connectedCallback() {
        // Bot / rep joined → bot is live (a beat before its first message).
        assignMessagingEventHandler(MESSAGING_EVENT.PARTICIPANT_JOINED, () =>
            this._scheduleReveal(SETTLE_MS)
        );
        // Runtime asks us to show/hide the back button.
        assignMessagingEventHandler(
            MESSAGING_EVENT.TOGGLE_BACK_BUTTON,
            (data) => {
                this.showBackButton = !!(data && data.showBackButton);
            }
        );
        // Opportunistic: the exact first-bot-message signal is a host-page
        // window event that normally can't cross into this iframe — but if it
        // ever does, reveal instantly (the message is already here, no settle).
        this._onHostFirstBot = () => this._reveal();
        window.addEventListener(HOST_FIRST_BOT_EVENT, this._onHostFirstBot);
        // Never strand the loader.
        this._safetyTimer = setTimeout(() => this._reveal(), SAFETY_MS);
    }

    disconnectedCallback() {
        this._clearTimer("_settleTimer");
        this._clearTimer("_safetyTimer");
        if (this._onHostFirstBot) {
            window.removeEventListener(
                HOST_FIRST_BOT_EVENT,
                this._onHostFirstBot
            );
        }
    }

    // ---- reveal gate -----------------------------------------------------
    _scheduleReveal(delay) {
        if (this._phase !== "loading") return;
        this._clearTimer("_settleTimer");
        this._settleTimer = setTimeout(() => this._reveal(), delay);
    }

    _reveal() {
        this._clearTimer("_settleTimer");
        this._clearTimer("_safetyTimer");
        if (this._phase !== "loading") return;
        this._phase = "ready";
        this._expanded = true;
    }

    _clearTimer(key) {
        if (this[key]) {
            clearTimeout(this[key]);
            this[key] = undefined;
        }
    }

    // ---- interactions ----------------------------------------------------
    onToggleSuggestions() {
        this._expanded = !this._expanded;
    }

    /** A sample-utterance chip was tapped: send it, then collapse the panel. */
    onUtteranceClick(event) {
        const text = event.currentTarget.dataset.text;
        this._usedOnce = true;
        this._expanded = false;
        const util = this.configuration && this.configuration.util;
        if (util && typeof util.sendTextMessage === "function" && text) {
            util.sendTextMessage(text).catch((error) => {
                // eslint-disable-next-line no-console
                console.error("Skywave header: sendTextMessage failed", error);
            });
        }
    }

    onMinimizeClick() {
        dispatchMessagingEvent(MESSAGING_EVENT.MINIMIZE_BUTTON_CLICK, {});
    }

    onCloseClick() {
        dispatchMessagingEvent(MESSAGING_EVENT.CLOSE_CONTAINER, {});
    }

    onBackClick() {
        dispatchMessagingEvent(MESSAGING_EVENT.BACK_BUTTON_CLICK, {});
    }

    /**
     * End the conversation. Verified users end the whole session; guests just
     * close the conversation (mirrors the Salesforce reference header).
     */
    onEndSessionClick() {
        if (
            this.isAuthenticatedContext &&
            this.configuration?.util?.endSession
        ) {
            this.configuration.util.endSession();
        } else {
            dispatchMessagingEvent(MESSAGING_EVENT.CLOSE_CONVERSATION, {});
        }
    }
}
