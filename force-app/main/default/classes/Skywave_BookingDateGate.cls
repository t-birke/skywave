/**
 * Single source of truth for "is this booking in the past?". Used by:
 *
 *   - Skywave_GetFlightBookings  (chat agent — drops past bookings entirely
 *                                 so the agent never proposes seat changes
 *                                 or talks about flown trips)
 *   - Skywave_ContactItinerary    (Contact-page LWC — tags isPast so the
 *                                 LWC can split into Upcoming / Past sections)
 *   - Skywave_WebsiteBookings    (website /api/website/bookings — same tag,
 *                                 same split on the customer-area page)
 *
 * Rule: a booking is in the past iff EVERY segment has flown. Equivalently,
 * MAX(Booking_Segment__c.Arrival_DateTime__c) < NOW. A booking with zero
 * segments, or where all segments have a null Arrival_DateTime__c, is NOT
 * past — we don't want to disappear records due to data gaps (e.g. a
 * Pending Confirmation booking before the segment dates are pinned).
 *
 * Uses the lighter helper Skywave_Now.now() so tests can mock the clock —
 * but for now Datetime.now() is fine; replace if a fixture-clock pattern
 * lands in this codebase.
 */
public with sharing class Skywave_BookingDateGate {

    public static Boolean isBookingPast(List<Booking_Segment__c> segs) {
        if (segs == null || segs.isEmpty()) return false;
        Datetime maxArrival = null;
        for (Booking_Segment__c s : segs) {
            if (s.Arrival_DateTime__c == null) continue;
            if (maxArrival == null || s.Arrival_DateTime__c > maxArrival) {
                maxArrival = s.Arrival_DateTime__c;
            }
        }
        if (maxArrival == null) return false;   // all-null arrivals → don't hide
        return maxArrival < Datetime.now();
    }
}
