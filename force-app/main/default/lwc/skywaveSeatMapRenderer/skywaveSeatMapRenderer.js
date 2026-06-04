import { LightningElement, api, track } from 'lwc';
import confirmSeatChange from '@salesforce/apex/Skywave_ChangeSeat.confirmSeatChange';

const ANIMATION_MS = 3000;

export default class SkywaveSeatMapRenderer extends LightningElement {
    @api value;

    @track bookingSegmentId = '';
    @track bookingCode = '';
    @track flightNumber = '';
    @track currentSeat = '';
    @track rows = [];

    @track selectedSeat = '';
    @track processing = false;
    @track completed = false;
    @track aborted = false;
    @track errorMessage = '';
    @track placeholderMessage = '';

    // Confirmation detail shown after a successful change.
    @track confirmedBookingCode = '';
    @track confirmedFlightNumber = '';
    @track confirmedSeat = '';

    connectedCallback() {
        console.log('#### SkywaveSeatMapRenderer input:', this.value);
        try {
            if (!this.value || !this.value.seatMapJSON) {
                this.placeholderMessage = 'Skywave Seat Map card preview';
                return;
            }
            const parsed = typeof this.value.seatMapJSON === 'string'
                ? JSON.parse(this.value.seatMapJSON)
                : this.value.seatMapJSON;

            this.bookingSegmentId = parsed.bookingSegmentId || '';
            this.bookingCode = parsed.bookingCode || '';
            this.flightNumber = parsed.flightNumber || '';
            this.currentSeat = (parsed.currentSeat || '').toUpperCase();
            this.selectedSeat = this.currentSeat;
            this.rows = this._buildRows(parsed.rows || []);
        } catch (e) {
            console.error('SkywaveSeatMapRenderer parse error:', e);
            this.errorMessage = 'Could not load the seat map.';
        }
    }

    // Decorate each seat with display flags + a stable key for iteration.
    _buildRows(rawRows) {
        return rawRows.map((r) => ({
            row: r.row,
            key: `row-${r.row}`,
            seats: (r.seats || []).map((s) => this._decorateSeat(s))
        }));
    }

    _decorateSeat(s) {
        const isSelected = s.code === this.selectedSeat;
        const isTaken = s.status === 'taken';
        const isCurrent = s.status === 'current';
        // CSS class drives the look; aria/disabled drive a11y + interaction.
        let cls = 'sw-seat';
        if (isTaken) cls += ' sw-seat_taken';
        else if (isSelected) cls += ' sw-seat_selected';
        else if (isCurrent) cls += ' sw-seat_current';
        else cls += ' sw-seat_available';
        return {
            code: s.code,
            status: s.status,
            cssClass: cls,
            disabled: isTaken || this.processing || this.completed || this.aborted,
            selectable: !isTaken
        };
    }

    // Re-decorate all seats against the current selection (cheap; small grid).
    _refreshSeats() {
        this.rows = this.rows.map((r) => ({
            ...r,
            seats: r.seats.map((s) => this._decorateSeat({ code: s.code, status: s.status }))
        }));
    }

    handleSeatClick(event) {
        if (this.processing || this.completed || this.aborted) return;
        const code = event.currentTarget.dataset.code;
        const status = event.currentTarget.dataset.status;
        if (status === 'taken') return;
        this.selectedSeat = code;
        this.errorMessage = '';
        this._refreshSeats();
    }

    handleConfirm() {
        if (this.processing || this.completed || this.aborted) return;
        if (!this.selectedSeat) {
            this.errorMessage = 'Please pick a seat first.';
            return;
        }
        this.errorMessage = '';
        this.processing = true;
        this._refreshSeats();

        // Run the airplane animation and the Apex call in parallel; only reveal
        // the confirmation once BOTH the timer and the response have resolved —
        // same punch-line timing as the payment card.
        const timerDone = new Promise((resolve) => setTimeout(resolve, ANIMATION_MS));
        const apexDone = confirmSeatChange({
            bookingSegmentId: this.bookingSegmentId,
            newSeatNumber: this.selectedSeat
        });

        Promise.all([timerDone, apexDone])
            .then(([, result]) => {
                if (!result || !result.success) {
                    this.errorMessage = (result && result.message) || 'Seat change failed.';
                    this.processing = false;
                    this._refreshSeats();
                    return;
                }
                this.confirmedBookingCode = result.bookingCode || this.bookingCode;
                this.confirmedFlightNumber = result.flightNumber || this.flightNumber;
                this.confirmedSeat = result.seatNumber || this.selectedSeat;
                this.processing = false;
                this.completed = true;
                this._cueAgent('seat change confirmed');
            })
            .catch((e) => {
                console.error('SkywaveSeatMapRenderer confirmSeatChange error:', e);
                this.errorMessage = (e && e.body && e.body.message) || 'Seat change failed.';
                this.processing = false;
                this._refreshSeats();
            });
    }

    handleAbort() {
        if (this.processing || this.completed || this.aborted) return;
        // No Apex — just collapse the card and tell the agent.
        this.aborted = true;
        this._cueAgent('seat change aborted');
    }

    _cueAgent(cue) {
        try {
            if (typeof embeddedservice_bootstrap !== 'undefined'
                && embeddedservice_bootstrap?.utilAPI?.sendTextMessage) {
                embeddedservice_bootstrap.utilAPI.sendTextMessage(cue)
                    .then(() => console.log('Seat cue sent (utilAPI):', cue))
                    .catch((e) => console.error('utilAPI.sendTextMessage error:', e));
                return;
            }
            if (typeof embeddedservice_configuration !== 'undefined'
                && embeddedservice_configuration?.util?.sendTextMessage) {
                embeddedservice_configuration.util.sendTextMessage(cue)
                    .then(() => console.log('Seat cue sent (configuration.util):', cue))
                    .catch((e) => console.error('configuration.util.sendTextMessage error:', e));
                return;
            }
            console.warn('No sendTextMessage API; would have sent:', cue);
        } catch (e) {
            console.error('SkywaveSeatMapRenderer cue error:', e);
        }
    }

    get headerSub() {
        const parts = [];
        if (this.bookingCode) parts.push(`Booking ${this.bookingCode}`);
        if (this.flightNumber) parts.push(`Flight ${this.flightNumber}`);
        return parts.join(' · ');
    }

    get selectionLabel() {
        if (!this.selectedSeat) return 'No seat selected';
        if (this.selectedSeat === this.currentSeat) return `Current seat ${this.selectedSeat}`;
        return `New seat ${this.selectedSeat}`;
    }

    get confirmDisabled() {
        return this.processing || !this.selectedSeat;
    }
}
