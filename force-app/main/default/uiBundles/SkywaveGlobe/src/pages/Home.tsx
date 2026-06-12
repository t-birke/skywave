import { useMemo, useState } from 'react';
import { HoloGlobe } from '@/globe/HoloGlobe';
import { toMarkers, toArcs } from '@/data/visitors';
import { useDemoFeed, type FeedStatus } from '@/data/useDemoFeed';
import { useReplay } from '@/data/useReplay';

const STATUS_COLOR: Record<FeedStatus, string> = {
  connecting: '#e0a000',
  connected: '#00ff88',
  disconnected: '#888888',
  error: '#ff4444',
};

// Replay presets, in hours. `null` = LIVE.
const PRESETS: { label: string; hours: number | null }[] = [
  { label: 'LIVE', hours: null },
  { label: '1H', hours: 1 },
  { label: '3H', hours: 3 },
  { label: '6H', hours: 6 },
  { label: '24H', hours: 24 },
];

export default function Home() {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  // Active replay window in hours (null = live). `replayNow` is captured at
  // click time so the replay range is stable across re-renders.
  const [replayHours, setReplayHours] = useState<number | null>(null);
  const [replayNow, setReplayNow] = useState<number>(0);

  const live = useDemoFeed();
  const replay = useReplay({ hours: replayHours, nowMs: replayNow });

  const replaying = replayHours != null;
  const visitors = replaying ? replay.visitors : live.visitors;

  const markers = useMemo(() => toMarkers(visitors), [visitors]);
  const arcs = useMemo(() => toArcs(visitors), [visitors]);

  const pick = (hours: number | null) => {
    setSelectedId(null);
    setReplayHours(hours);
    // Capture the replay anchor once per click (Date.now is only allowed in
    // event handlers here, never in render).
    if (hours != null) setReplayNow(Date.now());
  };

  return (
    <div style={{ position: 'fixed', inset: 0, background: '#0a0e1a' }}>
      <HoloGlobe
        markers={markers}
        arcs={arcs}
        selectedId={selectedId}
        onSelectMarker={id => setSelectedId(prev => (prev === id ? null : id))}
      />

      {/* HUD: status/stage + replay presets. */}
      <div
        style={{
          position: 'absolute',
          top: 16,
          left: 16,
          display: 'flex',
          flexDirection: 'column',
          gap: 10,
          fontFamily: 'monospace',
          fontSize: 12,
          letterSpacing: '0.08em',
          color: 'rgba(0,180,216,0.85)',
          textTransform: 'uppercase',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, pointerEvents: 'none' }}>
          <span
            style={{
              width: 9,
              height: 9,
              borderRadius: '50%',
              background: replaying ? '#9b6cff' : STATUS_COLOR[live.status],
              boxShadow: `0 0 8px ${replaying ? '#9b6cff' : STATUS_COLOR[live.status]}`,
            }}
          />
          {replaying ? (
            <span>
              replay {replayHours}h{replay.phase === 'loading' ? ' · loading…' : ''}
              {replay.phase === 'done' ? ' · done' : ''}
              {replay.phase === 'error' ? ' · error' : ''}
            </span>
          ) : (
            <>
              <span>{live.status}</span>
              <span style={{ color: 'rgba(0,180,216,0.4)' }}>·</span>
              <span>stage: {live.stage}</span>
            </>
          )}
          <span style={{ color: 'rgba(0,180,216,0.4)' }}>·</span>
          <span>
            {visitors.length} visitor{visitors.length === 1 ? '' : 's'}
          </span>
        </div>

        {/* Preset buttons. */}
        <div style={{ display: 'flex', gap: 6 }}>
          {PRESETS.map(p => {
            const active = p.hours === replayHours;
            return (
              <button
                key={p.label}
                onClick={() => pick(p.hours)}
                style={{
                  fontFamily: 'monospace',
                  fontSize: 11,
                  letterSpacing: '0.1em',
                  padding: '4px 10px',
                  borderRadius: 4,
                  cursor: 'pointer',
                  color: active ? '#0a0e1a' : 'rgba(0,180,216,0.85)',
                  background: active
                    ? p.hours == null
                      ? '#00ff88'
                      : '#9b6cff'
                    : 'rgba(0,180,216,0.08)',
                  border: `1px solid ${
                    active ? 'transparent' : 'rgba(0,180,216,0.3)'
                  }`,
                  transition: 'background 0.15s, color 0.15s',
                }}
              >
                {p.label}
              </button>
            );
          })}
        </div>

        {/* Replay progress bar. */}
        {replaying && replay.phase === 'playing' && (
          <div
            style={{
              width: 220,
              height: 3,
              background: 'rgba(155,108,255,0.2)',
              borderRadius: 2,
              overflow: 'hidden',
              pointerEvents: 'none',
            }}
          >
            <div
              style={{
                width: `${Math.round(replay.progress * 100)}%`,
                height: '100%',
                background: '#9b6cff',
                transition: 'width 0.1s linear',
              }}
            />
          </div>
        )}
      </div>
    </div>
  );
}
