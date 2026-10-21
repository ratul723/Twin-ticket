import { LightningElement, wire } from 'lwc';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import getContext from '@salesforce/apex/PaymentPageController.getContext';
import startPayment from '@salesforce/apex/PaymentPageController.startPayment';
import verifyPayment from '@salesforce/apex/PaymentPageController.verifyPayment';
import cancelAttempt from '@salesforce/apex/PaymentPageController.cancelAttempt';

const STRIPE_PREFIX = 'https://checkout.stripe.com/';
const GENERIC = 'Something went wrong. Please try again in a few minutes.';

export default class TwinPayPage extends NavigationMixin(LightningElement) {
    ctx;
    view = 'loading';       // loading | invalid | payable | busy | paid | pending | cancelled | review | unavailable
    message;
    errorText;
    busyText = 'Working…';
    _ref; _token; _result; _sid; _started = false;

    @wire(CurrentPageReference)
    setRef(ref) {
        if (!ref || this._started) { return; }
        const s = ref.state || {};
        this._ref = s.c__ref;
        this._token = s.c__t;
        this._result = s.c__r;
        this._sid = s.c__sid;
        this._started = true;
        this.init();
    }

    // ---------- view state ----------
    get isLoading() { return this.view === 'loading'; }
    get isInvalid() { return this.view === 'invalid'; }
    get isBusyView() { return this.view === 'busy'; }
    get isPaid() { return this.view === 'paid'; }
    get isReview() { return this.view === 'review'; }
    get isCancelled() { return this.view === 'cancelled'; }
    get isPending() { return this.view === 'pending'; }
    get isUnavailable() { return this.view === 'unavailable'; }
    get canRecheck() { return this.view === 'pending' && !!this._sid; }
    get payLabel() { return this.view === 'pending' || this.view === 'cancelled' ? 'Continue to payment' : 'Pay securely with Stripe'; }
    get amountLabel() {
        if (!this.ctx || this.ctx.amount == null) { return ''; }
        try {
            return new Intl.NumberFormat('en-US', { style: 'currency', currency: this.ctx.currencyCode || 'USD' }).format(this.ctx.amount);
        } catch (e) {
            return String(this.ctx.amount);
        }
    }
    get whenLabel() {
        return this.ctx && this.ctx.eventStart
            ? new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(this.ctx.eventStart))
            : '';
    }

    // ---------- flow ----------
    async init() {
        try {
            const ctx = await getContext({ reference: this._ref, token: this._token });
            if (!ctx.valid) {
                this.view = 'invalid';
                this.message = ctx.message || GENERIC;
                return;
            }
            this.ctx = ctx;
            // The redirect is only a HINT. Whatever the URL says, the server asks Stripe for the truth.
            if (this._result === 'cancel') {
                await this.runCancel();
            } else if (this._sid) {
                await this.runVerify();
            } else {
                this.view = ctx.state === 'PAID' ? 'paid' : ctx.state === 'UNAVAILABLE' ? 'unavailable' : 'payable';
                this.message = ctx.message;
            }
        } catch (e) {
            this.view = 'invalid';
            this.message = GENERIC;
        }
    }

    async runVerify() {
        this.view = 'busy';
        this.busyText = 'Confirming your payment with Stripe…';
        const r = await verifyPayment({ reference: this._ref, token: this._token, sessionId: this._sid });
        this.applyOutcome(r);
    }

    async runCancel() {
        this.view = 'busy';
        this.busyText = 'Cancelling…';
        const r = await cancelAttempt({ reference: this._ref, token: this._token });
        this.applyOutcome(r);
    }

    applyOutcome(r) {
        this.message = r.message;
        switch (r.outcome) {
            case 'PAID': this.view = 'paid'; break;
            case 'PENDING': this.view = 'pending'; break;
            case 'CANCELLED': this.view = 'cancelled'; break;
            case 'NEEDS_REVIEW':
            case 'DUPLICATE': this.view = 'review'; break;
            default: this.view = 'payable'; this.errorText = r.message || GENERIC;
        }
    }

    async handlePay() {
        this.errorText = undefined;
        const previous = this.view;
        this.view = 'busy';
        this.busyText = 'Preparing your secure payment…';
        try {
            const r = await startPayment({ reference: this._ref, token: this._token });
            if (r.success && r.checkoutUrl && r.checkoutUrl.startsWith(STRIPE_PREFIX)) {
                this.busyText = 'Redirecting to Stripe…';
                this[NavigationMixin.Navigate]({ type: 'standard__webPage', attributes: { url: r.checkoutUrl } });
                return;
            }
            if (r.alreadyPaid) { this.view = 'paid'; return; }
            this.view = previous;
            this.errorText = r.message || GENERIC;
        } catch (e) {
            this.view = previous;
            this.errorText = GENERIC;
        }
    }

    async handleRecheck() {
        try { await this.runVerify(); } catch (e) { this.view = 'pending'; this.errorText = GENERIC; }
    }
}