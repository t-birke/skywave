// Hi-fi seatmap renderer for the website's booking-management flow.
//
// Pure SVG, no canvas. Reads the layout JSON returned by
// /api/website/bookings/:code/seatmap (Skywave_Seat_Map__c.Layout_Json__c
// shape: classes[] with rows/abreast/exitRows/galleyAfter/premium flag).
//
// Visual model (vertical fuselage, top = nose, bottom = tail):
//   - Outline = stadium-shape body, narrow vs wide derived from the
//     widest abreast string (1 aisle = narrow, 2 aisles = wide).
//   - One row per data row. Seats laid out per the abreast string
//     (e.g. "3-3-3" → 9 seats, two aisles of empty space between groups).
//   - Class bands tinted (First gold, Business teal, Premium Economy
//     light teal, Economy neutral). Other-class rows render greyed
//     out and uninteractive — visitor can only pick within their fare.
//   - Galley breaks render as a transparent strip with a coffee glyph;
//     exit rows show small "EXIT" labels at the fuselage edge; lavatories
//     at every galley break.
//   - Per-seat states: available, occupied (×), current (visitor's own),
//     selected (preview before confirm).
//
// Flow:
//   open(booking, segment) → fetch /seatmap → render → user picks → confirm
//   bar at the bottom posts to /bookings/:code/seat → close + refresh.

const NS = 'http://www.w3.org/2000/svg';

const CLASS_TINTS = {
    'First':           { band: '#fef3c7', label: '#92400e', seat: '#fbbf24' },
    'Business':        { band: '#ccfbf1', label: '#0f766e', seat: '#14b8a6' },
    'Premium Economy': { band: '#dcfce7', label: '#166534', seat: '#86efac' },
    'Economy':         { band: '#f1f5f9', label: '#475569', seat: '#94a3b8' }
};

// Visual constants.
const ROW_H = 28;            // height per row
const SEAT_W = 24;
const SEAT_H = 22;
const SEAT_GAP = 4;          // between adjacent seats in same group
const AISLE_GAP = 22;        // between groups (= one aisle's width)
const BAND_PAD_X = 14;       // band-edge padding inside fuselage
const FUSELAGE_PAD = 18;     // outer fuselage outline padding
const NOSE_H = 56;
const TAIL_H = 64;
const GALLEY_H = 30;         // height of a galley/lavatory strip

function svg(tag, attrs = {}, ...children) {
    const e = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs)) {
        if (v == null || v === false) continue;
        if (k.startsWith('on') && typeof v === 'function') {
            e.addEventListener(k.slice(2).toLowerCase(), v);
        } else {
            e.setAttribute(k, v);
        }
    }
    for (const c of children.flat()) {
        if (c == null || c === false) continue;
        // Wrap raw strings/numbers in a text node — appendChild only
        // accepts Nodes. Was the cause of "parameter 1 is not of type
        // 'Node'" on every <text> element with a string child.
        e.appendChild(typeof c === 'object' ? c : document.createTextNode(String(c)));
    }
    return e;
}
function html(tag, attrs = {}, ...children) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
        if (v == null || v === false) continue;
        if (k === 'class') e.className = v;
        else if (k.startsWith('on') && typeof v === 'function') {
            e.addEventListener(k.slice(2).toLowerCase(), v);
        } else if (v === true) e.setAttribute(k, '');
        else e.setAttribute(k, v);
    }
    for (const c of children.flat()) {
        if (c == null || c === false) continue;
        e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return e;
}

// "3-3-3" → [3,3,3]
function parseAbreast(s) {
    return (s || '').split('-').map(n => parseInt(n, 10)).filter(n => Number.isFinite(n));
}
// Letters per group, e.g. abreast "3-3-3" → ["A","B","C"|"D","E","F"|"G","H","J"]
// Note: "I" is skipped per IATA convention.
function seatLetters(groups) {
    const letters = ['A','B','C','D','E','F','G','H','J','K','L','M'];
    const out = [];
    let idx = 0;
    for (const g of groups) {
        const arr = [];
        for (let i = 0; i < g; i++) arr.push(letters[idx++]);
        out.push(arr);
    }
    return out;
}

