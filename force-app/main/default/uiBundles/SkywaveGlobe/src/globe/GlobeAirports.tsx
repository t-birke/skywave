/**
 * Static airport network — small dots on the globe surface with subtle IATA
 * labels. Renders beneath the live visitor markers (renderOrder low) so a
 * visitor avatar always sits on top of its origin/destination airport.
 */
import { useMemo } from 'react';
import { Html } from '@react-three/drei';
import { AIRPORTS } from '@/data/airports';
import { latLngToArray } from './data/geo';

const GLOBE_RADIUS = 1;
const DOT_COLOR = '#2f6f8f';

export function GlobeAirports() {
  const pins = useMemo(
    () =>
      Object.values(AIRPORTS).map(a => ({
        code: a.code,
        pos: latLngToArray(a.lat, a.lon, GLOBE_RADIUS * 1.002),
      })),
    []
  );

  return (
    <group>
      {pins.map(p => (
        <group key={p.code} position={p.pos}>
          <mesh raycast={() => {}}>
            <sphereGeometry args={[0.006, 8, 8]} />
            <meshBasicMaterial color={DOT_COLOR} toneMapped={false} />
          </mesh>
          <Html
            center
            style={{ pointerEvents: 'none', whiteSpace: 'nowrap' }}
            position={[0, 0.018, 0]}
          >
            <div
              style={{
                fontFamily: 'monospace',
                fontSize: '6px',
                letterSpacing: '0.12em',
                color: 'rgba(0,180,216,0.35)',
              }}
            >
              {p.code}
            </div>
          </Html>
        </group>
      ))}
    </group>
  );
}
