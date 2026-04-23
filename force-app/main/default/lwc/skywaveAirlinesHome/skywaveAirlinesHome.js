import { LightningElement } from 'lwc';

// Populated by finalize.sh after the MIAW Embedded Service Deployment is
// created through the Setup wizard. Values are deterministic once that exists;
// baking them into the source avoids a guest-user Apex round-trip on every
// page load and makes the widget bootstrap nearly instant.
//
// Before finalize.sh runs these stay as placeholder tokens and the widget
// bootstrap is skipped gracefully.
const EMBEDDED_MESSAGING_CONFIG = {
    orgId: '__ESW_ORG_ID__',
    // Developer name of the EmbeddedServiceConfig deployment (NOT the
    // MessagingChannel). This is the esConfigName scrt2 expects.
    esConfigName: '__ESW_ESC_NAME__',
    siteUrl: '__ESW_SITE_URL__',
    scrt2Url: '__ESW_SCRT2_URL__'
};

export default class SkywaveAirlinesHome extends LightningElement {
    static renderMode = 'light';

    mobileView = false;
    mobileDrawerOpen = false;
    callActive = false;
    callStatus = 'calling...';
    clockText = '9:41';

    _forceViewMode = null;
    _callTimer = null;
    _callSecs = 0;
    _clockTimer = null;
    _messagingBootstrapped = false;
    _resizeHandler = null;

    get rootClass() {
        return this.mobileView ? 'host-root host-mobile-view' : 'host-root';
    }

    get mobileDrawerClass() {
        return this.mobileDrawerOpen ? 'mobile-nav-drawer open' : 'mobile-nav-drawer';
    }

    get callUIClass() {
        return this.callActive ? 'iphone-call-ui call-active' : 'iphone-call-ui';
    }

    connectedCallback() {
        this._resizeHandler = this.handleResize.bind(this);
        window.addEventListener('resize', this._resizeHandler);
        this.autoDetectView();
        this.startClock();
        this.bootstrapEmbeddedMessaging();
    }

    disconnectedCallback() {
        if (this._resizeHandler) window.removeEventListener('resize', this._resizeHandler);
        if (this._callTimer) clearInterval(this._callTimer);
        if (this._clockTimer) clearInterval(this._clockTimer);
    }

    setView(mobile) {
        this.mobileView = mobile;
        if (!mobile) this.mobileDrawerOpen = false;
    }

    autoDetectView() {
        if (this._forceViewMode === null) this.setView(window.innerWidth < 769);
    }

    handleResize() {
        if (this._forceViewMode === 'desktop' && window.innerWidth < 481) {
            this._forceViewMode = null;
        }
        this.autoDetectView();
    }

    handleViewToggle = () => {
        this._forceViewMode = this.mobileView ? 'desktop' : 'mobile';
        this.setView(!this.mobileView);
    };

    handleHamburger = () => {
        this.mobileDrawerOpen = !this.mobileDrawerOpen;
    };

    fmtTime(t) {
        const m = Math.floor(t / 60);
        const s = t % 60;
        return m + ':' + (s < 10 ? '0' + s : s);
    }

    handleCallOpen = () => {
        if (!this.mobileView) return;
        this.callActive = true;
        this.callStatus = 'calling...';
        this._callSecs = 0;
        setTimeout(() => {
            this.callStatus = this.fmtTime(0);
            this._callTimer = setInterval(() => {
                this._callSecs += 1;
                this.callStatus = this.fmtTime(this._callSecs);
            }, 1000);
        }, 2200);
    };

    handleCallEnd = () => {
        this.callActive = false;
        if (this._callTimer) {
            clearInterval(this._callTimer);
            this._callTimer = null;
        }
        this._callSecs = 0;
        this.callStatus = 'calling...';
        this.template.querySelectorAll('.c-btn.on').forEach((b) => b.classList.remove('on'));
    };

    handleCallCtrl = (event) => {
        event.currentTarget.classList.toggle('on');
    };

    handleCallRealPhone = (event) => {
        event.currentTarget.classList.add('on');
        window.location.href = 'tel:+16466533908';
    };

    startClock() {
        const update = () => {
            const d = new Date();
            const h = d.getHours();
            const m = d.getMinutes();
            this.clockText = h + ':' + (m < 10 ? '0' + m : m);
        };
        update();
        this._clockTimer = setInterval(update, 30000);
    }

    bootstrapEmbeddedMessaging() {
        if (this._messagingBootstrapped) return;
        const { orgId, esConfigName, siteUrl, scrt2Url } = EMBEDDED_MESSAGING_CONFIG;
        // If finalize.sh hasn't run yet, the tokens are still placeholders —
        // skip bootstrap rather than firing bogus network calls.
        if (orgId.startsWith('__') || esConfigName.startsWith('__') || siteUrl.startsWith('__') || scrt2Url.startsWith('__')) {
            return;
        }
        this._messagingBootstrapped = true;
        const script = document.createElement('script');
        script.src = siteUrl + '/assets/js/bootstrap.min.js';
        script.onload = () => {
            try {
                // eslint-disable-next-line no-undef
                embeddedservice_bootstrap.settings.language = 'en_US';
                // eslint-disable-next-line no-undef
                embeddedservice_bootstrap.init(orgId, esConfigName, siteUrl, { scrt2URL: scrt2Url });
            } catch (err) {
                // eslint-disable-next-line no-console
                console.error('Error loading Embedded Messaging: ', err);
            }
        };
        document.head.appendChild(script);
    }
}
