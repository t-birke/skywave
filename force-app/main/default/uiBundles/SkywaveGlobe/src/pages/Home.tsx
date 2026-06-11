import { useMemo, useState } from 'react';
import { HoloGlobe } from '@/globe/HoloGlobe';
import { toMarkers, toArcs, type Visitor } from '@/data/visitors';

// Placeholder visitors — replaced by the live Skywave feed in a later step.
// Avatar images use a deterministic public source just for local preview.
const av = (seed: string) => `https://i.pravatar.cc/80?u=${seed}`;

const DEMO_VISITORS: Visitor[] = [
  {
    sessionId: 'sess-amelia',
    firstName: 'Amelia',
    lastName: 'Cruz',
    avatarUrl: av('amelia'),
    seat: '14A',
    route: { legs: [{ from: 'LAX', to: 'JFK' }, { from: 'JFK', to: 'NBO' }], isConnection: true },
  },
  {
    sessionId: 'sess-ben',
    firstName: 'Ben',
    lastName: 'Okafor',
    avatarUrl: av('ben'),
    seat: '2C',
    route: { legs: [{ from: 'LHR', to: 'JFK' }], isConnection: false },
  },
  {
    sessionId: 'sess-chen',
    firstName: 'Chen',
    avatarUrl: av('chen'),
    city: 'Singapore',
    lat: 1.3521,
    lon: 103.8198,
  },
  {
    sessionId: 'sess-dara',
    firstName: 'Dara',
    avatarUrl: av('dara'),
    city: 'São Paulo',
    lat: -23.55,
    lon: -46.63,
    alert: true,
  },
];

export default function Home() {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const markers = useMemo(() => toMarkers(DEMO_VISITORS), []);
  const arcs = useMemo(() => toArcs(DEMO_VISITORS), []);

  return (
    <div style={{ position: 'fixed', inset: 0, background: '#0a0e1a' }}>
      <HoloGlobe
        markers={markers}
        arcs={arcs}
        selectedId={selectedId}
        onSelectMarker={id => setSelectedId(prev => (prev === id ? null : id))}
      />
    </div>
  );
}
