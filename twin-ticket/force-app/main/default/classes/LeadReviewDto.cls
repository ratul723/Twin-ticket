public class LeadReviewDto {
    public class ActionOption {
        @AuraEnabled public String value;
        @AuraEnabled public String label;
        @AuraEnabled public String help;
        public ActionOption(String v, String l, String h) { value = v; label = l; help = h; }
    }
    public class FileDto {
        @AuraEnabled public String documentId;
        @AuraEnabled public String title;
        @AuraEnabled public String extension;
        @AuraEnabled public Integer sizeKb;
    }
    public class ReviewData {
        @AuraEnabled public String leadId;
        @AuraEnabled public String reference;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean isConverted;
        @AuraEnabled public Boolean submissionComplete;
        @AuraEnabled public String buyerName;
        @AuraEnabled public String email;
        @AuraEnabled public String phone;
        @AuraEnabled public String organization;
        @AuraEnabled public String eventName;
        @AuraEnabled public Datetime eventStart;
        @AuraEnabled public String venue;
        @AuraEnabled public String categoryName;
        @AuraEnabled public Integer quantity;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal estimatedTotal;
        @AuraEnabled public Decimal availableNow;
        @AuraEnabled public String docType;
        @AuraEnabled public String last4;
        @AuraEnabled public String notes;
        @AuraEnabled public String reviewedBy;
        @AuraEnabled public Datetime reviewedOn;
        @AuraEnabled public Boolean canDecide;
        @AuraEnabled public List<String> blockers = new List<String>();
        @AuraEnabled public List<ActionOption> actions = new List<ActionOption>();
        @AuraEnabled public List<FileDto> files = new List<FileDto>();
        @AuraEnabled public String accountId;
        @AuraEnabled public String contactId;
        @AuraEnabled public String opportunityId;
        @AuraEnabled public String purchaseId;
    }
    public class DecisionResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String accountId;
        @AuraEnabled public String contactId;
        @AuraEnabled public String opportunityId;
        @AuraEnabled public String purchaseId;
    }
}