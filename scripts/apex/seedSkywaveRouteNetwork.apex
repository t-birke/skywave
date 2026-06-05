/**
 * Skywave route-network expansion seed (idempotent).
 *
 * Architecture: SINGLE HUB = JFK.
 *   - Feeders: ~16 major metros -> JFK (and JFK -> each, return) so an
 *     audience member near any of these can reach the hub.
 *   - Destinations: JFK -> 2-3 iconic cities per continent (and return),
 *     so the vibe x region survey can resolve to a real, bookable city
 *     on any continent.
 *
 * All flights operate EVERY day (all Operates_* = true) so any travel date
 * the visitor picks returns a flight (no day-of-week dead-ends in the demo).
 *
 * Uses the CURRENT generic fare fields (Base_Price_Economy / Premium_Economy /
 * Business / First) — NOT the retired Basic/Choice/_del fields. Matches what
 * the live Skywave_FlightSearch SELECTs.
 *
 * Re-runnable: keyed on Flight_Number__c, so a second run only inserts what's
 * missing. Existing SW1100/1200/1300/2100/2200/2300 are left untouched.
 *
 * Aircraft_Type__c is a plain text label (search reads it as a string).
 */

// route spec: number, origin, destination, deptHour, durationMin, aircraft, ecoPrice
// Feeders use short-haul economy prices; long-hauls scale with distance.
List<List<Object>> routes = new List<List<Object>>{
    // ── FEEDERS: metro -> JFK (and the return JFK -> metro) ──────────────────
    new List<Object>{ 'SW3001', 'LAX', 'JFK', 7,  350, 'Airbus A321neo', 340 },
    new List<Object>{ 'SW3002', 'JFK', 'LAX', 17, 375, 'Airbus A321neo', 340 },
    new List<Object>{ 'SW3003', 'ORD', 'JFK', 6,  140, 'Boeing 737-800', 180 },
    new List<Object>{ 'SW3004', 'JFK', 'ORD', 19, 150, 'Boeing 737-800', 180 },
    new List<Object>{ 'SW3005', 'SFO', 'JFK', 7,  340, 'Airbus A321neo', 330 },
    new List<Object>{ 'SW3006', 'JFK', 'SFO', 18, 365, 'Airbus A321neo', 330 },
    new List<Object>{ 'SW3007', 'DFW', 'JFK', 8,  225, 'Boeing 737-800', 220 },
    new List<Object>{ 'SW3008', 'JFK', 'DFW', 20, 235, 'Boeing 737-800', 220 },
    new List<Object>{ 'SW3009', 'ATL', 'JFK', 9,  140, 'Boeing 737-800', 170 },
    new List<Object>{ 'SW3010', 'JFK', 'ATL', 21, 150, 'Boeing 737-800', 170 },
    new List<Object>{ 'SW3011', 'SEA', 'JFK', 7,  330, 'Airbus A321neo', 320 },
    new List<Object>{ 'SW3012', 'JFK', 'SEA', 18, 350, 'Airbus A321neo', 320 },
    new List<Object>{ 'SW3013', 'MIA', 'JFK', 8,  180, 'Boeing 737-800', 200 },
    new List<Object>{ 'SW3014', 'JFK', 'MIA', 20, 190, 'Boeing 737-800', 200 },
    new List<Object>{ 'SW3015', 'BOS', 'JFK', 6,  85,  'Embraer E175',   140 },
    new List<Object>{ 'SW3016', 'JFK', 'BOS', 22, 90,  'Embraer E175',   140 },
    new List<Object>{ 'SW3017', 'DEN', 'JFK', 8,  235, 'Boeing 737-800', 240 },
    new List<Object>{ 'SW3018', 'JFK', 'DEN', 19, 250, 'Boeing 737-800', 240 },
    new List<Object>{ 'SW3019', 'IAD', 'JFK', 7,  80,  'Embraer E175',   150 },
    new List<Object>{ 'SW3020', 'JFK', 'IAD', 21, 85,  'Embraer E175',   150 },
    new List<Object>{ 'SW3021', 'YYZ', 'JFK', 9,  100, 'Embraer E175',   190 },
    new List<Object>{ 'SW3022', 'JFK', 'YYZ', 20, 105, 'Embraer E175',   190 },
    new List<Object>{ 'SW3023', 'PHX', 'JFK', 7,  300, 'Airbus A321neo', 300 },
    new List<Object>{ 'SW3024', 'JFK', 'PHX', 18, 320, 'Airbus A321neo', 300 },

    // ── DESTINATIONS: JFK -> world (2-3 per continent), with return ──────────
    // EUROPE — London, Paris, Rome
    new List<Object>{ 'SW4001', 'JFK', 'LHR', 21, 420, 'Boeing 777-300ER', 820 },
    new List<Object>{ 'SW4002', 'LHR', 'JFK', 11, 480, 'Boeing 777-300ER', 820 },
    new List<Object>{ 'SW4003', 'JFK', 'CDG', 20, 435, 'Boeing 777-300ER', 840 },
    new List<Object>{ 'SW4004', 'CDG', 'JFK', 11, 490, 'Boeing 777-300ER', 840 },
    new List<Object>{ 'SW4005', 'JFK', 'FCO', 19, 510, 'Boeing 787-9',     880 },
    new List<Object>{ 'SW4006', 'FCO', 'JFK', 10, 570, 'Boeing 787-9',     880 },
    // ASIA — Tokyo, Bangkok, Singapore
    new List<Object>{ 'SW4007', 'JFK', 'HND', 13, 825, 'Boeing 777-300ER', 1150 },
    new List<Object>{ 'SW4008', 'HND', 'JFK', 16, 780, 'Boeing 777-300ER', 1150 },
    new List<Object>{ 'SW4009', 'JFK', 'BKK', 11, 1010,'Boeing 777-300ER', 1240 },
    new List<Object>{ 'SW4010', 'BKK', 'JFK', 8,  1050,'Boeing 777-300ER', 1240 },
    new List<Object>{ 'SW4011', 'JFK', 'SIN', 22, 1110,'Airbus A350-900',  1320 },
    new List<Object>{ 'SW4012', 'SIN', 'JFK', 9,  1080,'Airbus A350-900',  1320 },
    // AFRICA — Cape Town, Marrakesh, Nairobi
    new List<Object>{ 'SW4013', 'JFK', 'CPT', 20, 920, 'Airbus A350-900',  1280 },
    new List<Object>{ 'SW4014', 'CPT', 'JFK', 18, 970, 'Airbus A350-900',  1280 },
    new List<Object>{ 'SW4015', 'JFK', 'RAK', 21, 450, 'Boeing 787-9',     760 },
    new List<Object>{ 'SW4016', 'RAK', 'JFK', 12, 510, 'Boeing 787-9',     760 },
    new List<Object>{ 'SW4017', 'JFK', 'NBO', 22, 870, 'Boeing 787-9',     1190 },
    new List<Object>{ 'SW4018', 'NBO', 'JFK', 23, 900, 'Boeing 787-9',     1190 },
    // AMERICAS (beyond US) — Rio, Mexico City, Buenos Aires
    new List<Object>{ 'SW4019', 'JFK', 'GIG', 22, 590, 'Boeing 787-9',     720 },
    new List<Object>{ 'SW4020', 'GIG', 'JFK', 21, 610, 'Boeing 787-9',     720 },
    new List<Object>{ 'SW4021', 'JFK', 'MEX', 8,  330, 'Boeing 737-800',   360 },
    new List<Object>{ 'SW4022', 'MEX', 'JFK', 16, 350, 'Boeing 737-800',   360 },
    new List<Object>{ 'SW4023', 'JFK', 'EZE', 21, 640, 'Boeing 787-9',     780 },
    new List<Object>{ 'SW4024', 'EZE', 'JFK', 22, 660, 'Boeing 787-9',     780 },
    // OCEANIA — Sydney, Auckland
    new List<Object>{ 'SW4025', 'JFK', 'SYD', 22, 1230,'Boeing 777-300ER', 1480 },
    new List<Object>{ 'SW4026', 'SYD', 'JFK', 14, 1200,'Boeing 777-300ER', 1480 },
    new List<Object>{ 'SW4027', 'JFK', 'AKL', 21, 1180,'Boeing 777-300ER', 1440 },
    new List<Object>{ 'SW4028', 'AKL', 'JFK', 15, 1150,'Boeing 777-300ER', 1440 },
    // MIDDLE EAST — Dubai, Istanbul
    new List<Object>{ 'SW4029', 'JFK', 'DXB', 23, 745, 'Airbus A350-900',  1100 },
    new List<Object>{ 'SW4030', 'DXB', 'JFK', 8,  855, 'Airbus A350-900',  1100 },
    new List<Object>{ 'SW4031', 'JFK', 'IST', 20, 600, 'Boeing 787-9',     960 },
    new List<Object>{ 'SW4032', 'IST', 'JFK', 9,  660, 'Boeing 787-9',     960 }
};

