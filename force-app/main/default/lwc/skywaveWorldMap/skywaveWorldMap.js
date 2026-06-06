/**
 * Stylized world map for the Skywave demo monitor.
 *
 * Renders an equirectangular SVG (viewBox 0 0 360 180) with stylised
 * continent silhouettes, plus three overlay layers built from props:
 *   - routes: SVG polylines (origin → optional connection → destination)
 *   - bubbles: HTML elements absolutely positioned via percent left/top
 *   - "no location" row beneath the map for sessions without coordinates
 *
 * Equirectangular makes lat/lon → pixel pure math: x = lon + 180,
 * y = 90 − lat. Survives any container size — both the SVG and bubble
 * positions are expressed as percentages of the same coordinate system.
 *
 * Pure presentational; the parent (skywaveDemoMonitor) owns subscription,
 * de-duplication, and event interpretation, and feeds this component
 * `bubbles[]` and `routes[]` already shaped for render.
 */
import { LightningElement, api } from 'lwc';
import { WORLD_LAND_PATH } from './landPath.js';

export default class SkywaveWorldMap extends LightningElement {
    landPath = WORLD_LAND_PATH;

    /** [{ id, lat, lon, label, avatarUrl, seat, status, hasLocation }] */
    @api bubbles = [];
    /** [{ id, points: [[lon,lat], ...], isConnection }] */
    @api routes = [];
    /** Skywave network airports keyed by IATA → {lat, lon}. Renders as
     *  small dots with subtle IATA labels under the continent layer. */
    @api airports = {};

    /** Network airports flattened for SVG render, in viewBox coords. */
    get airportPins() {
        const map = this.airports || {};
        const out = [];
        for (const code of Object.keys(map)) {
            const a = map[code];
            if (!a || typeof a.lat !== 'number' || typeof a.lon !== 'number') continue;
            out.push({
                code,
                cx: this._x(a.lon),
                cy: this._y(a.lat),
                // Label sits just to the right of the dot. Width approx by
                // viewBox units (1 unit ≈ 1 degree).
                lx: this._x(a.lon) + 0.9,
                ly: this._y(a.lat) + 0.4
            });
        }
        return out;
    }

    /** Equirectangular helpers — x and y are SVG units (also % when scaled). */
    _x(lon) { return Number(lon) + 180; }
    _y(lat) { return 90 - Number(lat); }

    /** Bubbles split into placed (on map) vs unplaced (below). */
    get placedBubbles() {
        return (this.bubbles || []).filter(b => b.hasLocation).map(b => {
            const left = this._x(b.lon) / 360 * 100;
            const top  = this._y(b.lat) / 180 * 100;
            return this._decorate(b, `left:${left.toFixed(2)}%; top:${top.toFixed(2)}%;`);
        });
    }

    get unplacedBubbles() {
        return (this.bubbles || []).filter(b => !b.hasLocation).map(b => this._decorate(b, ''));
    }

    _decorate(b, style) {
        const label = b.label || (b.id ? b.id.slice(-6) : '?');
        // Survey thumbs: ensure each has a stable key + a sane title for hover.
        const answers = (b.answers || []).filter(a => a && a.imageUrl).map(a => ({
            key: b.id + ':' + a.questionKey,
            imageUrl: a.imageUrl,
            answerText: a.answerText || a.answerKey || ''
        }));
        return {
            ...b,
            style,
            label,
            initial: (label || '?').charAt(0).toUpperCase(),
            tooltip: this._tooltip(b),
            answers,
            hasAnswers: answers.length > 0
        };
    }

    _tooltip(b) {
        const parts = [];
        if (b.label) parts.push(b.label);
        if (b.city)  parts.push(b.city);
        if (b.seat)  parts.push('seat ' + b.seat);
        return parts.join(' · ');
    }

    get hasUnplaced() {
        return this.unplacedBubbles.length > 0;
    }

    /** Route polyline strings, in SVG-unit coords (matches the viewBox). */
    get routeShapes() {
        return (this.routes || []).map(r => ({
            id: r.id,
            isConnection: r.isConnection,
            routeClass: r.isConnection ? 'sw-route sw-route-connection' : 'sw-route',
            d: this._pathFor(r.points),
            // Marker dot at the avatar's "current position" — midpoint of the
            // full route. For a 2-leg connection that's the connection city.
            midX: this._midX(r.points),
            midY: this._midY(r.points)
        }));
    }

    _pathFor(points) {
        // Smooth M…L…L… in SVG units. Antimeridian wrap is intentionally
        // ignored — for a JFK-hub demo, no real route crosses it.
        if (!points || points.length === 0) return '';
        return points.map((p, i) => {
            const cmd = i === 0 ? 'M' : 'L';
            return `${cmd}${this._x(p[0])},${this._y(p[1])}`;
        }).join(' ');
    }

