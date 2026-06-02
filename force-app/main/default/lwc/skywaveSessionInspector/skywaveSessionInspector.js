import { LightningElement, track } from 'lwc';
import getSessionGraph from '@salesforce/apex/Skywave_SessionInspectorController.getSessionGraph';

export default class SkywaveSessionInspector extends LightningElement {
    @track sessionId = '';
    @track groups = [];
    @track loading = false;
    @track searched = false;
    @track found = false;
    @track errorMsg = '';

    handleIdChange(event) {
        this.sessionId = event.target.value;
    }

    handleKeyup(event) {
        if (event.key === 'Enter') {
            this.handleInspect();
        }
    }

    async handleInspect() {
        const id = (this.sessionId || '').trim();
        if (!id) {
            this.errorMsg = 'Enter a session id first.';
            return;
        }
        this.loading = true;
        this.errorMsg = '';
        this.searched = true;
        try {
            const graph = await getSessionGraph({ sessionId: id });
            this.found = graph.found;
            // Shape each group for the template: build row objects whose
            // cells carry the field label + value, so the table is generic.
            this.groups = (graph.groups || []).map((g) => {
                const rows = (g.records || []).map((rec, idx) => {
                    const cells = g.fields.map((f, i) => ({
                        key: f,
                        label: g.fieldLabels[i],
                        value: rec[f]
                    }));
                    return { key: rec.Id || `${g.objectApiName}-${idx}`, cells };
                });
                return {
                    key: g.objectApiName,
                    objectApiName: g.objectApiName,
                    label: g.label,
                    recordCount: g.recordCount,
                    isEmpty: g.recordCount === 0,
                    rows
                };
            });
        } catch (e) {
            this.errorMsg =
                (e && e.body && e.body.message) || 'Failed to load session graph.';
            this.groups = [];
            this.found = false;
        } finally {
            this.loading = false;
        }
    }

    get hasResults() {
        return this.searched && !this.loading && this.groups.length > 0;
    }

    get notFound() {
        return this.searched && !this.loading && !this.found && !this.errorMsg;
    }
}
