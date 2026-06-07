// Customer features integrated into the existing Skywave website.
//
// Two responsibilities:
//
//   1. **Always-on identity** — on every page load, after the WebSDK is
//      ready, mints / refreshes the proof cookie via /api/website/session/init.
//      Updates the nav greeting slot if the visitor has a profile.
//      Failure mode is "anonymous" — the page works fine, the visitor
//      just doesn't see their name in the nav.
//
//   2. **Hash-routed customer sections** (#bookings, #profile, #book) —
//      render inline into <section id="customer-area"> between the hero
//      and the rest of the page. When a customer route is active, the
//      surrounding page-promo content (.main with [data-customer-aware])
//      is hidden so the page reads as "you're in your account" — but the
//      hero, nav and footer all stay, so it still feels like the same
//      website.
//
// Phone-demo modal is independent of all of this; it's an overlay layer
// on top.

import { initSession } from './skywave-session.js';

let session = null;
let bookingsCache = null;

const ROUTES = {
    '#book':    renderBook,
    '#bookings': renderBookings,
    '#profile':  renderProfile
};
const BOOKING_RE = /^#booking\/([A-Z0-9]{4,12})$/;

// ---------- nav identity slot ----------

function updateNavIdentity() {
    const slots = document.querySelectorAll('[data-identity-slot]');
    const identified = !!(session?.profileCompleted);
    slots.forEach(slot => {
        slot.querySelectorAll('[data-when="anonymous"]').forEach(el => {
            el.toggleAttribute('hidden', identified);
        });
        slot.querySelectorAll('[data-when="identified"]').forEach(el => {
            el.toggleAttribute('hidden', !identified);
            if (identified) decorateGreeting(el);
        });
    });
}

function decorateGreeting(el) {
    const p = session?.profile || {};
    const avatarSlot = el.querySelector('.nav-greeting-avatar');
    const textSlot = el.querySelector('.nav-greeting-text');
    if (avatarSlot) {
        avatarSlot.innerHTML = '';
        if (p.avatarUrl) {
            const img = document.createElement('img');
            img.src = p.avatarUrl;
            img.alt = '';
            avatarSlot.appendChild(img);
        } else {
            avatarSlot.textContent = initials(p);
        }
    }
    if (textSlot) {
        const name = (p.firstName || '').trim() || 'Member';
        const tier = p.membershipTier || '';
        textSlot.textContent = tier ? `${name} · ${tier}` : name;
    }
}

function initials(p) {
    if (!p) return '?';
    const f = (p.firstName || '').trim()[0] || '';
    const l = ((p.lastName || '').trim() && !/^[A-Za-z0-9_-]{8,64}$/.test((p.lastName || '').trim()))
        ? p.lastName.trim()[0] : '';
    return (f + l).toUpperCase() || '✈';
}

// ---------- routing & render shell ----------

function customerArea() {
    return document.getElementById('customer-area');
}
function customerInner() {
    return customerArea()?.querySelector('.customer-inner');
}
function setCustomerVisible(show) {
    const ca = customerArea();
    if (!ca) return;
    ca.dataset.state = show ? 'open' : 'hidden';
    document.querySelectorAll('[data-customer-aware]').forEach(el => {
        el.toggleAttribute('hidden', show);
    });
    if (show) ca.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function setActiveNav(routeKey) {
    document.querySelectorAll('[data-route]').forEach(el => {
        const r = el.dataset.route;
        el.classList.toggle('active', r === routeKey);
    });
}

function el(tag, props = {}, ...children) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
        if (k === 'class') e.className = v;
        else if (k === 'html') e.innerHTML = v;
        else if (k.startsWith('on') && typeof v === 'function') {
            e.addEventListener(k.slice(2).toLowerCase(), v);
        } else if (v === true) e.setAttribute(k, '');
        else if (v != null && v !== false) e.setAttribute(k, v);
    }
    for (const c of children.flat()) {
        if (c == null || c === false) continue;
        e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return e;
}

function header(title, subtitle) {
    return el('div', { class: 'cust-section-head' },
        el('h2', { class: 'cust-title' }, title),
        subtitle ? el('p', { class: 'cust-sub' }, subtitle) : null
    );
}

