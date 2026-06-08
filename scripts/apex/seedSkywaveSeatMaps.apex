// Skywave seat-map enrichment.
//
// Brings the three existing Skywave_Seat_Map__c records up to the richer
// JSON shape consumed by the website's hi-fi seatmap renderer:
//
//   {
//     "classes": [
//       { "name": "Business",
//         "rows": [3, 10],            // inclusive row range
//         "abreast": "2-2-2",
//         "premium": true,            // wider seat icon
//         "exitRows": [10],           // rows that line up with an exit door
//         "galleyAfter": 10           // visual lavatory/galley break after this row
//       },
//       ...
//     ]
//   }
//
// Layout intentionally simple: rows is a [start,end] pair (or single row for
// short bands). Renderer expands it. Premium Economy added to the 777-300ER
// (currently missing — bookings already accept the fare class). Galley breaks
// derived from real-world cabin layouts; exit rows from Boeing/Airbus standard
// emergency-exit positioning.
//
// Idempotent: re-running overwrites Layout_Json__c only if it differs from
// the canonical shape below.
//
// Run via:
//   sf apex run -f scripts/apex/seedSkywaveSeatMaps.apex --target-org si

Map<String, String> layoutByAircraft = new Map<String, String>{
    'Airbus A320neo' => JSON.serialize(new Map<String, Object>{
        'classes' => new List<Object>{
            new Map<String, Object>{
                'name' => 'Business',
                'rows' => new List<Integer>{ 1, 4 },
                'abreast' => '2-2',
                'premium' => true,
                'galleyAfter' => 4
            },
            new Map<String, Object>{
                'name' => 'Economy',
                'rows' => new List<Integer>{ 5, 30 },
                'abreast' => '3-3',
                'exitRows' => new List<Integer>{ 12, 13 }
            }
        }
    }),
    'Boeing 737-800' => JSON.serialize(new Map<String, Object>{
        'classes' => new List<Object>{
            new Map<String, Object>{
                'name' => 'First',
                'rows' => new List<Integer>{ 1, 2 },
                'abreast' => '2-2',
                'premium' => true,
                'galleyAfter' => 2
            },
            new Map<String, Object>{
                'name' => 'Business',
                'rows' => new List<Integer>{ 3, 6 },
                'abreast' => '2-2',
                'premium' => true,
                'galleyAfter' => 6
            },
            new Map<String, Object>{
                'name' => 'Economy',
                'rows' => new List<Integer>{ 7, 28 },
                'abreast' => '3-3',
                'exitRows' => new List<Integer>{ 16, 17 }
            }
        }
    }),
    'Boeing 777-300ER' => JSON.serialize(new Map<String, Object>{
        'classes' => new List<Object>{
            new Map<String, Object>{
                'name' => 'First',
                'rows' => new List<Integer>{ 1, 2 },
                'abreast' => '1-2-1',
                'premium' => true,
                'galleyAfter' => 2
            },
            new Map<String, Object>{
                'name' => 'Business',
                'rows' => new List<Integer>{ 3, 10 },
                'abreast' => '2-2-2',
                'premium' => true,
                'galleyAfter' => 10
            },
            new Map<String, Object>{
                'name' => 'Premium Economy',
                'rows' => new List<Integer>{ 11, 14 },
                'abreast' => '2-4-2',
                'galleyAfter' => 14
            },
            new Map<String, Object>{
                'name' => 'Economy',
                'rows' => new List<Integer>{ 15, 40 },
                'abreast' => '3-3-3',
                'exitRows' => new List<Integer>{ 25, 26 }
            }
        }
    })
};

// Total rows derived from the last class's last row, so the Total_Rows__c
// field always matches the layout body.
Map<String, Integer> totalRowsByAircraft = new Map<String, Integer>();
for (String name : layoutByAircraft.keySet()) {
    Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(layoutByAircraft.get(name));
    List<Object> classes = (List<Object>) root.get('classes');
    Map<String, Object> last = (Map<String, Object>) classes[classes.size() - 1];
    List<Object> rows = (List<Object>) last.get('rows');
    totalRowsByAircraft.put(name, ((Decimal) rows[rows.size() - 1]).intValue());
}

// Resolve Product2 ids by name (org-portable — no hardcoded ids).
Map<String, Id> productByName = new Map<String, Id>();
for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Name IN :layoutByAircraft.keySet()]) {
    productByName.put(p.Name, p.Id);
}
System.debug('Product matches: ' + productByName);

// Existing seatmap rows keyed by Aircraft_Type__c (Product2 Id).
Map<Id, Skywave_Seat_Map__c> existingByProduct = new Map<Id, Skywave_Seat_Map__c>();
for (Skywave_Seat_Map__c sm : [
    SELECT Id, Name, Aircraft_Type__c, Layout_Json__c, Total_Rows__c
    FROM Skywave_Seat_Map__c
    WHERE Aircraft_Type__c IN :productByName.values()
]) {
    existingByProduct.put(sm.Aircraft_Type__c, sm);
}

List<Skywave_Seat_Map__c> upserts = new List<Skywave_Seat_Map__c>();
for (String aircraftName : layoutByAircraft.keySet()) {
    Id pid = productByName.get(aircraftName);
    if (pid == null) {
        System.debug('SKIP no Product2 for ' + aircraftName);
        continue;
    }
    String layout = layoutByAircraft.get(aircraftName);
    Integer rows = totalRowsByAircraft.get(aircraftName);

    Skywave_Seat_Map__c sm = existingByProduct.get(pid);
    if (sm == null) {
        sm = new Skywave_Seat_Map__c(
            Name = aircraftName + ' seatmap',
            Aircraft_Type__c = pid
        );
    }
    Boolean changed = (sm.Layout_Json__c != layout) || (sm.Total_Rows__c != rows);
    if (changed) {
        sm.Layout_Json__c = layout;
        sm.Total_Rows__c = rows;
        upserts.add(sm);
    } else {
        System.debug('UNCHANGED ' + aircraftName);
    }
}

if (!upserts.isEmpty()) {
    upsert upserts;
    System.debug('UPSERTED ' + upserts.size() + ' seat maps');
} else {
    System.debug('No changes — all 3 seat maps already canonical');
}
