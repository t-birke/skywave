// Customer area: hash-routed pages that overlay the website backdrop.
//
// Routes:
//   #/profile          -- view + edit Contact (firstName, lastName, email, phone)
//   #/bookings         -- list of active bookings, links to detail
//   #/booking/:code    -- single-booking detail (segments, seat, fare class, etc.)
//
// Identity comes from the Heroku-side proof cookie. The website's WebSDK
// cookie stays untouched. On any 401 we re-init the session (cookie may
// have expired); on persistent 401 we degrade to "sign in to see this".
//
// All rendering is plain DOM (matching the existing site.js style — no
// frameworks). The container element is a sibling of the existing hero;
// when an account route is active we hide the hero and show the panel.

import { initSession, getSession, api } from './skywave-session.js';

const ROOT_ID = 'site-root';
const PANEL_ID = 'skywave-account-panel';

const ROUTES = {
    '/profile': renderProfile,
    '/bookings': renderBookings
};
const BOOKING_RE = /^\/booking\/([A-Z0-9]{4,12})$/;

let currentSession = null;

function el(tag, props = {}, ...children) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
        if (k === 'class') e.className = v;
        else if (k === 'html') e.innerHTML = v;
        else if (k.startsWith('on') && typeof v === 'function') {
            e.addEventListener(k.slice(2).toLowerCase(), v);
        } else if (v !== false && v != null) {
            e.setAttribute(k, v);
        }
    }
    for (const c of children.flat()) {
        if (c == null || c === false) continue;
        e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return e;
}

function getPanel() {
    let panel = document.getElementById(PANEL_ID);
    if (!panel) {
        panel = el('section', { id: PANEL_ID, class: 'sw-account-panel' });
        const root = document.getElementById(ROOT_ID);
        const hero = root?.querySelector('.hero');
        if (hero) {
            hero.parentNode.insertBefore(panel, hero.nextSibling);
        } else {
            (root || document.body).appendChild(panel);
        }
    }
    return panel;
}

function showPanel(show) {
    const root = document.getElementById(ROOT_ID);
    const hero = root?.querySelector('.hero');
    const main = root?.querySelector('.main');
    const panel = document.getElementById(PANEL_ID);
    if (hero) hero.style.display = show ? 'none' : '';
    if (main) main.style.display = show ? 'none' : '';
    if (panel) panel.style.display = show ? '' : 'none';
}

function setActiveNav(label) {
    document.querySelectorAll('.nav .nav-links a, .mobile-nav-drawer .mob-nav-links a')
        .forEach(a => a.classList.toggle('active', a.textContent.trim() === label));
}

function loading() {
    return el('div', { class: 'sw-acct-loading' },
        el('div', { class: 'sw-acct-spinner' }),
        el('p', {}, 'Loading…')
    );
}

function header(title, subtitle) {
    return el('header', { class: 'sw-acct-header' },
        el('h1', {}, title),
        subtitle ? el('p', {}, subtitle) : null
    );
}

function pageShell(title, subtitle) {
    const panel = getPanel();
    panel.innerHTML = '';
    panel.appendChild(el('div', { class: 'sw-acct-shell' },
        sidebar(),
        el('div', { class: 'sw-acct-main' },
            header(title, subtitle),
            el('div', { class: 'sw-acct-body', id: 'sw-acct-body' }, loading())
        )
    ));
    return panel.querySelector('#sw-acct-body');
}

function sidebar() {
    const route = (location.hash || '#/profile').slice(1);
    function link(href, label) {
        const a = el('a', {
            href: '#' + href,
            class: 'sw-acct-nav-link' + (route === href || (href === '/bookings' && route.startsWith('/booking')) ? ' active' : '')
        }, label);
        return a;
    }
    return el('aside', { class: 'sw-acct-sidebar' },
        el('div', { class: 'sw-acct-greeting' },
            el('div', { class: 'sw-acct-avatar' },
                currentSession?.profile?.avatarUrl
                    ? el('img', { src: currentSession.profile.avatarUrl, alt: '' })
                    : el('span', {}, initials(currentSession?.profile))
            ),
            el('div', {},
                el('div', { class: 'sw-acct-name' },
                    fullName(currentSession?.profile) || 'Guest'),
                el('div', { class: 'sw-acct-tier' },
                    currentSession?.profile?.membershipTier || 'No tier yet')
            )
        ),
        el('nav', { class: 'sw-acct-nav' },
            link('/profile', 'Profile'),
            link('/bookings', 'My bookings')
        )
    );
}