function loadingCard() {
    return el('div', { class: 'cust-empty' },
        el('div', { class: 'cust-spinner' }),
        el('p', {}, 'Loading…')
    );
}

function emptyCard(title, body, action) {
    return el('div', { class: 'cust-empty' },
        el('h3', {}, title),
        el('p', {}, body),
        action || null
    );
}

function errorCard(err) {
    return el('div', { class: 'cust-empty error' },
        el('h3', {}, 'Couldn’t load that'),
        el('p', {}, err?.message || 'Try again in a moment'),
        el('button', { class: 'btn-pts cust-btn',
            onclick: () => router() }, 'Retry')
    );
}

function ensureIdentified(action) {
    if (session?.contactId) return true;
    const ca = customerInner();
    if (!ca) return false;
    ca.innerHTML = '';
    ca.appendChild(emptyCard(
        'Sign in to continue',
        'We use a cookie to recognize you across visits. Click below to set it up — no password needed.',
        el('button', {
            class: 'btn-pts cust-btn',
            onclick: async () => {
                ca.innerHTML = '';
                ca.appendChild(loadingCard());
                try {
                    session = await initSession({ force: true });
                    updateNavIdentity();
                    router();
                } catch (e) {
                    ca.innerHTML = '';
                    ca.appendChild(errorCard(e));
                }
            }
        }, 'Sign me in')
    ));
    return false;
}

// ---------- /book (search results page) ----------
//
// Reads the query params off location.hash (#book?origin=...&destination=
// ...&date=...&fareClass=...). The hero search-card form posts to this
// hash, so the URL is shareable and the back button works as expected.

async function renderBook() {
    setActiveNav('#book');
    const ca = customerInner();
    ca.innerHTML = '';

    const params = parseHashParams();
    if (!params.origin || !params.destination || !params.date) {
        ca.appendChild(header('Search flights', 'Use the search box at the top of the page to find a flight.'));
        return;
    }

    ca.appendChild(header(
        `${params.origin} → ${params.destination}`,
        formatDateLong(params.date) + ' · ' + (params.fareClass || 'Economy')
    ));

    const resultsBox = el('div', { class: 'cust-results' });
    resultsBox.appendChild(loadingCard());
    ca.appendChild(resultsBox);

    try {
        const r = await fetch('/api/website/flights/search', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                origin: params.origin.toUpperCase(),
                destination: params.destination.toUpperCase(),
                date: params.date
            })
        });
        const data = await r.json();
        if (!r.ok) throw new Error(data?.error || ('HTTP ' + r.status));
        resultsBox.innerHTML = '';
        if (!data.options?.length) {
            resultsBox.appendChild(emptyCard(
                'No flights match this search',
                'We don’t fly that route on this date. Try a different date or destination.'
            ));
            return;
        }
        const fareClass = params.fareClass || 'Economy';
        data.options.forEach((opt, i) => {
            resultsBox.appendChild(flightOptionCard(opt, fareClass, params.date, i));
        });
    } catch (err) {
        resultsBox.innerHTML = '';
        resultsBox.appendChild(errorCard(err));
    }
}

const FARE_CLASSES = ['Economy', 'Premium Economy', 'Business', 'First'];

