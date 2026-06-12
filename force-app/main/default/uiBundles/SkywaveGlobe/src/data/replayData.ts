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
 * DEV transport: the Vite /sf-query proxy forwards SOQL to the org REST query
 * API with the token injected. Swaps to the GraphQL SDK once deployed in-org.
 */
import type { PlatformEventPayload } from './visitorReducer';

export interface TimelineEntry {
  t: number; // ms epoch (CreatedDate)
  payload: PlatformEventPayload;
}

interface ContactRow {
  Id: string;
  FirstName: string | null;
  LastName: string | null;
  ContactCardPicture__c: string | null;
  Geo_Latitude__c: number | null;
  Geo_Longitude__c: number | null;
  Geo_City__c: string | null;
  Session_Id__c: string | null;
  Demo_Session__c: string | null;
  CreatedDate: string;
}

interface SegmentRow {
  Segment_Order__c: number;
  Seat_Number__c: string | null;
  Flight__r: { Origin__c: string | null; Destination__c: string | null } | null;
  Booking__r: {
    CreatedDate: string;
    Contact__r: { Session_Id__c: string | null; Demo_Session__c: string | null } | null;
  } | null;
}

interface QueryResponse<T> {
  totalSize: number;
  done: boolean;
  records: T[];
}

const SOQL_LIMIT = 2000;

async function soql<T>(query: string): Promise<T[]> {
  const res = await fetch(`/sf-query?q=${encodeURIComponent(query)}`, {
    headers: { Accept: 'application/json' },
  });
  if (!res.ok) {
    throw new Error(`SOQL query failed: ${res.status} ${await res.text().catch(() => '')}`);
  }
  const data = (await res.json()) as QueryResponse<T>;
  return data.records ?? [];
}

/** ISO string the SOQL layer expects for a datetime literal (no quotes). */
function sinceLiteral(hoursAgo: number, nowMs: number): string {
  return new Date(nowMs - hoursAgo * 3600_000).toISOString();
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
  const since = sinceLiteral(hours, nowMs);
  const demoFilter = activeDemoSessionId
    ? `AND Demo_Session__c = '${activeDemoSessionId}'`
    : '';
  const bookingDemoFilter = activeDemoSessionId
    ? `AND Booking__r.Contact__r.Demo_Session__c = '${activeDemoSessionId}'`
    : '';

  // Contacts → session_started (geo) + profile_created (name/avatar).
  const contacts = await soql<ContactRow>(
    `SELECT Id, FirstName, LastName, ContactCardPicture__c, Geo_Latitude__c,
            Geo_Longitude__c, Geo_City__c, Session_Id__c, Demo_Session__c, CreatedDate
     FROM Contact
     WHERE Demo_Session__c != null AND Session_Id__c != null
       AND CreatedDate >= ${since} ${demoFilter}
     ORDER BY CreatedDate ASC LIMIT ${SOQL_LIMIT}`
  );

  // Booking segments → flight_booked (origin→…→dest legs) + seat.
  const segments = await soql<SegmentRow>(
    `SELECT Segment_Order__c, Seat_Number__c,
            Flight__r.Origin__c, Flight__r.Destination__c,
            Booking__r.CreatedDate,
            Booking__r.Contact__r.Session_Id__c, Booking__r.Contact__r.Demo_Session__c
     FROM Booking_Segment__c
     WHERE Booking__r.Contact__r.Demo_Session__c != null
       AND Booking__r.CreatedDate >= ${since} ${bookingDemoFilter}
     ORDER BY Booking__r.CreatedDate ASC, Segment_Order__c ASC LIMIT ${SOQL_LIMIT}`
  );

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
            city: c.Geo_City__c ?? undefined,
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
  }

  // Group segments by booking (session + createdDate) into one flight_booked.
  const bookingKey = (s: SegmentRow) =>
    `${s.Booking__r?.Contact__r?.Session_Id__c ?? ''}|${s.Booking__r?.CreatedDate ?? ''}`;
  const byBooking = new Map<string, SegmentRow[]>();
  for (const s of segments) {
    if (!s.Booking__r?.Contact__r?.Session_Id__c || !s.Flight__r) continue;
    const k = bookingKey(s);
    (byBooking.get(k) ?? byBooking.set(k, []).get(k)!).push(s);
  }

  for (const segs of byBooking.values()) {
    segs.sort((a, b) => (a.Segment_Order__c ?? 0) - (b.Segment_Order__c ?? 0));
    const first = segs[0];
    const sessionId = first.Booking__r!.Contact__r!.Session_Id__c!;
    const t = Date.parse(first.Booking__r!.CreatedDate);
    const legs = segs
      .filter(s => s.Flight__r?.Origin__c && s.Flight__r?.Destination__c)
      .map(s => ({ from: s.Flight__r!.Origin__c!, to: s.Flight__r!.Destination__c! }));
    if (!legs.length) continue;

    const base = {
      Session_Id__c: sessionId,
      Demo_Session_Id__c: first.Booking__r!.Contact__r!.Demo_Session__c ?? undefined,
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
