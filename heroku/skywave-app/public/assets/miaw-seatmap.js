// miaw-seatmap.js — standalone port of skywaveSeatMapRenderer (LWC) for the
// custom chat client. Same markup, data-shaping and dark-card look, but
// plain DOM. Uses the SHARED primitives in miaw-cards.css (.sw-card,
// .sw-btn, .sw-success, .sw-aborted, .sw-anim) plus seatmap-specific classes.
// Consumes the seatMapJSON exactly as it arrives over the MIAW REST API.
//
// Seat-confirm does NOT call Apex here — it hands the selection up to the UI
// layer (onConfirm), which routes the change through the host app's
// Heroku->Apex path, then cues the agent with "seat change confirmed".

const ANIMATION_MS = 1600;  // matches the LWC airplane animation timing

function decorateSeat(s, selectedSeat, frozen) {
    const isSelected = s.code === selectedSeat;
    const isTaken = s.status === 'taken';
    const isCurrent = s.status === 'current';
    let cls = 'sw-seat';
    if (isTaken) cls += ' sw-seat_taken';
    else if (isSelected) cls += ' sw-seat_selected';
    else if (isCurrent) cls += ' sw-seat_current';
    else cls += ' sw-seat_available';
    return { code: s.code, status: s.status, cssClass: cls, disabled: isTaken || frozen };
}

// container: the .miaw-card element to render into.
// seatMapJSON: stringified payload from the action output.
// handlers: { onConfirm(selection), onAbort() }
export function renderSeatMapCard(container, seatMapJSON, handlers) {
    let parsed;
    try { parsed = typeof seatMapJSON === 'string' ? JSON.parse(seatMapJSON) : seatMapJSON; }
    catch (e) { container.innerHTML = '<p class="sw-error">Could not load the seat map.</p>'; return; }

    const state = {
        bookingSegmentId: parsed.bookingSegmentId || '',
        bookingCode: parsed.bookingCode || '',
        flightNumber: parsed.flightNumber || '',
        currentSeat: (parsed.currentSeat || '').toUpperCase(),
        selectedSeat: (parsed.currentSeat || '').toUpperCase(),
        rows: parsed.rows || [],
        frozen: false,
        error: ''
    };

    const headerSub = [state.flightNumber && `Flight ${state.flightNumber}`,
        state.bookingCode && `Booking ${state.bookingCode}`,
        state.currentSeat && `Current seat ${state.currentSeat}`]
        .filter(Boolean).join(' · ');

    function paint() {
        if (state.view === 'processing') {
            container.innerHTML = `
                <div class="sw-anim">
                    <div class="sw-anim__sky"><span class="sw-anim__plane" aria-label="airplane">✈</span></div>
                    <div class="sw-anim__caption">Changing your seat…</div>
                </div>`;
            return;
        }
        if (state.view === 'completed') {
            container.innerHTML = `
                <div class="sw-success">
                    <span class="sw-success__icon">✓</span>
                    <div>
                        <div class="sw-success__title">Seat change confirmed</div>
                        <div class="sw-success__sub">Booking ${state.bookingCode} · Flight ${state.flightNumber} · Seat ${state.selectedSeat}</div>
                    </div>
                </div>`;
            return;
        }
        if (state.view === 'aborted') {
            container.innerHTML = `
                <div class="sw-aborted">
                    <span class="sw-aborted__icon">✕</span>
                    <div class="sw-aborted__title">Seat change aborted</div>
                </div>`;
            return;
        }

        const rowsHtml = state.rows.map((r) => {
            const seats = (r.seats || []).map((s) => {
                const d = decorateSeat(s, state.selectedSeat, state.frozen);
                return `<button type="button" class="${d.cssClass}" data-code="${d.code}" data-status="${d.status}"${d.disabled ? ' disabled' : ''}>${d.code}</button>`;
            }).join('');
            return `<div class="sw-seat-row"><span class="sw-seat-row__num">${r.row}</span>${seats}</div>`;
        }).join('');

        const selectionLabel = state.selectedSeat
            ? (state.selectedSeat === state.currentSeat ? `Current seat: ${state.selectedSeat}` : `New seat: ${state.selectedSeat}`)
            : 'Pick a seat';

        container.innerHTML = `
            <article class="sw-card">
                <header class="sw-card__header">
                    <h3 class="sw-card__title">Choose your seat</h3>
                    <p class="sw-card__sub">${headerSub}</p>
                </header>
                <div class="sw-seat-cabin">${rowsHtml}</div>
                <div class="sw-seat-legend">
                    <span class="sw-seat-legend__item"><span class="sw-seat-swatch sw-seat-swatch_available"></span>Available</span>
                    <span class="sw-seat-legend__item"><span class="sw-seat-swatch sw-seat-swatch_selected"></span>Selected</span>
                    <span class="sw-seat-legend__item"><span class="sw-seat-swatch sw-seat-swatch_taken"></span>Taken</span>
                </div>
                <p class="sw-seat-selection">${selectionLabel}</p>
                ${state.error ? `<p class="sw-error">${state.error}</p>` : ''}
                <div class="sw-seat-actions">
                    <button type="button" class="sw-btn sw-btn_ghost" data-act="abort">Abort</button>
                    <button type="button" class="sw-btn sw-btn_teal" data-act="confirm"${(!state.selectedSeat || state.selectedSeat === state.currentSeat) ? ' disabled' : ''}>Confirm seat</button>
                </div>
            </article>`;

        container.querySelectorAll('.sw-seat').forEach((btn) => {
            btn.addEventListener('click', () => {
                if (state.frozen || btn.dataset.status === 'taken') return;
                state.selectedSeat = btn.dataset.code;
                state.error = '';
                paint();
            });
        });
        container.querySelector('[data-act="abort"]').addEventListener('click', () => {
            state.view = 'aborted'; paint();
            handlers.onAbort?.();
        });
        container.querySelector('[data-act="confirm"]').addEventListener('click', () => {
            if (!state.selectedSeat || state.selectedSeat === state.currentSeat) {
                state.error = 'Please pick a different seat first.'; paint(); return;
            }
            state.frozen = true;
            state.view = 'processing';
            paint();
            // onConfirm performs ONLY the seat change (no cue). The agent cue
            // fires from onComplete — after BOTH the change and the animation
            // finish — so the agent never verifies while the card is still
            // "Changing your seat…" (same early-cue race as payment).
            const timer = new Promise((r) => setTimeout(r, ANIMATION_MS));
            const confirm = Promise.resolve(handlers.onConfirm?.({
                bookingSegmentId: state.bookingSegmentId,
                newSeatNumber: state.selectedSeat,
                bookingCode: state.bookingCode,
                flightNumber: state.flightNumber
            }));
            Promise.all([timer, confirm])
                .then(() => { state.view = 'completed'; paint(); handlers.onComplete?.(); })
                .catch(() => { state.view = undefined; state.frozen = false; state.error = 'Could not change the seat.'; paint(); });
        });
    }

    paint();
}
