/**
 * Shared geometry for the curved flight arcs.
 *
 * Single source of truth so the rendered line (GlobeArc) and the avatar that
 * rides it (visitors.ts) use the IDENTICAL bezier — change the curve here and
 * both move together.
 *
 * The arc is a quadratic bezier from `start` to `end` with a control point
 * pushed radially outward. The bulge grows with distance but is CAPPED so a
 * long-haul (e.g. polar LAX→LHR) doesn't balloon off the top of the view.
 */
import * as THREE from 'three';

// Max radial bulge above the unit sphere for the control point. Short hops
// stay near the surface; long hauls top out here instead of growing without
// bound.
const MAX_BULGE = 0.35;

/** Control point of the arc's quadratic bezier (drei's `mid`). */
export function arcControlPoint(
  start: [number, number, number],
  end: [number, number, number]
): [number, number, number] {
  const s = new THREE.Vector3(...start);
  const e = new THREE.Vector3(...end);
  const dist = s.distanceTo(e);
  const bulge = Math.min(dist * 0.4, MAX_BULGE);
  const ctrl = s.clone().add(e).multiplyScalar(0.5).normalize().multiplyScalar(1 + bulge);
  return ctrl.toArray() as [number, number, number];
}

/** Point at parameter t along the arc (t=0.5 → centre of the flight path). */
export function arcPointAt(
  start: [number, number, number],
  end: [number, number, number],
  t: number
): [number, number, number] {
  const s = new THREE.Vector3(...start);
  const e = new THREE.Vector3(...end);
  const c = new THREE.Vector3(...arcControlPoint(start, end));
  // Quadratic bezier B(t) = (1-t)^2 s + 2(1-t)t c + t^2 e
  const mt = 1 - t;
  const p = s
    .clone()
    .multiplyScalar(mt * mt)
    .add(c.multiplyScalar(2 * mt * t))
    .add(e.clone().multiplyScalar(t * t));
  return p.toArray() as [number, number, number];
}
