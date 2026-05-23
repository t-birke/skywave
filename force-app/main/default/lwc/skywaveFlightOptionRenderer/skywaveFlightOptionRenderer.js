import { LightningElement, api } from 'lwc';

export default class SkywaveFlightOptionRenderer extends LightningElement {
    @api value;

    get flightNumber()      { return this.value?.flightNumber; }
    get startingAirport()   { return this.value?.startingAirport; }
    get arrivingAirport()   { return this.value?.arrivingAirport; }
    get departureTime()     { return this.value?.departureTime; }
    get arrivalTime()       { return this.value?.arrivalTime; }
    get stopovers()         { return this.value?.stopovers; }
    get aircraft()          { return this.value?.aircraft; }
    get price()             { return this.value?.price; }

    get durationLabel() {
        const min = this.value?.duration;
        if (min == null) return '';
        const h = Math.floor(min / 60);
        const m = min % 60;
        return `${h}h ${m}m`;
    }
}