function initials(p) {
    if (!p) return '?';
    const f = (p.firstName || '').trim()[0] || '';
    const l = (p.lastName || '').trim()[0] || '';
    return (f + l).toUpperCase() || '?';
}

function fullName(p) {
    if (!p) return '';
    const f = (p.firstName || '').trim();
    const l = (p.lastName || '').trim();
    if (!f && !l) return '';
    if (l && /^[A-Za-z0-9_-]{8,64}$/.test(l) && !f) return ''; // placeholder LastName
    return [f, l].filter(Boolean).join(' ');
}

// ---------- /profile ----------

async function renderProfile() {
    setActiveNav('Profile');
    const body = pageShell('Profile', 'Update the details we use for bookings and rewards.');
    try {
        const me = await api('GET', '/me');
        currentSession = me;
        renderProfileForm(body, me);
    } catch (err) {
        body.innerHTML = '';
        body.appendChild(errorCard(err));
    }
}

function renderProfileForm(body, me) {
    body.innerHTML = '';
    const p = me.profile || {};
    const form = el('form', { class: 'sw-acct-form', onsubmit: (e) => e.preventDefault() },
        twoCol(
            field('First name', el('input', {
                type: 'text', name: 'firstName', value: p.firstName || '', required: true, minlength: 2
            })),
            field('Last name', el('input', {
                type: 'text', name: 'lastName',
                // If LastName is the deviceId placeholder, blank it for editing.
                value: (p.lastName && /^[A-Za-z0-9_-]{8,64}$/.test(p.lastName)) ? '' : (p.lastName || ''),
                required: true, minlength: 2
            }))
        ),
        twoCol(
            field('Email', el('input', {
                type: 'email', name: 'email', value: p.email || '', required: true
            })),
            field('Phone', el('input', {
                type: 'tel', name: 'phone', value: p.phone || ''
            }))
        ),
        readonlyRow('Home airport',
            p.homeAirport
                ? el('span', { class: 'sw-acct-pill' }, p.homeAirport)
                : el('span', { class: 'sw-acct-muted' }, 'Will be set on first booking')),
        readonlyRow('Membership',
            el('span', {}, p.membershipTier || 'Basic'),
            p.memberNumber ? el('span', { class: 'sw-acct-muted' }, '#' + p.memberNumber) : null,
            p.loyaltyPoints != null
                ? el('span', { class: 'sw-acct-points' }, p.loyaltyPoints.toLocaleString() + ' pts')
                : null),
        el('div', { class: 'sw-acct-actions' },
            el('button', {
                type: 'submit',
                class: 'btn-pts',
                onclick: (e) => submitProfile(e, form)
            }, me.profileCompleted ? 'Save changes' : 'Save profile'),
            el('span', { class: 'sw-acct-status', id: 'sw-acct-profile-status' })
        )
    );
    body.appendChild(form);
}

function field(label, input) {
    return el('label', { class: 'sw-acct-field' },
        el('span', { class: 'sw-acct-label' }, label),
        input
    );
}
function twoCol(a, b) {
    return el('div', { class: 'sw-acct-cols' }, a, b);
}
function readonlyRow(label, ...vals) {
    return el('div', { class: 'sw-acct-readonly' },
        el('span', { class: 'sw-acct-label' }, label),
        el('div', { class: 'sw-acct-readonly-val' }, vals)
    );
}

