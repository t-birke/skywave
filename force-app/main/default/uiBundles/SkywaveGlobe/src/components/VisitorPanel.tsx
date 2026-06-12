/**
 * Detail panel shown when a visitor avatar is clicked — avatar, name, route,
 * seat, and the survey-answer thumbnails (the "bubble" detail the old 2D LWC
 * map showed). Survey images are resolved here from the option-image map.
 */
import type { Visitor } from '@/data/visitors';
import { optionImageKey, type OptionImageMap } from '@/data/surveyImages';

interface VisitorPanelProps {
  visitor: Visitor;
  optionImages: OptionImageMap;
  onClose: () => void;
}

function displayName(v: Visitor): string {
  if (v.firstName) return v.lastName ? `${v.firstName} ${v.lastName}` : v.firstName;
  return v.sessionId.slice(-6);
}

function routeText(v: Visitor): string | null {
  const legs = v.route?.legs;
  if (!legs || !legs.length) return null;
  return `${legs[0].from} → ${legs[legs.length - 1].to}`;
}

export function VisitorPanel({ visitor, optionImages, onClose }: VisitorPanelProps) {
  const answers = (visitor.answers ?? []).map(a => ({
    ...a,
    img: a.imageUrl ?? optionImages[optionImageKey(a.questionKey, a.answerKey)] ?? null,
  }));
  const route = routeText(visitor);

  return (
    <div
      style={{
        position: 'relative',
        width: 280,
        background: 'rgba(13,17,23,0.92)',
        border: '1px solid rgba(0,180,216,0.25)',
        borderRadius: 10,
        padding: 16,
        fontFamily: 'monospace',
        color: 'rgba(0,180,216,0.9)',
        boxShadow: '0 8px 32px rgba(0,0,0,0.5)',
        backdropFilter: 'blur(6px)',
        pointerEvents: 'auto',
      }}
    >
      {/* Close */}
      <button
        onClick={onClose}
        aria-label="Close"
        style={{
          position: 'absolute',
          top: 8,
          right: 10,
          background: 'transparent',
          border: 'none',
          color: 'rgba(0,180,216,0.6)',
          fontSize: 16,
          cursor: 'pointer',
          lineHeight: 1,
        }}
      >
        ×
      </button>

      {/* Header: avatar + name + route/seat */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        {visitor.avatarUrl ? (
          <img
            src={visitor.avatarUrl}
            alt=""
            referrerPolicy="no-referrer"
            style={{
              width: 52,
              height: 52,
              borderRadius: '50%',
              objectFit: 'cover',
              border: '2px solid #00ff88',
              boxShadow: '0 0 10px rgba(0,255,136,0.5)',
              flexShrink: 0,
            }}
          />
        ) : (
          <div
            style={{
              width: 52,
              height: 52,
              borderRadius: '50%',
              background: 'rgba(0,180,216,0.15)',
              border: '2px solid rgba(0,180,216,0.4)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 20,
              flexShrink: 0,
            }}
          >
            {displayName(visitor).charAt(0).toUpperCase()}
          </div>
        )}
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 14, color: '#7fefff', letterSpacing: '0.04em' }}>
            {displayName(visitor)}
          </div>
          <div style={{ fontSize: 11, color: 'rgba(0,180,216,0.55)', marginTop: 3 }}>
            {route ? <span>{route}</span> : visitor.city ? <span>{visitor.city}</span> : null}
            {visitor.seat ? <span> · seat {visitor.seat}</span> : null}
          </div>
        </div>
      </div>

      {/* Survey answers */}
      {answers.length > 0 && (
        <div style={{ marginTop: 16 }}>
          <div
            style={{
              fontSize: 10,
              letterSpacing: '0.14em',
              textTransform: 'uppercase',
              color: 'rgba(0,180,216,0.5)',
              marginBottom: 8,
            }}
          >
            Survey
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
            {answers.map(a => (
              <div
                key={a.questionKey}
                title={a.answerText ?? a.answerKey}
                style={{ width: 72, textAlign: 'center' }}
              >
                {a.img ? (
                  <img
                    src={a.img}
                    alt={a.answerText ?? a.answerKey}
                    style={{
                      width: 72,
                      height: 54,
                      objectFit: 'cover',
                      borderRadius: 6,
                      border: '1px solid rgba(0,180,216,0.25)',
                      display: 'block',
                    }}
                  />
                ) : (
                  <div
                    style={{
                      width: 72,
                      height: 54,
                      borderRadius: 6,
                      background: 'rgba(0,180,216,0.1)',
                      border: '1px solid rgba(0,180,216,0.2)',
                    }}
                  />
                )}
                <div
                  style={{
                    fontSize: 9,
                    color: 'rgba(0,180,216,0.65)',
                    marginTop: 4,
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                  }}
                >
                  {a.answerText ?? a.answerKey}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