// Don't recreate flights that already exist.
Set<String> wantNumbers = new Set<String>();
for (List<Object> r : routes) wantNumbers.add((String) r[0]);
Set<String> existing = new Set<String>();
for (Flight__c f : [SELECT Flight_Number__c FROM Flight__c WHERE Flight_Number__c IN :wantNumbers]) {
    existing.add(f.Flight_Number__c);
}

List<Flight__c> toInsert = new List<Flight__c>();
for (List<Object> r : routes) {
    String num = (String) r[0];
    if (existing.contains(num)) continue;
    Integer deptHour = (Integer) r[3];
    Integer durMin   = (Integer) r[4];
    Time dept = Time.newInstance(deptHour, 0, 0, 0);
    // arrival clock time = (dept + duration) mod 24h; search handles +1 day rollover
    Integer arrMinsOfDay = Math.mod(deptHour * 60 + durMin, 1440);
    Time arr = Time.newInstance(arrMinsOfDay / 60, Math.mod(arrMinsOfDay, 60), 0, 0);
    Decimal eco = (Decimal) r[6];

    toInsert.add(new Flight__c(
        Name = num,
        Flight_Number__c = num,
        Origin__c = (String) r[1],
        Destination__c = (String) r[2],
        Scheduled_Departure_Time__c = dept,
        Scheduled_Arrival_Time__c = arr,
        Duration_Minutes__c = durMin,
        Aircraft_Type__c = (String) r[5],
        Active__c = true,
        Operates_Monday__c = true, Operates_Tuesday__c = true,
        Operates_Wednesday__c = true, Operates_Thursday__c = true,
        Operates_Friday__c = true, Operates_Saturday__c = true,
        Operates_Sunday__c = true,
        Base_Price_Economy__c         = eco,
        Base_Price_Premium_Economy__c = (eco * 1.6).setScale(2),
        Base_Price_Business__c        = (eco * 2.8).setScale(2),
        Base_Price_First__c           = (eco * 4.2).setScale(2)
    ));
}

if (!toInsert.isEmpty()) insert toInsert;
System.debug('Route-network seed: inserted ' + toInsert.size() + ' new flights (skipped ' + existing.size() + ' existing).');