    _midX(points) {
        if (!points || !points.length) return 0;
        if (points.length === 1) return this._x(points[0][0]);
        if (points.length === 2) {
            return (this._x(points[0][0]) + this._x(points[1][0])) / 2;
        }
        // Connection (3 points): match the bubble — midpoint of the second
        // leg, NOT the hub itself (otherwise every connecting visitor stacks
        // on JFK).
        return (this._x(points[1][0]) + this._x(points[2][0])) / 2;
    }

    _midY(points) {
        if (!points || !points.length) return 0;
        if (points.length === 1) return this._y(points[0][1]);
        if (points.length === 2) {
            return (this._y(points[0][1]) + this._y(points[1][1])) / 2;
        }
        return (this._y(points[1][1]) + this._y(points[2][1])) / 2;
    }

    /** Run collision-deconfliction after each render. Bubble widths depend
     *  on label/seat/answer-strip content, so we can't compute them ahead
     *  of layout — measure rects, then iteratively push overlapping pairs
     *  apart and write the result back as a CSS custom-property offset. */
    renderedCallback() {
        // Defer one frame so the just-rendered DOM has settled.
        if (this._raf) cancelAnimationFrame(this._raf);
        this._raf = requestAnimationFrame(() => this._deconflict());
    }

    disconnectedCallback() {
        if (this._raf) cancelAnimationFrame(this._raf);
    }

    _deconflict() {
        const host = this.template.querySelector('.sw-bubble-layer');
        if (!host) return;
        const els = Array.from(this.template.querySelectorAll('.sw-bubble-placed'));
        if (els.length < 2) {
            // Single bubble (or none): clear any prior offsets.
            els.forEach(el => {
                el.style.setProperty('--sw-dx', '0px');
                el.style.setProperty('--sw-dy', '0px');
            });
            return;
        }
        const hostRect = host.getBoundingClientRect();
        // Build a working set: rect (relative to host) + current offset accumulator.
        const PAD = 4;     // visual breathing room between pills
        const MAX_DRIFT = 80; // px — cap how far a bubble can wander from its true point
        const ITER = 60;
        const items = els.map(el => {
            const r = el.getBoundingClientRect();
            // Anchor = the geographic position before any offset. Since we
            // start each pass from the previous offset, undo it first.
            const dx = parseFloat(el.style.getPropertyValue('--sw-dx')) || 0;
            const dy = parseFloat(el.style.getPropertyValue('--sw-dy')) || 0;
            return {
                el,
                w: r.width,
                h: r.height,
                // cx/cy are the bubble center (rect center) RELATIVE to host,
                // with the previous offset rolled back to the true anchor.
                cx: (r.left + r.right) / 2 - hostRect.left - dx,
                cy: (r.top + r.bottom) / 2 - hostRect.top - dy,
                // working offsets; updated each iteration.
                ox: dx,
                oy: dy
            };
        });

        // Iterative repulsion. For each overlapping pair, push them apart
        // along the vector between their (currently-positioned) centers.
        // Heavier weight on y so bubbles tend to ladder up/down rather than
        // crawl horizontally off their actual route position.
        for (let it = 0; it < ITER; it++) {
            let any = false;
            for (let i = 0; i < items.length; i++) {
                for (let j = i + 1; j < items.length; j++) {
                    const a = items[i], b = items[j];
                    const ax = a.cx + a.ox, ay = a.cy + a.oy;
                    const bx = b.cx + b.ox, by = b.cy + b.oy;
                    const minDx = (a.w + b.w) / 2 + PAD;
                    const minDy = (a.h + b.h) / 2 + PAD;
                    const ddx = bx - ax, ddy = by - ay;
                    // Manhattan-style overlap test on AABBs.
                    const overlapX = minDx - Math.abs(ddx);
                    const overlapY = minDy - Math.abs(ddy);
                    if (overlapX <= 0 || overlapY <= 0) continue;
                    any = true;
                    // Push along the smaller overlap axis (cheapest separation).
                    if (overlapY <= overlapX) {
                        const push = (overlapY / 2) + 0.5;
                        const sign = ddy >= 0 ? 1 : -1;
                        a.oy -= push * sign;
                        b.oy += push * sign;
                    } else {
                        const push = (overlapX / 2) + 0.5;
                        const sign = ddx >= 0 ? 1 : -1;
                        a.ox -= push * sign;
                        b.ox += push * sign;
                    }
                }
            }
            if (!any) break;
        }

        // Cap drift so a tightly-clustered bunch doesn't fling someone to
        // Madagascar. If they hit the cap, that's acceptable visual overflow.
        for (const it of items) {
            if (it.ox >  MAX_DRIFT) it.ox =  MAX_DRIFT;
            if (it.ox < -MAX_DRIFT) it.ox = -MAX_DRIFT;
            if (it.oy >  MAX_DRIFT) it.oy =  MAX_DRIFT;
            if (it.oy < -MAX_DRIFT) it.oy = -MAX_DRIFT;
            it.el.style.setProperty('--sw-dx', it.ox.toFixed(1) + 'px');
            it.el.style.setProperty('--sw-dy', it.oy.toFixed(1) + 'px');
        }
    }
}
