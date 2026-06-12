import { useRef, useMemo } from 'react';
import { useFrame } from '@react-three/fiber';
import { Line, Html } from '@react-three/drei';
import * as THREE from 'three';
import { arcPoints, arcPointAt } from './arcGeometry';

interface GlobeArcProps {
  start: [number, number, number];
  end: [number, number, number];
  label?: string;
}

export function GlobeArc({ start, end, label }: GlobeArcProps) {
  const lineRef = useRef<{ material: THREE.LineDashedMaterial }>(null);

  // Great-circle polyline with a sine altitude arch — always above surface.
  const points = useMemo(() => arcPoints(start, end), [start, end]);
  // Route label rides just past the apex — lifted outward so it floats above
  // the visitor avatar (which sits exactly on the apex).
  const labelPos = useMemo(() => {
    const a = arcPointAt(start, end, 0.5);
    const v = new THREE.Vector3(...a);
    return v.multiplyScalar(1.06).toArray() as [number, number, number];
  }, [start, end]);

  useFrame(({ clock }) => {
    if (lineRef.current?.material) {
      (lineRef.current.material as unknown as { dashOffset: number }).dashOffset =
        -clock.elapsedTime * 0.3;
    }
  });

  return (
    <>
      {/* Soft wide underglow — a solid, low-opacity halo beneath the dashes. */}
      <Line
        points={points}
        color="#5fe0ff"
        lineWidth={5}
        transparent
        opacity={0.18}
        toneMapped={false}
        depthWrite={false}
      />
      {/* Crisp bright dashed flight path, animated. */}
      <Line
        ref={lineRef as never}
        points={points}
        color="#7fefff"
        lineWidth={2}
        transparent
        opacity={0.95}
        toneMapped={false}
        depthWrite={false}
        dashed
        dashScale={20}
        dashSize={0.3}
        gapSize={0.2}
      />
      {/* Route name riding above the arc apex. */}
      {label && (
        <Html center style={{ pointerEvents: 'none', whiteSpace: 'nowrap' }} position={labelPos}>
          <div
            style={{
              fontFamily: 'monospace',
              fontSize: '8px',
              letterSpacing: '0.12em',
              color: 'rgba(127,239,255,0.85)',
              textShadow: '0 0 6px rgba(0,180,216,0.6)',
            }}
          >
            {label}
          </div>
        </Html>
      )}
    </>
  );
}
