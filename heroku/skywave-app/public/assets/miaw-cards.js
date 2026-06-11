// miaw-cards.js — standalone plain-DOM renderers for the flight, payment
// and profile CLT cards (ports of the skywave*Renderer LWCs). All share the
// primitives in miaw-cards.css. The seatmap lives in miaw-seatmap.js.
//
// Each renderer takes (container, payloadJSON, handlers) and matches its
// LWC counterpart's markup, data-shaping and behavior. Cards that mutate
// data (payment, profile) hand the action up to the UI layer (which routes
// through the proof-cookie'd Heroku->Apex path), then the UI cues the agent.

// ============================ FLIGHT OPTIONS ============================
// Cue-only: clicking Book just sends "Book flight <number>" to the agent,
// which drives the booking. No direct write (mirrors the LWC).
// options: { done } — done=true renders the options read-only (a card
// replayed from the transcript on reload); the Book buttons are disabled so
// a re-tap can't re-send the booking cue.
export function renderFlightCard(container, flightsJSON, handlers, options = {}) {
    let parsed;
    try { parsed = typeof flightsJSON === 'string' ? JSON.parse(flightsJSON) : flightsJSON; }
    catch (e) { container.innerHTML = '<p class="sw-error">Error loading flight options</p>'; return; }
    if (parsed?.error) { container.innerHTML = `<p class="sw-error">${parsed.error}</p>`; return; }

    const fareClass = parsed?.fareClass ?? '';
    const fmtDur = (min) => (min == null ? '' : `${Math.floor(min / 60)}h ${min % 60}m`);
    const flights = (parsed?.flights ?? []).map((f, idx) => ({
        ...f,
        key: f.flightId ?? `${f.flightNumber}-${idx}`,
        durationLabel: fmtDur(f.duration),
        fareClass: f.fareClass ?? fareClass
    }));

    container.innerHTML = `<div class="sw-flight-list">${flights.map((f) => `
        <article class="sw-flight-card">
            <div class="sw-flight-route">
                <div class="sw-flight-endpoint">
                    <span class="sw-flight-time">${f.departureTime ?? ''}</span>
                    <span class="sw-flight-airport">${f.startingAirport ?? ''}</span>
                </div>
                <div class="sw-flight-connector"><span class="sw-flight-connector__label">${f.stopovers ?? ''}</span></div>
                <div class="sw-flight-endpoint sw-flight-endpoint_arrival">
                    <span class="sw-flight-time">${f.arrivalTime ?? ''}</span>
                    <span class="sw-flight-airport">${f.arrivingAirport ?? ''}</span>
                </div>
            </div>
            <div class="sw-flight-meta">
                <span class="sw-flight-meta__item"><span class="sw-flight-meta__icon">⏱</span>${f.durationLabel}</span>
                <span class="sw-flight-meta__item"><span class="sw-flight-meta__icon">✈</span>${f.flightNumber ?? ''} · ${f.aircraft ?? ''}</span>
            </div>
            <footer class="sw-flight-card__footer">
                <div class="sw-flight-card__pricing">
                    <span class="sw-fare-chip">${f.fareClass ?? ''}</span>
                    <span class="sw-flight-price">${f.price ?? ''}</span>
                </div>
                <button type="button" class="sw-btn sw-btn_teal sw-book-button" data-flightnumber="${f.flightNumber ?? ''}"${options.done ? ' disabled' : ''}>Book</button>
            </footer>
        </article>`).join('')}</div>`;

    // Replayed-from-transcript cards are read-only — don't wire the cue.
    if (options.done) return;
    container.querySelectorAll('.sw-book-button').forEach((btn) => {
        btn.addEventListener('click', () => {
            handlers.onBook?.(btn.dataset.flightnumber);
        });
    });
}

