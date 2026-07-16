import { LightningElement, api, wire } from 'lwc';
import HERO_IMG from '@salesforce/resourceUrl/agentforceServiceAssistantHero';
import getTransferDateTime from '@salesforce/apex/Skywave_VoiceCallTransferInfo.getTransferDateTime';

export default class AgentforceServiceAssistant extends LightningElement {
    @api recordId;

    catchUpExpanded = true;
    heroImg = HERO_IMG;

    summary =
        'The caller reached out to change the seat on an upcoming Skywave booking. The Agentforce voice agent verified their identity, located the reservation, and confirmed the requested seat change. Mid-conversation the caller asked to be transferred to a live agent and the call was escalated — no reason was given before the hand-off.';

    topic =
        'Seat change completed on an existing booking, followed by an unexplained escalation to a human agent. Reason for the transfer is unknown; recommend confirming what the caller still needs before the seat change is finalized.';

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
        return new Intl.DateTimeFormat('en-US', {
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