import { LightningElement, api, track } from 'lwc';
import saveProfile from '@salesforce/apex/Skywave_SaveProfile.saveProfile';

const MAX_AVATAR_BYTES = 2 * 1024 * 1024; // 2 MB raw, before base64 inflation

export default class SkywaveProfileFormRenderer extends LightningElement {
    @api value;

    @track contactId = '';
    @track firstName = '';
    @track lastName = '';
    @track email = '';
    @track phone = '';
    @track consent = false;

    @track avatarBase64 = '';
    @track avatarFileName = '';
    @track avatarPreview = '';

    @track submitting = false;
    @track submitted = false;
    @track errorMessage = '';
    @track placeholderMessage = '';

    connectedCallback() {
        console.log('#### SkywaveProfileFormRenderer input:', this.value);
        try {
            if (!this.value || !this.value.formStateJSON) {
                this.placeholderMessage = 'Skywave Profile Form card preview';
                return;
            }
            const raw = this.value.formStateJSON;
            const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
            this.contactId = parsed.contactId || '';
            this.firstName = parsed.firstName || '';
            this.lastName = parsed.lastName || '';
            this.email = parsed.email || '';
            this.phone = parsed.phone || '';
        } catch (e) {
            console.error('SkywaveProfileFormRenderer parse error:', e);
            this.errorMessage = 'Could not load profile form.';
        }
    }

    handleField(event) {
        const field = event.target.dataset.field;
        if (!field) return;
        if (field === 'consent') {
            this.consent = event.target.checked;
            return;
        }
        this[field] = event.target.value;
    }

    handleAvatarChange(event) {
        const file = event.target.files && event.target.files[0];
        if (!file) return;
        if (file.size > MAX_AVATAR_BYTES) {
            this.errorMessage = 'Avatar too large (max 2 MB).';
            return;
        }
        const reader = new FileReader();
        reader.onload = () => {
            // dataURL form: "data:image/png;base64,AAAA..."
            this.avatarBase64 = reader.result;
            this.avatarPreview = reader.result;
            this.avatarFileName = file.name || 'avatar.png';
        };
        reader.onerror = () => {
            this.errorMessage = 'Could not read image.';
        };
        reader.readAsDataURL(file);
    }

    get isValid() {
        return (
            (this.firstName || '').trim().length >= 2
            && (this.lastName || '').trim().length >= 2
            && (this.email || '').includes('@')
            && this.consent === true
            && !this.submitting
        );
    }

    get submitDisabled() {
        return !this.isValid;
    }

    get avatarStyle() {
        return this.avatarPreview
            ? `background-image: url(${this.avatarPreview});`
            : '';
    }

    handleSubmit() {
        if (!this.isValid) return;
        this.submitting = true;
        this.errorMessage = '';

        saveProfile({
            contactId: this.contactId,
            firstName: this.firstName,
            lastName: this.lastName,
            email: this.email,
            phone: this.phone,
            avatarBase64: this.avatarBase64 || '',
            avatarFileName: this.avatarFileName || ''
        })
            .then((result) => {
                if (!result || !result.success) {
                    this.errorMessage = (result && result.message) || 'Profile save failed.';
                    return;
                }
                this.submitted = true;
                this.cueAgent();
            })
            .catch((e) => {
                console.error('SkywaveProfileFormRenderer saveProfile error:', e);
                this.errorMessage = (e && e.body && e.body.message) || 'Profile save failed.';
            })
            .finally(() => {
                this.submitting = false;
            });
    }

    cueAgent() {
        const cue = 'Profile created';
        try {
            if (typeof embeddedservice_bootstrap !== 'undefined'
                && embeddedservice_bootstrap?.utilAPI?.sendTextMessage) {
                embeddedservice_bootstrap.utilAPI.sendTextMessage(cue)
                    .then(() => console.log('Profile cue sent (utilAPI):', cue))
                    .catch((e) => console.error('utilAPI.sendTextMessage error:', e));
                return;
            }
            if (typeof embeddedservice_configuration !== 'undefined'
                && embeddedservice_configuration?.util?.sendTextMessage) {
                embeddedservice_configuration.util.sendTextMessage(cue)
                    .then(() => console.log('Profile cue sent (configuration.util):', cue))
                    .catch((e) => console.error('configuration.util.sendTextMessage error:', e));
                return;
            }
            console.warn('No sendTextMessage API available; would have sent:', cue);
        } catch (e) {
            console.error('SkywaveProfileFormRenderer cue error:', e);
        }
    }
}
