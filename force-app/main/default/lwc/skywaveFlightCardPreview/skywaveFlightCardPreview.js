import { LightningElement, track } from 'lwc';

const SAMPLE_SINGLE = JSON.stringify({
    fareClass: 'Business',
    flights: [
        {
            flightId: 'a01000000000001',
            flightNumber: 'SW1200',
            startingAirport: 'JFK',
            arrivingAirport: 'HND',
            departureTime: '1:00 PM',
            arrivalTime: '4:30 PM',
            duration: 825,
            stopovers: 'Non-stop',
            aircraft: 'Boeing 777-300ER',
            price: '$5950.00',
            fareClass: 'Business'
        }
    ]
}, null, 2);

const SAMPLE_MULTIPLE = JSON.stringify({
    fareClass: 'Economy',
    flights: [
        {
            flightId: 'a01000000000001',
            flightNumber: 'SW1200',
            startingAirport: 'JFK',
            arrivingAirport: 'HND',
            departureTime: '1:00 PM',
            arrivalTime: '4:30 PM',
            duration: 825,
            stopovers: 'Non-stop',
            aircraft: 'Boeing 777-300ER',
            price: '$1280.00',
            fareClass: 'Economy'
        },
        {
            flightId: 'a01000000000002',
            flightNumber: 'SW1202',
            startingAirport: 'JFK',
            arrivingAirport: 'HND',
            departureTime: '7:45 PM',
            arrivalTime: '11:15 PM',
            duration: 810,
            stopovers: 'Non-stop',
            aircraft: 'Boeing 787-9',
            price: '$1340.00',
            fareClass: 'Economy'
        },
        {
            flightId: 'a01000000000003',
            flightNumber: 'SW1204',
            startingAirport: 'JFK',
            arrivingAirport: 'HND',
            departureTime: '11:30 PM',
            arrivalTime: '3:00 AM',
            duration: 825,
            stopovers: 'Non-stop',
            aircraft: 'Airbus A350-900',
            price: '$1410.00',
            fareClass: 'Economy'
        }
    ]
}, null, 2);

const SAMPLE_ERROR = JSON.stringify({
    error: 'No flights match JFK to HND on 2026-05-26.'
}, null, 2);

const SAMPLE_EMPTY = JSON.stringify({
    fareClass: 'Economy',
    flights: []
}, null, 2);

export default class SkywaveFlightCardPreview extends LightningElement {
    @track jsonInput = SAMPLE_SINGLE;
    @track currentValue = { flightsJSON: SAMPLE_SINGLE };
    @track parseError = '';

    connectedCallback() {
        // Pre-render the initial sample so the user sees a card on first paint.
        this.handleRender();
    }

    get widthOptions() {
        return [
            { label: '380px (chat)', value: '380' },
            { label: '320px (mobile chat)', value: '320' },
            { label: '480px (desktop chat)', value: '480' },
            { label: '100% (fluid)', value: '100' }
        ];
    }

    @track widthChoice = '380';

    get frameStyle() {
        if (this.widthChoice === '100') {
            return 'width: 100%;';
        }
        return `width: ${this.widthChoice}px;`;
    }

    handleJsonChange(event) {
        this.jsonInput = event.detail.value;
    }

    handleWidthChange(event) {
        this.widthChoice = event.target.value;
    }

    handleRender() {
        this.parseError = '';
        try {
            // Validate it's parseable JSON, but ship the raw string —
            // that's what the real renderer DTO holds.
            JSON.parse(this.jsonInput);
            this.currentValue = { flightsJSON: this.jsonInput };
        } catch (e) {
            this.parseError = e.message;
        }
    }

    handleSampleSingle() {
        this.jsonInput = SAMPLE_SINGLE;
        this.handleRender();
    }

    handleSampleMultiple() {
        this.jsonInput = SAMPLE_MULTIPLE;
        this.handleRender();
    }

    handleSampleError() {
        this.jsonInput = SAMPLE_ERROR;
        this.handleRender();
    }

    handleSampleEmpty() {
        this.jsonInput = SAMPLE_EMPTY;
        this.handleRender();
    }

    handleClear() {
        this.jsonInput = '';
        this.currentValue = { flightsJSON: '' };
        this.parseError = '';
    }
}
