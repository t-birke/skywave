import { useRef, useState } from 'react';
import { useFrame, useThree } from '@react-three/fiber';
import { Html } from '@react-three/drei';
import * as THREE from 'three';
import type { MarkerStatus } from './types';

const STATUS_COLORS: Record<MarkerStatus, string> = {
  active: '#00ff88',
  idle: '#666666',
  alert: '#ff4444',
};

interface GlobeMarkerProps {
  id: string;
  status: MarkerStatus;
  position: [number, number, number];
  label: string;
  sublabel?: string;
  avatarUrl?: string | null;
  selected: boolean;
  dimmed: boolean;
  onSelect: (id: string) => void;
}

export function GlobeMarker({
  id,
  status,
  position,
  label,
  sublabel,
  avatarUrl,
  selected,
  dimmed,
  onSelect,
}: GlobeMarkerProps) {
  const groupRef = useRef<THREE.Group>(null);
  const ringRef = useRef<THREE.Mesh>(null);
  const pulseRef = useRef<THREE.Mesh>(null);
  const dotRef = useRef<THREE.Mesh>(null);
  const [hovered, setHovered] = useState(false);
  const { camera } = useThree();

  const color = STATUS_COLORS[status];

  useFrame(({ clock }) => {
    if (!groupRef.current) return;

    const pos = new THREE.Vector3(...position);
    groupRef.current.position.copy(pos);
    groupRef.current.lookAt(pos.clone().multiplyScalar(2));

    // Fade markers on backside — dot product of marker normal vs camera direction
    const camDir = new THREE.Vector3().subVectors(camera.position, pos).normalize();
    const markerNormal = pos.clone().normalize();
    const facing = markerNormal.dot(camDir); // 1 = facing camera, -1 = away

    const backsideFade = facing > 0 ? 1 : Math.max(0.2, 0.2 + facing + 0.2);
    const finalOpacity = (dimmed ? 0.3 : 1) * backsideFade;

    if (dotRef.current) {
      (dotRef.current.material as THREE.MeshBasicMaterial).opacity = finalOpacity;
    }
    if (ringRef.current) {
      (ringRef.current.material as THREE.MeshBasicMaterial).opacity = 0.6 * finalOpacity;
    }

    if (status === 'alert' && ringRef.current) {
      const scale = 1 + Math.sin(clock.elapsedTime * 4) * 0.3;
      ringRef.current.scale.setScalar(scale);
    }

    if (selected && pulseRef.current) {
      const t = (clock.elapsedTime * 0.8) % 1;
      pulseRef.current.scale.setScalar(1 + t * 3);
      (pulseRef.current.material as THREE.MeshBasicMaterial).opacity =
        0.4 * (1 - t) * backsideFade;
    }
  });

  const dotSize = selected ? 0.028 : 0.02;
  const ringSize = selected ? 0.055 : 0.04;

  return (
    <group ref={groupRef} renderOrder={999}>
      {/* Invisible hit target */}
      <mesh
        onClick={e => {
          e.stopPropagation();
          onSelect(id);
        }}
        onPointerOver={e => {
          e.stopPropagation();
          setHovered(true);
          document.body.style.cursor = 'pointer';
        }}
        onPointerOut={() => {
          setHovered(false);
          document.body.style.cursor = 'auto';
        }}
      >
        <sphereGeometry args={[0.05, 8, 8]} />
        <meshBasicMaterial transparent opacity={0} depthWrite={false} depthTest={false} />
      </mesh>

      {/* Visible dot — hidden when an avatar sprite stands in for it. */}
      {!avatarUrl && (
        <mesh ref={dotRef}>
          <sphereGeometry args={[dotSize, 12, 12]} />
          <meshBasicMaterial
            color={color}
            transparent
            opacity={1}
            toneMapped={false}
            depthTest={false}
            depthWrite={false}
          />
        </mesh>
      )}

      {/* Always-on avatar sprite, ringed in the status color. */}
      {avatarUrl && (
        <Html center style={{ pointerEvents: 'none' }} position={[0, 0, 0]}>
          <div
            style={{
              width: selected ? '38px' : '30px',
              height: selected ? '38px' : '30px',
              borderRadius: '50%',
              border: `2.5px solid ${color}`,
              // Layered glow: tight bright core + soft wide halo so the
              // avatar reads as lit, not painted on the surface.
              boxShadow: `0 0 6px ${color}, 0 0 16px ${color}99, 0 0 2px #ffffff`,
              overflow: 'hidden',
              background: '#0d1117',
              opacity: dimmed ? 0.35 : 1,
              transition: 'width 0.2s, height 0.2s',
            }}
          >
            <img
              src={avatarUrl}
              alt=""
              referrerPolicy="no-referrer"
              style={{
                width: '100%',
                height: '100%',
                objectFit: 'cover',
                display: 'block',
                // Lift the photo so faces pop against the dark globe.
                filter: 'brightness(1.12) contrast(1.08) saturate(1.1)',
              }}
            />
          </div>
        </Html>
      )}

      {/* Outer ring */}
      <mesh ref={ringRef}>
        <ringGeometry args={[ringSize * 0.7, ringSize, 24]} />
        <meshBasicMaterial
          color={color}
          transparent
          opacity={0.6}
          side={THREE.DoubleSide}
          toneMapped={false}
          depthTest={false}
          depthWrite={false}
        />
      </mesh>

      {/* Selected ping ring */}
      {selected && (
        <mesh ref={pulseRef}>
          <ringGeometry args={[ringSize * 0.9, ringSize * 1.1, 32]} />
          <meshBasicMaterial
            color={color}
            transparent
            opacity={0.4}
            side={THREE.DoubleSide}
            toneMapped={false}
            depthTest={false}
            depthWrite={false}
          />
        </mesh>
      )}

      {/* Persistent label — pushed clear of the avatar sprite when present. */}
      {!dimmed && (
        <Html
          center
          style={{ pointerEvents: 'none', whiteSpace: 'nowrap' }}
          position={[0, avatarUrl ? -0.1 : -0.06, 0]}
        >
          <div
            style={{
              fontFamily: 'monospace',
              fontSize: '7px',
              letterSpacing: '0.15em',
              textTransform: 'uppercase',
              color: 'rgba(0, 180, 216, 0.5)',
            }}
          >
            {label}
          </div>
        </Html>
      )}

      {/* Hover tooltip */}
      {hovered && (
        <Html
          center
          style={{ pointerEvents: 'none', whiteSpace: 'nowrap' }}
          position={[0, 0.08, 0]}
        >
          <div
            style={{
              borderRadius: '4px',
              background: 'rgba(13, 17, 23, 0.9)',
              padding: '4px 8px',
              fontFamily: 'monospace',
              fontSize: '10px',
              letterSpacing: '0.05em',
              color: '#00b4d8',
              boxShadow: '0 4px 12px rgba(0,0,0,0.5)',
              backdropFilter: 'blur(4px)',
              border: '1px solid rgba(0, 180, 216, 0.2)',
            }}
          >
            <span>{label.toUpperCase()}</span>
            {sublabel && (
              <span style={{ marginLeft: '6px', color: 'rgba(0, 180, 216, 0.5)' }}>
                {sublabel}
              </span>
            )}
          </div>
        </Html>
      )}
    </group>
  );
}
