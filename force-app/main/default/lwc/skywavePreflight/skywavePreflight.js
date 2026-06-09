import { LightningElement, track } from 'lwc';
import runPreflight from '@salesforce/apex/Skywave_PreflightController.runPreflight';

// Order in which group sections are rendered. Anything not in this list
// falls through to the end in arrival order.
const GROUP_ORDER = ['org', 'agent', 'relay', 'e2e', 'platform', 'manual'];

// All known check ids the controller may emit, so a row can be shown in a
// "pending / running / not-yet-run" state even before runPreflight returns
// — the user sees the full list immediately, with each row resolving live.
const KNOWN_ROWS = [
    { id: 'org.activeSession',     groupKey: 'org',      groupLabel: 'Org Data',             label: 'Active Demo_Session present' },
    { id: 'org.sessionReset',      groupKey: 'org',      groupLabel: 'Org Data',             label: 'Active session reset to stage 1 (idle)' },
    { id: 'org.surveyQuestions',   groupKey: 'org',      groupLabel: 'Org Data',             label: 'Survey questions seeded' },
    { id: 'org.airlineData',       groupKey: 'org',      groupLabel: 'Org Data',             label: 'Airline data seeded (flights, seat maps, bookings)' },
    { id: 'agent.botUser',         groupKey: 'agent',    groupLabel: 'Agent & Chat',         label: 'Bot user has Skywave_Agent_User permset' },
    { id: 'agent.published',       groupKey: 'agent',    groupLabel: 'Agent & Chat',         label: 'Skywave_Airlines_Agent published & active' },
    { id: 'relay.reach',           groupKey: 'relay',    groupLabel: 'Heroku Relay',         label: 'Heroku /api/preflight reachable' },
    { id: 'relay.pubsub',          groupKey: 'relay',    groupLabel: 'Heroku Relay',         label: 'Pub/Sub subscriber connected to Demo_State_Change__e' },
    { id: 'relay.dynoUptime',      groupKey: 'relay',    groupLabel: 'Heroku Relay',         label: 'Dyno not approaching daily cycle' },
    { id: 'relay.configPresent',   groupKey: 'relay',    groupLabel: 'Heroku Relay',         label: 'Heroku ESW_* and SDK URL all set' },
    { id: 'e2e.loopback',          groupKey: 'e2e',      groupLabel: 'End-to-End Roundtrip', label: 'Loopback push delivered on dyno' },
    { id: 'platform.incidents',    groupKey: 'platform', groupLabel: 'Platform / Outage',    label: 'No active Heroku incidents' },
    { id: 'platform.maintenance',  groupKey: 'platform', groupLabel: 'Platform / Outage',    label: 'No upcoming Heroku maintenance' },
    { id: 'manual.esdRepublish',   groupKey: 'manual',   groupLabel: 'Manual Confirmation',  label: 'ESD republished after last agent publish/activate', manual: true },
    { id: 'manual.cltRender',      groupKey: 'manual',   groupLabel: 'Manual Confirmation',  label: 'CLT card visually renders in chat preview', manual: true }
];

export default class SkywavePreflight extends LightningElement {
    @track rows = [];
    @track running = false;
    @track lastRunAt = null;
    manualChecked = {};  // { id: true } — client-side only, resets on reload

    connectedCallback() {
        this.rows = KNOWN_ROWS.map((r) => ({ ...r, status: 'idle', detail: '' }));
    }

    async handleCheck() {
        if (this.running) return;
        this.running = true;
        this.rows = this.rows.map((r) => ({
            ...r,
            status: r.manual ? 'manual' : 'running',
            detail: r.manual ? r.detail : 'running…'
        }));

        try {
            const results = await runPreflight();
            const byId = new Map(results.map((r) => [r.id, r]));
            this.rows = this.rows.map((r) => {
                const got = byId.get(r.id);
                if (!got) {
                    return { ...r, status: r.manual ? 'manual' : 'fail', detail: r.manual ? r.detail : 'no result returned' };
                }
                return {
                    ...r,
                    status: got.status,
                    detail: got.detail || ''
                };
            });
            this.lastRunAt = new Date().toLocaleTimeString();
        } catch (e) {
            const msg = (e && e.body && e.body.message) || (e && e.message) || String(e);
            this.rows = this.rows.map((r) => ({
                ...r,
                status: r.manual ? 'manual' : 'fail',
                detail: r.manual ? r.detail : 'runPreflight failed: ' + msg
            }));
        } finally {
            this.running = false;
        }
    }

