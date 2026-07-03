/**
 * Call-in companion to the join QR — a phone-icon button that sits just left of
 * the `QrJoinOverlay` corner card. Where the QR lets an audience *scan* to join
 * the web experience, this reveals the number to *call* the Skywave voice agent.
 *
 * Deliberately self-contained (independent of the QR card's enlarge/hide state):
 * the button holds ONLY a phone icon; clicking it toggles a holographic label
 * showing the number above it. Palette/animation mirror the HUD + QR pill so the
 * two affordances read as a pair.
 */
import { useState } from 'react';

// The Skywave voice-agent call-in number, in the form shown on the monitor for
// the audience to read and dial (raw: +16159098098).
const CALL_NUMBER_DISPLAY = '+1 (615) 909-8098';

export function CallJoinOverlay() {
  const [revealed, setRevealed] = useState(false);

  return (
    <div
      style={{
        position: 'absolute',
        // Aligned to the QR card's bottom baseline, just left of its left edge
        // (the QR is 18vh wide at right:4vh, so its left edge sits at right:22vh).
        bottom: '4vh',
        right: '23vh',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'flex-end',
        gap: 8,
        zIndex: 60,
      }}
    >
      {/* Revealed number — a holographic pill that grows upward from the button.
          Kept OUTSIDE the button so the button contains only the phone icon. */}
      {revealed && (
        <span
          style={{
            fontFamily: 'monospace',
            fontSize: 15,
            letterSpacing: '0.08em',
            padding: '6px 12px',
            borderRadius: 6,
            color: 'rgba(0,180,216,0.95)',
            background: 'rgba(0,180,216,0.08)',
            border: '1px solid rgba(0,180,216,0.3)',
            whiteSpace: 'nowrap',
          }}
        >
          {CALL_NUMBER_DISPLAY}
        </span>
      )}

      <button
        onClick={() => setRevealed(r => !r)}
        aria-label="Show call-in phone number"
        aria-expanded={revealed}
        title={revealed ? 'Hide call-in number' : `Call ${CALL_NUMBER_DISPLAY}`}
        style={{
          display: 'grid',
          placeItems: 'center',
          width: 44,
          height: 44,
          borderRadius: 8,
          cursor: 'pointer',
          color: revealed ? '#0a0e1a' : 'rgba(0,180,216,0.85)',
          background: revealed ? 'rgba(0,180,216,0.9)' : 'rgba(0,180,216,0.08)',
          border: '1px solid rgba(0,180,216,0.3)',
          boxShadow: revealed ? '0 0 12px rgba(0,180,216,0.5)' : 'none',
          transition: 'background 0.2s, color 0.2s, box-shadow 0.2s',
        }}
      >
        {/* Feather-style phone glyph; inherits color via currentColor. */}
        <svg
          width="22"
          height="22"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z" />
        </svg>
      </button>
    </div>
  );
}