function flightOptionCard(opt, defaultFare, travelDate, idx) {
    const card = el('div', { class: 'cust-flight' });
    const fareState = { selected: defaultFare };

    // top: route + times
    card.appendChild(el('div', { class: 'cust-flight-top' },
        el('div', { class: 'cust-segment-side' },
            el('div', { class: 'cust-iata' }, opt.origin || '?'),
            el('div', { class: 'cust-segment-time' }, opt.departure)
        ),
        el('div', { class: 'cust-flight-mid' },
            el('div', { class: 'cust-segment-line' }),
            el('div', { class: 'cust-segment-duration' }, opt.duration),
            opt.stops > 0
                ? el('div', { class: 'cust-segment-meta' },
                    `${opt.stops} stop · ${opt.stopVia}`)
                : el('div', { class: 'cust-segment-meta' }, 'Non-stop'),
            el('div', { class: 'cust-segment-meta' },
                (opt.flightNumbers || []).join(' · ') + ' · ' + (opt.aircraft || ''))
        ),
        el('div', { class: 'cust-segment-side right' },
            el('div', { class: 'cust-iata' }, opt.destination || '?'),
            el('div', { class: 'cust-segment-time' }, opt.arrival)
        )
    ));

    // bottom: fare-class chips + price + book button
    const fareChips = el('div', { class: 'cust-fares' });
    const priceLabel = el('div', { class: 'cust-flight-price' });
    const bookBtn = el('button', {
        class: 'btn-pts cust-btn',
        type: 'button',
        onclick: () => bookFlight(opt, fareState.selected, travelDate, bookBtn, card)
    }, 'Book');

    function refreshSelection() {
        fareChips.querySelectorAll('.cust-fare-chip').forEach(c => {
            c.classList.toggle('active', c.dataset.fare === fareState.selected);
        });
        const fare = opt.fares?.[fareState.selected];
        priceLabel.textContent = fare?.display || 'Unavailable';
        bookBtn.disabled = !fare;
    }

    FARE_CLASSES.forEach(fc => {
        const fare = opt.fares?.[fc];
        const chip = el('button', {
            class: 'cust-fare-chip' + (fare ? '' : ' disabled'),
            type: 'button',
            'data-fare': fc,
            disabled: fare ? false : true,
            onclick: () => { if (fare) { fareState.selected = fc; refreshSelection(); } }
        },
            el('span', { class: 'cust-fare-chip-name' }, fc),
            el('span', { class: 'cust-fare-chip-price' }, fare?.display || '—')
        );
        fareChips.appendChild(chip);
    });

    card.appendChild(el('div', { class: 'cust-flight-bottom' },
        fareChips,
        el('div', { class: 'cust-flight-cta' }, priceLabel, bookBtn)
    ));
    refreshSelection();
    return card;
}

async function bookFlight(opt, fareClass, travelDate, btn, card) {
    if (!session?.contactId) {
        try {
            session = await initSession({ force: true });
            updateNavIdentity();
        } catch (e) {
            alert('Sign-in failed: ' + e.message);
            return;
        }
    }
    btn.disabled = true;
    btn.textContent = 'Booking…';
    try {
        const r = await fetch('/api/website/bookings', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                flightKey: opt.flightKey,
                travelDate: travelDate,
                fareClass: fareClass,
                checkedBags: 0,
                seatPreference: 'No preference'
            })
        });
        const data = await r.json();
        if (!r.ok) throw new Error(data?.error || 'Booking failed');
        bookingsCache = null;  // invalidate
        // Replace the card with a confirmation panel.
        const confirm = el('div', { class: 'cust-booked' },
            el('div', { class: 'cust-booked-icon' }, '✓'),
            el('h3', {}, 'Booking confirmed'),
            el('p', {},
                'Confirmation code ',
                el('strong', {}, data.bookingCode),
                ' · Total ',
                el('strong', {}, data.totalCharged)
            ),
            el('a', { class: 'btn-pts cust-btn', href: '#booking/' + encodeURIComponent(data.bookingCode) },
                'View booking')
        );
        card.replaceWith(confirm);
    } catch (err) {
        btn.disabled = false;
        btn.textContent = 'Book';
        alert('Could not book: ' + err.message);
    }
}

function parseHashParams() {
    const h = location.hash || '';
    const q = h.indexOf('?');
    if (q < 0) return {};
    const out = {};
    new URLSearchParams(h.slice(q + 1)).forEach((v, k) => { out[k] = v; });
    return out;
}

function formatDateLong(d) {
    try {
        const [y, m, day] = d.split('-').map(Number);
        return new Date(Date.UTC(y, m - 1, day)).toLocaleDateString(undefined, {
            weekday: 'long', month: 'long', day: 'numeric', year: 'numeric'
        });
    } catch (_) { return d; }
}

// ---------- /bookings ----------

