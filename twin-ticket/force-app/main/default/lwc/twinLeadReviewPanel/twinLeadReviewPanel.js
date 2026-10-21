import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import getReviewData from '@salesforce/apex/LeadReviewController.getReviewData';
import submitDecision from '@salesforce/apex/LeadReviewController.submitDecision';

const MONEY = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });
const STATUS_CLASS = {
    Pending: 'chip chip--pending',
    Approved: 'chip chip--ok',
    Rejected: 'chip chip--bad',
    'Additional Information Required': 'chip chip--warn'
};

export default class TwinLeadReviewPanel extends NavigationMixin(LightningElement) {
    @api recordId;
    d;
    loadError;
    isLoading = true;
    decision;
    notes = '';
    buyerMessage = '';
    errorText;
    isSaving = false;
    _wired;

    @wire(getReviewData, { recordId: '$recordId' })
    wiredData(result) {
        this._wired = result;
        const { data, error } = result;
        if (data) {
            this.d = data;
            this.loadError = undefined;
            this.isLoading = false;
        } else if (error) {
            this.d = undefined;
            this.loadError = (error.body && error.body.message) || 'This request could not be loaded.';
            this.isLoading = false;
        }
    }

    get statusClass() { return STATUS_CLASS[this.d.status] || 'chip'; }
    get hasBlockers() { return this.d.blockers && this.d.blockers.length > 0; }
    get hasFiles() { return this.d.files && this.d.files.length > 0; }
    get fileRows() { return this.d.files; }
    get hasActions() { return this.d.actions && this.d.actions.length > 0; }
    get isFinal() { return !this.d.isConverted && this.d.canDecide && !this.hasActions && !this.hasBlockers
        && (this.d.status === 'Approved' || this.d.status === 'Rejected'); }
    get cannotDecide() { return !this.d.canDecide; }
    get unitPriceLabel() { return this.d.unitPrice == null ? 'n/a' : MONEY.format(this.d.unitPrice); }
    get totalLabel() { return this.d.estimatedTotal == null ? 'n/a' : MONEY.format(this.d.estimatedTotal); }
    get eventWhen() {
        return this.d.eventStart
            ? new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(this.d.eventStart)) + ' · ' + (this.d.venue || '')
            : '';
    }
    get actionOptions() { return this.d.actions.map((a) => ({ label: a.label, value: a.value })); }
    get selectedHelp() {
        const a = this.d.actions.find((x) => x.value === this.decision);
        return a ? a.help : '';
    }
    get isRequestInfo() { return this.decision === 'REQUEST_INFO'; }
    get submitDisabled() { return !this.decision || this.isSaving; }
    get submitVariant() { return this.decision === 'REJECT' ? 'destructive' : 'brand'; }
    get submitLabel() {
        const a = this.d.actions.find((x) => x.value === this.decision);
        return this.isSaving ? 'Saving…' : a ? a.label : 'Choose an action';
    }

    handleDecision(e) { this.decision = e.detail.value; this.errorText = undefined; }
    handleNotes(e) { this.notes = e.detail.value; }
    handleMessage(e) { this.buyerMessage = e.detail.value; }

    async handleSubmit() {
        this.errorText = undefined;
        const fields = Array.from(this.template.querySelectorAll('lightning-textarea'));
        if (!fields.reduce((ok, f) => f.reportValidity() && ok, true)) { return; }

        if (this.decision === 'APPROVE' || this.decision === 'REJECT') {
            const approve = this.decision === 'APPROVE';
            const ok = await LightningConfirm.open({
                message: approve
                    ? 'This converts the request into an Account, Contact, Opportunity and purchase. It cannot be undone.'
                    : 'Rejecting is final. The buyer will be emailed.',
                variant: 'header',
                label: approve ? 'Approve and convert?' : 'Reject this request?',
                theme: approve ? 'success' : 'error'
            });
            if (!ok) { return; }
        }

        this.isSaving = true;
        try {
            const res = await submitDecision({
                recordId: this.recordId, decision: this.decision, notes: this.notes, buyerMessage: this.buyerMessage
            });
            if (res.success) {
                this.dispatchEvent(new ShowToastEvent({ title: 'Done', message: res.message, variant: 'success' }));
                this.decision = undefined;
                this.notes = '';
                this.buyerMessage = '';
                await refreshApex(this._wired);
                await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            } else {
                this.errorText = res.message;
            }
        } catch (e) {
            this.errorText = 'Something went wrong. Please try again.';
        } finally {
            this.isSaving = false;
        }
    }

    handlePreview(e) {
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: e.currentTarget.dataset.id }
        });
    }

    handleOpen(e) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: e.currentTarget.dataset.id, objectApiName: e.currentTarget.dataset.object, actionName: 'view' }
        });
    }
}