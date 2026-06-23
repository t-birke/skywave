import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import listMySessions from '@salesforce/apex/Skywave_DemoMonitorController.listMySessions';
import createSession from '@salesforce/apex/Skywave_DemoMonitorController.createSession';
import setActive from '@salesforce/apex/Skywave_DemoMonitorController.setActive';

/**
 * Demo Home — the presenter's per-user landing surface.
 *
 * Multi-tenancy lives here: a presenter creates their own Demo_Session__c
 * (owned by them via standard OwnerId) and selects exactly ONE as active.
 * The list is owner-scoped server-side, and the unique Active_Owner_Key__c
 * guarantees a single active session per presenter. The Preflight checklist
 * is embedded below so the presenter sets up and verifies in one place.
 */
export default class SkywaveDemoHome extends LightningElement {
    @track sessions = [];
    @track activeId = null;
    @track loading = true;
    @track busy = false;
    newCustomer = '';

    connectedCallback() {
        this.refresh();
    }

    async refresh() {
        this.loading = true;
        try {
            const list = await listMySessions();
            this.sessions = (list || []).map((s) => ({
                ...s,
                rowClass: s.active
                    ? 'slds-box slds-box_x-small slds-m-bottom_x-small slds-theme_shade'
                    : 'slds-box slds-box_x-small slds-m-bottom_x-small',
                stateLabel: s.state || 'idle',
                activateDisabled: s.active === true,
                activateLabel: s.active ? 'Active' : 'Make active',
                activateVariant: s.active ? 'success' : 'neutral'
            }));
            const activeRow = this.sessions.find((s) => s.active);
            this.activeId = activeRow ? activeRow.id : null;
        } catch (e) {
            this.toastError(e);
        }
        this.loading = false;
    }

    get hasSessions() {
        return this.sessions && this.sessions.length > 0;
    }

    get hasActive() {
        return !!this.activeId;
    }

    handleCustomerChange(event) {
        this.newCustomer = event.target.value;
    }

    async handleCreate() {
        this.busy = true;
        try {
            await createSession({ customer: this.newCustomer, activateNow: true });
            this.newCustomer = '';
            await this.refresh();
            this.toast('Session created', 'Your new demo session is now active.', 'success');
        } catch (e) {
            this.toastError(e);
        }
        this.busy = false;
    }

    async handleActivate(event) {
        const id = event.currentTarget.dataset.id;
        if (!id || id === this.activeId) return;
        this.busy = true;
        try {
            await setActive({ sessionId: id });
            await this.refresh();
            this.toast('Activated', 'This session is now your active demo.', 'success');
        } catch (e) {
            this.toastError(e);
        }
        this.busy = false;
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    toastError(e) {
        const message = (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
        this.toast('Error', message, 'error');
    }
}