async function renderBookings() {
    setActiveNav('#bookings');
    const ca = customerInner();
    ca.innerHTML = '';
    ca.appendChild(header('My bookings', 'Your upcoming and pending itineraries.'));
    if (!ensureIdentified()) return;

    const list = el('div', { class: 'cust-bookings' });
    list.appendChild(loadingCard());
    ca.appendChild(list);

    try {
        const data = await fetchBookings();
        list.innerHTML = '';
        if (!data.bookings?.length) {
            list.appendChild(emptyCard(
                'No active bookings yet',
                'Once you book a flight — via the website or the chat assistant — it shows up here.',
                el('a', { class: 'btn-pts cust-btn', href: '#book' }, 'Book a flight')
            ));
            return;
        }
        data.bookings.forEach(b => list.appendChild(bookingCard(b)));
    } catch (err) {
        list.innerHTML = '';
        list.appendChild(errorCard(err));
    }
}

async function fetchBookings() {
    if (bookingsCache) return bookingsCache;
    const r = await fetch('/api/website/bookings', {
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' }
    });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    bookingsCache = await r.json();
    return bookingsCache;
}

function bookingCard(b) {
    const first = b.flights?.[0];
    const last = b.flights?.[b.flights.length - 1];
    return el('a', {
        class: 'cust-booking',
        href: '#booking/' + encodeURIComponent(b.bookingReference)
    },
        el('div', { class: 'cust-booking-head' },
            el('div', {},
                el('div', { class: 'cust-booking-route' },
                    first?.originAirportCode || '?',
                    el('span', { class: 'cust-arrow' }, ' → '),
                    last?.destinationAirportCode || '?'
                ),
                el('div', { class: 'cust-booking-cities' },
                    `${first?.originCity || ''} to ${last?.destinationCity || ''}`)
            ),
            el('div', { class: 'cust-pill', 'data-status': b.status || '' },
                b.status || 'Confirmed')
        ),
        el('div', { class: 'cust-booking-meta' },
            el('span', {}, first?.originDateTime || ''),
            b.fareClass ? el('span', { class: 'cust-pill light' }, b.fareClass) : null,
            el('span', { class: 'cust-pill light' }, '#' + b.bookingReference),
            el('span', { class: 'cust-booking-total' }, b.total)
        )
    );
}

// ---------- /booking/:code ----------

async function renderBookingDetail(code) {
    setActiveNav('#bookings');
    const ca = customerInner();
    ca.innerHTML = '';
    ca.appendChild(el('div', { class: 'cust-section-head' },
        el('a', { class: 'cust-back', href: '#bookings' }, '← All bookings'),
        el('h2', { class: 'cust-title' }, 'Booking ' + code)
    ));
    if (!ensureIdentified()) return;

    const body = el('div', {});
    body.appendChild(loadingCard());
    ca.appendChild(body);

    try {
        const data = await fetchBookings();
        const b = data.bookings.find(x => x.bookingReference === code);
        body.innerHTML = '';
        if (!b) {
            body.appendChild(emptyCard(
                'Booking not found',
                'It may have been cancelled or it’s not associated with your account.',
                el('a', { class: 'btn-pts cust-btn', href: '#bookings' }, 'Back to bookings')
            ));
            return;
        }
        body.appendChild(bookingDetail(b));
    } catch (err) {
        body.innerHTML = '';
        body.appendChild(errorCard(err));
    }
}

function bookingDetail(b) {
    return el('div', { class: 'cust-detail' },
        el('div', { class: 'cust-detail-grid' },
            kv('Fare class', b.fareClass || '—'),
            kv('Total', b.total),
            kv('Baggage', b.checkedBaggageAllowance || '—'),
            kv('Cancellation', b.cancellationConditions || '—'),
            kv('Changes', b.rebookingConditions || '—')
        ),
        el('h3', { class: 'cust-h3' }, 'Itinerary'),
        el('div', { class: 'cust-segments' },
            ...(b.flights || []).map(segmentCard)
        ),
        el('p', { class: 'cust-foot' },
            'Need to make changes? Use the Skywave assistant in the bottom right.')
    );
}

function kv(k, v) {
    return el('div', { class: 'cust-kv' },
        el('span', { class: 'cust-kv-k' }, k),
        el('span', { class: 'cust-kv-v' }, v));
}

