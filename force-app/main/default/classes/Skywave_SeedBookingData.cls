/**
 * One-shot seed for the Phase 3.5a booking demo. Idempotent — skips
 * any entity that already exists. Safe to rerun.
 *
 * Why a class and not an anonymous-Apex script: anonymous Apex
 * compiles against the running user's view of the schema, and our
 * admin user doesn't have FLS read on the Flight__c custom fields
 * (they exist in metadata but no permset on the admin's license
 * grants access). An Apex class deployed to the org bypasses that
 * compile-time check and `without sharing` runs the DML in system
 * context.
 *
 * Run via:  sf apex run --target-org si -e "Skywave_SeedBookingData.run();"
 */
public without sharing class Skywave_SeedBookingData {

    @AuraEnabled
    public static String run() {
        seedAircraftTypes();
        Map<String, Id> productIds = querySeededProducts();
        seedSeatMaps(productIds);
        Id airlineAccountId = ensureAirlineAccount();
        Map<String, Id> assetIds = seedTailNumbers(airlineAccountId, productIds);
        seedFlights(assetIds, productIds);
        return 'Skywave booking seed complete.';
    }

    // ── 1. Product2 (aircraft types) ────────────────────────────────────────
    private static void seedAircraftTypes() {
        Map<String, Map<String, Object>> types = new Map<String, Map<String, Object>>{
            'B737-800' => new Map<String, Object>{
                'Name' => 'Boeing 737-800',
                'Description' => 'Narrow-body single-aisle, 162 seats, short/medium-haul.'
            },
            'A320neo' => new Map<String, Object>{
                'Name' => 'Airbus A320neo',
                'Description' => 'Narrow-body single-aisle, 174 seats, short/medium-haul.'
            },
            'B777-300ER' => new Map<String, Object>{
                'Name' => 'Boeing 777-300ER',
                'Description' => 'Wide-body twin-aisle, 350 seats, long-haul international.'
            }
        };

        Set<String> existingCodes = new Set<String>();
        for (Product2 p : [SELECT ProductCode FROM Product2 WHERE ProductCode IN :types.keySet()]) {
            existingCodes.add(p.ProductCode);
        }
        List<Product2> toInsert = new List<Product2>();
        for (String code : types.keySet()) {
            if (existingCodes.contains(code)) continue;
            Map<String, Object> spec = types.get(code);
            toInsert.add(new Product2(
                Name = (String) spec.get('Name'),
                ProductCode = code,
                Description = (String) spec.get('Description'),
                IsActive = true
            ));
        }
        if (!toInsert.isEmpty()) insert toInsert;
    }

    private static Map<String, Id> querySeededProducts() {
        Map<String, Id> ids = new Map<String, Id>();
        for (Product2 p : [SELECT Id, ProductCode FROM Product2
                           WHERE ProductCode IN ('B737-800', 'A320neo', 'B777-300ER')]) {
            ids.put(p.ProductCode, p.Id);
        }
        return ids;
    }

    // ── 2. Skywave_Seat_Map__c per aircraft type ────────────────────────────
    private static void seedSeatMaps(Map<String, Id> productIds) {
        Map<String, Integer> totalRows = new Map<String, Integer>{
            'B737-800' => 28, 'A320neo' => 30, 'B777-300ER' => 40
        };
        Map<String, String> nameByCode = new Map<String, String>{
            'B737-800'  => 'Boeing 737-800 Seat Map',
            'A320neo'   => 'Airbus A320neo Seat Map',
            'B777-300ER' => 'Boeing 777-300ER Seat Map'
        };
        Map<String, String> layoutByCode = new Map<String, String>{
            'B737-800'   => '{"classes":[{"name":"First","rows":[1,2],"abreast":"2-2"},{"name":"Business","rows":[3,4,5,6],"abreast":"2-2"},{"name":"Economy","rows":[7,28],"abreast":"3-3"}]}',
            'A320neo'    => '{"classes":[{"name":"Business","rows":[1,2,3,4],"abreast":"2-2"},{"name":"Economy","rows":[5,30],"abreast":"3-3"}]}',
            'B777-300ER' => '{"classes":[{"name":"First","rows":[1,2],"abreast":"1-2-1"},{"name":"Business","rows":[3,4,5,6,7,8,9,10],"abreast":"2-2-2"},{"name":"Economy","rows":[11,40],"abreast":"3-3-3"}]}'
        };

        Set<Id> existingProductIds = new Set<Id>();
        for (Skywave_Seat_Map__c m : [SELECT Aircraft_Type__c FROM Skywave_Seat_Map__c
                                      WHERE Aircraft_Type__c IN :productIds.values()]) {
            existingProductIds.add(m.Aircraft_Type__c);
        }
        List<Skywave_Seat_Map__c> toInsert = new List<Skywave_Seat_Map__c>();
        for (String code : productIds.keySet()) {
            Id pid = productIds.get(code);
            if (existingProductIds.contains(pid)) continue;
            toInsert.add(new Skywave_Seat_Map__c(
                Name = nameByCode.get(code),
                Aircraft_Type__c = pid,
                Total_Rows__c = totalRows.get(code),
                Layout_Json__c = layoutByCode.get(code)
            ));
        }
        if (!toInsert.isEmpty()) insert toInsert;
    }

    // ── 3. Internal "Skywave Airlines" Account (parent for Asset rows) ──────
    private static Id ensureAirlineAccount() {
        List<Account> existing = [SELECT Id FROM Account
                                  WHERE Name = 'Skywave Airlines (Internal)' LIMIT 1];
        if (!existing.isEmpty()) return existing[0].Id;
        Account a = new Account(Name = 'Skywave Airlines (Internal)');
        insert a;
        return a.Id;
    }

    // ── 4. Asset rows (tail numbers) ────────────────────────────────────────
    private static Map<String, Id> seedTailNumbers(Id airlineAccountId, Map<String, Id> productIds) {
        Map<String, String> tailToCode = new Map<String, String>{
            'N12345' => 'B737-800',
            'N67890' => 'B737-800',
            'N24680' => 'A320neo',
            'N13579' => 'A320neo',
            'N99999' => 'B777-300ER'
        };

        Map<String, Id> assetIds = new Map<String, Id>();
        for (Asset a : [SELECT Id, Name FROM Asset
                        WHERE Name IN :tailToCode.keySet() AND AccountId = :airlineAccountId]) {
            assetIds.put(a.Name, a.Id);
        }
        List<Asset> toInsert = new List<Asset>();
        for (String tail : tailToCode.keySet()) {
            if (assetIds.containsKey(tail)) continue;
            toInsert.add(new Asset(
                Name = tail,
                SerialNumber = tail,
                AccountId = airlineAccountId,
                Product2Id = productIds.get(tailToCode.get(tail)),
                Status = 'Installed'
            ));
        }
        if (!toInsert.isEmpty()) insert toInsert;
        for (Asset a : toInsert) assetIds.put(a.Name, a.Id);
        return assetIds;
    }

    // ── 5. Flight__c rows on routes that match the survey ───────────────────
    private static void seedFlights(Map<String, Id> assetIds, Map<String, Id> productIds) {
        // Map productCode → display name for the legacy Aircraft_Type__c text field
        Map<String, String> codeToName = new Map<String, String>{
            'B737-800' => 'Boeing 737-800',
            'A320neo' => 'Airbus A320neo',
            'B777-300ER' => 'Boeing 777-300ER'
        };
        Map<String, String> tailToCode = new Map<String, String>{
            'N12345' => 'B737-800', 'N67890' => 'B737-800',
            'N24680' => 'A320neo',  'N13579' => 'A320neo',
            'N99999' => 'B777-300ER'
        };

        // route specs: number, origin, destination, dept-time-h:m, arr-time-h:m,
        //              duration-min, tail, days(comma), priceBasic
        List<List<Object>> routes = new List<List<Object>>{
            new List<Object>{ 'SW1100', 'JFK', 'LHR', 21, 30,  9, 30, 420, 'N99999', 'Mon,Tue,Wed,Thu,Fri,Sat,Sun', 800 },
            new List<Object>{ 'SW1200', 'JFK', 'HND', 13,  0, 16, 30, 825, 'N99999', 'Mon,Wed,Fri,Sun',           1100 },
            new List<Object>{ 'SW1300', 'JFK', 'SYD', 22, 30,  7,  0, 1230, 'N99999', 'Tue,Thu,Sat',              1400 },
            new List<Object>{ 'SW2100', 'ORD', 'SFO',  9,  0, 11, 45, 285,  'N12345', 'Mon,Tue,Wed,Thu,Fri,Sat,Sun', 280 },
            new List<Object>{ 'SW2200', 'JFK', 'LAX',  8, 30, 11, 30, 360,  'N24680', 'Mon,Tue,Wed,Thu,Fri,Sat,Sun', 320 },
            new List<Object>{ 'SW2300', 'LHR', 'HND', 11,  0,  7, 30, 690,  'N99999', 'Mon,Wed,Fri',               1200 }
        };

        Set<String> flightNumbers = new Set<String>();
        for (List<Object> r : routes) flightNumbers.add((String) r[0]);
        Set<String> existing = new Set<String>();
        for (Flight__c f : [SELECT Flight_Number__c FROM Flight__c WHERE Flight_Number__c IN :flightNumbers]) {
            existing.add(f.Flight_Number__c);
        }

        List<Flight__c> toInsert = new List<Flight__c>();
        for (List<Object> r : routes) {
            String num = (String) r[0];
            if (existing.contains(num)) continue;
            String tail = (String) r[8];
            String typeName = codeToName.get(tailToCode.get(tail));
            Decimal basic = (Decimal) r[10];
            Set<String> days = new Set<String>(((String) r[9]).split(','));

            Flight__c f = new Flight__c(
                Name = num,
                Flight_Number__c = num,
                Origin__c = (String) r[1],
                Destination__c = (String) r[2],
                Scheduled_Departure_Time__c = Time.newInstance((Integer) r[3], (Integer) r[4], 0, 0),
                Scheduled_Arrival_Time__c   = Time.newInstance((Integer) r[5], (Integer) r[6], 0, 0),
                Duration_Minutes__c = (Integer) r[7],
                Aircraft__c = assetIds.get(tail),
                Aircraft_Type__c = typeName,
                Active__c = true,
                Operates_Monday__c    = days.contains('Mon'),
                Operates_Tuesday__c   = days.contains('Tue'),
                Operates_Wednesday__c = days.contains('Wed'),
                Operates_Thursday__c  = days.contains('Thu'),
                Operates_Friday__c    = days.contains('Fri'),
                Operates_Saturday__c  = days.contains('Sat'),
                Operates_Sunday__c    = days.contains('Sun'),
                Base_Price_Basic__c            = basic,
                Base_Price_Choice__c           = (basic * 1.3).setScale(2),
                Base_Price_Choice_Preferred__c = (basic * 1.8).setScale(2),
                Base_Price_Choice_Extra__c     = (basic * 2.5).setScale(2)
            );
            toInsert.add(f);
        }
        if (!toInsert.isEmpty()) insert toInsert;
    }
}
