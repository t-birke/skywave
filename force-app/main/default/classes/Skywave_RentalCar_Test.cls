/**
 * Coverage for the Skywave Rental Car agent's Apex layer:
 *   - Skywave_RentalCatalog  (tiers, normalise, clamp)
 *   - Skywave_RentalEngine   (create, pricing, code, flight link)
 *   - Skywave_ResolveRentalContext (identity + flight gating)
 *   - Skywave_ReserveVehicle / PresentRentalOffer / PresentRentalPayment
 *   - Skywave_ProcessRentalPayment (LWC pay) / Skywave_ConfirmRental (verify)
 */
@IsTest
private class Skywave_RentalCar_Test {

    @TestSetup
    static void seed() {
        Contact c = new Contact(
            LastName = 'Rental Tester',
            Session_Id__c = 'dev-rental-001',
            Profile_Completed__c = true
        );
        insert c;

        Flight__c f = new Flight__c(
            Flight_Number__c = 'SW9100',
            Origin__c = 'JFK',
            Destination__c = 'FCO',
            Duration_Minutes__c = 540,
            Scheduled_Departure_Time__c = Time.newInstance(9, 0, 0, 0),
            Scheduled_Arrival_Time__c = Time.newInstance(18, 0, 0, 0),
            Active__c = true
        );
        insert f;

        Booking__c b = new Booking__c(
            Contact__c = c.Id,
            Confirmation_Code__c = 'FLT001',
            Status__c = 'Confirmed',
            Payment_Status__c = 'Paid',
            Fare_Class__c = 'Economy',
            Total_Amount__c = 1200,
            Booking_Date__c = Date.today()
        );
        insert b;

        // Future-dated segment so ResolveRentalContext treats the trip as
        // upcoming and offers a car.
        DateTime dep = System.now().addDays(20);
        insert new Booking_Segment__c(
            Booking__c = b.Id,
            Flight__c = f.Id,
            Segment_Order__c = 1,
            Travel_Date__c = dep.date(),
            Departure_DateTime__c = dep,
            Arrival_DateTime__c = dep.addMinutes(540),
            Segment_Status__c = 'Scheduled'
        );
    }

    private static Id contactId() {
        return [SELECT Id FROM Contact WHERE Session_Id__c = 'dev-rental-001' LIMIT 1].Id;
    }

    @IsTest
    static void catalog_normalises_and_prices() {
        System.assertEquals('Economy', Skywave_RentalCatalog.normalize('eco'));
        System.assertEquals('Comfort', Skywave_RentalCatalog.normalize('COMFORT'));
        System.assertEquals('Luxury',  Skywave_RentalCatalog.normalize('premium'));
        System.assertEquals(null, Skywave_RentalCatalog.normalize('spaceship'));
        System.assertEquals(1,  Skywave_RentalCatalog.clampDays(0));
        System.assertEquals(14, Skywave_RentalCatalog.clampDays(99));
        System.assertEquals(5,  Skywave_RentalCatalog.clampDays(5));
        System.assertEquals(3, Skywave_RentalCatalog.TIERS.size());
        System.assertEquals(75, Skywave_RentalCatalog.tierFor('Comfort').dailyRate);
    }

    @IsTest
    static void resolve_context_gates_on_flight() {
        Test.startTest();
        // Drive the happy path via the verified-session deviceId shape, which
        // resolves the seeded Contact by Session_Id__c.
        Skywave_ResolveRentalContext.Input in2 = new Skywave_ResolveRentalContext.Input();
        in2.sessionKey = 'v2/iamessage/AUTH/Skywave_Identity/uid:dev-rental-001';
        List<Skywave_ResolveRentalContext.Output> outs =
            Skywave_ResolveRentalContext.resolve(new List<Skywave_ResolveRentalContext.Input>{ in2 });
        Test.stopTest();

        Skywave_ResolveRentalContext.Output o = outs[0];
        System.assert(o.success, 'resolve should succeed');
        System.assertEquals(contactId(), o.contactId, 'resolves seeded contact by deviceId');
        System.assert(o.hasFlightBooking, 'upcoming flight should gate the offer true');
        System.assertEquals('FCO', o.destinationCode);
        System.assertEquals('Rome', o.destinationCity);
        System.assertEquals('FLT001', o.flightBookingCode);
        System.assert(String.isNotBlank(o.pickupDate), 'pickup date from arrival');
    }

