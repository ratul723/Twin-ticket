public class PaymentDto {
    public class Context {
        @AuraEnabled public Boolean valid = false;
        @AuraEnabled public String message;
        @AuraEnabled public String state;          // PAYABLE | PAID | UNAVAILABLE
        @AuraEnabled public String reference;
        @AuraEnabled public String eventName;
        @AuraEnabled public Datetime eventStart;
        @AuraEnabled public String venue;
        @AuraEnabled public String categoryName;
        @AuraEnabled public Integer quantity;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String currencyCode;
    }
    public class StartResult {
        @AuraEnabled public Boolean success = false;
        @AuraEnabled public Boolean alreadyPaid = false;
        @AuraEnabled public String message;
        @AuraEnabled public String checkoutUrl;
    }
    public class VerifyResult {
        @AuraEnabled public Boolean success = false;
        @AuraEnabled public String outcome;        // PAID | PENDING | CANCELLED | NEEDS_REVIEW | DUPLICATE | NONE | ERROR
        @AuraEnabled public String message;
    }
    public class AttemptRow {
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String detail;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public Datetime createdOn;
        @AuraEnabled public Datetime verifiedOn;
        @AuraEnabled public String providerRef;    // last 8 characters only
    }
    public class Overview {
        @AuraEnabled public String reference;
        @AuraEnabled public String paymentStatus;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Datetime paidOn;
        @AuraEnabled public Boolean canManage;
        @AuraEnabled public List<AttemptRow> attempts = new List<AttemptRow>();
        @AuraEnabled public String portalAccess;     // NOT_PAID | NONE | ACTIVE | INACTIVE
        @AuraEnabled public String portalUsername;
        @AuraEnabled public Boolean canPreviewPdf;
    }
}