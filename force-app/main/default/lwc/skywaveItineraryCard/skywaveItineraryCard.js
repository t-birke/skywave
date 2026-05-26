import { LightningElement, api, wire, track } from 'lwc';
import getBookings from '@salesforce/apex/Skywave_ContactItinerary.getBookings';

export default class SkywaveItineraryCard extends LightningElement {
    @api recordId;
    @track bookings = [];
    @track loading = true;
    @track errorMessage = '';
    @track expandedIds = new Set();

    @wire(getBookings, { contactId: '$recordId' })
    wiredBookings({ data, error }) {
        this.loading = false;
        if (error) {
            console.error('SkywaveItineraryCard wire error:', error);
            this.errorMessage = (error.body && error.body.message) || 'Could not load bookings.';
            return;
        }
        if (data) {
            this.bookings = data.map((b, idx) => ({
                ...b,
                expanded: idx === 0,
                cssClass: idx === 0 ? 'sw-itin sw-itin_expanded' : 'sw-itin',
                segmentsKeyed: (b.segments || []).map((s, sidx) => ({
                    ...s,
                    key: s.segmentId || `${b.bookingId}-${sidx}`
                }))
            }));
            // Track expanded ids so toggling preserves which cards user opened.
            this.expandedIds = new Set(data.length > 0 ? [data[0].bookingId] : []);
        }
    }

    handleToggle(event) {
        const id = event.currentTarget.dataset.bookingid;
        if (!id) return;
        if (this.expandedIds.has(id)) {
            this.expandedIds.delete(id);
        } else {
            this.expandedIds.add(id);
        }
        this.bookings = this.bookings.map(b => ({
            ...b,
            expanded: this.expandedIds.has(b.bookingId),
            cssClass: this.expandedIds.has(b.bookingId)
                ? 'sw-itin sw-itin_expanded'
                : 'sw-itin'
        }));
    }

    get hasBookings() { return this.bookings && this.bookings.length > 0; }
    get hasError() { return Boolean(this.errorMessage); }
    get isEmpty() { return !this.loading && !this.hasError && !this.hasBookings; }
}
