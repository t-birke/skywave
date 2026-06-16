import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getDataStreamId from '@salesforce/apex/SDO_Analytics_DataStreamNavigator.getDataStreamId';

export default class SdoAnalyticsDataStreamNavigator extends NavigationMixin(LightningElement) {
    @api buttonLabel = 'Open Data Stream';
    @api streamName;

    isDisabled = false;
    isLoading = false;
    errorMessage;

    handleNavigateToDataStream() {
        if (!this.streamName) {
            this.errorMessage = 'Data Stream Name is required';
            return;
        }

        this.isLoading = true;
        this.isDisabled = true;
        this.errorMessage = null;

        getDataStreamId({ dataStreamName: this.streamName })
            .then(dataStreamId => {
                if (dataStreamId) {
                    this[NavigationMixin.Navigate]({
                        type: 'standard__recordPage',
                        attributes: {
                            recordId: dataStreamId,
                            objectApiName: 'DataStream',
                            actionName: 'view'
                        }
                    });
                } else {
                    this.errorMessage = `Data Stream '${this.streamName}' not found`;
                }
            })
            .catch(error => {
                console.error('Error loading Data Stream:', error);
                this.errorMessage = error.body?.message || 'Error loading Data Stream';
            })
            .finally(() => {
                this.isLoading = false;
                this.isDisabled = false;
            });
    }

    get hasError() {
        return !!this.errorMessage;
    }
}
