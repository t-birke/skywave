import { LightningElement, api, track } from 'lwc';

/**
 * Renders the Skywave rental offer as a single chat card: a duration
 * slider (1-14 days) at the top and three vehicle tiles (Economy /
 * Comfort / Luxury) whose per-tile totals update live as the slider
 * moves. Tapping a tile's Reserve button posts
 *   "Rent <category> for <N> days"
 * back to chat, which the rental agent maps to Skywave_ReserveVehicle.
 */
export default class SkywaveRentalOfferRenderer extends LightningElement {
    @api value;

    @track destinationCity = '';
    @track destinationCode = '';
    @track pickupLabel = '';
    @track minDays = 1;
    @track maxDays = 14;
    @track days = 3;
    @track tiers = [];
    @track errorMessage = '';
    @track placeholderMessage = '';
    @track reserved = false;
    @track reservedLabel = '';

    connectedCallback() {
        console.log('#### SkywaveRentalOfferRenderer input:', this.value);
        try {
            if (!this.value || !this.value.offerStateJSON) {
                this.placeholderMessage = 'Skywave Rental Offer card preview';
                return;
            }
            const parsed = typeof this.value.offerStateJSON === 'string'
                ? JSON.parse(this.value.offerStateJSON)
                : this.value.offerStateJSON;

            this.destinationCity = parsed.destinationCity || parsed.destinationCode || '';
            this.destinationCode = parsed.destinationCode || '';
            this.minDays = parsed.minDays != null ? Number(parsed.minDays) : 1;
            this.maxDays = parsed.maxDays != null ? Number(parsed.maxDays) : 14;
            this.days = parsed.defaultDays != null ? Number(parsed.defaultDays) : this.minDays;
            this.pickupLabel = this._formatPickup(parsed.pickupDate);
            this._rawTiers = Array.isArray(parsed.tiers) ? parsed.tiers : [];
            this._recompute();
        } catch (e) {
            console.error('SkywaveRentalOfferRenderer parse error:', e);
            this.errorMessage = 'Could not load rental options.';
        }
    }

    handleSliderChange(event) {
        this.days = Number(event.target.value);
        this._recompute();
    }

    handleReserve(event) {
        const category = event.currentTarget.dataset.category;
        const message = `Rent ${category} for ${this.days} ${this.days === 1 ? 'day' : 'days'}`;
        this.reserved = true;
        this.reservedLabel = `${category} · ${this.days} ${this.days === 1 ? 'day' : 'days'}`;
        console.log('#### SkywaveRentalOfferRenderer reserving:', message);
        this._sendCue(message);
    }

    // Rebuild the tile view models with the current day count so the totals
    // and the daily-rate line stay in sync with the slider.
    _recompute() {
        this.tiers = this._rawTiers.map((t) => {
            const rate = Number(t.dailyRate) || 0;
            const total = rate * this.days;
            return {
                category: t.category,
                exampleModel: t.exampleModel,
                blurb: t.blurb,
                rateLabel: `$${rate}/day`,
                totalLabel: `$${total.toFixed(2)}`
            };
        });
    }

    _formatPickup(iso) {
        if (!iso) return '';
        // iso is YYYY-MM-DD; render as "Jun 14" without timezone drift.
        const parts = String(iso).split('-');
        if (parts.length !== 3) return '';
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        const m = Number(parts[1]) - 1;
        const d = Number(parts[2]);
        if (m < 0 || m > 11 || !d) return '';
        return `${months[m]} ${d}`;
    }

    _sendCue(message) {
        try {
            if (typeof embeddedservice_bootstrap !== 'undefined'
                && embeddedservice_bootstrap?.utilAPI?.sendTextMessage) {
                embeddedservice_bootstrap.utilAPI.sendTextMessage(message)
                    .then(() => console.log('Rental cue sent (utilAPI):', message))
                    .catch((e) => console.error('utilAPI.sendTextMessage error:', e));
                return;
            }
            if (typeof embeddedservice_configuration !== 'undefined'
                && embeddedservice_configuration?.util?.sendTextMessage) {
                embeddedservice_configuration.util.sendTextMessage(message)
                    .then(() => console.log('Rental cue sent (configuration.util):', message))
                    .catch((e) => console.error('configuration.util.sendTextMessage error:', e));
                return;
            }
            console.warn('No sendTextMessage API; would have sent:', message);
        } catch (e) {
            console.error('SkywaveRentalOfferRenderer cue error:', e);
        }
    }

    get headline() {
        return this.destinationCity
            ? `Rent a car in ${this.destinationCity}`
            : 'Rent a car for your trip';
    }

    get pickupSubtitle() {
        return this.pickupLabel
            ? `Pick-up ${this.pickupLabel} (arrival)`
            : 'Pick-up on your arrival date';
    }

    get daysLabel() {
        return `${this.days} ${this.days === 1 ? 'day' : 'days'}`;
    }
}
