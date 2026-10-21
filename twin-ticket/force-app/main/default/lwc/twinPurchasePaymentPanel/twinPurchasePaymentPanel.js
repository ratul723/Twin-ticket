import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getOverview from '@salesforce/apex/PurchasePaymentController.getOverview';
import sendPaymentLink from '@salesforce/apex/PurchasePaymentController.sendPaymentLink';
import reverifyPayment from '@salesforce/apex/PurchasePaymentController.reverifyPayment';
import requestPortalAccess from '@salesforce/apex/PurchasePaymentController.requestPortalAccess';
import sendPasswordReset from '@salesforce/apex/PurchasePaymentController.sendPasswordReset';

const STATUS_CLASS = {
    Paid: 'chip chip--ok', Completed: 'chip chip--ok', Pending: 'chip chip--pending', Created: 'chip chip--pending',
    'Awaiting Payment': 'chip', Failed: 'chip chip--bad', Cancelled: 'chip chip--warn'
};

export default class TwinPurchasePaymentPanel extends LightningElement {
    @api recordId;
    o;
    loadError;
    isWorking = false;
    actionMessage;
    manualLink;
    _wired;

    @wire(getOverview, { recordId: '$recordId' })
    wiredOverview(result) {
        this._wired = result;
        if (result.data) {
            this.o = result.data;
            this.loadError = undefined;
        } else if (result.error) {
            this.o = undefined;
            this.loadError = (result.error.body && result.error.body.message) || 'The payment details could not be loaded.';
        }
    }

    get amountLabel() { return this.o.amount == null ? '' : new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(this.o.amount); }
    get statusClass() { return STATUS_CLASS[this.o.paymentStatus] || 'chip'; }
    get paidLabel() { return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(this.o.paidOn)); }
    get showLink() { return !!this.manualLink; }
    get actionsDisabled() { return this.isWorking || this.o.paymentStatus === 'Paid'; }
    get sendLabel() { return this.o.attempts.length || this.o.paymentStatus !== 'Awaiting Payment' ? 'Resend payment link' : 'Send payment link'; }
    get hasAttempts() { return this.o.attempts && this.o.attempts.length > 0; }
    get rows() {
        return this.o.attempts.map((a) => ({
            ...a,
            statusClass: STATUS_CLASS[a.status] || 'chip',
            amountLabel: a.amount == null ? '' : new Intl.NumberFormat('en-US', { style: 'currency', currency: a.currencyCode || 'USD' }).format(a.amount),
            createdLabel: new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(a.createdOn))
        }));
    }
    get portalText() {
        switch (this.o.portalAccess) {
            case 'ACTIVE': return `Portal access is active. Username: ${this.o.portalUsername || 'hidden'}`;
            case 'INACTIVE': return 'A portal user exists but is inactive.';
            case 'NONE': return 'The purchase is paid but no portal user exists yet.';
            default: return 'Portal access is created automatically after verified payment.';
        }
    }
    get showProvision() { return this.o.canManage && this.o.portalAccess === 'NONE'; }
    get showReset() { return this.o.canManage && this.o.portalAccess === 'ACTIVE'; }

    async handleProvision() {
        await this.run(async () => {
            const r = await requestPortalAccess({ recordId: this.recordId });
            this.actionMessage = r.message;
            this.toast('Portal access', r.message, r.outcome === 'OK' ? 'success' : 'error');
        });
    }

    async handleReset() {
        await this.run(async () => {
            const r = await sendPasswordReset({ recordId: this.recordId });
            this.actionMessage = r.message;
            this.toast('Password email', r.message, r.outcome === 'OK' ? 'success' : 'error');
        });
    }

    handlePreview() {
        window.open(`/apex/TwinTicketConfirmation?id=${encodeURIComponent(this.recordId)}`, '_blank', 'noopener');
    }

    async handleSend() {
        await this.run(async () => {
            const r = await sendPaymentLink({ recordId: this.recordId });
            this.manualLink = r.success && !r.emailSent ? r.link : undefined;
            this.actionMessage = r.message;
            this.toast(r.success ? (r.emailSent ? 'Link sent' : 'Link created') : 'Not sent', r.message, r.success && r.emailSent ? 'success' : 'warning');
        });
    }

    async handleReverify() {
        await this.run(async () => {
            const r = await reverifyPayment({ recordId: this.recordId });
            this.actionMessage = r.message;
            this.toast('Payment check', r.message, r.outcome === 'PAID' ? 'success' : r.outcome === 'ERROR' ? 'error' : 'info');
        });
    }

    async run(work) {
        this.isWorking = true;
        this.actionMessage = undefined;
        try {
            await work();
            await refreshApex(this._wired);
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } catch (e) {
            this.toast('Something went wrong', 'Please try again or contact an administrator.', 'error');
        } finally {
            this.isWorking = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}