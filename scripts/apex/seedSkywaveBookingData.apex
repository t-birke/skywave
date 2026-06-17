/**
 * Idempotent seed for the Phase 3.5a booking demo.
 *
 * Creates (if not already present):
 *   - 3 Product2 rows (aircraft types)
 *   - 1 Skywave_Seat_Map__c per Product2 (cabin layout)
 *   - 5 Asset rows (tail numbers, each tied to one Product2)
 *   - 6 Flight__c rows on routes that match the survey destinations
 *     (NYC↔LHR, NYC↔HND, NYC↔SYD, ORD↔SFO, etc.) — each Flight assigns
 *     a specific tail number via Aircraft__c lookup
 *
 * Re-runnable: every entity is keyed on a stable external/business
 * identifier (ProductCode, Asset Name, Flight Name) so a second run
 * just no-ops. Verified for the v1 demo only — when you start
 * touching anything Skywave-related at scale, look here first.
 */

// ── 1. Product2 rows (aircraft types) ───────────────────────────────────────
Map<String, Map<String, Object>> aircraftTypes = new Map<String, Map<String, Object>>{
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

Map<String, Id> productIdByCode = new Map<String, Id>();
for (Product2 p : [SELECT Id, ProductCode FROM Product2 WHERE ProductCode IN :aircraftTypes.keySet()]) {
    productIdByCode.put(p.ProductCode, p.Id);
}

List<Product2> productsToInsert = new List<Product2>();
for (String code : aircraftTypes.keySet()) {
    if (productIdByCode.containsKey(code)) continue;
    Map<String, Object> spec = aircraftTypes.get(code);
    productsToInsert.add(new Product2(
        Name = (String) spec.get('Name'),
        ProductCode = code,
        Description = (String) spec.get('Description'),
        IsActive = true
    ));
}
if (!productsToInsert.isEmpty()) insert productsToInsert;
for (Product2 p : productsToInsert) productIdByCode.put(p.ProductCode, p.Id);

System.debug('Aircraft Product2 rows: ' + productIdByCode);

// ── 2. Skywave_Seat_Map__c per aircraft type ────────────────────────────────
Map<String, String> seatMapJsonByCode = new Map<String, String>{
    'B737-800' => JSON.serialize(new Map<String, Object>{
        'classes' => new List<Map<String, Object>>{
            new Map<String, Object>{ 'name' => 'First',    'rows' => new List<Integer>{1,2},        'abreast' => '2-2'   },
            new Map<String, Object>{ 'name' => 'Business', 'rows' => new List<Integer>{3,4,5,6},    'abreast' => '2-2'   },
            new Map<String, Object>{ 'name' => 'Economy',  'rows' => new List<Integer>{7,28},       'abreast' => '3-3'   }
        }
    }),
    'A320neo' => JSON.serialize(new Map<String, Object>{
        'classes' => new List<Map<String, Object>>{
            new Map<String, Object>{ 'name' => 'Business', 'rows' => new List<Integer>{1,2,3,4},    'abreast' => '2-2'   },
            new Map<String, Object>{ 'name' => 'Economy',  'rows' => new List<Integer>{5,30},       'abreast' => '3-3'   }
        }
    }),
    'B777-300ER' => JSON.serialize(new Map<String, Object>{
        'classes' => new List<Map<String, Object>>{
            new Map<String, Object>{ 'name' => 'First',    'rows' => new List<Integer>{1,2},        'abreast' => '1-2-1' },
            new Map<String, Object>{ 'name' => 'Business', 'rows' => new List<Integer>{3,4,5,6,7,8,9,10}, 'abreast' => '2-2-2' },
            new Map<String, Object>{ 'name' => 'Economy',  'rows' => new List<Integer>{11,40},      'abreast' => '3-3-3' }
        }
    })
};
Map<String, Integer> totalRowsByCode = new Map<String, Integer>{
    'B737-800' => 28, 'A320neo' => 30, 'B777-300ER' => 40
};

Set<Id> existingMapProductIds = new Set<Id>();
for (Skywave_Seat_Map__c m : [SELECT Aircraft_Type__c FROM Skywave_Seat_Map__c WHERE Aircraft_Type__c IN :productIdByCode.values()]) {
    existingMapProductIds.add(m.Aircraft_Type__c);
}

List<Skywave_Seat_Map__c> seatMapsToInsert = new List<Skywave_Seat_Map__c>();
for (String code : productIdByCode.keySet()) {
    Id productId = productIdByCode.get(code);
    if (existingMapProductIds.contains(productId)) continue;
    seatMapsToInsert.add(new Skywave_Seat_Map__c(
        Name = (String) aircraftTypes.get(code).get('Name') + ' Seat Map',
        Aircraft_Type__c = productId,
        Total_Rows__c = totalRowsByCode.get(code),
        Layout_Json__c = seatMapJsonByCode.get(code)
    ));
}
if (!seatMapsToInsert.isEmpty()) insert seatMapsToInsert;
System.debug('Seat maps inserted: ' + seatMapsToInsert.size());

// ── 3. Skywave Airlines Account (parent for Asset rows) ─────────────────────
List<Account> existingAirline = [SELECT Id FROM Account WHERE Name = 'Skywave Airlines (Internal)' LIMIT 1];
Id airlineAccountId;
if (existingAirline.isEmpty()) {
    Account airline = new Account(Name = 'Skywave Airlines (Internal)');
    insert airline;
    airlineAccountId = airline.Id;
} else {
    airlineAccountId = existingAirline[0].Id;
}

// ── 4. Asset rows (tail numbers) ────────────────────────────────────────────
Map<String, String> tailToProductCode = new Map<String, String>{
    'N12345' => 'B737-800',
    'N67890' => 'B737-800',
    'N24680' => 'A320neo',
    'N13579' => 'A320neo',
    'N99999' => 'B777-300ER'
};

Map<String, Id> assetIdByTail = new Map<String, Id>();
for (Asset a : [SELECT Id, Name FROM Asset WHERE Name IN :tailToProductCode.keySet() AND AccountId = :airlineAccountId]) {
    assetIdByTail.put(a.Name, a.Id);
}

List<Asset> assetsToInsert = new List<Asset>();
for (String tail : tailToProductCode.keySet()) {
    if (assetIdByTail.containsKey(tail)) continue;
    String productCode = tailToProductCode.get(tail);
    assetsToInsert.add(new Asset(
        Name = tail,
        SerialNumber = tail,
        AccountId = airlineAccountId,
        Product2Id = productIdByCode.get(productCode),
        Status = 'Installed'
    ));
}
if (!assetsToInsert.isEmpty()) insert assetsToInsert;
for (Asset a : assetsToInsert) assetIdByTail.put(a.Name, a.Id);

System.debug('Tail numbers (Asset rows): ' + assetIdByTail);

// ── 5. Flight__c rows on routes that match the survey ───────────────────────
// Survey "fav_destination" answers: "New York", "Tokyo", "Sydney" (mapped to
// JFK, HND, SYD). The agent demo wants flights _to_ these from the user's
// current location — for a public demo audience, JFK is the assumed home
// hub. Add a few intra-US routes for variety.
List<Map<String, Object>> routes = new List<Map<String, Object>>{
    new Map<String, Object>{
        'number' => 'SW1100', 'origin' => 'JFK', 'destination' => 'LHR',
        'deptTime' => Time.newInstance(21, 30, 0, 0), 'arrivalTime' => Time.newInstance(9, 30, 0, 0), 'duration' => 420,
        'tail' => 'N99999',  // 777
        'days' => new List<String>{'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'},
        'priceBasic' => 800
    },
    new Map<String, Object>{
        'number' => 'SW1200', 'origin' => 'JFK', 'destination' => 'HND',
        'deptTime' => Time.newInstance(13, 0, 0, 0), 'arrivalTime' => Time.newInstance(16, 30, 0, 0), 'duration' => 825,
        'tail' => 'N99999',  // 777
        'days' => new List<String>{'Monday','Wednesday','Friday','Sunday'},
        'priceBasic' => 1100
    },
    new Map<String, Object>{
        'number' => 'SW1300', 'origin' => 'JFK', 'destination' => 'SYD',
        'deptTime' => Time.newInstance(22, 30, 0, 0), 'arrivalTime' => Time.newInstance(7, 0, 0, 0), 'duration' => 1230,
        'tail' => 'N99999',  // 777
        'days' => new List<String>{'Tuesday','Thursday','Saturday'},
        'priceBasic' => 1400
    },
    new Map<String, Object>{
        'number' => 'SW2100', 'origin' => 'ORD', 'destination' => 'SFO',
        'deptTime' => Time.newInstance(9, 0, 0, 0), 'arrivalTime' => Time.newInstance(11, 45, 0, 0), 'duration' => 285,
        'tail' => 'N12345',  // 737
        'days' => new List<String>{'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'},
        'priceBasic' => 280
    },
    new Map<String, Object>{
        'number' => 'SW2200', 'origin' => 'JFK', 'destination' => 'LAX',
        'deptTime' => Time.newInstance(8, 30, 0, 0), 'arrivalTime' => Time.newInstance(11, 30, 0, 0), 'duration' => 360,
        'tail' => 'N24680',  // A320
        'days' => new List<String>{'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'},
        'priceBasic' => 320
    },
    new Map<String, Object>{
        'number' => 'SW2300', 'origin' => 'LHR', 'destination' => 'HND',
        'deptTime' => Time.newInstance(11, 0, 0, 0), 'arrivalTime' => Time.newInstance(7, 30, 0, 0), 'duration' => 690,
        'tail' => 'N99999',  // 777
        'days' => new List<String>{'Monday','Wednesday','Friday'},
        'priceBasic' => 1200
    }
};

Map<String, Id> flightIdByNumber = new Map<String, Id>();
Set<String> flightNumbers = new Set<String>();
for (Map<String, Object> r : routes) flightNumbers.add((String) r.get('number'));
for (Flight__c f : [SELECT Id, Flight_Number__c FROM Flight__c WHERE Flight_Number__c IN :flightNumbers]) {
    flightIdByNumber.put(f.Flight_Number__c, f.Id);
}

List<Flight__c> flightsToInsert = new List<Flight__c>();
for (Map<String, Object> r : routes) {
    String num = (String) r.get('number');
    if (flightIdByNumber.containsKey(num)) continue;
    Flight__c f = new Flight__c(
        Name = num,
        Flight_Number__c = num,
        Origin__c = (String) r.get('origin'),
        Destination__c = (String) r.get('destination'),
        Scheduled_Departure_Time__c = (Time) r.get('deptTime'),
        Scheduled_Arrival_Time__c = (Time) r.get('arrivalTime'),
        Duration_Minutes__c = (Integer) r.get('duration'),
        Aircraft__c = assetIdByTail.get((String) r.get('tail')),
        Aircraft_Type__c = (String) aircraftTypes.get(tailToProductCode.get((String) r.get('tail'))).get('Name'),
        Active__c = true
    );
    List<String> days = (List<String>) r.get('days');
    f.Operates_Monday__c    = days.contains('Monday');
    f.Operates_Tuesday__c   = days.contains('Tuesday');
    f.Operates_Wednesday__c = days.contains('Wednesday');
    f.Operates_Thursday__c  = days.contains('Thursday');
    f.Operates_Friday__c    = days.contains('Friday');
    f.Operates_Saturday__c  = days.contains('Saturday');
    f.Operates_Sunday__c    = days.contains('Sunday');
    // Cabin-class pricing (the Basic/Choice fare-bundle fields were removed in the
    // Phase 4 booking overhaul). `priceBasic` is the Economy floor; the multipliers
    // match scripts/apex/seedSkywaveRouteNetwork.apex so both seeders price alike.
    Decimal eco = (Decimal) r.get('priceBasic');
    f.Base_Price_Economy__c         = eco;
    f.Base_Price_Premium_Economy__c = (eco * 1.6).setScale(2);
    f.Base_Price_Business__c        = (eco * 2.8).setScale(2);
    f.Base_Price_First__c           = (eco * 4.2).setScale(2);
    flightsToInsert.add(f);
}
if (!flightsToInsert.isEmpty()) insert flightsToInsert;
System.debug('Flights inserted: ' + flightsToInsert.size());

System.debug('Phase 3.5a seed complete.');