async function submitProfile(ev, form) {
    ev.preventDefault();
    const fd = new FormData(form);
    const body = {
        firstName: (fd.get('firstName') || '').toString().trim(),
        lastName:  (fd.get('lastName') || '').toString().trim(),
        email:     (fd.get('email') || '').toString().trim(),
        phone:     (fd.get('phone') || '').toString().trim() || undefined
    };
    const status = document.getElementById('sw-acct-profile-status');
    status.textContent = 'Saving…';
    status.className = 'sw-acct-status';
    try {
        await api('PUT', '/profile', body);
        status.textContent = 'Saved';
        status.className = 'sw-acct-status ok';
        // Refresh in-memory session so sidebar greeting updates.
        const me = await api('GET', '/me');
        currentSession = me;
        document.querySelector('.sw-acct-sidebar')?.replaceWith(sidebar());
    } catch (err) {
        status.textContent = err.body?.issues?.[0]?.message || err.message || 'Save failed';
        status.className = 'sw-acct-status err';
    }
}

// ---------- /bookings ----------

async function renderBookings() {
    setActiveNav('My bookings');
    const body = pageShell('My bookings', 'Your active itineraries and confirmations.');
    try {
        const data = await api('GET', '/bookings');
        body.innerHTML = '';
        if (!data.bookings?.length) {
            body.appendChild(emptyCard(
                'No active bookings yet',
                'When you book a flight, it shows up here automatically.'
            ));
            return;
        }
        const list = el('div', { class: 'sw-acct-bookings' });
        for (const b of data.bookings) list.appendChild(bookingCard(b));
        body.appendChild(list);
    } catch (err) {
        body.innerHTML = '';
        body.appendChild(errorCard(err));
    }
}

function bookingCard(b) {
    const first = b.flights?.[0];
    const last = b.flights?.[b.flights.length - 1];
    const href = '#/booking/' + encodeURIComponent(b.bookingReference);
    return el('a', { class: 'sw-acct-booking', href },
        el('div', { class: 'sw-acct-booking-head' },
            el('div', {},
                el('div', { class: 'sw-acct-booking-route' },
                    first?.originAirportCode || '?',
                    el('span', { class: 'sw-acct-arrow' }, ' → '),
                    last?.destinationAirportCode || '?'
                ),
                el('div', { class: 'sw-acct-booking-cities' },
                    (first?.originCity || '') + ' to ' + (last?.destinationCity || ''))
            ),
            el('div', { class: 'sw-acct-booking-status', 'data-status': b.status || '' },
                b.status || 'Confirmed')
        ),
        el('div', { class: 'sw-acct-booking-meta' },
            el('span', {}, b.flights?.[0]?.originDateTime || ''),
            el('span', { class: 'sw-acct-pill' }, b.fareClass || ''),
            el('span', { class: 'sw-acct-pill' }, '#' + b.bookingReference),
            el('span', {}, b.total)
        )
    );
}

// ---------- /booking/:code ----------

async function renderBookingDetail(code) {
    setActiveNav('My bookings');
    const body = pageShell('Booking ' + code, '');
    try {
        const data = await api('GET', '/bookings');
        const b = data.bookings.find(x => x.bookingReference === code);
        if (!b) {
            body.innerHTML = '';
            body.appendChild(emptyCard(
                'Booking not found',
                'This booking may have been cancelled or is not associated with your account.'
            ));
            return;
        }
        body.innerHTML = '';
        body.appendChild(bookingDetail(b));
    } catch (err) {
        body.innerHTML = '';
        body.appendChild(errorCard(err));
    }
}

function bookingDetail(b) {
    return el('div', { class: 'sw-acct-booking-detail' },
        el('div', { class: 'sw-acct-detail-head' },
            el('h2', {}, '#' + b.bookingReference),
            el('span', { class: 'sw-acct-booking-status', 'data-status': b.status || '' },
                b.status || 'Confirmed')
        ),
        el('div', { class: 'sw-acct-detail-grid' },
            kvCard('Fare class', b.fareClass || '—'),
            kvCard('Total', b.total),
            kvCard('Baggage', b.checkedBaggageAllowance || '—'),
            kvCard('Cancellation', b.cancellationConditions || '—'),
            kvCard('Changes', b.rebookingConditions || '—')
        ),
        el('h3', { class: 'sw-acct-section-h' }, 'Itinerary'),
        el('div', { class: 'sw-acct-segments' },
            ...b.flights.map(segmentCard)
        ),
        el('div', { class: 'sw-acct-detail-foot sw-acct-muted' },
            'Need to make changes? Use the Skywave assistant in the bottom right of the page.')
    );
}

