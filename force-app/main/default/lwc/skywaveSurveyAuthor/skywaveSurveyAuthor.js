import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import listQuestions from '@salesforce/apex/Skywave_SurveyAuthorController.listQuestions';
import saveQuestion from '@salesforce/apex/Skywave_SurveyAuthorController.saveQuestion';
import deleteQuestion from '@salesforce/apex/Skywave_SurveyAuthorController.deleteQuestion';
import reorderQuestions from '@salesforce/apex/Skywave_SurveyAuthorController.reorderQuestions';

const TYPE_OPTIONS = [
    { label: 'Single Choice', value: 'single_choice' },
    { label: 'Multi Choice', value: 'multi_choice' }
];

let localIdCounter = 0;
const newLocalId = () => `local-${++localIdCounter}`;

export default class SkywaveSurveyAuthor extends LightningElement {
    @track questions = [];
    @track selected = null;
    @track dirty = false;
    @track saving = false;

    typeOptions = TYPE_OPTIONS;

    get hasNoQuestions() { return this.questions.length === 0; }
    get selectedHasNoOptions() { return this.selected && this.selected.options.length === 0; }

    connectedCallback() {
        this.refresh();
    }

    async refresh(keepSelectedId) {
        try {
            const data = await listQuestions();
            this.questions = data.map((q, i) => this.decorateQuestion(q, i, data.length));
            const target = keepSelectedId
                ? this.questions.find(q => q.id === keepSelectedId)
                : (this.selected ? this.questions.find(q => q.id === this.selected.id) : null);
            this.selected = target ? this.adoptForEdit(target) : null;
            this.dirty = false;
        } catch (e) {
            this.toastError('Load failed', e);
        }
    }

    decorateQuestion(q, idx, total) {
        return {
            ...q,
            isFirst: idx === 0,
            isLast: idx === total - 1,
            rowClass: this.questionRowClass(q)
        };
    }

    questionRowClass(q) {
        const parts = [];
        if (this.selected && this.selected.id === q.id) parts.push('selected');
        if (!q.active) parts.push('inactive');
        return parts.join(' ');
    }

    adoptForEdit(q) {
        const options = (q.options || []).map((o, i, arr) => ({
            ...o,
            localId: o.id || newLocalId(),
            isFirst: i === 0,
            isLast: i === arr.length - 1
        }));
        return { ...q, options };
    }

    refreshSelectedDecorations() {
        if (!this.selected) return;
        this.selected.options = this.selected.options.map((o, i, arr) => ({
            ...o,
            isFirst: i === 0,
            isLast: i === arr.length - 1
        }));
        this.questions = this.questions.map(q => ({
            ...q,
            rowClass: this.questionRowClass(q)
        }));
    }

    handleSelectQuestion(event) {
        const id = event.currentTarget.dataset.id;
        if (this.dirty && !confirm('Discard unsaved changes?')) return;
        const q = this.questions.find(x => x.id === id);
        this.selected = q ? this.adoptForEdit(q) : null;
        this.dirty = false;
        this.refreshSelectedDecorations();
    }

    stopProp(event) { event.stopPropagation(); }

    handleQuestionFieldChange(event) {
        const field = event.target.dataset.field;
        const value = field === 'active' ? event.target.checked : event.target.value;
        this.selected = { ...this.selected, [field]: value };
        this.dirty = true;
    }

    handleAddQuestion() {
        if (this.dirty && !confirm('Discard unsaved changes?')) return;
        const order = (this.questions[this.questions.length - 1]?.order || this.questions.length) + 1;
        this.selected = {
            id: null,
            name: '(new)',
            questionText: '',
            questionKey: '',
            questionType: 'single_choice',
            order,
            active: true,
            options: []
        };
        this.dirty = true;
    }

