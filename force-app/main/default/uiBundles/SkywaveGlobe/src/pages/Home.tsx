import { useEffect, useMemo, useState } from 'react';
import { HoloGlobe } from '@/globe/HoloGlobe';
import { toMarkers, toArcs } from '@/data/visitors';
import { useDemoFeed, type FeedStatus } from '@/data/useDemoFeed';
import { useReplay } from '@/data/useReplay';
import { loadOptionImageMap, type OptionImageMap } from '@/data/surveyImages';
import { fetchActiveSession, setSeatEnabled } from '@/data/seatToggle';

const STATUS_COLOR: Record<FeedStatus, string> = {
  connecting: '#e0a000',
  connected: '#00ff88',
  disconnected: '#888888',
  error: '#ff4444',
};

// Replay presets, in hours. `null` = LIVE. Windows reach back far enough to
// catch persisted demo data between live runs (newest records can be days old).
const PRESETS: { label: string; hours: number | null }[] = [
  { label: 'LIVE', hours: null },
  { label: '6H', hours: 6 },
  { label: '24H', hours: 24 },
  { label: '7D', hours: 24 * 7 },
  { label: '30D', hours: 24 * 30 },
];

const SEAT_ON = 'agent_seat_pass';

export default function Home() {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  // Active replay window in hours (null = live). `replayNow` is captured at
  // click time so the replay range is stable across re-renders.
  const [replayHours, setReplayHours] = useState<number | null>(null);
  const [replayNow, setReplayNow] = useState<number>(0);

  // Multi-tenant: the presenter's OWN active Demo_Session__c. Resolved by the
  // active-session effect below; until then it is null and the feed/replay
  // filters are no-ops (fail-open). Once set, both the live feed and replay
  // scope to this session so only this presenter's visitors render.
  const [myActiveSessionId, setMyActiveSessionId] = useState<string | null>(null);

  const live = useDemoFeed(myActiveSessionId);
  const replay = useReplay({ hours: replayHours, nowMs: replayNow, activeDemoSessionId: myActiveSessionId });

  const replaying = replayHours != null;
  const visitors = replaying ? replay.visitors : live.visitors;

  const markers = useMemo(() => toMarkers(visitors), [visitors]);
  const arcs = useMemo(() => toArcs(visitors), [visitors]);

  // Survey-option → image map, fetched once; used to resolve answer thumbs.
  const [optionImages, setOptionImages] = useState<OptionImageMap>({});
  useEffect(() => {
    loadOptionImageMap().then(setOptionImages);
  }, []);

  // Inconspicuous seat-capability switch (bottom-right corner dot). Reflects
  // and flips Demo_Session__c.State__c agent_seat_fail <-> agent_seat_pass,
  // which the agent reads per turn to gate the seat-change subagent live.
  const [seatOn, setSeatOn] = useState<boolean>(false);
  const [seatBusy, setSeatBusy] = useState<boolean>(false);

  // Stage seeded from Demo_Session__c.State__c on load. Live stage_changed
  // events from the relay (useDemoFeed) override this once they flow; before
  // the first one arrives the seeded value is the visible status — mirroring
  // how the old skywaveDemoMonitor LWC read the active session on load.
  const [seededStage, setSeededStage] = useState<string>('idle');

  // One active-session read (owner-scoped) seeds the seat indicator, the
  // stage, AND the feed/replay scope key — so the globe shows only this
  // presenter's visitors.
  useEffect(() => {
    fetchActiveSession()
      .then(s => {
        if (!s) return;
        setMyActiveSessionId(s.id);
        setSeatOn(s.state === SEAT_ON);
        if (s.state) setSeededStage(s.state);
      })
      .catch(() => {});
  }, []);

  // Prefer a live stage once CometD delivers one; otherwise show the seed.
  const displayStage = live.stage !== 'idle' ? live.stage : seededStage;
  const toggleSeat = async () => {
    if (seatBusy) return;
    setSeatBusy(true);
    try {
      const next = await setSeatEnabled();
      setSeatOn(next);
    } catch {
      // best-effort; leave the indicator as-is on failure
    } finally {
      setSeatBusy(false);
    }
  };

  const selectedVisitor = useMemo(
    () => (selectedId ? visitors.find(v => v.sessionId === selectedId) ?? null : null),
    [selectedId, visitors]
  );

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
        selectedVisitor={selectedVisitor}
        optionImages={optionImages}
        onClosePanel={() => setSelectedId(null)}
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
              <span>stage: {displayStage}</span>
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

      {/* Inconspicuous seat-capability switch — a dim corner dot. Invisible to
          the audience; clickable by the operator to flip seat-change ON/OFF on
          the active demo session (agent reads it live, no reload). Brightens
          when enabled. */}
      <div
        onClick={toggleSeat}
        title={`Seat change: ${seatOn ? 'ENABLED' : 'disabled'}${
          seatBusy ? ' (…)' : ''
        } — click to ${seatOn ? 'disable' : 'enable'}`}
        style={{
          position: 'absolute',
          bottom: 10,
          right: 10,
          width: 10,
          height: 10,
          borderRadius: '50%',
          cursor: 'pointer',
          background: seatOn ? 'rgba(0,255,136,0.9)' : 'rgba(255,255,255,0.06)',
          boxShadow: seatOn ? '0 0 10px rgba(0,255,136,0.8)' : 'none',
          opacity: seatBusy ? 0.4 : 1,
          transition: 'background 0.2s, box-shadow 0.2s, opacity 0.15s',
        }}
      />
    </div>
  );
}
