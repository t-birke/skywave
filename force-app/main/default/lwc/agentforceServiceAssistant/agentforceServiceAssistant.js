import { LightningElement, api, wire } from 'lwc';
import HERO_IMG from '@salesforce/resourceUrl/agentforceServiceAssistantHero';
import getTransferDateTime from '@salesforce/apex/Skywave_VoiceCallTransferInfo.getTransferDateTime';

export default class AgentforceServiceAssistant extends LightningElement {
    @api recordId;

    catchUpExpanded = true;
    heroImg = HERO_IMG;

    summary =
        'Stefan ruft an, weil seine Vitocal 250-A einen Fehlercode zeigt und nicht heizt. Der Agent hat eine Ferndiagnose ausgelöst und einen Servicetermin angeboten.';

    topic =
        'Kunde benötigt einen Technikereinsatz für die Wärmepumpe und möchte zusätzlich Informationen zum erweiterten Garantieangebot erhalten.';

    transferDateTime;

    @wire(getTransferDateTime, { voiceCallId: '$recordId' })
    wiredTransfer({ data }) {
        if (data) {
            this.transferDateTime = data;
        }
    }

    get summaryCreated() {
        if (!this.transferDateTime) {
            return null;
        }
        const dt = new Date(this.transferDateTime);
        return new Intl.DateTimeFormat('de-DE', {
            day: '2-digit',
            month: '2-digit',
            year: 'numeric',
            hour: '2-digit',
            minute: '2-digit'
        }).format(dt);
    }

    get heroStyle() {
        return `background-image: url('${this.heroImg}');`;
    }

    handleToggleCatchUp() {
        this.catchUpExpanded = !this.catchUpExpanded;
    }

    get catchUpIcon() {
        return this.catchUpExpanded ? 'utility:chevrondown' : 'utility:chevronright';
    }

    get catchUpClass() {
        return this.catchUpExpanded ? 'catch-up open' : 'catch-up';
    }
}