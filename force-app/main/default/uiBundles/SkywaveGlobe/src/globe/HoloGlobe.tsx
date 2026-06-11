import { useMemo, useRef, useEffect } from 'react';
import { Canvas, useFrame, useThree } from '@react-three/fiber';
import { OrbitControls, Line, Sphere } from '@react-three/drei';
import type { OrbitControls as OrbitControlsImpl } from 'three-stdlib';
import * as THREE from 'three';
import { atmosphereVertexShader, atmosphereFragmentShader } from './shaders/atmosphere';
import { latLngToVector3, createEarthTexture } from './data/geo';
import { GlobeMarker } from './GlobeMarker';
import { GlobeArc } from './GlobeArc';
import type { GlobeMarker as GlobeMarkerData, GlobeArcData } from './types';

const GLOBE_RADIUS = 1;
const GRID_COLOR = '#1a3a5c';

function GlobeGrid() {
  const gridLines = useMemo(() => {
    const lines: THREE.Vector3[][] = [];

    for (let lng = 0; lng < 360; lng += 30) {
      const pts: THREE.Vector3[] = [];
      for (let lat = -90; lat <= 90; lat += 3) {
        pts.push(latLngToVector3(lat, lng, GLOBE_RADIUS * 1.002));
      }
      lines.push(pts);
    }

    for (let lat = -60; lat <= 60; lat += 30) {
      const pts: THREE.Vector3[] = [];
      for (let lng = 0; lng <= 360; lng += 3) {
        pts.push(latLngToVector3(lat, lng, GLOBE_RADIUS * 1.002));
      }
      lines.push(pts);
    }

    return lines;
  }, []);

  return (
    <>
      {gridLines.map((pts, i) => (
        <Line
          key={`grid-${i}`}
          points={pts}
          color={GRID_COLOR}
          lineWidth={0.5}
          transparent
          opacity={0.2}
        />
      ))}
    </>
  );
}

function EarthSphere() {
  const texture = useMemo(() => {
    const canvas = createEarthTexture(2048, 1024);
    const tex = new THREE.CanvasTexture(canvas);
    tex.wrapS = THREE.RepeatWrapping;
    tex.wrapT = THREE.ClampToEdgeWrapping;
    return tex;
  }, []);

  return (
    <Sphere args={[GLOBE_RADIUS, 64, 64]} raycast={() => {}}>
      <meshBasicMaterial map={texture} />
    </Sphere>
  );
}

function Atmosphere() {
  const uniforms = useMemo(
    () => ({
      uColor: { value: new THREE.Color('#00b4d8') },
      uIntensity: { value: 0.6 },
    }),
    []
  );

  return (
    <Sphere args={[GLOBE_RADIUS * 1.04, 48, 48]} raycast={() => {}}>
      <shaderMaterial
        vertexShader={atmosphereVertexShader}
        fragmentShader={atmosphereFragmentShader}
        uniforms={uniforms}
        transparent
        side={THREE.BackSide}
        depthWrite={false}
      />
    </Sphere>
  );
}

function RadarSweep() {
  const meshRef = useRef<THREE.Mesh>(null);

  const geometry = useMemo(() => {
    return new THREE.RingGeometry(0, GLOBE_RADIUS * 1.02, 32, 1, 0, Math.PI / 6);
  }, []);

  useFrame(({ clock }) => {
    if (meshRef.current) {
      meshRef.current.rotation.y = clock.elapsedTime * 1.05;
    }
  });

  return (
    <mesh
      ref={meshRef}
      geometry={geometry}
      rotation={[Math.PI / 2, 0, 0]}
      raycast={() => {}}
    >
      <meshBasicMaterial
        color="#00ffff"
        transparent
        opacity={0.04}
        side={THREE.DoubleSide}
        depthWrite={false}
      />
    </mesh>
  );
}

function shortAngleDist(from: number, to: number): number {
  const diff = ((to - from + Math.PI) % (Math.PI * 2)) - Math.PI;
  return diff < -Math.PI ? diff + Math.PI * 2 : diff;
}

