/**
 * Profile-saved acknowledgement + Booking__c insert.
 *
 * Phase 3.5b-r2 moved booking creation here. The visitor's profile is
 * the gate: as soon as we have a real Contact identity, we create the
 * Booking__c so it's live with status `Pending Confirmation` /
 * payment_status `Unpaid`. The CLT 4 payment widget then flips both
 * fields to `Confirmed` / `Paid` once Demo Pay completes.
 *
 * Why insert here (not in confirm_booking): the payment widget is
 * client-side and needs a real bookingCode + amount BEFORE it animates.
 * Inserting at the profile gate gives the agent something to pass to
 * present_payment_form; abandoned-after-profile sessions leave a
 * single Pending/Unpaid row that's easy to filter.
 *
 * Inputs: contactId + the pinned selection variables. Reads the
 * Flight__c row, computes the total, inserts Booking__c +
 * Booking_Segment__c.
 *
 * Outputs: bookingCode + totalCharged for the agent to pin and pass
 * to the payment widget.
 */
public with sharing class Skywave_AckProfileForm {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;

        @InvocableVariable(label='Flight Id' required=true)
        public String flightId;

        @InvocableVariable(label='Travel Date (YYYY-MM-DD)' required=true)
        public String travelDate;

        @InvocableVariable(label='Fare Class' required=true)
        public String fareClass;

        @InvocableVariable(label='Checked Bags')
        public Integer checkedBags;

        @InvocableVariable(label='Seat Preference')
        public String seatPreference;
    }

    public class Output {
        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='message')
        public String message;

        @InvocableVariable(label='Booking code')
        public String bookingCode;

        @InvocableVariable(label='Total charged')
        public String totalCharged;
    }

    @InvocableMethod(
        label='Skywave: Acknowledge profile + create booking'
        description='Invoke when the visitor sends "Profile created" (cue from the form LWC) OR when the visitor has provided full name + email via text fallback. Inserts the Pending/Unpaid Booking__c using pinned selection variables and returns the booking code + total amount, which the agent passes to the payment widget.'
        category='Skywave'
    )
    public static List<Output> ack(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) outs.add(ackOne(req));
        return outs;
    }

    private static Output ackOne(Input req) {
        Output out = new Output();
        out.success = false;
        out.bookingCode = '';
        out.totalCharged = '$0.00';

        if (String.isBlank(req.contactId)) {
            out.message = 'Contact Id is required.';
            return out;
        }
        if (String.isBlank(req.flightId)) {
            out.message = 'Flight selection lost — flightId missing.';
            return out;
        }
        if (String.isBlank(req.travelDate)) {
            out.message = 'Travel date missing.';
            return out;
        }
        if (String.isBlank(req.fareClass)) {
            out.message = 'Fare class missing.';
            return out;
        }

        Date travelDateParsed;
        try {
            travelDateParsed = Date.valueOf(req.travelDate);
        } catch (Exception e) {
            out.message = 'Travel date must be YYYY-MM-DD; got "' + req.travelDate + '".';
            return out;
        }

        String canonicalFareClass = Skywave_FareClass.normalizeOrDefault(req.fareClass);
        String key = req.flightId.trim();

        try {
            // Resolve flight by Id or by Flight_Number — see Skywave_BookFlight.
            List<Flight__c> flights;
            if (key.length() == 15 || key.length() == 18) {
                flights = [
                    SELECT Id, Scheduled_Departure_Time__c, Scheduled_Arrival_Time__c,
                           Base_Price_Economy__c, Base_Price_Premium_Economy__c,
                           Base_Price_Business__c, Base_Price_First__c
                    FROM Flight__c WHERE Id = :key LIMIT 1
                ];
            }
            if (flights == null || flights.isEmpty()) {
                flights = [
                    SELECT Id, Scheduled_Departure_Time__c, Scheduled_Arrival_Time__c,
                           Base_Price_Economy__c, Base_Price_Premium_Economy__c,
                           Base_Price_Business__c, Base_Price_First__c
                    FROM Flight__c WHERE Flight_Number__c = :key LIMIT 1
                ];
            }
            if (flights.isEmpty()) {
                out.message = 'Flight not found for: ' + key;
                return out;
            }
            Flight__c flight = flights[0];

            Decimal totalAmount = priceFor(flight, canonicalFareClass);

            Booking__c booking = new Booking__c(
                Contact__c = req.contactId,
                Confirmation_Code__c = generateConfirmationCode(),
                Status__c = 'Pending Confirmation',
                Payment_Status__c = 'Unpaid',
                Fare_Class__c = canonicalFareClass,
                Total_Amount__c = totalAmount,
                Checked_Bags__c = req.checkedBags != null ? req.checkedBags : 0,
                Booking_Date__c = Date.today()
            );
            insert booking;

            DateTime departureDT = DateTime.newInstance(travelDateParsed, flight.Scheduled_Departure_Time__c);
            DateTime arrivalDT = DateTime.newInstance(travelDateParsed, flight.Scheduled_Arrival_Time__c);
            if (flight.Scheduled_Arrival_Time__c < flight.Scheduled_Departure_Time__c) {
                arrivalDT = arrivalDT.addDays(1);
            }

            Booking_Segment__c segment = new Booking_Segment__c(
                Booking__c = booking.Id,
                Flight__c = flight.Id,
                Travel_Date__c = travelDateParsed,
                Departure_DateTime__c = departureDT,
                Arrival_DateTime__c = arrivalDT,
                Segment_Order__c = 1,
                Segment_Status__c = 'Scheduled',
                Seat_Number__c = assignSeat(req.seatPreference)
            );
            insert segment;

            out.success = true;
            out.bookingCode = booking.Confirmation_Code__c;
            out.totalCharged = '$' + totalAmount.setScale(2).toPlainString();
            out.message = 'Booking created (Pending/Unpaid).';
        } catch (Exception e) {
            out.message = 'Booking creation failed: ' + e.getMessage();
            System.debug('Skywave_AckProfileForm error: ' + e.getMessage() +
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
            List<String> seats = new List<String>{'A','B','C','D','E','F'};
            seat = seats[Math.mod(Math.abs(Crypto.getRandomInteger()), seats.size())];
        }
        return String.valueOf(row) + seat;
    }
}
