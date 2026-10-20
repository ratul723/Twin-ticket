import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getPublishedEvents from '@salesforce/apex/PublicEventController.getPublishedEvents';
import { decorateEvent } from 'c/twinUtils';

export default class TwinEventList extends NavigationMixin(LightningElement) {
    events = [];
    errorMessage;
    isLoading = true;

    @wire(getPublishedEvents)
    wiredEvents({ data, error }) {
        if (data) {
            this.events = data.map(decorateEvent);
            this.errorMessage = undefined;
            this.isLoading = false;
        } else if (error) {
            // Fixed friendly message only. Never render the raw error to a public visitor.
            this.events = [];
            this.errorMessage = 'We could not load events right now. Please try again shortly.';
            this.isLoading = false;
        }
    }

    get isEmpty() {
        return this.events.length === 0;
    }

    handleView(event) {
        this.goTo('Event_Page__c', event.currentTarget.dataset.id);
    }

    handleBulk(event) {
        this.goTo('Bulk_Request__c', event.currentTarget.dataset.id);
    }

    goTo(pageApiName, eventId) {
        this[NavigationMixin.Navigate]({
            type: 'comm__namedPage',
            attributes: { name: pageApiName },
            state: { c__eventId: eventId }
        });
    }
}