function CameraController({
  selectedId,
  markers,
  controlsRef,
}: {
  selectedId: string | null;
  markers: GlobeMarkerData[];
  controlsRef: React.RefObject<OrbitControlsImpl | null>;
}) {
  const { camera } = useThree();
  const animating = useRef(false);
  const startSpherical = useRef(new THREE.Spherical());
  const endSpherical = useRef(new THREE.Spherical());
  const progress = useRef(0);
  const lastSelection = useRef<string | null>(null);

  useEffect(() => {
    if (selectedId === lastSelection.current) return;
    lastSelection.current = selectedId;

    if (!selectedId || !controlsRef.current) return;
    const marker = markers.find(m => m.id === selectedId);
    if (!marker) return;

    const pos = new THREE.Vector3(...marker.position);
    const camDist = camera.position.length();
    const targetCamPos = pos.normalize().multiplyScalar(camDist);

    startSpherical.current.setFromVector3(camera.position);
    endSpherical.current.setFromVector3(targetCamPos);
    progress.current = 0;
    animating.current = true;
  }, [selectedId, markers, camera, controlsRef]);

  useFrame((_, delta) => {
    if (!animating.current || !controlsRef.current) return;

    progress.current = Math.min(1, progress.current + delta * 2);
    const t = 1 - Math.pow(1 - progress.current, 3);

    const s = startSpherical.current;
    const e = endSpherical.current;
    const current = new THREE.Spherical(
      THREE.MathUtils.lerp(s.radius, e.radius, t),
      THREE.MathUtils.lerp(s.phi, e.phi, t),
      s.theta + shortAngleDist(s.theta, e.theta) * t
    );

    camera.position.setFromSpherical(current);
    controlsRef.current.update();

    if (progress.current >= 1) {
      animating.current = false;
    }
  });

  return null;
}

function GlobeScene({ children }: { children?: React.ReactNode }) {
  return (
    <group>
      <EarthSphere />
      <GlobeGrid />
      <Atmosphere />
      <RadarSweep />
      {children}
    </group>
  );
}

interface HoloGlobeProps {
  markers?: GlobeMarkerData[];
  arcs?: GlobeArcData[];
  selectedId?: string | null;
  onSelectMarker?: (id: string) => void;
}

export function HoloGlobe({
  markers = [],
  arcs = [],
  selectedId,
  onSelectMarker,
}: HoloGlobeProps) {
  const controlsRef = useRef<OrbitControlsImpl>(null);

  return (
    <div className="h-full w-full">
      <Canvas
        camera={{ position: [0, 0, 3], fov: 45 }}
        gl={{ antialias: true, alpha: false }}
        onCreated={({ gl }) => {
          gl.setClearColor('#0a0e1a');
        }}
      >
        <ambientLight intensity={0.1} color="#4488ff" />

        <GlobeScene>
          {markers.map(m => (
            <GlobeMarker
              key={m.id}
              id={m.id}
              status={m.status}
              position={m.position}
              label={m.label}
              sublabel={m.sublabel}
              avatarUrl={m.avatarUrl}
              selected={m.id === selectedId}
              dimmed={selectedId != null && m.id !== selectedId}
              onSelect={onSelectMarker ?? (() => {})}
            />
          ))}
          {arcs.map(arc => (
            <GlobeArc key={arc.id} start={arc.start} end={arc.end} />
          ))}
        </GlobeScene>

        <CameraController
          selectedId={selectedId ?? null}
          markers={markers}
          controlsRef={controlsRef}
        />
        <OrbitControls
          ref={controlsRef}
          autoRotate
          autoRotateSpeed={0.3}
          enablePan={false}
          enableZoom={false}
          minDistance={2}
          maxDistance={6}
          enableDamping
          dampingFactor={0.05}
        />
      </Canvas>
    </div>
  );
}

export { GLOBE_RADIUS };
