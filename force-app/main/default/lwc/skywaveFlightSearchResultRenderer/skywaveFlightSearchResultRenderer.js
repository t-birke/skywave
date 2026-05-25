import { LightningElement, api, track } from 'lwc';

export default class SkywaveFlightSearchResultRenderer extends LightningElement {
    @api value;
    @track flights = [];
    @track fareClass = '';
    @track errorMessage = '';
    @track placeholderMessage = '';

    connectedCallback() {
        console.log('#### SkywaveFlightSearchResultRenderer input:', this.value);
        try {
            if (!this.value || this.value.flightsJSON == null || this.value.flightsJSON === '') {
                this.placeholderMessage = 'Skywave Flight Search Result card preview';
                return;
            }
            const raw = this.value.flightsJSON;
            let parsed;
            if (typeof raw === 'string') {
                parsed = JSON.parse(raw);
            } else if (typeof raw === 'object') {
                parsed = raw;
            } else {
                this.placeholderMessage = 'Skywave Flight Search Result card preview';
                return;
            }
            if (parsed?.error) {
                this.errorMessage = parsed.error;
                return;
            }
            this.fareClass = parsed?.fareClass ?? '';
            const list = parsed?.flights ?? [];
            this.flights = list.map((f, idx) => ({
                ...f,
                key: f.flightId ?? `${f.flightNumber}-${idx}`,
                durationLabel: this._formatDuration(f.duration),
                fareClass: f.fareClass ?? this.fareClass
            }));
        } catch (e) {
            console.error('SkywaveFlightSearchResultRenderer parse error:', e);
            this.errorMessage = 'Error loading flight options';
        }
    }

    handleBook(event) {
        const flightNumber = event.target.dataset.flightnumber;
        const message = `Book flight ${flightNumber}`;
        console.log('#### SkywaveFlightSearchResultRenderer booking:', message);
        try {
            if (typeof embeddedservice_bootstrap !== 'undefined'
                && embeddedservice_bootstrap?.utilAPI?.sendTextMessage) {
                embeddedservice_bootstrap.utilAPI.sendTextMessage(message)
                    .then(() => console.log('Booking message sent (utilAPI):', message))
                    .catch((e) => console.error('utilAPI.sendTextMessage error:', e));
                return;
            }
            if (typeof embeddedservice_configuration !== 'undefined'
                && embeddedservice_configuration?.util?.sendTextMessage) {
                embeddedservice_configuration.util.sendTextMessage(message)
                    .then(() => console.log('Booking message sent (configuration.util):', message))
                    .catch((e) => console.error('configuration.util.sendTextMessage error:', e));
                return;
            }
            console.warn('No sendTextMessage API available; would have sent:', message);
        } catch (e) {
            console.error('SkywaveFlightSearchResultRenderer book error:', e);
        }
    }

    _formatDuration(min) {
        if (min == null) return '';
        const h = Math.floor(min / 60);
        const m = min % 60;
        return `${h}h ${m}m`;
    }
}
