import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { NavigationMixin } from 'lightning/navigation';
import getAgentApiName from '@salesforce/apex/SDO_Analytics_QuickAccessSession.getAgentApiName';

const FIELDS = ['SDO_Analytics_AIAgentSession_v2__c.External_ID__c'];

export default class SdoAnalyticsQuickAccessSession extends NavigationMixin(LightningElement) {
    @api recordId;

    externalId;
    agentApiName;
    isDisabled = true;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredRecord({ error, data }) {
        if (data) {
            this.externalId = getFieldValue(data, FIELDS[0]);
            if (this.externalId) {
                this.loadAgentApiName();
            } else {
                this.isDisabled = true;
            }
        } else if (error) {
            console.error('Error loading record:', error);
            this.isDisabled = true;
        }
    }

    loadAgentApiName() {
        getAgentApiName({ externalId: this.externalId })
            .then(result => {
                this.agentApiName = result;
                // Enable button if we have both externalId and agentApiName
                this.isDisabled = !this.externalId || !this.agentApiName;
            })
            .catch(error => {
                console.error('Error loading Agent API Name:', error);
                this.agentApiName = null;
                this.isDisabled = true;
            });
    }

    handleNavigateToAnalytics() {
        if (!this.externalId || !this.agentApiName) {
            return;
        }

        // Navigate to the Lightning component with state parameters
        this[NavigationMixin.Navigate]({
            type: 'standard__component',
            attributes: {
                componentName: 'runtime_analytics_evf_aie__record'
            },
            state: {
                c__id: '',
                c__type: '2',
                c__title: this.externalId,
                c__sessionId: this.externalId,
                c__agentApiName: this.agentApiName
            }
        });
    }
}
