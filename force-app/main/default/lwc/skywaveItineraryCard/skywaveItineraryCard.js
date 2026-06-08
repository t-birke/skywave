import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getBookings from '@salesforce/apex/Skywave_ContactItinerary.getBookings';
import cancelBooking from '@salesforce/apex/Skywave_ContactItinerary.cancelBooking';

export default class SkywaveItineraryCard extends LightningElement {
    @api recordId;
    @track bookings = [];
    @track loading = true;
    @track errorMessage = '';
    @track expandedIds = new Set();
    @track cancellingId = null;          // booking Id mid-cancel (button spinner)
    @track cancelError = '';             // last cancel error, surfaced inline

    // Hold the wired result so refreshApex can re-fire after a cancel.
    wiredResult;

    @wire(getBookings, { contactId: '$recordId' })
    wiredBookings(result) {
        this.wiredResult = result;
        const { data, error } = result;
        this.loading = false;
        if (error) {
            console.error('SkywaveItineraryCard wire error:', error);
            this.errorMessage = (error.body && error.body.message) || 'Could not load bookings.';
            return;
        }
        if (data) {
            // Most recent booking expanded by default — but only if it's
            // an upcoming one. Past bookings stay collapsed (history).
            const firstUpcomingId = data.find(b => !b.isPast)?.bookingId;
            this.expandedIds = new Set(firstUpcomingId ? [firstUpcomingId] : []);
            this.bookings = data.map((b) => this.decorate(b));
        }
    }

    decorate(b) {
        const expanded = this.expandedIds.has(b.bookingId);
        return {
            ...b,
            expanded,
            cssClass: this.classFor(b, expanded),
            segmentsKeyed: (b.segments || []).map((s, sidx) => ({
                ...s,
                key: s.segmentId || `${b.bookingId}-${sidx}`
            }))
        };
    }

    classFor(b, expanded) {
        const parts = ['sw-itin'];
        if (expanded) parts.push('sw-itin_expanded');
        if (b.isPast) parts.push('sw-itin_past');
        return parts.join(' ');
    }

    handleToggle(event) {
        const id = event.currentTarget.dataset.bookingid;
        if (!id) return;
        if (this.expandedIds.has(id)) {
            this.expandedIds.delete(id);
        } else {
            this.expandedIds.add(id);
        }
        this.bookings = this.bookings.map(b => this.decorate(b));
    }

    async handleCancel(event) {
        // Stop the click from bubbling up to handleToggle (parent header).
        event.stopPropagation();
        const code = event.currentTarget.dataset.code;
        const id = event.currentTarget.dataset.bookingid;
        if (!code || !id) return;

        // Plain confirm dialog — keeps the LWC self-contained, no toast/modal
        // dependencies on the host app. Presenter UI, not customer-facing.
        const ok = window.confirm(`Cancel booking ${code}? This is permanent.`);
        if (!ok) return;

        this.cancellingId = id;
        this.cancelError = '';
        try {
            await cancelBooking({ contactId: this.recordId, confirmationCode: code });
            // Engine has flipped Status__c=Cancelled. The wire query filters
            // to Status='Confirmed', so refreshApex makes the row vanish.
            await refreshApex(this.wiredResult);
        } catch (e) {
            this.cancelError = (e.body && e.body.message) || e.message || 'Cancel failed.';
            console.error('cancelBooking failed:', e);
        } finally {
            this.cancellingId = null;
        }
    }

    isCancelling(b) {
        return this.cancellingId === b.bookingId;
    }

    // Two computed views over the same list. The HTML renders Upcoming
    // first (heading + cards), then Past (separate heading + cards) only
    // if the contact has any flown bookings.
    get upcomingBookings() {
        return (this.bookings || []).filter(b => !b.isPast).map(b => ({
            ...b,
            cancelDisabled: this.cancellingId === b.bookingId,
            cancelLabel: this.cancellingId === b.bookingId ? 'Cancelling…' : 'Cancel booking'
        }));
    }
    get pastBookings() {
        return (this.bookings || []).filter(b => b.isPast);
    }

    get hasUpcoming() { return this.upcomingBookings.length > 0; }
    get hasPast() { return this.pastBookings.length > 0; }
    get hasBookings() { return this.bookings && this.bookings.length > 0; }
    get hasError() { return Boolean(this.errorMessage); }
    get isEmpty() { return !this.loading && !this.hasError && !this.hasBookings; }
}
