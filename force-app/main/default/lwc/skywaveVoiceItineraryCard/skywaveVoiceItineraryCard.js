import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import CONTACT_FIELD from '@salesforce/schema/VoiceCall.Contact__c';

/**
 * VoiceCall-page wrapper for skywaveItineraryCard.
 *
 * On a VoiceCall record page `recordId` is the VoiceCall, not the Contact.
 * This wrapper resolves VoiceCall.Contact__c and passes it down as the inner
 * card's record-id (the inner card uses recordId AS the contactId), so the
 * proven Contact-page card works unchanged during a live call.
 */
export default class SkywaveVoiceItineraryCard extends LightningElement {
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
