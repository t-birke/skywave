import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { subscribe, onError } from 'lightning/empApi';
import QRCodeJS from '@salesforce/resourceUrl/QRCodeJS';
import getActiveDemoSession from '@salesforce/apex/Skywave_DemoMonitorController.getActiveDemoSession';

const CONSUMER_SITE_URL = 'https://skywave-app-bb0e8666933b.herokuapp.com/';
const STATE_CHANNEL = '/event/Demo_State_Change__e';

export default class SkywaveDemoMonitor extends LightningElement {
    @track currentState = 'idle';
    @track demoSessionName = null;
    @track activeCount = 0;

    qrCodeVisible = true;
    qrCodeGenerated = false;
    qrcodeClass = 'qrcode';
    _qrLibLoaded = false;
    _stateSubscription = null;

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

    disconnectedCallback() {
        // empApi subscription auto-cleans on component destroy in v55+, but we
        // guard against accidental leaks during HMR / tab switches.
        this._stateSubscription = null;
    }

    async loadActiveSession() {
        try {
            const data = await getActiveDemoSession();
            if (data) {
                this.demoSessionName = data.name;
                this.currentState = data.state || 'idle';
                this.activeCount = data.contactCount || 0;
            } else {
                this.demoSessionName = null;
            }
        } catch (e) {
            console.error('getActiveDemoSession failed', e);
        }
    }

    subscribeStateChanges() {
        const callback = (msg) => {
            const payload = msg?.data?.payload || {};
            this.currentState = payload.New_State__c || this.currentState;
        };
        subscribe(STATE_CHANNEL, -1, callback).then((sub) => {
            this._stateSubscription = sub;
        });
        onError((err) => console.error('empApi error', err));
    }

    renderQRCode() {
        if (!this._qrLibLoaded) return;
        const container = this.template.querySelector('.qrcodecontainer');
        if (!container) {
            // Render hasn't placed the element yet; try again next tick.
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
}
