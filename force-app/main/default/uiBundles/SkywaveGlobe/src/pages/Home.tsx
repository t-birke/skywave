import { useMemo, useState } from 'react';
import { HoloGlobe } from '@/globe/HoloGlobe';
import { toMarkers, toArcs } from '@/data/visitors';
import { useDemoFeed, type FeedStatus } from '@/data/useDemoFeed';

const STATUS_COLOR: Record<FeedStatus, string> = {
  connecting: '#e0a000',
  connected: '#00ff88',
  disconnected: '#888888',
  error: '#ff4444',
};

export default function Home() {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const { visitors, stage, status } = useDemoFeed();

  const markers = useMemo(() => toMarkers(visitors), [visitors]);
  const arcs = useMemo(() => toArcs(visitors), [visitors]);

  return (
    <div style={{ position: 'fixed', inset: 0, background: '#0a0e1a' }}>
      <HoloGlobe
        markers={markers}
        arcs={arcs}
        selectedId={selectedId}
        onSelectMarker={id => setSelectedId(prev => (prev === id ? null : id))}
      />

      {/* Feed status + current stage (demo HUD). */}
      <div
        style={{
          position: 'absolute',
          top: 16,
          left: 16,
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          fontFamily: 'monospace',
          fontSize: 12,
          letterSpacing: '0.08em',
          color: 'rgba(0,180,216,0.85)',
          textTransform: 'uppercase',
          pointerEvents: 'none',
        }}
      >
        <span
          style={{
            width: 9,
            height: 9,
            borderRadius: '50%',
            background: STATUS_COLOR[status],
            boxShadow: `0 0 8px ${STATUS_COLOR[status]}`,
          }}
        />
        <span>{status}</span>
        <span style={{ color: 'rgba(0,180,216,0.4)' }}>·</span>
        <span>stage: {stage}</span>
        <span style={{ color: 'rgba(0,180,216,0.4)' }}>·</span>
        <span>{visitors.length} visitor{visitors.length === 1 ? '' : 's'}</span>
      </div>
    </div>
  );
}