function segmentCard(f) {
    return el('div', { class: 'cust-segment' },
        el('div', { class: 'cust-segment-side' },
            el('div', { class: 'cust-iata' }, f.originAirportCode || '?'),
            el('div', { class: 'cust-segment-city' }, f.originCity || ''),
            el('div', { class: 'cust-segment-time' }, f.originDateTime || '')
        ),
        el('div', { class: 'cust-segment-mid' },
            el('div', { class: 'cust-segment-line' }),
            el('div', { class: 'cust-segment-duration' }, f.duration || ''),
            el('div', { class: 'cust-segment-meta' },
                (f.flightNumbers || []).join(' · '))
        ),
        el('div', { class: 'cust-segment-side right' },
            el('div', { class: 'cust-iata' }, f.destinationAirportCode || '?'),
            el('div', { class: 'cust-segment-city' }, f.destinationCity || ''),
            el('div', { class: 'cust-segment-time' }, f.destinationDateTime || '')
        )
    );
}

// ---------- /profile ----------

async function renderProfile() {
    setActiveNav('#profile');
    const ca = customerInner();
    ca.innerHTML = '';
    ca.appendChild(header(
        'Profile',
        'Update the details we use for bookings and rewards.'
    ));
    if (!ensureIdentified()) return;

    const body = el('div', {});
    body.appendChild(loadingCard());
    ca.appendChild(body);

    try {
        const r = await fetch('/api/website/me', { credentials: 'same-origin' });
        if (!r.ok) throw new Error('HTTP ' + r.status);
        const me = await r.json();
        session = me;
        updateNavIdentity();
        body.innerHTML = '';
        body.appendChild(profileForm(me));
    } catch (err) {
        body.innerHTML = '';
        body.appendChild(errorCard(err));
    }
}

function profileForm(me) {
    const p = me.profile || {};
    const placeholderLast = (p.lastName && /^[A-Za-z0-9_-]{8,64}$/.test(p.lastName)) ? '' : (p.lastName || '');
    const form = el('form', { class: 'cust-form', onsubmit: (e) => e.preventDefault() },
        el('div', { class: 'cust-form-grid' },
            field('First name',  el('input', { type: 'text', name: 'firstName', value: p.firstName || '', required: true, minlength: 2 })),
            field('Last name',   el('input', { type: 'text', name: 'lastName', value: placeholderLast, required: true, minlength: 2 })),
            field('Email',       el('input', { type: 'email', name: 'email', value: p.email || '', required: true })),
            field('Phone',       el('input', { type: 'tel', name: 'phone', value: p.phone || '' })),
            readonlyField('Home airport', p.homeAirport || 'Will be set on first booking'),
            readonlyField('Membership', `${p.membershipTier || 'Basic'}${p.memberNumber ? ' · #' + p.memberNumber : ''}${p.loyaltyPoints != null ? ' · ' + p.loyaltyPoints.toLocaleString() + ' pts' : ''}`)
        ),
        el('div', { class: 'cust-form-actions' },
            el('button', {
                type: 'submit', class: 'btn-pts cust-btn',
                onclick: (e) => submitProfile(e, form)
            }, me.profileCompleted ? 'Save changes' : 'Save profile'),
            el('span', { class: 'cust-status', id: 'cust-profile-status' })
        )
    );
    return form;
}

function field(label, input) {
    return el('label', { class: 'cust-field' },
        el('span', { class: 'cust-label' }, label),
        input
    );
}
function readonlyField(label, value) {
    return el('div', { class: 'cust-field readonly' },
        el('span', { class: 'cust-label' }, label),
        el('span', { class: 'cust-readonly-val' }, value)
    );
}

async function submitProfile(ev, form) {
    ev.preventDefault();
    const fd = new FormData(form);
    const status = document.getElementById('cust-profile-status');
    status.textContent = 'Saving…';
    status.className = 'cust-status';
    try {
        const r = await fetch('/api/website/profile', {
            method: 'PUT',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                firstName: (fd.get('firstName') || '').toString().trim(),
                lastName:  (fd.get('lastName') || '').toString().trim(),
                email:     (fd.get('email') || '').toString().trim(),
                phone:     (fd.get('phone') || '').toString().trim() || undefined
            })
        });
        const data = await r.json();
        if (!r.ok) throw new Error(data?.issues?.[0]?.message || data.error || ('HTTP ' + r.status));
        status.textContent = 'Saved';
        status.className = 'cust-status ok';
        // Refresh in-memory session so nav greeting updates.
        const me = await (await fetch('/api/website/me', { credentials: 'same-origin' })).json();
        session = me;
        updateNavIdentity();
    } catch (err) {
        status.textContent = err.message;
        status.className = 'cust-status err';
    }
}

