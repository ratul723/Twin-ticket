public class BulkRequestDto {
    public class Option {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public Option(String l, String v) { label = l; value = v; }
    }
    public class FormConfig {
        @AuraEnabled public Integer minQuantity;
        @AuraEnabled public Integer maxQuantity;
        @AuraEnabled public Integer maxFiles;
        @AuraEnabled public Integer maxFileKb;
        @AuraEnabled public List<String> allowedExtensions;
        @AuraEnabled public List<Option> docTypes;
    }
    public class RequestInput {
        @AuraEnabled public String fullName;
        @AuraEnabled public String email;
        @AuraEnabled public String phone;
        @AuraEnabled public String organization;
        @AuraEnabled public String eventId;
        @AuraEnabled public String categoryId;
        @AuraEnabled public Integer quantity;
        @AuraEnabled public String identityDocType;
        @AuraEnabled public String identityLast4;
        @AuraEnabled public Boolean consent;
        @AuraEnabled public String website; // honeypot: humans never see or fill this
    }
    public class FieldError {
        @AuraEnabled public String field;
        @AuraEnabled public String message;
        public FieldError(String f, String m) { field = f; message = m; }
    }
    public class SubmitResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String reference;
        @AuraEnabled public String uploadToken;
        @AuraEnabled public String message;
        @AuraEnabled public List<FieldError> fieldErrors;
    }
    public class StepResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public Integer fileCount;
    }
}