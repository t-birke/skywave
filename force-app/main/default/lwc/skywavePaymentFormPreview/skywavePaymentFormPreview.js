import { LightningElement, track } from 'lwc';

const SAMPLE = JSON.stringify({
    contactId: '003000000000000',
    bookingCode: 'A2K9XQ',
    totalCharged: '$1,430.00'
}, null, 2);

export default class SkywavePaymentFormPreview extends LightningElement {
    @track jsonInput = SAMPLE;
    @track currentValue = { paymentStateJSON: SAMPLE };
    @track parseError = '';
    @track widthChoice = '380';

    connectedCallback() { this.handleRender(); }

    get widthOptions() {
        return [
            { label: '380px (chat)', value: '380' },
            { label: '320px (mobile chat)', value: '320' },
            { label: '480px (desktop chat)', value: '480' },
            { label: '100% (fluid)', value: '100' }
        ];
    }

    get frameStyle() {
        return this.widthChoice === '100' ? 'width: 100%;' : `width: ${this.widthChoice}px;`;
    }

    handleJsonChange(e) { this.jsonInput = e.detail.value; }
    handleWidthChange(e) { this.widthChoice = e.target.value; }

    handleRender() {
        this.parseError = '';
        try {
            JSON.parse(this.jsonInput);
            this.currentValue = { paymentStateJSON: this.jsonInput };
        } catch (e) {
            this.parseError = e.message;
        }
    }

    handleClear() {
        this.jsonInput = '';
        this.currentValue = { paymentStateJSON: '' };
        this.parseError = '';
    }
}