    handleManualToggle(event) {
        const id = event.currentTarget.dataset.id;
        this.manualChecked = { ...this.manualChecked, [id]: !this.manualChecked[id] };
    }

    // ---------- view shape ----------

    get groups() {
        const buckets = new Map();
        for (const r of this.rows) {
            if (!buckets.has(r.groupKey)) {
                buckets.set(r.groupKey, { key: r.groupKey, label: r.groupLabel, rows: [] });
            }
            buckets.get(r.groupKey).rows.push(this.shapeRow(r));
        }
        const ordered = [];
        for (const k of GROUP_ORDER) if (buckets.has(k)) ordered.push(buckets.get(k));
        for (const [k, v] of buckets) if (!GROUP_ORDER.includes(k)) ordered.push(v);
        return ordered.map((g) => ({
            ...g,
            summary: this.groupSummary(g.rows)
        }));
    }

    shapeRow(r) {
        const manualDone = r.manual && this.manualChecked[r.id];
        // For manual rows: unchecked → dash icon; checked → green success.
        let effectiveStatus;
        if (r.manual) {
            effectiveStatus = manualDone ? 'pass' : 'manual';
        } else {
            effectiveStatus = r.status;
        }
        return {
            ...r,
            effectiveStatus,
            cssClass: 'pf-row pf-row--' + effectiveStatus,
            iconName: ICON_BY_STATUS[effectiveStatus] || 'utility:dash',
            iconVariant: ICON_VARIANT[effectiveStatus] || '',
            isRunning: effectiveStatus === 'running',
            manualButtonClass: 'pf-manual-toggle' + (manualDone ? ' pf-manual-toggle--checked' : '')
        };
    }

    groupSummary(rows) {
        const total = rows.length;
        const green = rows.filter((r) => r.effectiveStatus === 'pass').length;
        return green + '/' + total + ' green';
    }

    get summary() {
        const all = this.rows.map((r) => this.shapeRow(r));
        const total = all.length;
        const green = all.filter((r) => r.effectiveStatus === 'pass').length;
        const fails = all.filter((r) => r.effectiveStatus === 'fail').length;
        const warns = all.filter((r) => r.effectiveStatus === 'warn').length;
        const pending = all.filter((r) => r.effectiveStatus === 'idle' || r.effectiveStatus === 'running' || (r.manual && r.effectiveStatus === 'manual')).length;
        return { total, green, fails, warns, pending };
    }

    get summaryLabel() {
        const s = this.summary;
        if (this.running) return `Running ${s.total} checks…`;
        if (s.fails > 0) return `${s.fails} failing — do not start the demo until resolved`;
        if (s.warns > 0) return `${s.green}/${s.total} green, ${s.warns} warning(s)`;
        if (s.pending > 0) return `${s.green}/${s.total} green, ${s.pending} pending`;
        return `All ${s.total} checks green — go for demo`;
    }

    get summaryClass() {
        const s = this.summary;
        if (this.running) return 'pf-summary pf-summary--running';
        if (s.fails > 0) return 'pf-summary pf-summary--fail';
        if (s.warns > 0) return 'pf-summary pf-summary--warn';
        if (s.pending > 0) return 'pf-summary pf-summary--pending';
        return 'pf-summary pf-summary--pass';
    }

    get buttonLabel() {
        return this.running ? 'Checking…' : 'Check Demo';
    }
    get buttonDisabled() {
        return this.running;
    }
    get lastRunLabel() {
        return this.lastRunAt ? `Last run ${this.lastRunAt}` : '';
    }
}

const ICON_BY_STATUS = {
    pass:    'utility:success',
    fail:    'utility:error',
    warn:    'utility:warning',
    manual:  'utility:adjust_value',
    running: 'utility:spinner',
    idle:    'utility:dash'
};
const ICON_VARIANT = {
    pass:    'success',
    fail:    'error',
    warn:    'warning',
    manual:  '',
    running: '',
    idle:    ''
};
