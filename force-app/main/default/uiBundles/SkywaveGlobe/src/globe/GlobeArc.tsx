import { useRef, useMemo } from 'react';
import { useFrame } from '@react-three/fiber';
import { QuadraticBezierLine } from '@react-three/drei';
import * as THREE from 'three';
import { arcControlPoint } from './arcGeometry';

interface GlobeArcProps {
  start: [number, number, number];
  end: [number, number, number];
}

export function GlobeArc({ start, end }: GlobeArcProps) {
  const lineRef = useRef<{ material: THREE.LineDashedMaterial }>(null);

  const mid = useMemo(() => arcControlPoint(start, end), [start, end]);

  useFrame(({ clock }) => {
    if (lineRef.current?.material) {
      (lineRef.current.material as unknown as { dashOffset: number }).dashOffset =
        -clock.elapsedTime * 0.3;
    }
  });

  return (
    <>
      {/* Soft wide underglow — a solid, low-opacity halo beneath the dashes. */}
      <QuadraticBezierLine
        start={start}
        end={end}
        mid={mid}
        color="#5fe0ff"
        lineWidth={5}
        transparent
        opacity={0.18}
        toneMapped={false}
        depthWrite={false}
      />
      {/* Crisp bright dashed flight path, animated. */}
      <QuadraticBezierLine
        ref={lineRef as never}
        start={start}
        end={end}
        mid={mid}
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
    </>
  );
}
