@JsonAccess(serializable='always' deserializable='always')
global class Skywave_FlightSearchResultData {

    @AuraEnabled
    global String flightsJSON;

    global Skywave_FlightSearchResultData(String flightsJSON) {
        this.flightsJSON = flightsJSON;
    }

    global Skywave_FlightSearchResultData() {
        this.flightsJSON = '';
    }
}
