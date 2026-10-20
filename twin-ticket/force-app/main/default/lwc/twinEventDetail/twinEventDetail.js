import { LightningElement, wire } from 'lwc';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import getEventDetail from '@salesforce/apex/PublicEventController.getEventDetail';
import { decorateEvent } from 'c/twinUtils';

export default class TwinEventDetail extends NavigationMixin(LightningElement) {
    eventId;
    ev;
    errorMessage;
    isLoading = true;

    @wire(CurrentPageReference)
    setPageRef(ref) {
        if (!ref) {
            return;
        }
        this.eventId = ref.state ? ref.state.c__eventId : undefined;
        if (!this.eventId) {
            this.isLoading = false;
            this.errorMessage = 'No event was selected. Please choose an event from the list.';
        }
    }

    @wire(getEventDetail, { eventId: '$eventId' })
    wiredEvent({ data, error }) {
        if (data) {
            this.ev = decorateEvent(data);
            this.errorMessage = undefined;
            this.isLoading = false;
        } else if (error) {
            // The server already hides drafts and bad ids behind one answer. Show a fixed, safe message.
            this.ev = undefined;
            this.errorMessage = 'This event is not available. It may have ended or may not be published yet.';
            this.isLoading = false;
        }
    }

    handleBack() {
        this[NavigationMixin.Navigate]({ type: 'comm__namedPage', attributes: { name: 'Home' } });
    }

    handleBulk() {
        this[NavigationMixin.Navigate]({
            type: 'comm__namedPage',
            attributes: { name: 'Bulk_Request__c' },
            state: { c__eventId: this.eventId }
        });
    }
}