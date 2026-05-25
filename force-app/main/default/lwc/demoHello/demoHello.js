import { LightningElement, api, track } from 'lwc';

export default class DemoHello extends LightningElement {
    @api value;
    @track greeting = '';
    @track when = '';
    @track errorMessage = '';

    connectedCallback() {
        console.log('#### DemoHello input:', this.value);
        try {
            if (!this.value || !this.value.messageJSON) {
                this.errorMessage = 'No data';
                return;
            }
            const data = JSON.parse(this.value.messageJSON);
            this.greeting = data.greeting || '';
            this.when = data.when || '';
        } catch (e) {
            console.error('DemoHello parse error:', e);
            this.errorMessage = 'Error loading';
        }
    }
}
