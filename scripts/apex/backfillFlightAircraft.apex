// Backfills Flight__c.Aircraft__c (Asset lookup) from the legacy
// Aircraft_Type__c text field. Idempotent: only writes flights that have
// the text but no Asset link.
//
// Asset records: one per aircraft type (representing a fleet stand-in,
// not a specific tail number — that level of fidelity is a follow-up).
// Created if missing, reused otherwise. Each Asset.Product2Id points to
// the Product2 that the Skywave_Seat_Map__c keys on, so the chain
// Flight -> Asset -> Product2 -> SeatMap is fully wired.
//
// Run:  sf apex run -f scripts/apex/backfillFlightAircraft.apex --target-org si

Set<String> typeNames = new Set<String>();
for (Flight__c f : [
    SELECT Aircraft_Type__c FROM Flight__c
    WHERE Aircraft__c = null AND Aircraft_Type__c != null
]) {
    typeNames.add(f.Aircraft_Type__c);
}
System.debug('Aircraft types needing assets: ' + typeNames);

Map<String, Id> productByName = new Map<String, Id>();
for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Name IN :typeNames]) {
    productByName.put(p.Name, p.Id);
}

// Find existing fleet-stand-in Assets (one per type, named "<type> fleet").
Map<Id, Id> assetByProduct = new Map<Id, Id>();
for (Asset a : [
    SELECT Id, Product2Id FROM Asset
    WHERE Product2Id IN :productByName.values()
]) {
    if (!assetByProduct.containsKey(a.Product2Id)) {
        assetByProduct.put(a.Product2Id, a.Id);
    }
}

// Create Assets for any type that has no fleet stand-in yet.
List<Asset> newAssets = new List<Asset>();
for (String typeName : productByName.keySet()) {
    Id pid = productByName.get(typeName);
    if (!assetByProduct.containsKey(pid)) {
        newAssets.add(new Asset(
            Name = typeName + ' fleet',
            Product2Id = pid
        ));
    }
}
if (!newAssets.isEmpty()) {
    insert newAssets;
    for (Asset a : newAssets) assetByProduct.put(a.Product2Id, a.Id);
    System.debug('Inserted ' + newAssets.size() + ' fleet-stand-in Assets');
}

// Backfill Flight__c.Aircraft__c.
List<Flight__c> updates = new List<Flight__c>();
for (Flight__c f : [
    SELECT Id, Aircraft_Type__c FROM Flight__c
    WHERE Aircraft__c = null AND Aircraft_Type__c != null
]) {
    Id pid = productByName.get(f.Aircraft_Type__c);
    if (pid == null) {
        System.debug('SKIP no Product2 for type ' + f.Aircraft_Type__c);
        continue;
    }
    Id assetId = assetByProduct.get(pid);
    if (assetId == null) continue;
    updates.add(new Flight__c(Id = f.Id, Aircraft__c = assetId));
}
if (!updates.isEmpty()) {
    update updates;
    System.debug('Backfilled Aircraft__c on ' + updates.size() + ' Flight__c rows');
} else {
    System.debug('Nothing to backfill — Flight__c rows already linked or no matching Product2.');
}
