import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getVoiceCallRecording from '@salesforce/apex/SDO_Analytics_SessionAudio.getVoiceCallRecording';
import updateVoiceCallRecordingMedia from '@salesforce/apex/SDO_Analytics_SessionAudio.updateVoiceCallRecordingMedia';
import getAvailableAudioFiles from '@salesforce/apex/SDO_Analytics_SessionAudio.getAvailableAudioFiles';
import getAcceptedAudioFormats from '@salesforce/apex/SDO_Analytics_SessionAudio.getAcceptedAudioFormats';

const RELATED_VOICE_CALL_FIELD = 'SDO_Analytics_AIAgentSession_v2__c.Related_Voice_Call__c';
const FIELDS = [RELATED_VOICE_CALL_FIELD];

export default class SdoAnalyticsSessionAudio extends LightningElement {
    @api recordId;

    voiceCallId;
    recordingData;
    errorMessage;
    isLoading = true;
    showUploadSection = false;
    isUploading = false;
    hasVoiceCallRecording = false;
    uploadMode = 'new';
    availableFiles = [];
    selectedFileId;
    acceptedFormats = [];

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredRecord({ error, data }) {
        if (data) {
            this.voiceCallId = getFieldValue(data, RELATED_VOICE_CALL_FIELD);
            if (this.voiceCallId) {
                this.loadRecording();
            } else {
                this.errorMessage = 'No related voice call found for this session';
                this.isLoading = false;
                this.hasVoiceCallRecording = false;
            }
        } else if (error) {
            this.errorMessage = 'Error loading record: ' + (error.body?.message || error.message);
            this.isLoading = false;
            this.hasVoiceCallRecording = false;
        }
    }

    @wire(getAvailableAudioFiles)
    wiredAudioFiles({ error, data }) {
        if (data) {
            this.availableFiles = data;
        } else if (error) {
            console.error('Error loading audio files:', error);
            this.availableFiles = [];
        }
    }

    @wire(getAcceptedAudioFormats)
    wiredAcceptedFormats({ error, data }) {
        if (data) {
            this.acceptedFormats = data;
        } else if (error) {
            console.error('Error loading accepted formats:', error);
            this.acceptedFormats = ['.mp3', '.wav', '.ogg', '.webm', '.m4a', '.aac', '.flac', '.opus'];
        }
    }

    loadRecording() {
        this.isLoading = true;
        this.errorMessage = null;

        getVoiceCallRecording({ voiceCallId: this.voiceCallId })
            .then(result => {
                if (result.error) {
                    this.errorMessage = result.error;
                    this.recordingData = null;
                    this.hasVoiceCallRecording = result.hasVoiceCallRecording || false;
                } else {
                    this.recordingData = result;
                    this.hasVoiceCallRecording = result.hasVoiceCallRecording || false;
                }
                this.isLoading = false;
            })
            .catch(error => {
                this.errorMessage = 'Failed to load recording: ' + (error.body?.message || error.message);
                this.recordingData = null;
                this.hasVoiceCallRecording = false;
                this.isLoading = false;
            });
    }

    get hasRecording() {
        return !this.isLoading && !this.errorMessage && this.recordingData;
    }

    get hasError() {
        return !this.isLoading && this.errorMessage;
    }

    get showNoRecording() {
        return !this.isLoading && !this.errorMessage && !this.recordingData && !this.voiceCallId;
    }

    get showUploadOption() {
        // Only show upload option if there's a VoiceCallRecording record
        return !this.isLoading && this.hasVoiceCallRecording;
    }

    get uploadLabel() {
        return this.recordingData ? 'Change Audio File' : 'Upload Audio File';
    }

    get uploadModeOptions() {
        return [
            { label: 'Upload New File', value: 'new' },
            { label: 'Select Existing File', value: 'existing' }
        ];
    }

    get isNewFileMode() {
        return this.uploadMode === 'new';
    }

    get isExistingFileMode() {
        return this.uploadMode === 'existing';
    }