function bandWidthPx(groups) {
    // Total seat width + intra-group gaps, plus aisle gaps between groups.
    let w = 0;
    groups.forEach((g, gi) => {
        w += g * SEAT_W + (g - 1) * SEAT_GAP;
        if (gi < groups.length - 1) w += AISLE_GAP;
    });
    return w;
}

// Expand a layout's classes[] into a flat per-row sequence of:
//   { type: 'row', row: N, className, groups, exit, premium }
//   { type: 'galley', after: N, label }
function expandRows(layout) {
    const out = [];
    const classes = layout.classes || [];
    classes.forEach(c => {
        const [start, end] = (c.rows && c.rows.length === 2) ? c.rows : [c.rows[0], c.rows[0]];
        const groups = parseAbreast(c.abreast);
        const exitSet = new Set(c.exitRows || []);
        for (let r = start; r <= end; r++) {
            out.push({
                type: 'row',
                row: r,
                className: c.name,
                groups,
                exit: exitSet.has(r),
                premium: c.premium === true
            });
        }
        if (c.galleyAfter) {
            out.push({ type: 'galley', after: c.galleyAfter, label: 'Galley · Lavatories' });
        }
    });
    return out;
}

function isOtherClass(rowClass, bookedClass) {
    return rowClass !== bookedClass;
}

/**
 * Open the seatmap modal for (bookingCode, segmentOrder, currentSeat).
 * onConfirm receives { newSeat } once the seat-change POST succeeds.
 */
export async function openSeatMap(bookingCode, segment, onConfirm) {
    const overlay = html('div', { class: 'sw-seatmap-overlay' });
    const card = html('div', { class: 'sw-seatmap-card' });
    overlay.appendChild(card);
    document.body.appendChild(overlay);

    function close() { overlay.remove(); }
    overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });

    card.appendChild(html('button', {
        class: 'sw-seatmap-close', type: 'button',
        onclick: close, 'aria-label': 'Close'
    }, '×'));

    card.appendChild(html('div', { class: 'sw-seatmap-loading' },
        html('div', { class: 'cust-spinner' }),
        html('p', {}, 'Loading seatmap…')));

    let data;
    try {
        const r = await fetch(
            `/api/website/bookings/${encodeURIComponent(bookingCode)}/seatmap?segmentOrder=${segment.segmentOrder}`,
            { credentials: 'same-origin' });
        data = await r.json();
        if (!r.ok || !data.ok) throw new Error(data.error || 'load_failed');
    } catch (err) {
        card.querySelector('.sw-seatmap-loading')?.remove();
        card.appendChild(html('div', { class: 'cust-empty error' },
            html('h3', {}, 'Couldn’t load seatmap'),
            html('p', {}, err.message || 'Try again in a moment')));
        return;
    }

    card.querySelector('.sw-seatmap-loading')?.remove();
    try {
        renderSeatMapCard(card, data, bookingCode, segment, close, onConfirm);
    } catch (err) {
        // Surface the error inline so we don't have to dive into DevTools.
        // The `card` already contains the header at this point; append a
        // visible error block so the failure shape is obvious.
        console.error('[skywave-seatmap] render failed:', err);
        card.appendChild(html('div', { class: 'cust-empty error', style: 'padding:24px' },
            html('h3', {}, 'Seatmap render failed'),
            html('pre', { style: 'font-size:11px;text-align:left;white-space:pre-wrap;color:#dc2626' },
                (err && err.stack) ? err.stack : String(err))
        ));
    }
}

