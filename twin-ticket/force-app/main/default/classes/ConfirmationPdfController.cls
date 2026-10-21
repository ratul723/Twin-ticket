/**
 * Feeds the PDF page. Every request is authorised by PortalPurchaseService (own purchase, Paid only; staff preview for reviewers).
 * On ANY failure the page shows one neutral message, so nothing leaks about other customers' purchases.
 */
public with sharing class ConfirmationPdfController {
    private static final String LOG = 'TT-PDF ';

    public Boolean available { get; private set; }
    public String message { get; private set; }
    public String reference { get; private set; }
    public String purchaseNumber { get; private set; }
    public String buyerName { get; private set; }
    public String organization { get; private set; }
    public String eventName { get; private set; }
    public String eventWhen { get; private set; }
    public String venue { get; private set; }
    public String categoryName { get; private set; }
    public String quantity { get; private set; }
    public String unitPrice { get; private set; }
    public String total { get; private set; }
    public String paidOn { get; private set; }
    public String paymentReference { get; private set; }
    public String generatedOn { get; private set; }

    public ConfirmationPdfController() {
        available = false;
        message = 'This confirmation is not available.';
    }

    public void init() {
        try {
            String raw = ApexPages.currentPage().getParameters().get('id');
            Id purchaseId = String.isBlank(raw) ? null : Id.valueOf(raw.trim());
            Purchase__c p = PortalPurchaseService.loadAuthorized(purchaseId, true);

            PortalDisplayLookup.EventInfo ev = PortalDisplayLookup.events(new Set<Id>{ p.Event__c }).get(p.Event__c);
            Map<String, String> buyer = PortalDisplayLookup.buyer(p.Id);
            String cur = TwinTicketConfig.paymentCurrency().toUpperCase();

            reference = p.Request_Reference__c;
            purchaseNumber = p.Name;
            buyerName = buyer.get('name');
            organization = buyer.get('organization');
            eventName = ev == null ? '' : ev.name;
            eventWhen = formatWhen(ev);
            venue = ev == null ? '' : ev.venue;
            categoryName = PortalDisplayLookup.categoryNames(new Set<Id>{ p.Ticket_Category__c }).get(p.Ticket_Category__c);
            quantity = String.valueOf(p.Quantity__c.intValue());
            unitPrice = cur + ' ' + p.Unit_Price__c.setScale(2).format();
            total = cur + ' ' + p.Total_Amount__c.setScale(2).format();
            paidOn = p.Paid_On__c == null ? '' : p.Paid_On__c.formatGmt('d MMM yyyy, HH:mm') + ' UTC';
            paymentReference = PortalDisplayLookup.paymentReference(p.Id);
            generatedOn = Datetime.now().formatGmt('d MMM yyyy, HH:mm') + ' UTC';
            available = true;
            message = null;
            // Make the browser download the file instead of showing it inline.
            ApexPages.currentPage().getHeaders().put('Content-Disposition',
                'attachment; filename=TwinTicket-Confirmation-' + reference.replaceAll('[^A-Za-z0-9-]', '') + '.pdf');
            System.debug(LoggingLevel.INFO, LOG + 'confirmation generated ref=' + reference);
        } catch (PortalPurchaseService.PortalException pe) {
            available = false;
            message = pe.getMessage() == PortalPurchaseService.MSG_NOT_PAID ? PortalPurchaseService.MSG_NOT_PAID : 'This confirmation is not available.';
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'init failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            available = false;
            message = 'This confirmation is not available.';
        }
    }

    private static String formatWhen(PortalDisplayLookup.EventInfo ev) {
        if (ev == null || ev.startAt == null) { return ''; }
        try {
            return ev.startAt.format('EEE, d MMM yyyy, HH:mm', String.isBlank(ev.timeZone) ? 'GMT' : ev.timeZone)
                + (String.isBlank(ev.timeZone) ? '' : ' (' + ev.timeZone + ')');
        } catch (Exception e) {
            return ev.startAt.formatGmt('EEE, d MMM yyyy, HH:mm') + ' UTC';
        }
    }
}