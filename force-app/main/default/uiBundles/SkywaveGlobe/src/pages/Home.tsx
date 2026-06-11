import { useMemo } from 'react';
import { HoloGlobe } from '@/globe/HoloGlobe';
import { latLngToArray } from '@/globe/data/geo';
import type { GlobeMarker } from '@/globe/types';

const GLOBE_RADIUS = 1;

// Placeholder markers — replaced by live Skywave session data in a later step.
const DEMO_POINTS: { id: string; lat: number; lng: number; label: string; status: GlobeMarker['status'] }[] = [
  { id: 'jfk', lat: 40.6413, lng: -73.7781, label: 'JFK', status: 'active' },
  { id: 'lhr', lat: 51.47, lng: -0.4543, label: 'LHR', status: 'active' },
  { id: 'nbo', lat: -1.3192, lng: 36.9278, label: 'NBO', status: 'idle' },
  { id: 'sin', lat: 1.3644, lng: 103.9915, label: 'SIN', status: 'alert' },
];

export default function Home() {
  const markers = useMemo<GlobeMarker[]>(
    () =>
      DEMO_POINTS.map(p => ({
        id: p.id,
        position: latLngToArray(p.lat, p.lng, GLOBE_RADIUS * 1.01),
        label: p.label,
        status: p.status,
      })),
    []
  );

  return (
    <div style={{ position: 'fixed', inset: 0, background: '#0a0e1a' }}>
      <HoloGlobe markers={markers} />
    </div>
  );
}
