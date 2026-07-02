/**
 * Historical replay source — reconstructs a Demo_Event__e-shaped timeline
 * from PERSISTED RECORDS (Contact + Booking + Booking_Segment + Flight),
 * because HighVolume Platform Events are NOT replayable over the CometD
 * Streaming API (only live -1 delivers; replay -2 / specific-replayId return
 * nothing). Records survive past the 72h PE window and are deterministic.
 *
 * Each record becomes one or more timeline entries stamped with the record's
 * CreatedDate, ordered ascending, then fed through the SAME visitorReducer
 * the live feed uses — so a replay looks identical to having watched it live.
 *
 * Transport: UI API GraphQL via @salesforce/sdk-data (see ./graphql). Works
 * natively in-org and through the official dev proxy — no custom SOQL proxy.
 */
import type { PlatformEventPayload } from './visitorReducer';
import { queryEdges, v, sinceIso } from './graphql';

export interface TimelineEntry {
  t: number; // ms epoch (CreatedDate)
  payload: PlatformEventPayload;
}

// Flat rows (UI API envelopes already unwrapped via v()).
interface ContactRow {
  FirstName: string | null;
  LastName: string | null;
  ContactCardPicture__c: string | null;
  Geo_Latitude__c: number | null;
  Geo_Longitude__c: number | null;
  MailingCity: string | null;
  Session_Id__c: string | null;
  Demo_Session__c: string | null;
  Skywave_Survey_Json__c: string | null;
  CreatedDate: string;
}

interface SegmentRow {
  Segment_Order__c: number | null;
  Seat_Number__c: string | null;
  Origin__c: string | null;
  Destination__c: string | null;
  BookingCreatedDate: string | null;
  Session_Id__c: string | null;
  Demo_Session__c: string | null;
}

const GQL_LIMIT = 2000;

/** UI API node shape for the Contact query (verbose `{ value }` envelopes). */
interface ContactNode {
  FirstName: { value: string | null } | null;
  LastName: { value: string | null } | null;
  ContactCardPicture__c: { value: string | null } | null;
  Geo_Latitude__c: { value: number | null } | null;
  Geo_Longitude__c: { value: number | null } | null;
  MailingCity: { value: string | null } | null;
  Session_Id__c: { value: string | null } | null;
  Demo_Session__c: { value: string | null } | null;
  Skywave_Survey_Json__c: { value: string | null } | null;
  CreatedDate: { value: string | null } | null;
}

interface SegmentNode {
  Segment_Order__c: { value: number | null } | null;
  Seat_Number__c: { value: string | null } | null;
  Flight__r: {
    Origin__c: { value: string | null } | null;
    Destination__c: { value: string | null } | null;
  } | null;
  Booking__r: {
    CreatedDate: { value: string | null } | null;
    Contact__r: {
      Session_Id__c: { value: string | null } | null;
      Demo_Session__c: { value: string | null } | null;
    } | null;
  } | null;
}

/**
 * Build the ordered replay timeline for the last `hours`, scoped to a demo
 * session if given. Returns entries sorted by CreatedDate ascending.
 */
