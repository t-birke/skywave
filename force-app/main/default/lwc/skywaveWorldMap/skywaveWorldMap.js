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
        // For a connection (3 points), the connection airport IS the middle.
        return this._x(points[1][0]);
    }

    _midY(points) {
        if (!points || !points.length) return 0;
        if (points.length === 1) return this._y(points[0][1]);
        if (points.length === 2) {
            return (this._y(points[0][1]) + this._y(points[1][1])) / 2;
        }
        return this._y(points[1][1]);
    }
}