function renderSeatMapCard(card, data, bookingCode, segment, close, onConfirm) {
    const occupied = new Set((data.occupied || []).map(s => s.toUpperCase()));
    const currentSeat = (data.currentSeat || '').toUpperCase();
    const bookedClass = data.fareClass || 'Economy';
    const layout = data.layout || { classes: [] };

    // Header
    card.appendChild(html('div', { class: 'sw-seatmap-head' },
        html('h3', {}, 'Choose your seat'),
        html('p', {},
            data.aircraftType, ' · ', bookedClass,
            currentSeat ? html('span', { class: 'sw-seatmap-current-tag' }, ' Current ' + currentSeat) : null)
    ));

    // SVG canvas — width determined by widest band, height by row count + galleys + nose/tail.
    const rowsExpanded = expandRows(layout);
    let widestBand = 0;
    rowsExpanded.forEach(r => {
        if (r.type === 'row') widestBand = Math.max(widestBand, bandWidthPx(r.groups));
    });
    const cabinW = widestBand + BAND_PAD_X * 2;
    const cabinX = FUSELAGE_PAD;

    // Compute layout y-positions.
    let y = NOSE_H;
    const items = [];
    rowsExpanded.forEach(r => {
        if (r.type === 'row') {
            items.push({ ...r, y });
            y += ROW_H;
        } else if (r.type === 'galley') {
            items.push({ ...r, y });
            y += GALLEY_H;
        }
    });
    const cabinH = y - NOSE_H;
    const totalH = NOSE_H + cabinH + TAIL_H;
    const totalW = cabinX * 2 + cabinW;

    // Wrap the SVG in a scrollable container so the modal can show the
    // legend + confirm bar at the bottom even on long cabins. The SVG
    // itself gets explicit width/height attributes (no `flex: 1 1 auto`
    // collapse trap) so its rendered size matches its viewBox aspect.
    const scrollWrap = html('div', { class: 'sw-seatmap-scroll' });
    const renderWidth = Math.min(420, totalW * 1.4);
    const renderHeight = renderWidth * (totalH / totalW);
    const root = svg('svg', {
        class: 'sw-seatmap-svg',
        viewBox: `0 0 ${totalW} ${totalH}`,
        width: renderWidth,
        height: renderHeight,
        preserveAspectRatio: 'xMidYMin meet'
    });
    scrollWrap.appendChild(root);

    // Fuselage: stadium-shape outline (rounded nose, square mid, rounded tail).
    // Drawn as a single path for a clean profile.
    const noseRX = totalW / 2;
    const tailRX = totalW / 2;
    const fuselagePath = [
        `M ${cabinX} ${NOSE_H}`,
        `Q ${totalW / 2} 0 ${totalW - cabinX} ${NOSE_H}`,
        `L ${totalW - cabinX} ${NOSE_H + cabinH}`,
        `Q ${totalW / 2} ${totalH} ${cabinX} ${NOSE_H + cabinH}`,
        `Z`
    ].join(' ');
    root.appendChild(svg('path', {
        d: fuselagePath, fill: '#f8fafc', stroke: '#cbd5e1', 'stroke-width': 1.5
    }));

    // Per-row class bands (tinted background behind rows of the same class).
    const bandsByClass = new Map();
    items.forEach(it => {
        if (it.type !== 'row') return;
        if (!bandsByClass.has(it.className)) {
            bandsByClass.set(it.className, { yStart: it.y, yEnd: it.y + ROW_H });
        } else {
            bandsByClass.get(it.className).yEnd = it.y + ROW_H;
        }
    });
    bandsByClass.forEach((band, name) => {
        const tint = CLASS_TINTS[name] || CLASS_TINTS['Economy'];
        root.appendChild(svg('rect', {
            x: cabinX, y: band.yStart,
            width: cabinW, height: band.yEnd - band.yStart,
            fill: tint.band, opacity: isOtherClass(name, bookedClass) ? 0.35 : 0.9
        }));
        // Class label on the right side
        root.appendChild(svg('text', {
            x: totalW - 4, y: (band.yStart + band.yEnd) / 2 + 4,
            'text-anchor': 'end',
            'font-size': '10', 'font-weight': '700',
            'letter-spacing': '0.1em',
            fill: tint.label,
            transform: `rotate(-90 ${totalW - 4} ${(band.yStart + band.yEnd) / 2 + 4})`
        }, name.toUpperCase()));
    });

    // Per-row contents.
    items.forEach(it => {
        if (it.type === 'galley') {
            renderGalley(root, it, cabinX, cabinW);
        } else {
            renderSeatRow(root, it, cabinX, cabinW, {
                bookedClass, currentSeat, occupied,
                onPick: (seat) => {
                    state.selected = seat;
                    refreshSelection(root, state, currentSeat, occupied, bookedClass);
                    confirmBar.textContent = '';
                    confirmBar.appendChild(buildConfirmBar(state, bookingCode, segment, onConfirm, close, currentSeat));
                }
            });
        }
    });

    card.appendChild(scrollWrap);

    // Legend
    card.appendChild(html('div', { class: 'sw-seatmap-legend' },
        legendChip('available', 'Available'),
        legendChip('selected',  'Selected'),
        legendChip('current',   'Current'),
        legendChip('occupied',  'Taken'),
        legendChip('other',     'Other class')
    ));

    // Confirm bar
    const state = { selected: null };
    const confirmBar = html('div', { class: 'sw-seatmap-confirm' });
    confirmBar.appendChild(buildConfirmBar(state, bookingCode, segment, onConfirm, close, currentSeat));
    card.appendChild(confirmBar);
}

