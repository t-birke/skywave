import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { subscribe, onError } from 'lightning/empApi';
import QRCodeJS from '@salesforce/resourceUrl/QRCodeJS';
import getActiveDemoSession from '@salesforce/apex/Skywave_DemoMonitorController.getActiveDemoSession';
import setActive from '@salesforce/apex/Skywave_DemoMonitorController.setActive';
import advanceState from '@salesforce/apex/Skywave_DemoMonitorController.advanceState';
import searchSessions from '@salesforce/apex/Skywave_DemoMonitorController.searchSessions';

const CONSUMER_SITE_URL = 'https://skywave-app-bb0e8666933b.herokuapp.com/';
const STATE_CHANNEL = '/event/Demo_State_Change__e';

const STAGES = [
    { value: 'idle', label: 'Idle' },
    { value: 'scan', label: 'Scan' },
    { value: 'survey', label: 'Survey' },
    { value: 'agent_book', label: 'Agent: Book' },
    { value: 'profile', label: 'Profile' },
    { value: 'c360', label: 'C360' },
    { value: 'agent_seat_fail', label: 'Seat (Fail)' },
    { value: 'agent_seat_pass', label: 'Seat (Pass)' },
    { value: 'race', label: 'Race' },
    { value: 'slack', label: 'Slack' },
    { value: 'done', label: 'Done' }
];

const STAGE_LABELS = Object.fromEntries(STAGES.map(s => [s.value, s.label]));

export default class SkywaveDemoMonitor extends LightningElement {
    @track activeId = null;
    @track name = null;
    @track customer = null;
    @track demoDate = null;
    @track currentState = 'idle';
    @track activeCount = 0;

    qrCodeVisible = true;
    qrCodeGenerated = false;
    qrcodeClass = 'qrcode';
    _qrLibLoaded = false;

    @track showSettings = false;

    @track pickerOpen = false;
    @track pickerOptions = [];
    @track pickerInputValue = '';
    _pickerTypeTimer = null;

    toggleSettings() {
        this.showSettings = !this.showSettings;
    }

    get pickerEmpty() { return this.pickerOpen && this.pickerOptions.length === 0; }

    get hasActive() { return !!this.activeId; }

    get currentStateLabel() {
        return STAGE_LABELS[this.currentState] || this.currentState;
    }

    get stageButtons() {
        return STAGES.map(s => ({
            ...s,
            variant: s.value === this.currentState ? 'brand' : 'neutral'
        }));
    }

    async connectedCallback() {
        try {
            await loadScript(this, QRCodeJS);
            this._qrLibLoaded = true;
            this.renderQRCode();
        } catch (e) {
            console.error('QRCodeJS load failed', e);
        }

        await this.loadActiveSession();
        this.subscribeStateChanges();
    }

    async loadActiveSession() {
        try {
            const data = await getActiveDemoSession();
            this.applySession(data);
        } catch (e) {
            console.error('getActiveDemoSession failed', e);
        }
    }

    applySession(data) {
        if (data) {
            this.activeId = data.id;
            this.name = data.name;
            this.customer = data.customer;
            this.demoDate = data.demoDate;
            this.currentState = data.state || 'idle';
            this.activeCount = data.contactCount || 0;
            this.pickerInputValue = data.customer || data.name || '';
        } else {
            this.activeId = null;
            this.name = null;
            this.customer = null;
            this.demoDate = null;
            this.currentState = 'idle';
            this.activeCount = 0;
            this.pickerInputValue = '';
        }
    }

    async openPicker() {
        this.pickerOpen = true;
        await this.refreshPickerOptions('');
    }

    closePickerSoon() {
        // Delay so the mousedown on a list item fires first.
        setTimeout(() => { this.pickerOpen = false; }, 150);
    }

    handlePickerType(event) {
        const term = event.target.value;
        this.pickerInputValue = term;
        clearTimeout(this._pickerTypeTimer);
        this._pickerTypeTimer = setTimeout(() => this.refreshPickerOptions(term), 150);
    }

    async refreshPickerOptions(term) {
        try {
            this.pickerOptions = await searchSessions({ term: term || '' });
        } catch (e) {
            console.error('searchSessions failed', e);
            this.pickerOptions = [];
        }
    }

    async handlePickerSelect(event) {
        const newId = event.currentTarget.dataset.id;
        this.pickerOpen = false;
        if (!newId || newId === this.activeId) return;
        try {
            const data = await setActive({ sessionId: newId });
            this.applySession(data);
        } catch (e) {
            console.error('setActive failed', e);
        }
    }

    subscribeStateChanges() {
        const callback = (msg) => {
            const payload = msg?.data?.payload || {};
            // Filter to the active demo session so monitor isn't disturbed
            // by historical replays from other sessions.
            if (payload.Demo_Session_Id__c && payload.Demo_Session_Id__c !== this.activeId) return;
            this.currentState = payload.New_State__c || this.currentState;
        };
        subscribe(STATE_CHANNEL, -1, callback).catch((e) => console.error('subscribe failed', e));
        onError((err) => console.error('empApi error', err));
    }

    renderQRCode() {
        if (!this._qrLibLoaded) return;
        const container = this.template.querySelector('.qrcodecontainer');
        if (!container) {
            setTimeout(() => this.renderQRCode(), 100);
            return;
        }
        container.innerHTML = '';
        // eslint-disable-next-line no-undef, new-cap
        new QRCode(container, {
            text: CONSUMER_SITE_URL,
            width: 512,
            height: 512,
            colorDark: '#0b1d3a',
            colorLight: '#ffffff',
            // eslint-disable-next-line no-undef
            correctLevel: QRCode.CorrectLevel.H
        });
        this.qrCodeGenerated = true;
    }

    toggleQrCodeVisibility() {
        this.qrCodeVisible = !this.qrCodeVisible;
        if (this.qrCodeVisible) {
            this.qrCodeGenerated = false;
            setTimeout(() => this.renderQRCode(), 100);
        }
    }

    toggleenlarge() {
        this.qrcodeClass = this.qrcodeClass === 'qrcode' ? 'qrcode enlarged' : 'qrcode';
    }

    async handleStageClick(event) {
        const newState = event.target.dataset.state;
        if (!newState || newState === this.currentState || !this.activeId) return;
        // Optimistic — Pub/Sub catch-up will reconcile.
        this.currentState = newState;
        try {
            await advanceState({ sessionId: this.activeId, newState });
        } catch (e) {
            console.error('advanceState failed', e);
            this.loadActiveSession();
        }
    }
}