function kvCard(k, v) {
    return el('div', { class: 'sw-acct-kv' },
        el('span', { class: 'sw-acct-label' }, k),
        el('span', { class: 'sw-acct-kv-v' }, v)
    );
}

function segmentCard(f) {
    return el('div', { class: 'sw-acct-segment' },
        el('div', { class: 'sw-acct-segment-cols' },
            el('div', { class: 'sw-acct-segment-side' },
                el('div', { class: 'sw-acct-iata' }, f.originAirportCode || '?'),
                el('div', { class: 'sw-acct-segment-city' }, f.originCity || ''),
                el('div', { class: 'sw-acct-segment-time' }, f.originDateTime || '')
            ),
            el('div', { class: 'sw-acct-segment-mid' },
                el('div', { class: 'sw-acct-segment-line' }),
                el('div', { class: 'sw-acct-segment-duration' }, f.duration || ''),
                el('div', { class: 'sw-acct-segment-meta' },
                    (f.flightNumbers || []).join(' · ') || ''),
                f.numberOfFlights > 1
                    ? el('div', { class: 'sw-acct-segment-stops' },
                        f.numberOfFlights - 1, ' stop')
                    : null
            ),
            el('div', { class: 'sw-acct-segment-side right' },
                el('div', { class: 'sw-acct-iata' }, f.destinationAirportCode || '?'),
                el('div', { class: 'sw-acct-segment-city' }, f.destinationCity || ''),
                el('div', { class: 'sw-acct-segment-time' }, f.destinationDateTime || '')
            )
        )
    );
}

// ---------- helpers ----------

function emptyCard(title, body) {
    return el('div', { class: 'sw-acct-empty' },
        el('h3', {}, title),
        el('p', {}, body)
    );
}
function errorCard(err) {
    const msg = err?.message || 'Something went wrong';
    return el('div', { class: 'sw-acct-empty error' },
        el('h3', {}, 'Couldn’t load that page'),
        el('p', {}, msg),
        el('button', {
            class: 'nav-btn',
            onclick: () => router()
        }, 'Try again')
    );
}

// ---------- router ----------

async function router() {
    const hash = location.hash || '';
    const path = hash.startsWith('#/') ? hash.slice(1) : '';
    const accountRoute = path === '/profile'
        || path === '/bookings'
        || BOOKING_RE.test(path);

    if (!accountRoute) {
        showPanel(false);
        return;
    }

    showPanel(true);
    if (!currentSession) {
        try { currentSession = await initSession(); }
        catch (err) {
            const body = pageShell('Sign in', 'Establishing your session…');
            body.innerHTML = '';
            body.appendChild(errorCard(err));
            return;
        }
    }

    if (path === '/profile') return renderProfile();
    if (path === '/bookings') return renderBookings();
    const m = path.match(BOOKING_RE);
    if (m) return renderBookingDetail(m[1]);
}

// ---------- bootstrap ----------

function wireNavLinks() {
    // Repurpose the existing static nav links (Sign in, SkyRewards, etc.)
    // for the customer area without breaking the visual design. The
    // burger drawer mirrors these.
    const map = [
        { match: 'Sign in',         href: '#/profile' },
        { match: 'Join SkyRewards', href: '#/profile' },
        { match: 'SkyRewards',      href: '#/bookings' }
    ];
    document.querySelectorAll('.nav .nav-links a, .nav .nav-link-text, .nav .nav-btn, .mob-nav-links a, .mob-user-links a')
        .forEach(a => {
            const t = (a.textContent || '').trim();
            const m = map.find(x => x.match === t);
            if (m) {
                a.setAttribute('href', m.href);
                a.style.cursor = 'pointer';
                a.addEventListener('click', (e) => {
                    e.preventDefault();
                    location.hash = m.href.slice(1);
                });
            }
        });
}

export function startAccount() {
    wireNavLinks();
    window.addEventListener('hashchange', router);
    router();
}