function legendChip(kind, label) {
    return html('span', { class: 'sw-seatmap-legend-chip' },
        html('span', { class: 'sw-seatmap-legend-dot', 'data-kind': kind }), label);
}

function renderGalley(root, it, cabinX, cabinW) {
    root.appendChild(svg('rect', {
        x: cabinX + 6, y: it.y + 4,
        width: cabinW - 12, height: GALLEY_H - 8,
        rx: 6, fill: '#e2e8f0', stroke: '#cbd5e1', 'stroke-dasharray': '3 3'
    }));
    // Two lavatory glyphs at edges, kitchen icon middle.
    root.appendChild(svg('text', {
        x: cabinX + 18, y: it.y + GALLEY_H / 2 + 4,
        'font-size': '12', fill: '#64748b'
    }, '\u{1F6BB}'));   // toilet emoji as compact glyph
    root.appendChild(svg('text', {
        x: cabinX + cabinW / 2, y: it.y + GALLEY_H / 2 + 4,
        'text-anchor': 'middle',
        'font-size': '11', fill: '#64748b', 'letter-spacing': '0.06em'
    }, 'GALLEY'));
    root.appendChild(svg('text', {
        x: cabinX + cabinW - 18, y: it.y + GALLEY_H / 2 + 4,
        'text-anchor': 'end',
        'font-size': '12', fill: '#64748b'
    }, '\u{1F6BB}'));
}

function renderSeatRow(root, row, cabinX, cabinW, ctx) {
    const groups = row.groups;
    const letters = seatLetters(groups);
    const bandW = bandWidthPx(groups);
    let x = cabinX + (cabinW - bandW) / 2;
    const tint = CLASS_TINTS[row.className] || CLASS_TINTS['Economy'];
    const dimmed = isOtherClass(row.className, ctx.bookedClass);

    // Row number (left margin)
    root.appendChild(svg('text', {
        x: cabinX + 4, y: row.y + ROW_H / 2 + 4,
        'font-size': '10', 'font-weight': '600',
        fill: dimmed ? '#94a3b8' : '#0f172a'
    }, String(row.row)));

    // Exit-row marker (left margin)
    if (row.exit) {
        root.appendChild(svg('rect', {
            x: cabinX - 6, y: row.y + ROW_H / 2 - 7,
            width: 4, height: 14, fill: '#dc2626'
        }));
        root.appendChild(svg('rect', {
            x: cabinX + cabinW + 2, y: row.y + ROW_H / 2 - 7,
            width: 4, height: 14, fill: '#dc2626'
        }));
    }

    groups.forEach((g, gi) => {
        for (let s = 0; s < g; s++) {
            const seatLetter = letters[gi][s];
            const seatLabel = `${row.row}${seatLetter}`;
            const sx = x + s * (SEAT_W + SEAT_GAP);
            const sy = row.y + (ROW_H - SEAT_H) / 2;
            const seatGroup = renderSeat(sx, sy, seatLabel, tint, row.premium, ctx, dimmed);
            seatGroup.dataset.seat = seatLabel;
            root.appendChild(seatGroup);
        }
        x += g * SEAT_W + (g - 1) * SEAT_GAP + AISLE_GAP;
    });
}