    @IsTest
    static void present_offer_builds_card() {
        Skywave_PresentRentalOffer.Input in1 = new Skywave_PresentRentalOffer.Input();
        in1.contactId = contactId();
        in1.destinationCode = 'FCO';
        in1.destinationCity = 'Rome';
        in1.pickupDate = String.valueOf(Date.today().addDays(20));
        in1.flightBookingCode = 'FLT001';

        List<Skywave_PresentRentalOffer.Output> outs =
            Skywave_PresentRentalOffer.present(new List<Skywave_PresentRentalOffer.Input>{ in1 });

        System.assert(outs[0].success);
        String json = outs[0].offerData.offerStateJSON;
        System.assert(json.contains('Rome'), 'destination in payload');
        System.assert(json.contains('Economy') && json.contains('Comfort') && json.contains('Luxury'),
            'all three tiers serialised');
    }

    @IsTest
    static void full_reserve_pay_confirm_flow() {
        Id cId = contactId();

        Test.startTest();
        // 1) Reserve a Comfort car for 4 days.
        Skywave_ReserveVehicle.Input rin = new Skywave_ReserveVehicle.Input();
        rin.contactId = cId;
        rin.category = 'Comfort';
        rin.rentalDays = 4;
        rin.pickupDate = String.valueOf(Date.today().addDays(20));
        rin.destination = 'FCO';
        rin.flightBookingCode = 'FLT001';
        Skywave_ReserveVehicle.Output rout =
            Skywave_ReserveVehicle.reserve(new List<Skywave_ReserveVehicle.Input>{ rin })[0];

        System.assert(rout.success, rout.message);
        System.assertEquals('$300.00', rout.totalCharged, '75/day x 4 days');
        String code = rout.bookingCode;
        System.assert(code.startsWith('RC'), 'rental code prefixed RC');

        // Pending/Unpaid before payment.
        Vehicle_Booking__c pending = [
            SELECT Status__c, Payment_Status__c, Flight_Booking__c, Return_Date__c
            FROM Vehicle_Booking__c WHERE Confirmation_Code__c = :code LIMIT 1
        ];
        System.assertEquals('Pending Confirmation', pending.Status__c);
        System.assertEquals('Unpaid', pending.Payment_Status__c);
        System.assertNotEquals(null, pending.Flight_Booking__c, 'linked to flight booking');
        System.assertNotEquals(null, pending.Return_Date__c, 'return date computed');

        // 2) Present the payment card.
        Skywave_PresentRentalPayment.Input pin = new Skywave_PresentRentalPayment.Input();
        pin.contactId = cId;
        pin.bookingCode = code;
        pin.totalCharged = rout.totalCharged;
        System.assert(Skywave_PresentRentalPayment.present(
            new List<Skywave_PresentRentalPayment.Input>{ pin })[0].success);

        // 3) LWC Demo Pay flips it to Paid/Confirmed.
        Skywave_ProcessRentalPayment.Result pr =
            Skywave_ProcessRentalPayment.processPayment(code, 'Demo card');
        System.assert(pr.success, pr.message);

        // 4) Verify-only confirm reports success.
        Skywave_ConfirmRental.Input cin = new Skywave_ConfirmRental.Input();
        cin.contactId = cId;
        cin.bookingCode = code;
        Skywave_ConfirmRental.Output cout =
            Skywave_ConfirmRental.confirm(new List<Skywave_ConfirmRental.Input>{ cin })[0];
        Test.stopTest();

        System.assert(cout.success, cout.errorMessage);
        System.assertEquals(code, cout.confirmationCode);
        System.assertEquals('Comfort', cout.category);
        System.assertEquals(4, cout.rentalDays);
        System.assertEquals('$300.00', cout.totalCharged);
    }

    @IsTest
    static void confirm_fails_when_unpaid() {
        Id cId = contactId();
        Skywave_ReserveVehicle.Input rin = new Skywave_ReserveVehicle.Input();
        rin.contactId = cId;
        rin.category = 'Economy';
        rin.rentalDays = 2;
        rin.destination = 'FCO';
        Skywave_ReserveVehicle.Output rout =
            Skywave_ReserveVehicle.reserve(new List<Skywave_ReserveVehicle.Input>{ rin })[0];

        Skywave_ConfirmRental.Input cin = new Skywave_ConfirmRental.Input();
        cin.contactId = cId;
        cin.bookingCode = rout.bookingCode;
        Skywave_ConfirmRental.Output cout =
            Skywave_ConfirmRental.confirm(new List<Skywave_ConfirmRental.Input>{ cin })[0];

        System.assert(!cout.success, 'unpaid rental must not verify');
        System.assert(cout.errorMessage.contains('Unpaid'));
    }

    @IsTest
    static void reserve_rejects_bad_category() {
        Skywave_ReserveVehicle.Input rin = new Skywave_ReserveVehicle.Input();
        rin.contactId = contactId();
        rin.category = 'spaceship';
        rin.rentalDays = 3;
        Skywave_ReserveVehicle.Output rout =
            Skywave_ReserveVehicle.reserve(new List<Skywave_ReserveVehicle.Input>{ rin })[0];
        System.assert(!rout.success, 'unknown category rejected');
    }
}
