import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import CONTACT_FIELD from '@salesforce/schema/VoiceCall.Contact__c';

/**
 * VoiceCall-page wrapper for skywaveEngagementTimeline.
 *
 * Resolves VoiceCall.Contact__c and passes it down as the inner timeline's
 * record-id, so the caller's engagement events (survey, bookings, seat changes)
 * show during a live call without editing the proven Contact-page component.
 */
export default class SkywaveVoiceEngagementTimeline extends LightningElement {
    @api recordId; // VoiceCall Id

    @wire(getRecord, { recordId: '$recordId', fields: [CONTACT_FIELD] })
    voiceCall;

    get contactId() {
        return this.voiceCall && this.voiceCall.data
            ? getFieldValue(this.voiceCall.data, CONTACT_FIELD)
            : null;
    }

    get hasContact() {
        return Boolean(this.contactId);
    }
}
