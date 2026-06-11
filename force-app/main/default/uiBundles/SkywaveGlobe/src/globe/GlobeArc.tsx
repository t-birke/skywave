import { useRef, useMemo } from 'react';
import { useFrame } from '@react-three/fiber';
import { QuadraticBezierLine } from '@react-three/drei';
import * as THREE from 'three';

interface GlobeArcProps {
  start: [number, number, number];
  end: [number, number, number];
}

export function GlobeArc({ start, end }: GlobeArcProps) {
  const lineRef = useRef<{ material: THREE.LineDashedMaterial }>(null);

  const mid = useMemo(() => {
    const s = new THREE.Vector3(...start);
    const e = new THREE.Vector3(...end);
    const midpoint = s.clone().add(e).multiplyScalar(0.5);
    const dist = s.distanceTo(e);
    midpoint.normalize().multiplyScalar(1 + dist * 0.4);
    return midpoint.toArray() as [number, number, number];
  }, [start, end]);

  useFrame(({ clock }) => {
    if (lineRef.current?.material) {
      (lineRef.current.material as unknown as { dashOffset: number }).dashOffset =
        -clock.elapsedTime * 0.3;
    }
  });

  return (
    <QuadraticBezierLine
      ref={lineRef as never}
      start={start}
      end={end}
      mid={mid}
      color="#00b4d8"
      lineWidth={1}
      transparent
      opacity={0.2}
      dashed
      dashScale={20}
      dashSize={0.3}
      gapSize={0.2}
    />
  );
}
