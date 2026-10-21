import { LightningElement, wire } from 'lwc';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import getEventDetail from '@salesforce/apex/PublicEventController.getEventDetail';
import getFormConfig from '@salesforce/apex/BulkRequestController.getFormConfig';
import submitRequest from '@salesforce/apex/BulkRequestController.submitRequest';
import uploadDocument from '@salesforce/apex/BulkRequestController.uploadDocument';
import completeSubmission from '@salesforce/apex/BulkRequestController.completeSubmission';
import { decorateEvent, formatPrice } from 'c/twinUtils';

const GENERIC_ERROR = 'We could not complete that. Please try again in a few minutes.';

export default class TwinBulkRequestForm extends NavigationMixin(LightningElement) {
    eventId;
    ev;
    cfg;
    loadError;
    phase = 'form';            // form | submitting | partial | success
    banner;
    fileError;
    statusText = '';
    progress = 0;
    copied = false;
    reference;
    form = {};
    files = [];

    _token;                    // one-time upload token: kept in memory only, never in the URL or storage
    _store = new Map();        // id -> File object (kept out of reactive state)
    _seq = 0;

    @wire(CurrentPageReference)
    setPageRef(ref) {
        this.eventId = ref && ref.state ? ref.state.c__eventId : undefined;
        if (ref && !this.eventId) {
            this.loadError = 'No event was selected. Please choose an event first.';
        }
    }

    @wire(getEventDetail, { eventId: '$eventId' })
    wiredEvent({ data, error }) {
        if (data) {
            this.ev = decorateEvent(data);
        } else if (error) {
            this.loadError = 'This event is not available for bulk requests.';
        }
    }

    @wire(getFormConfig)
    wiredConfig({ data, error }) {
        if (data) {
            this.cfg = data;
        } else if (error) {
            this.loadError = GENERIC_ERROR;
        }
    }

    // ---------- view state ----------
    get showForm() { return (this.phase === 'form' || this.phase === 'submitting') && this.ev && this.cfg && !this.loadError; }
    get isBusy() { return this.phase === 'submitting'; }
    get isPartial() { return this.phase === 'partial'; }
    get isSuccess() { return this.phase === 'success'; }
    get minQty() { return this.cfg ? this.cfg.minQuantity : 1; }
    get maxQty() { return this.cfg ? this.cfg.maxQuantity : 500; }
    get rangeMessage() { return `Please enter between ${this.minQty} and ${this.maxQty} tickets.`; }
    get quantityHelp() { return `Bulk requests are for ${this.minQty} to ${this.maxQty} tickets.`; }
    get copyLabel() { return this.copied ? 'Copied' : 'Copy reference'; }
    get docTypeOptions() { return this.cfg ? this.cfg.docTypes : []; }
    get acceptAttr() { return this.cfg ? this.cfg.allowedExtensions.map((e) => '.' + e).join(',') : ''; }
    get hasFiles() { return this.files.length > 0; }
    get uploadDisabled() { return this.isBusy || (this.cfg && this.files.length >= this.cfg.maxFiles); }
    get fileHelp() {
        return this.cfg
            ? `Upload up to ${this.cfg.maxFiles} files (${this.cfg.allowedExtensions.join(', ').toUpperCase()}), each up to ${this.cfg.maxFileKb} KB.`
            : '';
    }

    get categoryOptions() {
        if (!this.ev) { return []; }
        return this.ev.categories.filter((c) => !c.soldOut)
            .map((c) => ({ label: `${c.name} · ${c.priceLabel} · ${c.available} left`, value: c.id }));
    }
    get noTicketsLeft() { return this.ev && this.categoryOptions.length === 0; }

    get estimatedTotal() {
        const cat = this.ev ? this.ev.categories.find((c) => c.id === this.form.categoryId) : undefined;
        const qty = Number(this.form.quantity);
        return cat && qty > 0 ? formatPrice(cat.price * qty) : 'Choose tickets to see an estimate';
    }

    get fileRows() {
        return this.files.map((f) => ({
            ...f,
            statusLabel: f.uploaded ? 'Uploaded' : f.error ? 'Failed' : 'Ready',
            statusClass: f.uploaded ? 'chip chip--ok' : f.error ? 'chip chip--bad' : 'chip'
        }));
    }

    // ---------- input handling ----------
    handleChange(event) {
        const el = event.target;
        const value = el.type === 'checkbox' ? el.checked : event.detail.value;
        this.form = { ...this.form, [el.dataset.field]: value };
        if (el.setCustomValidity) { el.setCustomValidity(''); }
    }

    handleHoneypot(event) {
        this.form = { ...this.form, website: event.target.value };
    }

