/**
 * Shared geometry for the curved flight arcs.
 *
 * Single source of truth so the rendered line (GlobeArc) and the avatar that
 * rides it (visitors.ts) use the IDENTICAL curve — change it here and both
 * move together.
 *
 * The arc is a GREAT CIRCLE (slerp between the two endpoint directions) lifted
 * by a sine altitude arch: radius(t) = baseRadius + peak·sin(π·t). Because
 * sin(π·t) ≥ 0 for t in [0,1], the arc radius is ALWAYS ≥ the surface — so the
 * path can never dip below the globe (the bug a single-control-point bezier
 * had, where the curve sagged toward the chord and cut through the sphere on
 * long arcs).
 */
import * as THREE from 'three';

const SEGMENTS = 64;

// The globe is a unit sphere, so 1 unit == Earth's radius. Express the arch
// height in real km and convert, so it's tunable in human terms.
const EARTH_RADIUS_KM = 6371;
const APEX_PER_RADIAN_KM = 190; // arch grows with arc length…
const MAX_APEX_KM = 320; // …but a long haul tops out here (~300 km)

/**
 * Peak lift of the arch above the surface, in globe units. Scales with arc
 * length (great-circle angle ω in radians) and caps near MAX_APEX_KM so a
 * half-globe route stays a low, flat arch rather than towering thousands of km.
 */
function peakAltitude(omega: number): number {
  const km = Math.min(omega * APEX_PER_RADIAN_KM, MAX_APEX_KM);
  return km / EARTH_RADIUS_KM;
}

/** Point at parameter t along the arc (t=0.5 → top-centre of the flight path). */
export function arcPointAt(
  start: [number, number, number],
  end: [number, number, number],
  t: number
): [number, number, number] {
  const s = new THREE.Vector3(...start);
  const e = new THREE.Vector3(...end);
  const baseR = (s.length() + e.length()) / 2;
  const sn = s.clone().normalize();
  const en = e.clone().normalize();
  const omega = Math.acos(THREE.MathUtils.clamp(sn.dot(en), -1, 1));

  let dir: THREE.Vector3;
  if (omega < 1e-4) {
    dir = sn; // coincident endpoints — degenerate, no real arc
  } else {
    // Spherical linear interpolation along the great circle.
    const sinOmega = Math.sin(omega);
    const a = Math.sin((1 - t) * omega) / sinOmega;
    const b = Math.sin(t * omega) / sinOmega;
    dir = sn.clone().multiplyScalar(a).add(en.clone().multiplyScalar(b)).normalize();
  }
  const r = baseR + peakAltitude(omega) * Math.sin(Math.PI * t);
  return dir.multiplyScalar(r).toArray() as [number, number, number];
}

/** Tessellated polyline of the arc, for rendering. */
export function arcPoints(
  start: [number, number, number],
  end: [number, number, number]
): [number, number, number][] {
  const pts: [number, number, number][] = [];
  for (let i = 0; i <= SEGMENTS; i++) {
    pts.push(arcPointAt(start, end, i / SEGMENTS));
  }
  return pts;
}