// ---------- router ----------

function currentRouteKey() {
    const h = location.hash || '';
    const base = h.split('?')[0];
    if (base === '#book' || base === '#bookings' || base === '#profile') return base;
    if (BOOKING_RE.test(base)) return '#bookings';
    return '';
}

function router() {
    const h = location.hash || '';
    const base = h.split('?')[0];
    const renderer = ROUTES[base];
    if (renderer) {
        setCustomerVisible(true);
        renderer();
        return;
    }
    const m = base.match(BOOKING_RE);
    if (m) {
        setCustomerVisible(true);
        renderBookingDetail(m[1]);
        return;
    }
    // No customer route — keep customer area hidden, show normal page.
    setCustomerVisible(false);
    setActiveNav('');
}

// ---------- bootstrap ----------

function wireNavInteractions() {
    document.addEventListener('click', (e) => {
        const t = e.target.closest('[data-route]');
        if (t) {
            e.preventDefault();
            location.hash = t.dataset.route;
            return;
        }
        const signin = e.target.closest('[data-action="signin"]');
        if (signin) {
            e.preventDefault();
            location.hash = '#profile';
        }
    });
    // Hero search form: prefill date if blank, submit -> #book?... route.
    document.addEventListener('submit', (e) => {
        const form = e.target.closest('[data-search-form]');
        if (!form) return;
        e.preventDefault();
        const originField = form.querySelector('input[name="origin"]');
        const destField = form.querySelector('input[name="destination"]');
        // Prefer the canonical IATA stamped on the input by the
        // autocomplete picker; fall back to extracting a 3-letter code
        // from the visible text if the user typed it themselves
        // ("(SEA)" or just "SEA").
        const origin = resolveAirportInput(originField);
        const destination = resolveAirportInput(destField);
        const fd = new FormData(form);
        const date = (fd.get('date') || '').toString().trim();
        const fareClass = (fd.get('fareClass') || 'Economy').toString();
        if (!origin || !destination || !date) {
            alert('Pick an origin, a destination, and a date.');
            return;
        }
        const params = new URLSearchParams({ origin, destination, date, fareClass });
        location.hash = '#book?' + params.toString();
    });
    // Default date prefill on render.
    document.addEventListener('DOMContentLoaded', prefillSearchDefaults);
    setTimeout(prefillSearchDefaults, 0);  // also run if DOMContentLoaded already fired
    window.addEventListener('hashchange', router);
}

function prefillSearchDefaults() {
    const dateField = document.querySelector('[data-search-form] input[name="date"]');
    if (dateField && !dateField.value) {
        const d = new Date();
        d.setDate(d.getDate() + 14);
        dateField.value = d.toISOString().slice(0, 10);
    }
    // Wire the origin/destination inputs for autocomplete. Loads the
    // airport list lazily on first focus so we don't pay for it on
    // pages where the visitor never opens the search form.
    document.querySelectorAll('[data-search-form] input[name="origin"], [data-search-form] input[name="destination"]')
        .forEach(input => attachAirportAutocomplete(input));
}

function resolveAirportInput(input) {
    if (!input) return null;
    if (input.dataset.iata) return input.dataset.iata.toUpperCase();
    const v = (input.value || '').trim();
    // Accept "City (CODE)" or bare "CODE" the user typed manually.
    const paren = v.match(/\(([A-Z]{3})\)$/i);
    if (paren) return paren[1].toUpperCase();
    if (/^[A-Za-z]{3}$/.test(v)) return v.toUpperCase();
    return null;
}

// ---------- airport autocomplete ----------
//
// Two parallel filters: matches anything whose city OR code starts with
// (or contains) the typed string. Display is "City (CODE)". Keyboard
// navigation (↑/↓/Enter/Esc) plus mouse click. Selecting an option fills
// the input with "City (CODE)" and stores the IATA on the input's
// dataset so the form submit reads the canonical code, not whatever
// the user typed.