// ============================ PAYMENT ============================
// Demo Pay performs the charge through the UI layer (Heroku->Apex), plays
// the 3s animation, shows in-card success, then cues "Payment completed".
const PAY_ANIMATION_MS = 3000;
// options: { done } — done=true renders the final "Payment completed" state
// (a card replayed from the transcript on reload); no pay buttons, so a
// re-tap can't re-charge. We assume the payment succeeded.
export function renderPaymentCard(container, paymentStateJSON, handlers, options = {}) {
    let parsed;
    try { parsed = typeof paymentStateJSON === 'string' ? JSON.parse(paymentStateJSON) : paymentStateJSON; }
    catch (e) { container.innerHTML = '<p class="sw-error">Could not load payment form.</p>'; return; }

    const state = {
        bookingCode: parsed.bookingCode || '',
        totalCharged: parsed.totalCharged || '',
        view: options.done ? 'completed' : undefined, notice: '', error: ''
    };

    function paint() {
        if (state.view === 'processing') {
            container.innerHTML = `
                <div class="sw-anim">
                    <div class="sw-anim__sky"><span class="sw-anim__plane" aria-label="airplane">✈</span></div>
                    <div class="sw-anim__caption">Processing payment…</div>
                </div>`;
            return;
        }
        if (state.view === 'completed') {
            container.innerHTML = `
                <div class="sw-success">
                    <span class="sw-success__icon">✓</span>
                    <div>
                        <div class="sw-success__title">Payment completed</div>
                        <div class="sw-success__sub">Booking ${state.bookingCode} · ${state.totalCharged}</div>
                    </div>
                </div>`;
            return;
        }
        container.innerHTML = `
            <article class="sw-card">
                <header class="sw-card__header">
                    <h3 class="sw-card__title">How would you like to pay?</h3>
                    <p class="sw-card__sub">Booking <strong>${state.bookingCode}</strong> · <strong>${state.totalCharged}</strong></p>
                </header>
                <div class="sw-pay-options">
                    <button type="button" class="sw-btn sw-pay-btn sw-pay-btn_apple" data-act="apple"><span class="sw-pay-btn__icon"></span><span> Pay</span></button>
                    <button type="button" class="sw-btn sw-pay-btn sw-pay-btn_card" data-act="card"><span class="sw-pay-btn__icon">💳</span><span>Credit card</span></button>
                    <button type="button" class="sw-btn sw-btn_gold sw-pay-btn" data-act="demo"><span class="sw-pay-btn__icon">★</span><span>Demo Pay</span></button>
                </div>
                ${state.notice ? `<p class="sw-notice">${state.notice}</p>` : ''}
                ${state.error ? `<p class="sw-error">${state.error}</p>` : ''}
            </article>`;

        const demoNotice = (m) => { state.notice = `${m} is demo-only — please use Demo Pay to complete.`; paint(); };
        container.querySelector('[data-act="apple"]').addEventListener('click', () => demoNotice('Apple Pay'));
        container.querySelector('[data-act="card"]').addEventListener('click', () => demoNotice('Credit card'));
        container.querySelector('[data-act="demo"]').addEventListener('click', () => {
            if (state.view) return;
            state.error = ''; state.notice = '';
            state.view = 'processing'; paint();
            // Run the charge + the animation timer in parallel, but DON'T cue
            // the agent until BOTH resolve — onPay performs ONLY the charge
            // (no cue); the cue is sent here, after Promise.all, so the agent's
            // confirm_booking never runs before the card shows completed.
            const timer = new Promise((r) => setTimeout(r, PAY_ANIMATION_MS));
            const pay = Promise.resolve(handlers.onPay?.({ bookingCode: state.bookingCode }));
            Promise.all([timer, pay])
                .then(() => { state.view = 'completed'; paint(); handlers.onComplete?.(); })
                .catch(() => { state.view = undefined; state.error = 'Payment failed.'; paint(); });
        });
    }
    paint();
}

// ============================ PROFILE FORM ============================
// Validates + (optionally) resizes an avatar in-browser, saves through the
// UI layer (Heroku->Apex), then cues "Profile created".
const AVATAR_OUTPUT_SIZE = 512;
const AVATAR_OUTPUT_QUALITY = 0.5;
const MAX_AVATAR_BYTES = 20 * 1024 * 1024;