export async function fetchReplayTimeline(
  hours: number,
  nowMs: number,
  activeDemoSessionId?: string | null
): Promise<TimelineEntry[]> {
  const since = sinceIso(hours, nowMs);

  // Contacts → session_started (geo) + profile_created (name/avatar) +
  // survey_answer (from the persisted survey JSON).
  const contactWhere = [
    `{ Demo_Session__c: { ne: null } }`,
    `{ Session_Id__c: { ne: null } }`,
    `{ CreatedDate: { gte: { value: "${since}" } } }`,
    ...(activeDemoSessionId
      ? [`{ Demo_Session__c: { eq: "${activeDemoSessionId}" } }`]
      : []),
  ].join(', ');

  const contactNodes = await queryEdges<ContactNode>(
    `query {
      uiapi { query {
        Contact(first: ${GQL_LIMIT}, where: { and: [${contactWhere}] },
                orderBy: { CreatedDate: { order: ASC } }) {
          edges { node {
            FirstName { value } LastName { value } ContactCardPicture__c { value }
            Geo_Latitude__c { value } Geo_Longitude__c { value } MailingCity { value }
            Session_Id__c { value } Demo_Session__c { value }
            Skywave_Survey_Json__c { value } CreatedDate { value }
          } }
        }
      } }
    }`,
    'Contact'
  );
  const contacts: ContactRow[] = contactNodes.map(n => ({
    FirstName: v(n.FirstName),
    LastName: v(n.LastName),
    ContactCardPicture__c: v(n.ContactCardPicture__c),
    Geo_Latitude__c: v(n.Geo_Latitude__c),
    Geo_Longitude__c: v(n.Geo_Longitude__c),
    MailingCity: v(n.MailingCity),
    Session_Id__c: v(n.Session_Id__c),
    Demo_Session__c: v(n.Demo_Session__c),
    Skywave_Survey_Json__c: v(n.Skywave_Survey_Json__c),
    CreatedDate: v(n.CreatedDate) ?? '',
  }));

  // Booking segments → flight_booked (origin→…→dest legs) + seat.
  const segWhere = activeDemoSessionId
    ? `{ Booking__r: { Contact__r: { Demo_Session__c: { eq: "${activeDemoSessionId}" } } } }`
    : `{ Booking__r: { Contact__r: { Demo_Session__c: { ne: null } } } }`;

  const segmentNodes = await queryEdges<SegmentNode>(
    `query {
      uiapi { query {
        Booking_Segment__c(first: ${GQL_LIMIT}, where: ${segWhere},
                           orderBy: { Segment_Order__c: { order: ASC } }) {
          edges { node {
            Segment_Order__c { value } Seat_Number__c { value }
            Flight__r { Origin__c { value } Destination__c { value } }
            Booking__r {
              CreatedDate { value }
              Contact__r { Session_Id__c { value } Demo_Session__c { value } }
            }
          } }
        }
      } }
    }`,
    'Booking_Segment__c'
  );
  const segments: SegmentRow[] = segmentNodes.map(n => ({
    Segment_Order__c: v(n.Segment_Order__c),
    Seat_Number__c: v(n.Seat_Number__c),
    Origin__c: v(n.Flight__r?.Origin__c),
    Destination__c: v(n.Flight__r?.Destination__c),
    BookingCreatedDate: v(n.Booking__r?.CreatedDate),
    Session_Id__c: v(n.Booking__r?.Contact__r?.Session_Id__c),
    Demo_Session__c: v(n.Booking__r?.Contact__r?.Demo_Session__c),
  }));

  const entries: TimelineEntry[] = [];

  for (const c of contacts) {
    if (!c.Session_Id__c) continue;
    const t = Date.parse(c.CreatedDate);
    const base = { Session_Id__c: c.Session_Id__c, Demo_Session_Id__c: c.Demo_Session__c ?? undefined };

    // Geo first (so the marker can appear before the profile resolves).
    if (c.Geo_Latitude__c != null && c.Geo_Longitude__c != null) {
      entries.push({
        t,
        payload: {
          ...base,
          Type__c: 'session_started',
          Payload_Json__c: JSON.stringify({
            lat: c.Geo_Latitude__c,
            lon: c.Geo_Longitude__c,
            city: c.MailingCity ?? undefined,
          }),
        },
      });
    }
    // Profile (name + avatar) — only if we actually have a name/avatar.
    if (c.FirstName || c.LastName || c.ContactCardPicture__c) {
      entries.push({
        t: t + 1, // 1ms after geo so it folds in the right order
        payload: {
          ...base,
          Type__c: 'profile_created',
          Payload_Json__c: JSON.stringify({
            firstName: c.FirstName ?? undefined,
            lastName: c.LastName ?? undefined,
            avatarUrl: c.ContactCardPicture__c ?? undefined,
          }),
        },
      });
    }
    // Survey answers — persisted as { questionKey: {questionText, answerText,
    // answerKey} } on Skywave_Survey_Json__c. Emit one survey_answer each so
    // the reducer folds them exactly like the live events.
    if (c.Skywave_Survey_Json__c) {
      let parsed: Record<string, { answerKey?: string; answerText?: string }>;
      try {
        parsed = JSON.parse(c.Skywave_Survey_Json__c);
      } catch {
        parsed = {};
      }
      let offset = 2;
      for (const [questionKey, ans] of Object.entries(parsed)) {
        if (!ans?.answerKey) continue;
        entries.push({
          t: t + offset++, // after geo/profile, preserving order
          payload: {
            ...base,
            Type__c: 'survey_answer',
            Payload_Json__c: JSON.stringify({
              questionKey,
              answerKey: ans.answerKey,
              answerText: ans.answerText ?? undefined,
            }),
          },
        });
      }
    }
  }

  // Group segments by booking (session + createdDate) into one flight_booked.
  const bookingKey = (s: SegmentRow) =>
    `${s.Session_Id__c ?? ''}|${s.BookingCreatedDate ?? ''}`;
  const byBooking = new Map<string, SegmentRow[]>();
  for (const s of segments) {
    if (!s.Session_Id__c || !s.Origin__c || !s.Destination__c) continue;
    const k = bookingKey(s);
    (byBooking.get(k) ?? byBooking.set(k, []).get(k)!).push(s);
  }

  for (const segs of byBooking.values()) {
    segs.sort((a, b) => (a.Segment_Order__c ?? 0) - (b.Segment_Order__c ?? 0));
    const first = segs[0];
    const sessionId = first.Session_Id__c!;
    const t = first.BookingCreatedDate ? Date.parse(first.BookingCreatedDate) : 0;
    const legs = segs
      .filter(s => s.Origin__c && s.Destination__c)
      .map(s => ({ from: s.Origin__c!, to: s.Destination__c! }));
    if (!legs.length) continue;

    const base = {
      Session_Id__c: sessionId,
      Demo_Session_Id__c: first.Demo_Session__c ?? undefined,
    };
    entries.push({
      t,
      payload: {
        ...base,
        Type__c: 'flight_booked',
        Payload_Json__c: JSON.stringify({ legs, isConnection: legs.length > 1 }),
      },
    });
    // Seat from the first segment, if present.
    if (first.Seat_Number__c) {
      entries.push({
        t: t + 1,
        payload: {
          ...base,
          Type__c: 'seat_changed',
          Payload_Json__c: JSON.stringify({ seat: first.Seat_Number__c }),
        },
      });
    }
  }

  entries.sort((a, b) => a.t - b.t);
  return entries;
}
