/**
 * Single source of truth for rental-car booking creation and confirmation.
 * Modality wrappers (the chat invocables Skywave_ReserveVehicle /
 * Skywave_ConfirmRental and the LWC-invoked Skywave_ProcessRentalPayment)
 * are thin shims that translate their inputs/outputs into this contract.
 *
 * Mirrors Skywave_BookingEngine for flights: one place computes the price,
 * generates the confirmation code, resolves the linked flight booking, and
 * writes the Vehicle_Booking__c. Rentals are far simpler than flights — no
 * segments, no seat zones — so this is a single object insert.
 *
 * Runs `inherited sharing` so it adopts the caller's context: the chat
 * invocables run `with sharing` as the Einstein Agent User (which has the
 * object granted via Skywave_Agent_User), while the LWC payment path calls
 * from a `without sharing` shim so the ESW guest user can flip the record.
 */
public inherited sharing class Skywave_RentalEngine {

    // ---------- public DTOs --------------------------------------------

    public class CreateRequest {
        public String contactId;
        public String category;          // Economy | Comfort | Luxury (normalised here)
        public Integer rentalDays;       // clamped to 1–14
        public Date pickupDate;          // arrival date of the trip
        public String destination;       // IATA / city label
        public String flightBookingCode; // Confirmation_Code__c of the linked Booking__c (optional)
        public String initialStatus;         // 'Confirmed' or 'Pending Confirmation'
        public String initialPaymentStatus;  // 'Paid' or 'Unpaid'
    }

    public class CreateResult {
        public Boolean success;
        public String errorCode;
        public String errorMessage;
        public Id vehicleBookingId;
        public String bookingCode;
        public String category;
        public String exampleModel;
        public Decimal dailyRate;
        public Integer rentalDays;
        public Decimal totalAmount;
        public String totalDisplay;   // "$300.00"
        public Date pickupDate;
        public Date returnDate;
    }

    // ---------- create -------------------------------------------------

    public static CreateResult createBooking(CreateRequest req) {
        CreateResult r = new CreateResult();
        r.success = false;

        if (String.isBlank(req.contactId)) { r.errorCode = 'missing_contactId'; return r; }

        String category = Skywave_RentalCatalog.normalize(req.category);
        if (category == null) { r.errorCode = 'invalid_category'; r.errorMessage = 'Unknown vehicle category: ' + req.category; return r; }
        Skywave_RentalCatalog.Tier tier = Skywave_RentalCatalog.tierFor(category);

        Integer days = Skywave_RentalCatalog.clampDays(req.rentalDays);
        String initialStatus = String.isBlank(req.initialStatus)
            ? 'Pending Confirmation' : req.initialStatus;
        String initialPaymentStatus = String.isBlank(req.initialPaymentStatus)
            ? 'Unpaid' : req.initialPaymentStatus;

        try {
            // Verify Contact (defense in depth — the agent should already
            // have authenticated the contactId at the router).
            List<Contact> cs = [SELECT Id FROM Contact WHERE Id = :req.contactId LIMIT 1];
            if (cs.isEmpty()) {
                r.errorCode = 'contact_not_found';
                r.errorMessage = 'Contact not found.';
                return r;
            }

            // Resolve the linked flight booking by its confirmation code,
            // scoped to this contact. Optional — a rental can exist without
            // it, but the demo always has one because the offer is gated on
            // a booked flight.
            Id flightBookingId = null;
            if (String.isNotBlank(req.flightBookingCode)) {
                List<Booking__c> fbs = [
                    SELECT Id FROM Booking__c
                    WHERE Confirmation_Code__c = :req.flightBookingCode
                      AND Contact__c = :req.contactId
                    LIMIT 1
                ];
                if (!fbs.isEmpty()) flightBookingId = fbs[0].Id;
            }

            Decimal total = tier.dailyRate * days;
            String confirmationCode = generateConfirmationCode();
            Date pickup = req.pickupDate;

            Vehicle_Booking__c vb = new Vehicle_Booking__c(
                Contact__c = req.contactId,
                Flight_Booking__c = flightBookingId,
                Confirmation_Code__c = confirmationCode,
                Vehicle_Category__c = category,
                Example_Model__c = tier.exampleModel,
                Daily_Rate__c = tier.dailyRate,
                Rental_Days__c = days,
                Pickup_Date__c = pickup,
                Return_Date__c = (pickup != null ? pickup.addDays(days) : null),
                Destination__c = req.destination,
                Total_Amount__c = total,
                Status__c = initialStatus,
                Payment_Status__c = initialPaymentStatus,
                Booking_Date__c = System.now()
            );
            insert vb;

            publishMonitorEvent('rental_reserved', req.contactId, new Map<String, Object>{
                'bookingCode' => confirmationCode,
                'category' => category,
                'days' => days,
                'destination' => req.destination,
                'total' => '$' + total.setScale(2).toPlainString()
            });

            r.success = true;
            r.vehicleBookingId = vb.Id;
            r.bookingCode = confirmationCode;
            r.category = category;
            r.exampleModel = tier.exampleModel;
            r.dailyRate = tier.dailyRate;
            r.rentalDays = days;
            r.totalAmount = total;
            r.totalDisplay = '$' + total.setScale(2).toPlainString();
            r.pickupDate = pickup;
            r.returnDate = (pickup != null ? pickup.addDays(days) : null);
        } catch (Exception e) {
            r.errorCode = 'create_failed';
            r.errorMessage = e.getMessage();
            System.debug(LoggingLevel.ERROR, 'RentalEngine.createBooking: ' + e.getMessage()
                + '\n' + e.getStackTraceString());
        }
        return r;
    }

    // ---------- confirmation code -------------------------------------

    // RC-prefixed so rental codes are visually distinct from flight codes
    // (which are unprefixed 6-char). Still 6 chars total to fit the field.
    private static String generateConfirmationCode() {
        String chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        String code = 'RC';
        for (Integer i = 0; i < 4; i++) {
            Integer idx = Math.mod(Math.abs(Crypto.getRandomInteger()), chars.length());
            code += chars.substring(idx, idx + 1);
        }
        return code;
    }

    // ---------- monitor event publish ---------------------------------

    private static void publishMonitorEvent(
        String eventType, Id contactId, Map<String, Object> payload
    ) {
        try {
            List<Contact> cs = [
                SELECT Session_Id__c, Demo_Session__c FROM Contact WHERE Id = :contactId LIMIT 1
            ];
            if (cs.isEmpty() || String.isBlank(cs[0].Session_Id__c) || cs[0].Demo_Session__c == null) return;
            Skywave_RestUtil.publishEvent(eventType, cs[0].Session_Id__c, cs[0].Demo_Session__c, payload);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, eventType + ' publish skipped: ' + e.getMessage());
        }
    }
}
