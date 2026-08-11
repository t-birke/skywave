import { LightningElement, api, track } from 'lwc';
import processPayment from '@salesforce/apex/Skywave_ProcessRentalPayment.processPayment';

const ANIMATION_MS = 3000;

/**
 * Rental payment picker — the rental twin of skywavePaymentFormRenderer.
 * Three options (Apple Pay / Credit card / Demo Pay); only Demo Pay is
 * live and calls Skywave_ProcessRentalPayment imperatively to flip the
 * Vehicle_Booking__c to Paid/Confirmed. On success it posts
 * "Rental payment completed" to chat as the agent cue.
 */
export default class SkywaveRentalPaymentRenderer extends LightningElement {
    @api value;

    @track contactId = '';
    @track bookingCode = '';
    @track totalCharged = '';

    @track demoNotice = '';
    @track processing = false;
    @track completed = false;
    @track errorMessage = '';
    @track placeholderMessage = '';

    connectedCallback() {
        console.log('#### SkywaveRentalPaymentRenderer input:', this.value);
        try {
            if (!this.value || !this.value.paymentStateJSON) {
                this.placeholderMessage = 'Skywave Rental Payment card preview';
                return;
            }
            const parsed = typeof this.value.paymentStateJSON === 'string'
                ? JSON.parse(this.value.paymentStateJSON)
                : this.value.paymentStateJSON;
            this.contactId = parsed.contactId || '';
            this.bookingCode = parsed.bookingCode || '';
            this.totalCharged = parsed.totalCharged || '';
        } catch (e) {
            console.error('SkywaveRentalPaymentRenderer parse error:', e);
            this.errorMessage = 'Could not load payment form.';
        }
    }

    handleAppleClick() { this._showDemoNotice('Apple Pay'); }
    handleCardClick() { this._showDemoNotice('Credit card'); }

    _showDemoNotice(method) {
        this.demoNotice = method + ' is demo-only — please use Demo Pay to complete.';
    }

    handleDemoClick() {
        if (this.processing || this.completed) return;
        this.errorMessage = '';
        this.demoNotice = '';
        this.processing = true;

        // Run animation + Apex call in parallel; reveal "completed" only
        // after BOTH the timer AND the response resolve. The 3-second
        // animation is the demo punch-line — don't shortcut it.
        const timerDone = new Promise((resolve) => setTimeout(resolve, ANIMATION_MS));
        const apexDone = processPayment({
            bookingCode: this.bookingCode,
            paymentMethod: 'Demo card'
        });

        Promise.all([timerDone, apexDone])
            .then(([_, result]) => {
                if (!result || !result.success) {
                    this.errorMessage = (result && result.message) || 'Payment failed.';
                    this.processing = false;
                    return;
                }
                this.processing = false;
                this.completed = true;
                this._cueAgent();
            })
            .catch((e) => {
                console.error('SkywaveRentalPaymentRenderer processPayment error:', e);
                this.errorMessage = (e && e.body && e.body.message) || 'Payment failed.';
                this.processing = false;
            });
    }

    _cueAgent() {
        const cue = 'Rental payment completed';
        try {
            if (typeof embeddedservice_bootstrap !== 'undefined'
                && embeddedservice_bootstrap?.utilAPI?.sendTextMessage) {
                embeddedservice_bootstrap.utilAPI.sendTextMessage(cue)
                    .then(() => console.log('Rental payment cue sent (utilAPI):', cue))
                    .catch((e) => console.error('utilAPI.sendTextMessage error:', e));
                return;
            }
            if (typeof embeddedservice_configuration !== 'undefined'
                && embeddedservice_configuration?.util?.sendTextMessage) {
                embeddedservice_configuration.util.sendTextMessage(cue)
                    .then(() => console.log('Rental payment cue sent (configuration.util):', cue))
                    .catch((e) => console.error('configuration.util.sendTextMessage error:', e));
                return;
            }
            console.warn('No sendTextMessage API; would have sent:', cue);
        } catch (e) {
            console.error('SkywaveRentalPaymentRenderer cue error:', e);
        }
    }

    get hasDemoNotice() { return Boolean(this.demoNotice); }
}
