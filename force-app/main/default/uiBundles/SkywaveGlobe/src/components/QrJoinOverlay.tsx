/**
 * Join-QR overlay for the globe — the 3D successor to the QR corner card on the
 * 2D `skywaveDemoMonitor` LWC. Same three behaviours:
 *
 *   - dynamic: encodes `<consumer-site>/?ds=<activeSessionId>`, re-rendering
 *     whenever the active session changes (so the QR always points phones at
 *     THIS presenter's tenant);
 *   - enlarge: click the card to zoom it to a centred fullscreen-ish size, click
 *     again to shrink back to the bottom-right corner;
 *   - hide: a small × dismisses it to an inconspicuous "QR" pill that re-opens it.
 *
 * Sizing/animation mirror the LWC CSS (18vh corner → 75vh centred, 0.3s ease).
 */
import { useState } from 'react';
import { QRCodeCanvas } from 'qrcode.react';
import { joinUrl } from '@/lib/consumerSite';

interface QrJoinOverlayProps {
  /** The presenter's active Demo_Session__c Id, or null until resolved. */
  sessionId: string | null;
}

export function QrJoinOverlay({ sessionId }: QrJoinOverlayProps) {
  const [enlarged, setEnlarged] = useState(false);
  const [hidden, setHidden] = useState(false);

  const url = joinUrl(sessionId);

  // Hidden → an inconspicuous holographic pill (matches the HUD palette) that
  // brings the card back. Mirrors the LWC's "QR code on/off" settings toggle.
  if (hidden) {
    return (
      <button
        onClick={() => setHidden(false)}
        title="Show join QR code"
        style={{
          position: 'absolute',
          bottom: '4vh',
          right: '4vh',
          padding: '6px 12px',
          borderRadius: 6,
          fontFamily: 'monospace',
          fontSize: 11,
          letterSpacing: '0.14em',
          textTransform: 'uppercase',
          color: 'rgba(0,180,216,0.85)',
          background: 'rgba(0,180,216,0.08)',
          border: '1px solid rgba(0,180,216,0.3)',
          cursor: 'pointer',
          zIndex: 60,
        }}
      >
        QR
      </button>
    );
  }

  const size = enlarged ? '75vh' : '18vh';
  const position = enlarged
    ? { bottom: '50%', right: '50%', transform: 'translate(50%, 50%)' }
    : { bottom: '4vh', right: '4vh' };

  return (
    <div
      onClick={() => setEnlarged(e => !e)}
      title={enlarged ? 'Click to shrink' : 'Click to enlarge'}
      style={{
        position: 'absolute',
        ...position,
        width: size,
        height: size,
        background: '#fff',
        borderRadius: '0.5rem',
        boxShadow: '0 4px 24px rgba(0,0,0,0.45)',
        cursor: 'pointer',
        overflow: 'hidden',
        display: 'grid',
        placeItems: 'center',
        transition: 'width 0.3s, height 0.3s, bottom 0.3s, right 0.3s',
        zIndex: 60,
      }}
    >
      {/* Hide — stops propagation so it doesn't also trigger the enlarge toggle. */}
      <button
        onClick={e => {
          e.stopPropagation();
          setEnlarged(false);
          setHidden(true);
        }}
        aria-label="Hide QR code"
        title="Hide QR code"
        style={{
          position: 'absolute',
          top: 6,
          right: 8,
          background: 'transparent',
          border: 'none',
          color: 'rgba(11,29,58,0.55)',
          fontSize: 18,
          lineHeight: 1,
          cursor: 'pointer',
          zIndex: 1,
        }}
      >
        ×
      </button>

      {url ? (
        <QRCodeCanvas
          value={url}
          // High intrinsic resolution so it stays crisp when scaled to 75vh.
          size={1024}
          level="H"
          fgColor="#0b1d3a"
          bgColor="#ffffff"
          marginSize={2}
          style={{ width: '88%', height: '88%' }}
        />
      ) : (
        <div
          style={{
            padding: '1rem',
            textAlign: 'center',
            color: '#5c6b80',
            fontFamily: 'monospace',
            fontSize: 12,
            lineHeight: 1.5,
          }}
        >
          No active demo session — activate one in Demo Home to generate a join QR.
        </div>
      )}
    </div>
  );
}
