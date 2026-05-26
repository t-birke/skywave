import { LightningElement, api, wire, track } from 'lwc';
import getEvents from '@salesforce/apex/Skywave_ContactTimeline.getEvents';

export default class SkywaveEngagementTimeline extends LightningElement {
    @api recordId;
    @track events = [];
    @track loading = true;
    @track errorMessage = '';

    @wire(getEvents, { contactId: '$recordId' })
    wiredEvents({ data, error }) {
        this.loading = false;
        if (error) {
            console.error('SkywaveEngagementTimeline wire error:', error);
            this.errorMessage = (error.body && error.body.message) || 'Could not load engagement events.';
            return;
        }
        if (data) {
            this.events = data.map((e) => ({
                ...e,
                accentClass: `sw-tl__entry sw-tl__entry_${e.accent || 'navy'}`,
                iconClass: `sw-tl__icon sw-tl__icon_${e.accent || 'navy'}`
            }));
        }
    }

    get hasEvents() { return this.events && this.events.length > 0; }
    get hasError() { return Boolean(this.errorMessage); }
    get isEmpty() { return !this.loading && !this.hasError && !this.hasEvents; }
}
