import { LightningElement, api, track } from 'lwc';
import processPayment from '@salesforce/apex/Skywave_ProcessPayment.processPayment';

const ANIMATION_MS = 3000;

export default class SkywavePaymentFormRenderer extends LightningElement {
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
        console.log('#### SkywavePaymentFormRenderer input:', this.value);
        try {
            if (!this.value || !this.value.paymentStateJSON) {
                this.placeholderMessage = 'Skywave Payment Form card preview';
                return;
            }
            const parsed = typeof this.value.paymentStateJSON === 'string'
                ? JSON.parse(this.value.paymentStateJSON)
                : this.value.paymentStateJSON;
            this.contactId = parsed.contactId || '';
            this.bookingCode = parsed.bookingCode || '';
            this.totalCharged = parsed.totalCharged || '';
        } catch (e) {
            console.error('SkywavePaymentFormRenderer parse error:', e);
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
        // after BOTH the timer AND the response have resolved. The 3-second
        // animation is the demo's punch-line — don't shortcut it even if
        // Apex returns in 200ms.
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
                console.error('SkywavePaymentFormRenderer processPayment error:', e);
                this.errorMessage = (e && e.body && e.body.message) || 'Payment failed.';
                this.processing = false;
            });
    }

    _cueAgent() {
        const cue = 'Payment completed';
        try {
            if (typeof embeddedservice_bootstrap !== 'undefined'
                && embeddedservice_bootstrap?.utilAPI?.sendTextMessage) {
                embeddedservice_bootstrap.utilAPI.sendTextMessage(cue)
                    .then(() => console.log('Payment cue sent (utilAPI):', cue))
                    .catch((e) => console.error('utilAPI.sendTextMessage error:', e));
                return;
            }
            if (typeof embeddedservice_configuration !== 'undefined'
                && embeddedservice_configuration?.util?.sendTextMessage) {
                embeddedservice_configuration.util.sendTextMessage(cue)
                    .then(() => console.log('Payment cue sent (configuration.util):', cue))
                    .catch((e) => console.error('configuration.util.sendTextMessage error:', e));
                return;
            }
            console.warn('No sendTextMessage API; would have sent:', cue);
        } catch (e) {
            console.error('SkywavePaymentFormRenderer cue error:', e);
        }
    }

    get hasDemoNotice() { return Boolean(this.demoNotice); }
}
