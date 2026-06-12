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
import { arcPointAt } from '@/globe/arcGeometry';
import type { GlobeMarker, GlobeArcData, MarkerStatus } from '@/globe/types';

export interface RouteLeg {
  from: string;
  to: string;
}

/** One survey answer the visitor gave, with its resolved thumbnail. */
export interface SurveyAnswer {
  questionKey: string;
  answerKey: string;
  answerText?: string | null;
  imageUrl?: string | null;
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
  /** Survey answers given so far (deduped by questionKey). */
  answers?: SurveyAnswer[];
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

// Avatars and arcs sit slightly above the surface so they read as "in
// flight" rather than painted on the globe.
const SURFACE_LIFT = 1.01;

/**
 * Origin → final destination for a booked route, hubs dropped. The demo
 * routes everything through the JFK hub, but a single great-circle arc from
 * where the traveller started to where they're going reads far cleaner than
 * a two-leg dogleg through the hub.
 */
function routeEndpoints(
  legs: RouteLeg[]
): {
  origin: [number, number];
  dest: [number, number];
  originCode: string;
  destCode: string;
} | null {
  if (!legs.length) return null;
  const origin = airport(legs[0].from);
  const dest = airport(legs[legs.length - 1].to);
  if (!origin || !dest) return null;
  return {
    origin: [origin.lon, origin.lat],
    dest: [dest.lon, dest.lat],
    originCode: origin.code,
    destCode: dest.code,
  };
}

export interface VisitorMarker extends GlobeMarker {
  avatarUrl?: string | null;
}

/** Map visitors to globe markers (only those with a plottable position). */
export function toMarkers(visitors: Visitor[]): VisitorMarker[] {
  const out: VisitorMarker[] = [];
  for (const v of visitors) {
    let position: [number, number, number] | null = null;

    const ep = v.route ? routeEndpoints(v.route.legs) : null;
    if (ep) {
      // Booked → ride the centre of the origin→dest flight arc (t=0.5),
      // using the SAME bezier GlobeArc renders.
      const start = latLngToArray(ep.origin[1], ep.origin[0], GLOBE_RADIUS * SURFACE_LIFT);
      const end = latLngToArray(ep.dest[1], ep.dest[0], GLOBE_RADIUS * SURFACE_LIFT);
      position = arcPointAt(start, end, 0.5);
    } else if (typeof v.lat === 'number' && typeof v.lon === 'number') {
      // Browsing → on the surface at their geo location.
      position = latLngToArray(v.lat, v.lon, GLOBE_RADIUS * SURFACE_LIFT);
    }
    if (!position) continue;

    out.push({
      id: v.sessionId,
      position,
      label: label(v),
      sublabel: sublabel(v),
      status: statusFor(v),
      avatarUrl: v.avatarUrl ?? null,
    });
  }
  return out;
}

/** Map booked routes to globe arcs — one arc, origin → final destination. */
export function toArcs(visitors: Visitor[]): GlobeArcData[] {
  const arcs: GlobeArcData[] = [];
  for (const v of visitors) {
    if (!v.route) continue;
    const ep = routeEndpoints(v.route.legs);
    if (!ep) continue;
    arcs.push({
      id: `${v.sessionId}:route`,
      start: latLngToArray(ep.origin[1], ep.origin[0], GLOBE_RADIUS * SURFACE_LIFT),
      end: latLngToArray(ep.dest[1], ep.dest[0], GLOBE_RADIUS * SURFACE_LIFT),
      label: `${ep.originCode} → ${ep.destCode}`,
    });
  }
  return arcs;
}
