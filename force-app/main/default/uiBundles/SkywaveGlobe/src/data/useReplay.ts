/**
 * Historical time-lapse replay.
 *
 * Fetches a record-derived timeline (replayData) for the last N hours and
 * plays it through the SAME visitor reducer the live feed uses, stepping a
 * few events per animation frame so the globe fills in as a smooth time-lapse
 * — and so thousands of events auto-throttle to a fixed, watchable duration
 * instead of dumping at once.
 */
import { useEffect, useState } from 'react';
import type { Visitor } from './visitors';
import { applyPlatformEvent, snapshot, type VisitorMap } from './visitorReducer';
import { fetchReplayTimeline, type TimelineEntry } from './replayData';

export type ReplayPhase = 'idle' | 'loading' | 'playing' | 'done' | 'error';

export interface ReplayState {
  phase: ReplayPhase;
  visitors: Visitor[];
  /** 0..1 progress through the timeline. */
  progress: number;
  total: number;
}

// Target wall-clock duration for a full replay, regardless of event count.
const TARGET_DURATION_MS = 8000;
// Don't crawl when there are only a handful of events.
const MIN_STEP_MS = 40;

interface Options {
  hours: number | null; // null = not replaying
  nowMs: number;
  activeDemoSessionId?: string | null;
}

export function useReplay({ hours, nowMs, activeDemoSessionId }: Options): ReplayState {
  const [phase, setPhase] = useState<ReplayPhase>('idle');
  const [visitors, setVisitors] = useState<Visitor[]>([]);
  const [progress, setProgress] = useState(0);
  const [total, setTotal] = useState(0);

  useEffect(() => {
    if (hours == null) {
      setPhase('idle');
      setVisitors([]);
      setProgress(0);
      setTotal(0);
      return;
    }

    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const map: VisitorMap = new Map();

    setPhase('loading');
    setVisitors([]);
    setProgress(0);

    fetchReplayTimeline(hours, nowMs, activeDemoSessionId)
      .then(timeline => {
        if (cancelled) return;
        setTotal(timeline.length);
        if (timeline.length === 0) {
          setPhase('done');
          return;
        }
        setPhase('playing');

        // Spread the timeline across TARGET_DURATION at a steady step, but
        // never tick faster than the browser can paint: batch enough events
        // per tick that ticks stay >= MIN_STEP_MS apart.
        const stepMs = Math.max(MIN_STEP_MS, TARGET_DURATION_MS / timeline.length);
        const perTick = Math.max(1, Math.round(timeline.length / (TARGET_DURATION_MS / stepMs)));

        let i = 0;
        const tick = () => {
          if (cancelled) return;
          const end = Math.min(i + perTick, timeline.length);
          for (; i < end; i++) {
            const entry: TimelineEntry = timeline[i];
            applyPlatformEvent(map, entry.payload, entry.t, activeDemoSessionId);
          }
          // Replay snapshot keeps everyone (no TTL) — show the accumulated set.
          setVisitors(snapshot(map, nowMs, null));
          setProgress(i / timeline.length);

          if (i < timeline.length) {
            timer = setTimeout(tick, stepMs);
          } else {
            setPhase('done');
          }
        };
        tick();
      })
      .catch(err => {
        if (cancelled) return;
        console.error('[replay] failed', err);
        setPhase('error');
      });

    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
    };
  }, [hours, nowMs, activeDemoSessionId]);

  return { phase, visitors, progress, total };
}
