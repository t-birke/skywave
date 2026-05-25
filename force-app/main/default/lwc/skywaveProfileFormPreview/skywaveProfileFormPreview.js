import { LightningElement, track } from 'lwc';

const SAMPLE_EMPTY = JSON.stringify({
    contactId: '003000000000000',
    firstName: '',
    lastName: '',
    email: '',
    phone: ''
}, null, 2);

const SAMPLE_PARTIAL = JSON.stringify({
    contactId: '003000000000001',
    firstName: 'Tom',
    lastName: 'Birke',
    email: '',
    phone: ''
}, null, 2);

const SAMPLE_PREFILLED = JSON.stringify({
    contactId: '003000000000002',
    firstName: 'Lauren',
    lastName: 'Bailey',
    email: 'lauren@example.com',
    phone: '+1 415 555 0101'
}, null, 2);

export default class SkywaveProfileFormPreview extends LightningElement {
    @track jsonInput = SAMPLE_EMPTY;
    @track currentValue = { formStateJSON: SAMPLE_EMPTY };
    @track parseError = '';

    connectedCallback() {
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
            JSON.parse(this.jsonInput);
            this.currentValue = { formStateJSON: this.jsonInput };
        } catch (e) {
            this.parseError = e.message;
        }
    }

    handleSampleEmpty() {
        this.jsonInput = SAMPLE_EMPTY;
        this.handleRender();
    }

    handleSamplePartial() {
        this.jsonInput = SAMPLE_PARTIAL;
        this.handleRender();
    }

    handleSamplePrefilled() {
        this.jsonInput = SAMPLE_PREFILLED;
        this.handleRender();
    }

    handleClear() {
        this.jsonInput = '';
        this.currentValue = { formStateJSON: '' };
        this.parseError = '';
    }
}
