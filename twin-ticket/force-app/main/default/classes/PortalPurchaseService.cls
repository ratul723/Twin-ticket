/**
 * What a signed-in customer may see. THREE layers (see the slice overview):
 *  1. platform: external sharing is Private + a Sharing Set on Account (configured in Setup)
 *  2. WITH USER_MODE on every query (CRUD, FLS and sharing of the portal user)
 *  3. an explicit filter on the user's OWN Account, so a mistaken share can never leak another customer's purchase
 * The same message is returned for "does not exist" and "belongs to someone else", so ids cannot be probed.
 */
public with sharing class PortalPurchaseService {

    public class PortalException extends Exception {}

    @TestVisible public static final String MSG_NOT_FOUND = 'This purchase could not be found.';
    @TestVisible public static final String MSG_NOT_PAID = 'The confirmation becomes available once your payment has been received.';
    private static final String LOG = 'TT-PORTAL ';

    public class PurchaseView {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String reference;
        @AuraEnabled public String eventName;
        @AuraEnabled public Datetime eventStart;
        @AuraEnabled public String timeZone;
        @AuraEnabled public String venue;
        @AuraEnabled public String categoryName;
        @AuraEnabled public Integer quantity;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal total;
        @AuraEnabled public String statusCode;
        @AuraEnabled public String statusLabel;
        @AuraEnabled public String statusHelp;
        @AuraEnabled public Datetime paidOn;
        @AuraEnabled public Boolean canDownload;
    }

    public class MyPurchases {
        @AuraEnabled public Boolean isCustomer = false;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public List<PurchaseView> items = new List<PurchaseView>();
    }

    public static MyPurchases listMine() {
        MyPurchases out = new MyPurchases();
        out.currencyCode = TwinTicketConfig.paymentCurrency().toUpperCase();
        Id accountId = currentAccountId();
        if (accountId == null) { return out; }          // internal users and guests get NOTHING from this method
        out.isCustomer = true;

        List<Purchase__c> rows = [
            SELECT Id, Name, Request_Reference__c, Payment_Status__c, Quantity__c, Unit_Price__c, Total_Amount__c, Paid_On__c,
                   Event_Detail__c, Ticket_Category__c, Account__c
            FROM Purchase__c WHERE Account__c = :accountId      // layer 3
            WITH USER_MODE                                      // layer 2 (layer 1 is the Sharing Set)
            ORDER BY CreatedDate DESC LIMIT 50];

        Set<Id> eventIds = new Set<Id>();
        Set<Id> categoryIds = new Set<Id>();
        for (Purchase__c p : rows) { eventIds.add(p.Event_Detail__c); categoryIds.add(p.Ticket_Category__c); }
        Map<Id, PortalDisplayLookup.EventInfo> events = PortalDisplayLookup.events(eventIds);
        Map<Id, String> categories = PortalDisplayLookup.categoryNames(categoryIds);

        for (Purchase__c p : rows) {
            PurchaseView v = new PurchaseView();
            v.id = p.Id;
            v.name = p.Name;
            v.reference = p.Request_Reference__c;
            PortalDisplayLookup.EventInfo ev = events.get(p.Event_Detail__c);
            if (ev != null) { v.eventName = ev.name; v.eventStart = ev.startAt; v.timeZone = ev.timeZone; v.venue = ev.venue; }
            v.categoryName = categories.get(p.Ticket_Category__c);
            v.quantity = p.Quantity__c == null ? null : p.Quantity__c.intValue();
            v.unitPrice = p.Unit_Price__c;
            v.total = p.Total_Amount__c;
            v.statusCode = p.Payment_Status__c;
            v.statusLabel = labelFor(p.Payment_Status__c);
            v.statusHelp = helpFor(p.Payment_Status__c);
            v.paidOn = p.Paid_On__c;
            v.canDownload = p.Payment_Status__c == 'Paid';
            out.items.add(v);
        }
        System.debug(LoggingLevel.INFO, LOG + 'listMine returned ' + out.items.size() + ' purchases');
        return out;
    }

    /** Used by the PDF page. A customer must own the purchase. A staff reviewer may preview any purchase they can already read. */
    public static Purchase__c loadAuthorized(Id purchaseId, Boolean requirePaid) {
        if (purchaseId == null || purchaseId.getSObjectType() != Purchase__c.SObjectType) {
            throw new PortalException(MSG_NOT_FOUND);
        }
        Id accountId = currentAccountId();
        Boolean staff = accountId == null && LeadReviewService.canReview();
        if (accountId == null && !staff) {
            System.debug(LoggingLevel.WARN, LOG + 'denied: caller is neither a customer nor a reviewer');
            throw new PortalException(MSG_NOT_FOUND);
        }
        List<Purchase__c> rows;
        if (staff) {
            rows = [SELECT Id, Name, Request_Reference__c, Payment_Status__c, Quantity__c, Unit_Price__c, Total_Amount__c, Paid_On__c,
                           Event_Detail__c, Ticket_Category__c, Account__c FROM Purchase__c WHERE Id = :purchaseId WITH USER_MODE LIMIT 1];
        } else {
            rows = [SELECT Id, Name, Request_Reference__c, Payment_Status__c, Quantity__c, Unit_Price__c, Total_Amount__c, Paid_On__c,
                           Event_Detail__c, Ticket_Category__c, Account__c FROM Purchase__c
                    WHERE Id = :purchaseId AND Account__c = :accountId WITH USER_MODE LIMIT 1];
        }
        if (rows.isEmpty()) {
            System.debug(LoggingLevel.WARN, LOG + 'denied: purchase not visible to caller, id=' + purchaseId);
            throw new PortalException(MSG_NOT_FOUND);
        }
        if (requirePaid && rows[0].Payment_Status__c != 'Paid') { throw new PortalException(MSG_NOT_PAID); }
        return rows[0];
    }

    @TestVisible
    private static Id currentAccountId() {
        List<User> us = [SELECT ContactId, Contact.AccountId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        return (us.isEmpty() || us[0].ContactId == null) ? null : us[0].Contact.AccountId;
    }

    private static String labelFor(String s) {
        if (s == 'Paid') { return 'Paid'; }
        if (s == 'Pending') { return 'Payment in progress'; }
        if (s == 'Failed') { return 'Payment problem'; }
        if (s == 'Cancelled') { return 'Payment cancelled'; }
        return 'Awaiting payment';
    }

    private static String helpFor(String s) {
        if (s == 'Paid') { return null; }
        if (s == 'Pending') { return 'We are waiting for your payment to complete.'; }
        if (s == 'Failed') { return 'We could not confirm your payment. Please contact Twin Ticket and quote your reference.'; }
        if (s == 'Cancelled') { return 'You cancelled the payment. Use the payment link in your email to try again.'; }
        return 'Please use the secure payment link we emailed you to complete this purchase.';
    }
}