    async handleDeleteQuestion() {
        if (!this.selected?.id) {
            this.selected = null;
            this.dirty = false;
            return;
        }
        if (!confirm(`Delete "${this.selected.questionText}"? This also deletes its options.`)) return;
        try {
            await deleteQuestion({ questionId: this.selected.id });
            this.selected = null;
            this.dirty = false;
            await this.refresh();
            this.toast('Question deleted', 'success');
        } catch (e) {
            this.toastError('Delete failed', e);
        }
    }

    handleAddOption() {
        const order = (this.selected.options[this.selected.options.length - 1]?.order || this.selected.options.length) + 1;
        const newOpt = {
            id: null,
            localId: newLocalId(),
            name: '(new)',
            optionText: '',
            optionKey: '',
            imageUrl: '',
            order,
            active: true
        };
        this.selected = {
            ...this.selected,
            options: [...this.selected.options, newOpt]
        };
        this.refreshSelectedDecorations();
        this.dirty = true;
    }

    handleOptionFieldChange(event) {
        const localId = event.target.dataset.localid;
        const field = event.target.dataset.field;
        const value = field === 'active' ? event.target.checked : event.target.value;
        this.selected = {
            ...this.selected,
            options: this.selected.options.map(o =>
                o.localId === localId ? { ...o, [field]: value } : o
            )
        };
        this.dirty = true;
    }

    handleOptionDelete(event) {
        const localId = event.currentTarget.dataset.localid;
        this.selected = {
            ...this.selected,
            options: this.selected.options.filter(o => o.localId !== localId)
        };
        this.refreshSelectedDecorations();
        this.dirty = true;
    }

    handleOptionMoveUp(event) { this.swapOption(event.currentTarget.dataset.localid, -1); }
    handleOptionMoveDown(event) { this.swapOption(event.currentTarget.dataset.localid, 1); }

    swapOption(localId, delta) {
        const idx = this.selected.options.findIndex(o => o.localId === localId);
        if (idx < 0) return;
        const target = idx + delta;
        if (target < 0 || target >= this.selected.options.length) return;
        const next = [...this.selected.options];
        [next[idx], next[target]] = [next[target], next[idx]];
        next.forEach((o, i) => { o.order = i + 1; });
        this.selected = { ...this.selected, options: next };
        this.refreshSelectedDecorations();
        this.dirty = true;
    }

    async handleMoveUp(event) { await this.reorderQuestion(event.currentTarget.dataset.id, -1); }
    async handleMoveDown(event) { await this.reorderQuestion(event.currentTarget.dataset.id, 1); }

    async reorderQuestion(qid, delta) {
        const idx = this.questions.findIndex(q => q.id === qid);
        if (idx < 0) return;
        const target = idx + delta;
        if (target < 0 || target >= this.questions.length) return;
        const next = [...this.questions];
        [next[idx], next[target]] = [next[target], next[idx]];
        try {
            await reorderQuestions({ orderedIds: next.map(q => q.id) });
            await this.refresh(this.selected?.id);
            this.toast('Order saved', 'success');
        } catch (e) {
            this.toastError('Reorder failed', e);
        }
    }

    async handleSave() {
        if (!this.selected) return;
        this.saving = true;
        try {
            const payload = {
                id: this.selected.id || null,
                questionText: this.selected.questionText,
                questionKey: this.selected.questionKey,
                questionType: this.selected.questionType,
                order: this.selected.order,
                active: this.selected.active,
                options: this.selected.options.map(o => ({
                    id: (o.id && !String(o.id).startsWith('local-')) ? o.id : null,
                    optionText: o.optionText,
                    optionKey: o.optionKey,
                    imageUrl: o.imageUrl,
                    order: o.order,
                    active: o.active
                }))
            };
            const saved = await saveQuestion({ question: payload });
            await this.refresh(saved?.id);
            this.toast('Saved', 'success');
        } catch (e) {
            this.toastError('Save failed', e);
        } finally {
            this.saving = false;
        }
    }

    toast(title, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, variant }));
    }

    toastError(title, e) {
        const msg = e?.body?.message || e?.message || String(e);
        this.dispatchEvent(new ShowToastEvent({ title, message: msg, variant: 'error' }));
        console.error(title, e);
    }
}
