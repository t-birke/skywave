import { LightningElement, api, track } from 'lwc';
import saveProfile from '@salesforce/apex/Skywave_SaveProfile.saveProfile';

// Pre-resize gate. We always crop+resize to 512x512 JPEG q=0.5 in-browser
// before sending to Apex — that yields ~30-80kB regardless of input. The
// gate here is just a sanity bound on the original file the user picks
// (e.g. reject a 50MB DSLR shot before we try to decode it). Same recipe
// as the Electra Interactive demo (script.js#resizeImage).
const MAX_AVATAR_BYTES = 20 * 1024 * 1024;
const AVATAR_OUTPUT_SIZE = 512;
const AVATAR_OUTPUT_QUALITY = 0.5;

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
            this.errorMessage = 'Avatar file too large.';
            return;
        }
        const reader = new FileReader();
        reader.onload = () => {
            // Decode the image, then crop+resize to 512x512 JPEG before
            // sending to Apex. The original file may be a 4MB+ photo from
            // the camera — base64 of that exceeds Aura request limits and
            // wastes bandwidth besides. Resize matches Electra's recipe
            // (square-center-crop, 512x512, JPEG q=0.5).
            const img = new Image();
            img.onload = () => {
                const resized = this._resizeAvatar(img);
                this.avatarBase64 = resized;
                this.avatarPreview = resized;
                this.avatarFileName = (file.name || 'avatar') + '.jpg';
            };
            img.onerror = () => { this.errorMessage = 'Could not decode image.'; };
            img.src = reader.result;
        };
        reader.onerror = () => {
            this.errorMessage = 'Could not read image.';
        };
        reader.readAsDataURL(file);
    }

    _resizeAvatar(img) {
        const canvas = document.createElement('canvas');
        canvas.width = AVATAR_OUTPUT_SIZE;
        canvas.height = AVATAR_OUTPUT_SIZE;
        const ctx = canvas.getContext('2d');

        // Square center crop, then scale to AVATAR_OUTPUT_SIZE.
        const shortSide = Math.min(img.width, img.height);
        const startX = (img.width - shortSide) / 2;
        const startY = (img.height - shortSide) / 2;
        ctx.drawImage(
            img,
            startX, startY, shortSide, shortSide,
            0, 0, AVATAR_OUTPUT_SIZE, AVATAR_OUTPUT_SIZE
        );
        return canvas.toDataURL('image/jpeg', AVATAR_OUTPUT_QUALITY);
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
