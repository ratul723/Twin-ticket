import { LightningElement } from 'lwc';
import basePath from '@salesforce/community/basePath';
import getMyPurchases from '@salesforce/apex/PortalPurchaseController.getMyPurchases';

const STATUS = {
    Paid: { chip: 'chip chip--ok', card: 'card card--ok' },
    Pending: { chip: 'chip chip--pending', card: 'card card--pending' },
    Failed: { chip: 'chip chip--bad', card: 'card card--bad' },
    Cancelled: { chip: 'chip chip--warn', card: 'card card--warn' },
    'Awaiting Payment': { chip: 'chip', card: 'card' }
};

export default class TwinPortalPurchases extends LightningElement {
    isLoading = true;
    errorMessage;
    notCustomer = false;
    rows = [];

    async connectedCallback() {
        try {
            const res = await getMyPurchases();
            if (!res.isCustomer) {
                this.notCustomer = true;
            } else {
                const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: res.currencyCode || 'USD' });
                this.rows = res.items.map((p) => {
                    const s = STATUS[p.statusCode] || STATUS['Awaiting Payment'];
                    return {
                        ...p,
                        chipClass: s.chip,
                        cardClass: s.card,
                        unitPriceLabel: p.unitPrice == null ? '' : money.format(p.unitPrice),
                        totalLabel: p.total == null ? '' : money.format(p.total),
                        whenLabel: this.format(p.eventStart, p.timeZone),
                        paidLabel: p.paidOn ? this.format(p.paidOn) : ''
                    };
                });
            }
        } catch (e) {
            this.errorMessage = 'We could not load your purchases right now. Please try again in a few minutes.';
        } finally {
            this.isLoading = false;
        }
    }

    get isEmpty() { return this.rows.length === 0; }

    format(value, timeZone) {
        if (!value) { return ''; }
        const options = { dateStyle: 'medium', timeStyle: 'short' };
        try {
            return new Intl.DateTimeFormat('en-GB', { ...options, timeZone: timeZone || undefined }).format(new Date(value));
        } catch (e) {
            return new Intl.DateTimeFormat('en-GB', options).format(new Date(value));
        }
    }

    handleDownload(event) {
        // The Visualforce page lives at the site root, not under /s. The page itself re-checks that you own a PAID purchase.
        const root = basePath.replace(/\/s$/, '');
        window.open(`${root}/apex/TwinTicketConfirmation?id=${encodeURIComponent(event.currentTarget.dataset.id)}`, '_blank', 'noopener');
    }
}