// options: { done } — done=true renders the final "Profile saved" state (a
// card replayed from the transcript on reload); no form, so a re-submit can't
// re-save. We assume the save succeeded.
export function renderProfileCard(container, formStateJSON, handlers, options = {}) {
    let parsed;
    try { parsed = typeof formStateJSON === 'string' ? JSON.parse(formStateJSON) : formStateJSON; }
    catch (e) { container.innerHTML = '<p class="sw-error">Could not load profile form.</p>'; return; }

    const state = {
        firstName: parsed.firstName || '', lastName: parsed.lastName || '',
        email: parsed.email || '', phone: parsed.phone || '', consent: false,
        avatarBase64: '', avatarFileName: '', avatarPreview: '',
        submitting: false, submitted: options.done === true, error: ''
    };

    const isValid = () =>
        state.firstName.trim().length >= 2 &&
        state.lastName.trim().length >= 2 &&
        state.email.includes('@') &&
        state.consent === true && !state.submitting;

    function resizeAvatar(img) {
        const canvas = document.createElement('canvas');
        canvas.width = AVATAR_OUTPUT_SIZE; canvas.height = AVATAR_OUTPUT_SIZE;
        const ctx = canvas.getContext('2d');
        const shortSide = Math.min(img.width, img.height);
        const sx = (img.width - shortSide) / 2, sy = (img.height - shortSide) / 2;
        ctx.drawImage(img, sx, sy, shortSide, shortSide, 0, 0, AVATAR_OUTPUT_SIZE, AVATAR_OUTPUT_SIZE);
        return canvas.toDataURL('image/jpeg', AVATAR_OUTPUT_QUALITY);
    }

    function paint() {
        if (state.submitted) {
            container.innerHTML = `<div class="sw-success"><span class="sw-success__icon">✓</span><span>Profile saved.</span></div>`;
            return;
        }
        const avatarStyle = state.avatarPreview ? ` style="background-image:url(${state.avatarPreview})"` : '';
        container.innerHTML = `
            <article class="sw-card">
                <header class="sw-card__header">
                    <h3 class="sw-card__title">Almost there — your details</h3>
                    <p class="sw-card__sub">Skywave needs a few details to confirm your booking.</p>
                </header>
                <div class="sw-form-row sw-form-row_avatar">
                    <label class="sw-avatar"${avatarStyle}>
                        ${state.avatarPreview ? '<span class="sw-avatar__hint">Tap to retake</span>'
                            : '<span class="sw-avatar__icon">📷</span><span class="sw-avatar__hint">Add a photo</span>'}
                        <input type="file" accept="image/*" capture="user" class="sw-avatar__file" data-field="avatar" />
                    </label>
                </div>
                <div class="sw-form-row">
                    <label class="sw-label" for="sw-fn">First name</label>
                    <input id="sw-fn" class="sw-input" type="text" value="${esc(state.firstName)}" data-field="firstName" autocomplete="given-name" />
                </div>
                <div class="sw-form-row">
                    <label class="sw-label" for="sw-ln">Last name</label>
                    <input id="sw-ln" class="sw-input" type="text" value="${esc(state.lastName)}" data-field="lastName" autocomplete="family-name" />
                </div>
                <div class="sw-form-row">
                    <label class="sw-label" for="sw-em">Email</label>
                    <input id="sw-em" class="sw-input" type="email" value="${esc(state.email)}" data-field="email" autocomplete="email" />
                </div>
                <div class="sw-form-row">
                    <label class="sw-label" for="sw-ph">Phone</label>
                    <input id="sw-ph" class="sw-input" type="tel" value="${esc(state.phone)}" data-field="phone" autocomplete="tel" />
                </div>
                <label class="sw-form-consent">
                    <input type="checkbox" data-field="consent"${state.consent ? ' checked' : ''} />
                    <span>I consent to receive booking-related communication via email.</span>
                </label>
                ${state.error ? `<p class="sw-error">${state.error}</p>` : ''}
                <button type="button" class="sw-btn sw-btn_teal sw-form-submit" data-act="submit"${isValid() ? '' : ' disabled'}>
                    ${state.submitting ? 'Saving…' : 'Save and continue'}
                </button>
            </article>`;

        container.querySelectorAll('[data-field]').forEach((inp) => {
            const field = inp.dataset.field;
            if (field === 'avatar') {
                inp.addEventListener('change', (e) => onAvatar(e));
            } else if (field === 'consent') {
                inp.addEventListener('change', () => { state.consent = inp.checked; refreshSubmit(); });
            } else {
                inp.addEventListener('input', () => { state[field] = inp.value; refreshSubmit(); });
            }
        });
        container.querySelector('[data-act="submit"]').addEventListener('click', submit);
    }

    // Lightweight submit-button enable/disable without full repaint (so we
    // don't drop focus while typing).
    function refreshSubmit() {
        const btn = container.querySelector('[data-act="submit"]');
        if (btn) btn.disabled = !isValid();
    }

    function onAvatar(event) {
        const file = event.target.files && event.target.files[0];
        if (!file) return;
        if (file.size > MAX_AVATAR_BYTES) { state.error = 'Avatar file too large.'; paint(); return; }
        const reader = new FileReader();
        reader.onload = () => {
            const img = new Image();
            img.onload = () => {
                const resized = resizeAvatar(img);
                state.avatarBase64 = resized; state.avatarPreview = resized;
                state.avatarFileName = (file.name || 'avatar') + '.jpg';
                paint();
            };
            img.onerror = () => { state.error = 'Could not decode image.'; paint(); };
            img.src = reader.result;
        };
        reader.onerror = () => { state.error = 'Could not read image.'; paint(); };
        reader.readAsDataURL(file);
    }

    function submit() {
        if (!isValid()) return;
        state.submitting = true; state.error = ''; paint();
        Promise.resolve(handlers.onSave?.({
            firstName: state.firstName, lastName: state.lastName,
            email: state.email, phone: state.phone,
            avatarBase64: state.avatarBase64, avatarFileName: state.avatarFileName
        }))
            // Cue the agent only AFTER the save resolves and the success state
            // is shown — never before (consistent with seat/payment).
            .then(() => { state.submitting = false; state.submitted = true; paint(); handlers.onComplete?.(); })
            .catch(() => { state.submitting = false; state.error = 'Profile save failed.'; paint(); });
    }

    paint();
}

// Escape attribute values so prefilled name/email can't break the markup.
function esc(s) {
    return String(s ?? '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
}
