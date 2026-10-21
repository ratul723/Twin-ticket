/** Thin entry point for the guest site. All rules live in BulkRequestService. Users only ever see safe, fixed messages. */
public with sharing class BulkRequestController {
    private static final String LOG = 'TT-REQ ';
    private static final String MSG_GENERIC = 'Something went wrong on our side. Please try again in a few minutes.';
    @TestVisible private static Boolean simulateUnexpectedError = false; // lets tests exercise the safety-net branches

    @AuraEnabled(cacheable=true)
    public static BulkRequestDto.FormConfig getFormConfig() {
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            return BulkRequestService.getFormConfig();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'getFormConfig failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            AuraHandledException ex = new AuraHandledException(MSG_GENERIC);
            ex.setMessage(MSG_GENERIC);
            throw ex;
        }
    }

    @AuraEnabled
    public static BulkRequestDto.SubmitResult submitRequest(BulkRequestDto.RequestInput input) {
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            return BulkRequestService.submit(input);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'submitRequest failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            BulkRequestDto.SubmitResult r = new BulkRequestDto.SubmitResult();
            r.success = false;
            r.message = MSG_GENERIC;
            r.fieldErrors = new List<BulkRequestDto.FieldError>();
            return r;
        }
    }

    @AuraEnabled
    public static BulkRequestDto.StepResult uploadDocument(String reference, String uploadToken, String fileName, String base64Data) {
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            return BulkRequestService.uploadDocument(reference, uploadToken, fileName, base64Data);
        } catch (BulkRequestService.RequestException re) {
            return failure(re.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'uploadDocument failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            return failure(MSG_GENERIC);
        }
    }

    @AuraEnabled
    public static BulkRequestDto.StepResult completeSubmission(String reference, String uploadToken) {
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            return BulkRequestService.completeSubmission(reference, uploadToken);
        } catch (BulkRequestService.RequestException re) {
            return failure(re.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'completeSubmission failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            return failure(MSG_GENERIC);
        }
    }

    private static BulkRequestDto.StepResult failure(String message) {
        BulkRequestDto.StepResult r = new BulkRequestDto.StepResult();
        r.success = false;
        r.message = message;
        return r;
    }
}