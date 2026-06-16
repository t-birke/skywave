import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import findSessionByExternalId from '@salesforce/apex/SDO_Analytics_SyntheticSessionSearch.findSessionByExternalId';

export default class SdoAnalyticsSyntheticSessionSearch extends NavigationMixin(LightningElement) {
    searchUuid = '';
    errorMessage = '';
    isSearching = false;

    handleUuidChange(event) {
        this.searchUuid = event.target.value;
        this.errorMessage = '';
    }

    handleGoToSession() {
        if (!this.searchUuid || this.searchUuid.trim() === '') {
            this.errorMessage = 'Please enter a UUID to search';
            return;
        }

        this.isSearching = true;
        this.errorMessage = '';

        findSessionByExternalId({ externalId: this.searchUuid.trim() })
            .then(recordId => {
                if (recordId) {
                    // Navigate to the record page
                    this[NavigationMixin.Navigate]({
                        type: 'standard__recordPage',
                        attributes: {
                            recordId: recordId,
                            objectApiName: 'SDO_Analytics_AIAgentSession_v2__c',
                            actionName: 'view'
                        }
                    });

                    // Reset component state for next search
                    this.resetForm();
                }
            })
            .catch(error => {
                this.errorMessage = error.body?.message || error.message || 'An error occurred while searching';
                this.isSearching = false;
            });
    }

    resetForm() {
        this.searchUuid = '';
        this.errorMessage = '';
        this.isSearching = false;
    }
}
