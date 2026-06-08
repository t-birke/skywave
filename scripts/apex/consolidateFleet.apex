// Consolidate the Skywave fleet to the three modeled aircraft.
//
// Demo decision: keep the fleet narrative tight — only A320neo + 737-800
// (short-haul narrowbodies) and 777-300ER (med/long-haul widebody). Every
// other aircraft type referenced on Flight__c gets reassigned by hop
// duration:
//
//     <  6h  -> Boeing 737-800   (short-haul, 28-row narrowbody)
//     >= 6h  -> Boeing 777-300ER (long-haul, 40-row widebody)
//
// Then re-runs the Flight->Asset backfill so every flight has a working
// seatmap chain. Idempotent: re-running just skips flights already on
// modeled types.
//
// Run:  sf apex run -f scripts/apex/consolidateFleet.apex --target-org si

final Set<String> KEEP = new Set<String>{
    'Airbus A320neo', 'Boeing 737-800', 'Boeing 777-300ER'
};
final String SHORT_HAUL_AIRCRAFT = 'Boeing 737-800';
final String LONG_HAUL_AIRCRAFT  = 'Boeing 777-300ER';
final Decimal CUTOFF_MINUTES = 360; // 6 hours

List<Flight__c> updates = new List<Flight__c>();
for (Flight__c f : [
    SELECT Id, Flight_Number__c, Aircraft_Type__c, Duration_Minutes__c
    FROM Flight__c
    WHERE Aircraft_Type__c != null AND Aircraft_Type__c NOT IN :KEEP
]) {
    Decimal mins = f.Duration_Minutes__c == null ? 0 : f.Duration_Minutes__c;
    String newType = mins < CUTOFF_MINUTES ? SHORT_HAUL_AIRCRAFT : LONG_HAUL_AIRCRAFT;
    System.debug(f.Flight_Number__c + ' (' + mins + 'm): '
        + f.Aircraft_Type__c + ' -> ' + newType);
    updates.add(new Flight__c(
        Id = f.Id,
        Aircraft_Type__c = newType,
        Aircraft__c = null  // null out the Asset so the backfill below relinks it
    ));
}

if (updates.isEmpty()) {
    System.debug('Nothing to consolidate — all flights already on modeled types.');
    return;
}
update updates;
System.debug('Consolidated ' + updates.size() + ' flights to modeled fleet.');

// --- Inline backfill (Flight -> Asset) so the chain is whole again. ----
Set<String> typeNames = new Set<String>();
for (Flight__c f : [
    SELECT Aircraft_Type__c FROM Flight__c
    WHERE Aircraft__c = null AND Aircraft_Type__c != null
]) {
    typeNames.add(f.Aircraft_Type__c);
}

Map<String, Id> productByName = new Map<String, Id>();
for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Name IN :typeNames]) {
    productByName.put(p.Name, p.Id);
}

Map<Id, Id> assetByProduct = new Map<Id, Id>();
for (Asset a : [SELECT Id, Product2Id FROM Asset WHERE Product2Id IN :productByName.values()]) {
    if (!assetByProduct.containsKey(a.Product2Id)) assetByProduct.put(a.Product2Id, a.Id);
}

List<Asset> newAssets = new List<Asset>();
for (String typeName : productByName.keySet()) {
    Id pid = productByName.get(typeName);
    if (!assetByProduct.containsKey(pid)) {
        newAssets.add(new Asset(Name = typeName + ' fleet', Product2Id = pid));
    }
}
if (!newAssets.isEmpty()) {
    insert newAssets;
    for (Asset a : newAssets) assetByProduct.put(a.Product2Id, a.Id);
}

List<Flight__c> assetLinks = new List<Flight__c>();
for (Flight__c f : [
    SELECT Id, Aircraft_Type__c FROM Flight__c
    WHERE Aircraft__c = null AND Aircraft_Type__c != null
]) {
    Id pid = productByName.get(f.Aircraft_Type__c);
    if (pid == null) continue;
    Id assetId = assetByProduct.get(pid);
    if (assetId == null) continue;
    assetLinks.add(new Flight__c(Id = f.Id, Aircraft__c = assetId));
}
if (!assetLinks.isEmpty()) {
    update assetLinks;
    System.debug('Backfilled Aircraft__c on ' + assetLinks.size() + ' Flight__c rows');
}