let airportListPromise = null;

function loadAirports() {
    if (!airportListPromise) {
        airportListPromise = fetch('/api/website/airports', { credentials: 'same-origin' })
            .then(r => r.ok ? r.json() : { airports: [] })
            .then(d => d.airports || [])
            .catch(() => []);
    }
    return airportListPromise;
}

function attachAirportAutocomplete(input) {
    if (input.dataset.acAttached === '1') return;
    input.dataset.acAttached = '1';
    input.setAttribute('autocomplete', 'off');
    input.setAttribute('spellcheck', 'false');

    let airports = [];
    let menu = null;
    let activeIdx = -1;
    let currentMatches = [];

    loadAirports().then(list => { airports = list; });

    function ensureMenu() {
        if (menu) return menu;
        menu = document.createElement('div');
        menu.className = 'cust-ac-menu';
        // Position relative to the parent .s-field so we ride along even
        // when the page reflows.
        const wrap = input.closest('.s-field') || input.parentElement;
        wrap.style.position = 'relative';
        wrap.appendChild(menu);
        return menu;
    }

    function closeMenu() {
        if (menu) menu.style.display = 'none';
        activeIdx = -1;
    }

    function filter(q) {
        q = (q || '').trim().toLowerCase();
        if (!q) return airports.slice(0, 8);
        // Two parallel filters: code starts-with, or city contains.
        // Code-startsWith ranks higher (so typing "S" → SEA, SFO, SIN, SYD
        // bubble above "Singapore" / "Sydney" matches).
        const codeMatches = airports.filter(a => a.code.toLowerCase().startsWith(q));
        const cityMatches = airports.filter(a =>
            a.city.toLowerCase().includes(q) && !codeMatches.includes(a)
        );
        return codeMatches.concat(cityMatches).slice(0, 8);
    }

    function render(matches) {
        const m = ensureMenu();
        m.innerHTML = '';
        if (!matches.length) { closeMenu(); return; }
        m.style.display = '';
        matches.forEach((a, i) => {
            const opt = document.createElement('div');
            opt.className = 'cust-ac-opt' + (i === activeIdx ? ' active' : '');
            opt.dataset.code = a.code;
            opt.innerHTML = `<span class="cust-ac-city">${a.city}</span>` +
                `<span class="cust-ac-code">${a.code}</span>`;
            opt.addEventListener('mousedown', (e) => {
                e.preventDefault();  // prevent input blur before click registers
                pick(a);
            });
            m.appendChild(opt);
        });
        currentMatches = matches;
    }

    function pick(a) {
        input.value = `${a.city} (${a.code})`;
        input.dataset.iata = a.code;
        closeMenu();
    }

    input.addEventListener('focus', () => {
        render(filter(input.value));
    });
    input.addEventListener('input', () => {
        delete input.dataset.iata;  // user is typing — clear committed selection
        activeIdx = -1;
        render(filter(input.value));
    });
    input.addEventListener('blur', () => {
        // Delay so click on a menu option fires first.
        setTimeout(closeMenu, 120);
    });
    input.addEventListener('keydown', (e) => {
        if (!menu || menu.style.display === 'none') return;
        if (e.key === 'ArrowDown') {
            e.preventDefault();
            activeIdx = Math.min(currentMatches.length - 1, activeIdx + 1);
            render(currentMatches);
        } else if (e.key === 'ArrowUp') {
            e.preventDefault();
            activeIdx = Math.max(0, activeIdx - 1);
            render(currentMatches);
        } else if (e.key === 'Enter') {
            if (activeIdx >= 0 && currentMatches[activeIdx]) {
                e.preventDefault();
                pick(currentMatches[activeIdx]);
            }
        } else if (e.key === 'Escape') {
            closeMenu();
        }
    });
}

export async function startCustomer() {
    wireNavInteractions();
    router();   // if landed on a deep link, render immediately (will show
                // sign-in card if identity isn't ready yet)
    try {
        session = await initSession();
        updateNavIdentity();
        // Re-run router in case the active route was waiting on identity
        // (e.g. landed on #/bookings with no session).
        if (currentRouteKey()) router();
    } catch (e) {
        console.warn('[skywave-customer] identity init failed', e);
    }
}
