/**
 * Issues the booking. The single DB write in the booking flow.
 *
 * Inserts a Booking__c (status `Confirmed`, payment_status `Paid`)
 * plus the matching Booking_Segment__c, then returns the confirmation
 * code. Called once per visitor — only after profile + payment have
 * been collected.
 *
 * Why deferred: see Skywave_BookFlight header. Visitors who walk away
 * before completing payment must leave no DB residue.
 *
 * Inputs come from agent variables pinned during the earlier steps:
 * selected_flight_id, selected_fare_class, selected_payment_method,
 * resolved_contact_id, plus the travelDate/checkedBags/seatPreference
 * the visitor agreed to during search.
 *
 * Refuses to insert if any required input is blank — visitors should
 * never see "booking confirmed" without a real Booking__c row behind it.
 */
public with sharing class Skywave_ConfirmBooking {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;

        @InvocableVariable(label='Flight Id' required=true)
        public String flightId;

        @InvocableVariable(label='Travel Date (YYYY-MM-DD)' required=true)
        public String travelDate;

        @InvocableVariable(label='Fare Class' required=true)
        public String fareClass;

        @InvocableVariable(label='Payment Method' required=true)
        public String paymentMethod;

        @InvocableVariable(label='Checked Bags')
        public Integer checkedBags;

        @InvocableVariable(label='Seat Preference')
        public String seatPreference;
    }

    public class Output {
        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='error message')
        public String errorMessage;

        @InvocableVariable(label='Number of bookings confirmed')
        public Integer confirmedCount;

        @InvocableVariable(label='Confirmation codes (comma-separated)')
        public String confirmationCodes;

        @InvocableVariable(label='Total charged')
        public String totalCharged;
    }

    @InvocableMethod(
        label='Skywave: Confirm pending bookings'
        description='Issues a Confirmed/Paid Booking__c plus segment. Called once at the end of the booking flow after profile + payment.'
        category='Skywave'
    )
    public static List<Output> confirm(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) {
            outs.add(confirmOne(req));
        }
        return outs;
    }

    private static Output confirmOne(Input req) {
        Output out = new Output();
        out.success = false;
        out.confirmedCount = 0;
        out.confirmationCodes = '';
        out.totalCharged = '$0.00';

        // Defence: reject blanks loudly. Visitors must never see a
        // "Confirmed" reply without an actual row behind it.
        if (String.isBlank(req.contactId)) {
            out.errorMessage = 'Contact Id missing — cannot confirm.';
            return out;
        }
        if (String.isBlank(req.flightId)) {
            out.errorMessage = 'Flight Id missing — selection was lost.';
            return out;
        }
        if (String.isBlank(req.travelDate)) {
            out.errorMessage = 'Travel date missing — cannot confirm.';
            return out;
        }
        if (String.isBlank(req.fareClass)) {
            out.errorMessage = 'Fare class missing — cannot confirm.';
            return out;
        }
        if (String.isBlank(req.paymentMethod)) {
            out.errorMessage = 'Payment method missing — pay before confirming.';
            return out;
        }

        Date travelDateParsed;
        try {
            travelDateParsed = Date.valueOf(req.travelDate);
        } catch (Exception e) {
            out.errorMessage = 'Travel date must be YYYY-MM-DD; got "' + req.travelDate + '".';
            return out;
        }

        String canonicalFareClass = Skywave_FareClass.normalizeOrDefault(req.fareClass);

        try {
            List<Flight__c> flights = [
                SELECT Id, Scheduled_Departure_Time__c, Scheduled_Arrival_Time__c,
                       Base_Price_Economy__c, Base_Price_Premium_Economy__c,
                       Base_Price_Business__c, Base_Price_First__c
                FROM Flight__c
                WHERE Id = :req.flightId
                LIMIT 1
            ];
            if (flights.isEmpty()) {
                out.errorMessage = 'Flight not found for id: ' + req.flightId;
                return out;
            }
            Flight__c flight = flights[0];

            Decimal totalAmount = priceFor(flight, canonicalFareClass);

            Booking__c booking = new Booking__c(
                Contact__c = req.contactId,
                Confirmation_Code__c = generateConfirmationCode(),
                Status__c = 'Confirmed',
                Payment_Status__c = 'Paid',
                Payment_Method__c = req.paymentMethod,
                Fare_Class__c = canonicalFareClass,
                Total_Amount__c = totalAmount,
                Checked_Bags__c = req.checkedBags != null ? req.checkedBags : 0,
                Booking_Date__c = Date.today()
            );
            insert booking;

            DateTime departureDateTime = DateTime.newInstance(
                travelDateParsed, flight.Scheduled_Departure_Time__c
            );
            DateTime arrivalDateTime = DateTime.newInstance(
                travelDateParsed, flight.Scheduled_Arrival_Time__c
            );
            if (flight.Scheduled_Arrival_Time__c < flight.Scheduled_Departure_Time__c) {
                arrivalDateTime = arrivalDateTime.addDays(1);
            }

            Booking_Segment__c segment = new Booking_Segment__c(
                Booking__c = booking.Id,
                Flight__c = flight.Id,
                Travel_Date__c = travelDateParsed,
                Departure_DateTime__c = departureDateTime,
                Arrival_DateTime__c = arrivalDateTime,
                Segment_Order__c = 1,
                Segment_Status__c = 'Scheduled',
                Seat_Number__c = assignSeat(req.seatPreference)
            );
            insert segment;

            out.success = true;
            out.confirmedCount = 1;
            out.confirmationCodes = booking.Confirmation_Code__c;
            out.totalCharged = '$' + totalAmount.setScale(2).toPlainString();
        } catch (Exception e) {
            out.errorMessage = 'Confirm failed: ' + e.getMessage();
            System.debug('Skywave_ConfirmBooking error: ' + e.getMessage() +
                '\n' + e.getStackTraceString());
        }
        return out;
    }

    private static Decimal priceFor(Flight__c flight, String fareClass) {
        if (fareClass == Skywave_FareClass.ECONOMY && flight.Base_Price_Economy__c != null) {
            return flight.Base_Price_Economy__c;
        } else if (fareClass == Skywave_FareClass.PREMIUM_ECONOMY && flight.Base_Price_Premium_Economy__c != null) {
            return flight.Base_Price_Premium_Economy__c;
        } else if (fareClass == Skywave_FareClass.BUSINESS && flight.Base_Price_Business__c != null) {
            return flight.Base_Price_Business__c;
        } else if (fareClass == Skywave_FareClass.FIRST && flight.Base_Price_First__c != null) {
            return flight.Base_Price_First__c;
        }
        return flight.Base_Price_Economy__c != null ? flight.Base_Price_Economy__c : 0;
    }

    private static String generateConfirmationCode() {
        // Excludes ambiguous chars (I O 1 0).
        String chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        String code = '';
        for (Integer i = 0; i < 6; i++) {
            Integer idx = Math.mod(Math.abs(Crypto.getRandomInteger()), chars.length());
            code += chars.substring(idx, idx + 1);
        }
        return code;
    }

    private static String assignSeat(String preference) {
        Integer row = 10 + Math.mod(Math.abs(Crypto.getRandomInteger()), 20);
        String seat;
        if (preference == 'Window') {
            seat = Math.mod(Math.abs(Crypto.getRandomInteger()), 2) == 0 ? 'A' : 'F';
        } else if (preference == 'Aisle') {
            seat = Math.mod(Math.abs(Crypto.getRandomInteger()), 2) == 0 ? 'C' : 'D';
        } else {
            List<String> seats = new List<String>{'A', 'B', 'C', 'D', 'E', 'F'};
            seat = seats[Math.mod(Math.abs(Crypto.getRandomInteger()), seats.size())];
        }
        return String.valueOf(row) + seat;
    }
}
