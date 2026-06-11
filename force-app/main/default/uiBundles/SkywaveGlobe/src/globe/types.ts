/**
 * Domain-neutral data contract for the globe.
 *
 * The globe renderer knows nothing about Skywave visitors or centCom
 * services — it only consumes GlobeMarker[] / GlobeArcData[]. Each surface
 * maps its own domain into these shapes (see ../data/* for the Skywave map).
 */

/** Visual status of a marker — drives its color. */
export type MarkerStatus = 'active' | 'idle' | 'alert';

export interface GlobeMarker {
  /** Stable id (e.g. a session id). */
  id: string;
  /** Cartesian position on the unit sphere ([x,y,z], radius ~1). */
  position: [number, number, number];
  /** Short label rendered beneath the dot. */
  label: string;
  /** Optional secondary line shown in the hover tooltip. */
  sublabel?: string;
  status: MarkerStatus;
  /** Optional avatar image rendered as an always-on sprite on the dot. */
  avatarUrl?: string | null;
}

export interface GlobeArcData {
  id: string;
  start: [number, number, number];
  end: [number, number, number];
}
