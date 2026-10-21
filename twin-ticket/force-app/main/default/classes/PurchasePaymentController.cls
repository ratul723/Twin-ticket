/** Staff actions on a purchase. Needs the Review_Bulk_Requests Custom Permission AND the staff user's own record access. */
public with sharing class PurchasePaymentController {
    private static final String LOG = 'TT-PAY ';
    private static final String MSG_NO_PERMISSION = 'You do not have permission to manage payments.';
    private static final String MSG_GENERIC = 'Something went wrong. Please try again or contact an administrator.';
    @TestVisible private static Boolean simulateUnexpectedError = false;

    @AuraEnabled(cacheable=true)
    public static PaymentDto.Overview getOverview(Id recordId) {
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            Purchase__c p = readPurchase(recordId);
            PaymentDto.Overview o = new PaymentDto.Overview();
            o.reference = p.Request_Reference__c;
            o.paymentStatus = p.Payment_Status__c;
            o.amount = p.Total_Amount__c;
            o.paidOn = p.Paid_On__c;
            o.canManage = LeadReviewService.canReview();
            PortalProvisioningService.PortalInfo pi = PortalProvisioningService.infoForPurchase(recordId);
            o.portalAccess = pi.state;
            o.portalUsername = o.canManage ? pi.username : null;
            o.canPreviewPdf = p.Payment_Status__c == 'Paid';
            for (Ticket_Payment__c t : [
                    SELECT Name, Status__c, Status_Detail__c, Amount__c, Currency_Code__c, CreatedDate, Verified_On__c, Provider_Order_Id__c
                    FROM Ticket_Payment__c WHERE Purchase__c = :recordId WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 20]) {
                PaymentDto.AttemptRow row = new PaymentDto.AttemptRow();
                row.name = t.Name;
                row.status = t.Status__c;
                row.detail = t.Status_Detail__c;
                row.amount = t.Amount__c;
                row.currencyCode = t.Currency_Code__c;
                row.createdOn = t.CreatedDate;
                row.verifiedOn = t.Verified_On__c;
                row.providerRef = t.Provider_Order_Id__c == null ? null : t.Provider_Order_Id__c.right(8);
                o.attempts.add(row);
            }
            return o;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'getOverview failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            AuraHandledException ex = new AuraHandledException(MSG_GENERIC);
            ex.setMessage(MSG_GENERIC);
            throw ex;
        }
    }
        @AuraEnabled
    public static PaymentDto.VerifyResult requestPortalAccess(Id recordId) {
        PaymentDto.VerifyResult r = new PaymentDto.VerifyResult();
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            if (!LeadReviewService.canReview()) { r.outcome = 'ERROR'; r.message = MSG_NO_PERMISSION; return r; }
            Purchase__c p = readPurchase(recordId);          // proves this user may access this purchase
            if (p.Payment_Status__c != 'Paid') { r.outcome = 'ERROR'; r.message = 'Portal access is only available for paid purchases.'; return r; }
            Boolean ok = PortalProvisioningService.requestProvisioning(recordId);
            IntegrationLogger.flush();
            r.success = ok;
            r.outcome = ok ? 'OK' : 'ERROR';
            r.message = ok ? 'Portal access requested. It is created within a few seconds. Refresh to see it.'
                           : 'The request could not be queued. Please try again or contact an administrator.';
            return r;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'requestPortalAccess failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            r.outcome = 'ERROR';
            r.message = MSG_GENERIC;
            return r;
        }
    }

    @AuraEnabled
    public static PaymentDto.VerifyResult sendPasswordReset(Id recordId) {
        PaymentDto.VerifyResult r = new PaymentDto.VerifyResult();
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            if (!LeadReviewService.canReview()) { r.outcome = 'ERROR'; r.message = MSG_NO_PERMISSION; return r; }
            readPurchase(recordId);
            Boolean ok = PortalProvisioningService.resendPasswordEmail(recordId);
            r.success = ok;
            r.outcome = ok ? 'OK' : 'ERROR';
            r.message = ok ? 'A password email was sent to the buyer.' : 'There is no active portal user to email.';
            return r;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'sendPasswordReset failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            r.outcome = 'ERROR';
            r.message = MSG_GENERIC;
            return r;
        }
    }

    @AuraEnabled
    public static PaymentLinkService.SendResult sendPaymentLink(Id recordId) {
        PaymentLinkService.SendResult r = new PaymentLinkService.SendResult();
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            if (!LeadReviewService.canReview()) { r.message = MSG_NO_PERMISSION; return r; }
            readPurchase(recordId);                         // proves this user may access this purchase
            return PaymentLinkService.issueAndSend(recordId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'sendPaymentLink failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            r.success = false;
            r.message = MSG_GENERIC;
            return r;
        }
    }

    @AuraEnabled
    public static PaymentDto.VerifyResult reverifyPayment(Id recordId) {
        PaymentDto.VerifyResult r = new PaymentDto.VerifyResult();
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            if (!LeadReviewService.canReview()) {
                r.outcome = 'ERROR';
                r.message = MSG_NO_PERMISSION;
                return r;
            }
            readPurchase(recordId);
            return PaymentService.reverifyLatest(recordId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'reverifyPayment failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            r.outcome = 'ERROR';
            r.message = MSG_GENERIC;
            return r;
        }
    }

    private static Purchase__c readPurchase(Id recordId) {
        if (recordId == null || recordId.getSObjectType() != Purchase__c.SObjectType) {
            throw new IllegalArgumentException('invalid purchase id');
        }
        return [SELECT Id, Request_Reference__c, Payment_Status__c, Total_Amount__c, Paid_On__c
                FROM Purchase__c WHERE Id = :recordId WITH USER_MODE LIMIT 1];
    }
}