    get hasAvailableFiles() {
        return this.availableFiles && this.availableFiles.length > 0;
    }

    get audioUrl() {
        if (!this.recordingData?.contentVersionId) {
            return null;
        }
        // Use the ContentVersion download URL
        return `/sfc/servlet.shepherd/version/download/${this.recordingData.contentVersionId}`;
    }

    get audioType() {
        if (!this.recordingData?.fileType) {
            return 'audio/mpeg'; // Default
        }

        // Map file types to MIME types
        const typeMap = {
            'mp3': 'audio/mpeg',
            'wav': 'audio/wav',
            'ogg': 'audio/ogg',
            'webm': 'audio/webm',
            'm4a': 'audio/mp4',
            'aac': 'audio/aac',
            'flac': 'audio/flac',
            'opus': 'audio/opus'
        };

        const extension = this.recordingData.fileExtension?.toLowerCase();
        return typeMap[extension] || this.recordingData.fileType || 'audio/mpeg';
    }

    get recordingTitle() {
        return this.recordingData?.title || 'Unknown';
    }

    handleLookupChange() {
        // Auto-submit the form when the lookup value changes
        const form = this.template.querySelector('lightning-record-edit-form');
        if (form) {
            form.submit();
        }
    }

    handleSuccess(event) {
        // When the voice call lookup is updated, reload the recording
        const updatedRecord = event.detail;
        this.voiceCallId = updatedRecord.fields.Related_Voice_Call__c.value;

        if (this.voiceCallId) {
            this.loadRecording();
        } else {
            this.errorMessage = 'No related voice call selected';
            this.recordingData = null;
            this.hasVoiceCallRecording = false;
        }
    }

    toggleUploadSection() {
        this.showUploadSection = !this.showUploadSection;
        this.uploadMode = 'new';
        this.selectedFileId = null;
    }

    handleUploadModeChange(event) {
        this.uploadMode = event.detail.value;
        this.selectedFileId = null;
    }

    handleFileSelection(event) {
        this.selectedFileId = event.detail.value;
    }

    handleSelectExistingFile() {
        if (!this.selectedFileId) {
            this.showToast('Error', 'Please select a file', 'error');
            return;
        }

        this.isUploading = true;

        updateVoiceCallRecordingMedia({
            voiceCallId: this.voiceCallId,
            contentDocumentId: this.selectedFileId
        })
            .then(error => {
                if (error) {
                    this.showToast('Error', error, 'error');
                    this.isUploading = false;
                } else {
                    this.showToast('Success', 'Recording file selected successfully.', 'success');
                    this.showUploadSection = false;
                    this.selectedFileId = null;
                    this.loadRecording();
                    this.isUploading = false;
                }
            })
            .catch(error => {
                this.showToast('Error', 'Failed to update recording: ' + (error.body?.message || error.message), 'error');
                this.isUploading = false;
            });
    }

    handleUploadFinished(event) {
        this.isUploading = true;
        const uploadedFiles = event.detail.files;

        if (uploadedFiles && uploadedFiles.length > 0) {
            const contentDocumentId = uploadedFiles[0].documentId;

            // Update the VoiceCallRecording with the new MediaContentId
            updateVoiceCallRecordingMedia({
                voiceCallId: this.voiceCallId,
                contentDocumentId: contentDocumentId
            })
                .then(error => {
                    if (error) {
                        this.showToast('Error', error, 'error');
                        this.isUploading = false;
                    } else {
                        this.showToast('Success', 'Recording file uploaded successfully.', 'success');
                        this.showUploadSection = false;
                        // Automatically reload the recording to display the new file with fresh data
                        this.loadRecording();
                        this.isUploading = false;
                    }
                })
                .catch(error => {
                    this.showToast('Error', 'Failed to update recording: ' + (error.body?.message || error.message), 'error');
                    this.isUploading = false;
                });
        }
    }

    showToast(title, message, variant) {
        const event = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        });
        this.dispatchEvent(event);
    }
}