    handleFiles(event) {
        this.fileError = undefined;
        const picked = Array.from(event.target.files || []);
        const allowed = this.cfg.allowedExtensions;
        const maxBytes = this.cfg.maxFileKb * 1024;
        const next = [...this.files];
        picked.forEach((file) => {
            const ext = (file.name.split('.').pop() || '').toLowerCase();
            if (next.length >= this.cfg.maxFiles) {
                this.fileError = `You can upload at most ${this.cfg.maxFiles} files.`;
            } else if (!allowed.includes(ext)) {
                this.fileError = `"${file.name}" is not a supported type.`;
            } else if (file.size > maxBytes) {
                this.fileError = `"${file.name}" is larger than ${this.cfg.maxFileKb} KB.`;
            } else if (next.some((f) => f.name === file.name && f.size === file.size)) {
                this.fileError = `"${file.name}" was already added.`;
            } else {
                const id = `f${++this._seq}`;
                this._store.set(id, file);
                next.push({ id, name: file.name, size: file.size, sizeLabel: `${Math.max(1, Math.round(file.size / 1024))} KB`, uploaded: false, error: undefined });
            }
        });
        this.files = next;
    }

    handleRemove(event) {
        const id = event.currentTarget.dataset.id;
        this._store.delete(id);
        this.files = this.files.filter((f) => f.id !== id);
        this.fileError = undefined;
    }

    // ---------- client checks (for convenience only: the server re-validates everything) ----------
    validateClient() {
        const controls = Array.from(this.template.querySelectorAll('lightning-input, lightning-combobox'));
        const allValid = controls.reduce((ok, el) => (el.reportValidity ? el.reportValidity() && ok : ok), true);
        if (this.files.length === 0) {
            this.fileError = 'Please add at least one identity document.';
            return false;
        }
        return allValid;
    }

    buildInput() {
        const f = this.form;
        return {
            fullName: f.fullName, email: f.email, phone: f.phone, organization: f.organization,
            eventId: this.eventId, categoryId: f.categoryId, quantity: f.quantity ? Number(f.quantity) : null,
            identityDocType: f.identityDocType, identityLast4: f.identityLast4, consent: f.consent === true,
            website: f.website
        };
    }

    // ---------- submit flow ----------
    async handleSubmit() {
        this.banner = undefined;
        if (!this.validateClient()) { return; }
        this.phase = 'submitting';
        this.statusText = 'Submitting your request…';
        this.progress = 8;
        try {
            const res = await submitRequest({ input: this.buildInput() });
            if (!res.success) {
                this.phase = 'form';
                this.applyServerErrors(res);
                return;
            }
            this.reference = res.reference;
            this._token = res.uploadToken;
            await this.uploadAll();
        } catch (e) {
            this.phase = 'form';
            this.banner = GENERIC_ERROR;
        }
    }

    async uploadAll() {
        const pending = this.files.filter((f) => !f.uploaded);
        let done = 0;
        for (const f of pending) {
            this.phase = 'submitting';
            this.statusText = `Uploading document ${done + 1} of ${pending.length}…`;
            try {
                const base64 = await this.readAsBase64(this._store.get(f.id));
                const r = await uploadDocument({ reference: this.reference, uploadToken: this._token, fileName: f.name, base64Data: base64 });
                this.markFile(f.id, r.success, r.success ? undefined : r.message);
            } catch (e) {
                this.markFile(f.id, false, 'Upload failed. Please retry.');
            }
            done += 1;
            this.progress = 15 + Math.round((done / pending.length) * 75);
        }
        if (this.files.every((f) => f.uploaded)) {
            await this.finish();
        } else {
            this.phase = 'partial';
        }
    }

    async finish() {
        this.statusText = 'Finalising…';
        this.progress = 95;
        try {
            const r = await completeSubmission({ reference: this.reference, uploadToken: this._token });
            if (r.success) {
                this._store.clear();     // drop identity files from browser memory
                this._token = undefined;
                this.phase = 'success';
            } else {
                this.phase = 'partial';
                this.banner = r.message;
            }
        } catch (e) {
            this.phase = 'partial';
        }
    }

    handleRetry() { this.uploadAll(); }

    markFile(id, uploaded, error) {
        this.files = this.files.map((f) => (f.id === id ? { ...f, uploaded, error } : f));
    }

    applyServerErrors(res) {
        let general = res.message;
        (res.fieldErrors || []).forEach((err) => {
            const el = this.template.querySelector(`[data-field="${err.field}"]`);
            if (el && el.setCustomValidity) {
                el.setCustomValidity(err.message);
                el.reportValidity();
            } else {
                general = err.message;
            }
        });
        this.banner = general;
    }

    readAsBase64(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => {
                const s = String(reader.result);
                resolve(s.substring(s.indexOf(',') + 1)); // strip the "data:...;base64," prefix
            };
            reader.onerror = () => reject(new Error('read failed'));
            reader.readAsDataURL(file);
        });
    }

    async handleCopy() {
        try {
            await navigator.clipboard.writeText(this.reference);
            this.copied = true;
        } catch (e) {
            this.copied = false;
        }
    }

    handleBrowse() {
        this[NavigationMixin.Navigate]({ type: 'comm__namedPage', attributes: { name: 'Home' } });
    }
}