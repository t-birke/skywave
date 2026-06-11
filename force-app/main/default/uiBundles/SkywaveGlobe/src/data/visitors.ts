/**
 * Skywave visitor model + mapping into the globe's neutral marker/arc shapes.
 *
 * Mirrors the accumulation the LWC monitor does in handleDemoEvent: each
 * visitor session carries optional geo, a booked route, seat, and profile.
 * Placement/route logic is ported from skywaveDemoMonitor.js so the globe
 * plots avatars at the same spot the 2D map did.
 */
import { airport } from './airports';
import { latLngToArray } from '@/globe/data/geo';
import type { GlobeMarker, GlobeArcData, MarkerStatus } from '@/globe/types';

export interface RouteLeg {
  from: string;
  to: string;
}

export interface Visitor {
  sessionId: string;
  firstName?: string | null;
  lastName?: string | null;
  avatarUrl?: string | null;
  seat?: string | null;
  city?: string | null;
  /** IP-geolocated position, if resolved. */
  lat?: number | null;
  lon?: number | null;
  /** Set once a flight is booked. */
  route?: { legs: RouteLeg[]; isConnection: boolean } | null;
  surveyComplete?: boolean;
  /** Exception flag (e.g. payment/seat failure) → renders as alert. */
  alert?: boolean;
}

const GLOBE_RADIUS = 1;

/** Per-visitor progress → marker color. */
function statusFor(v: Visitor): MarkerStatus {
  if (v.alert) return 'alert';
  if (v.route && v.route.legs.length) return 'active'; // booked → green
  return 'idle'; // browsing / pre-booking → grey
}

function label(v: Visitor): string {
  if (v.firstName) {
    return v.lastName ? `${v.firstName} ${v.lastName.charAt(0)}.` : v.firstName;
  }
  return v.sessionId.slice(-6);
}

function sublabel(v: Visitor): string | undefined {
  const parts: string[] = [];
  if (v.city) parts.push(v.city);
  if (v.seat) parts.push(`seat ${v.seat}`);
  return parts.length ? parts.join(' · ') : undefined;
}

/** [lon,lat] points along a visitor's booked route, deduped at the seam. */
function routePoints(legs: RouteLeg[]): [number, number][] {
  const pts: [number, number][] = [];
  for (let i = 0; i < legs.length; i++) {
    const from = airport(legs[i].from);
    if (i === 0 && from) pts.push([from.lon, from.lat]);
    const to = airport(legs[i].to);
    if (to) pts.push([to.lon, to.lat]);
  }
  return pts;
}

/**
 * Where to plot a visitor's avatar — ported from the LWC's _placement:
 * route midpoint (second leg for connections, so connecting visitors don't
 * stack on the hub) > IP-geo location > null (unplaceable).
 */
function placement(v: Visitor): { lat: number; lon: number } | null {
  if (v.route && v.route.legs.length) {
    const pts = routePoints(v.route.legs);
    if (pts.length === 2) {
      return { lat: (pts[0][1] + pts[1][1]) / 2, lon: (pts[0][0] + pts[1][0]) / 2 };
    }
    if (pts.length >= 3) {
      return { lat: (pts[1][1] + pts[2][1]) / 2, lon: (pts[1][0] + pts[2][0]) / 2 };
    }
  }
  if (typeof v.lat === 'number' && typeof v.lon === 'number') {
    return { lat: v.lat, lon: v.lon };
  }
  return null;
}

export interface VisitorMarker extends GlobeMarker {
  avatarUrl?: string | null;
}

/** Map visitors to globe markers (only those with a plottable position). */
export function toMarkers(visitors: Visitor[]): VisitorMarker[] {
  const out: VisitorMarker[] = [];
  for (const v of visitors) {
    const place = placement(v);
    if (!place) continue;
    out.push({
      id: v.sessionId,
      position: latLngToArray(place.lat, place.lon, GLOBE_RADIUS * 1.01),
      label: label(v),
      sublabel: sublabel(v),
      status: statusFor(v),
      avatarUrl: v.avatarUrl ?? null,
    });
  }
  return out;
}

/** Map booked routes to globe arcs (origin → hub → dest, leg by leg). */
export function toArcs(visitors: Visitor[]): GlobeArcData[] {
  const arcs: GlobeArcData[] = [];
  for (const v of visitors) {
    if (!v.route || !v.route.legs.length) continue;
    const pts = routePoints(v.route.legs);
    for (let i = 0; i < pts.length - 1; i++) {
      arcs.push({
        id: `${v.sessionId}:leg${i}`,
        start: latLngToArray(pts[i][1], pts[i][0], GLOBE_RADIUS * 1.01),
        end: latLngToArray(pts[i + 1][1], pts[i + 1][0], GLOBE_RADIUS * 1.01),
      });
    }
  }
  return arcs;
}