function renderSeat(x, y, label, tint, premium, ctx, dimmed) {
    const g = svg('g', { class: 'sw-seat', 'data-state': 'available' });
    const w = premium ? SEAT_W + 4 : SEAT_W;
    const h = premium ? SEAT_H + 2 : SEAT_H;
    const rx = premium ? 8 : 5;
    const ox = premium ? -2 : 0;
    const oy = premium ? -1 : 0;

    let state = 'available';
    if (dimmed) state = 'other';
    else if (label === ctx.currentSeat) state = 'current';
    else if (ctx.occupied.has(label)) state = 'occupied';
    g.dataset.state = state;
    g.dataset.tint = tint.seat;

    g.appendChild(svg('rect', {
        x: x + ox, y: y + oy, width: w, height: h, rx, ry: rx,
        fill: stateFill(state, tint),
        stroke: stateStroke(state, tint),
        'stroke-width': state === 'current' || state === 'selected' ? 2 : 1
    }));

    if (state === 'occupied') {
        g.appendChild(svg('text', {
            x: x + SEAT_W / 2, y: y + SEAT_H / 2 + 4,
            'text-anchor': 'middle',
            'font-size': '11', fill: '#94a3b8'
        }, '×'));
    } else if (state !== 'other') {
        g.appendChild(svg('text', {
            x: x + SEAT_W / 2, y: y + SEAT_H / 2 + 4,
            'text-anchor': 'middle',
            'font-size': '9', 'font-weight': '600',
            fill: stateText(state, tint)
        }, label.replace(/^\d+/, '')));  // show just the letter for compactness
    }

    if (state === 'available' || state === 'current') {
        g.style.cursor = 'pointer';
        g.addEventListener('click', () => {
            if (g.dataset.state === 'occupied' || g.dataset.state === 'other') return;
            ctx.onPick(label);
        });
    }
    return g;
}

function stateFill(state, tint) {
    if (state === 'occupied') return '#e2e8f0';
    if (state === 'other')    return '#e2e8f0';
    if (state === 'current')  return tint.seat;
    if (state === 'selected') return '#0f172a';
    return '#fff';
}
function stateStroke(state, tint) {
    if (state === 'occupied') return '#cbd5e1';
    if (state === 'other')    return '#cbd5e1';
    if (state === 'current')  return tint.seat;
    if (state === 'selected') return '#0f172a';
    return tint.seat;
}
function stateText(state, tint) {
    if (state === 'current')  return '#fff';
    if (state === 'selected') return '#fff';
    return tint.label;
}

function refreshSelection(root, state, currentSeat, occupied, bookedClass) {
    root.querySelectorAll('.sw-seat').forEach(g => {
        const label = g.dataset.seat;
        const tintColor = g.dataset.tint;
        const tint = { seat: tintColor, label: '#475569' };
        let s;
        if (g.dataset.state === 'other')    s = 'other';
        else if (label === currentSeat)     s = state.selected ? 'current-was' : 'current';
        else if (occupied.has(label))       s = 'occupied';
        else if (state.selected === label)  s = 'selected';
        else                                s = 'available';
        g.dataset.state = s;
        const rect = g.querySelector('rect');
        if (rect) {
            rect.setAttribute('fill', stateFill(s === 'current-was' ? 'available' : s, tint));
            rect.setAttribute('stroke', stateStroke(s === 'current-was' ? 'available' : s, tint));
            rect.setAttribute('stroke-width', (s === 'current' || s === 'selected') ? 2 : 1);
        }
    });
}

function buildConfirmBar(state, bookingCode, segment, onConfirm, close, currentSeat) {
    const wrap = document.createDocumentFragment();
    const sel = state.selected;
    if (!sel) {
        wrap.appendChild(html('p', { class: 'sw-seatmap-confirm-hint' },
            'Tap a seat to select it.'));
        return wrap;
    }
    const label = html('p', { class: 'sw-seatmap-confirm-label' },
        currentSeat ? `Move from ${currentSeat} to ${sel}` : `Pick seat ${sel}`);
    const btn = html('button', {
        class: 'btn-pts sw-seatmap-confirm-btn', type: 'button',
        onclick: async () => {
            btn.disabled = true;
            btn.textContent = 'Saving…';
            try {
                const r = await fetch(`/api/website/bookings/${encodeURIComponent(bookingCode)}/seat`, {
                    method: 'POST', credentials: 'same-origin',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ segmentOrder: segment.segmentOrder, newSeat: sel })
                });
                const data = await r.json();
                if (!r.ok || !data.ok) throw new Error(data?.error || 'seat_change_failed');
                close();
                onConfirm({ newSeat: data.newSeat, oldSeat: data.oldSeat });
            } catch (err) {
                btn.disabled = false;
                btn.textContent = 'Confirm seat';
                alert('Could not change seat: ' + err.message);
            }
        }
    }, 'Confirm seat');
    wrap.appendChild(label);
    wrap.appendChild(btn);
    return wrap;
}
