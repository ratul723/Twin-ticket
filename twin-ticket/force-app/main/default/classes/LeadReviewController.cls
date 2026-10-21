public with sharing class LeadReviewController {
    private static final String LOG = 'TT-REVIEW ';
    private static final String MSG_GENERIC = 'Something went wrong. Please try again or contact an administrator.';
    @TestVisible private static Boolean simulateUnexpectedError = false;

    @AuraEnabled(cacheable=true)
    public static LeadReviewDto.ReviewData getReviewData(Id recordId) {
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            return LeadReviewService.getReviewData(recordId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'getReviewData failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            String msg = e instanceof LeadReviewService.ReviewException ? e.getMessage() : MSG_GENERIC;
            AuraHandledException ex = new AuraHandledException(msg);
            ex.setMessage(msg);
            throw ex;
        }
    }

    @AuraEnabled
    public static LeadReviewDto.DecisionResult submitDecision(Id recordId, String decision, String notes, String buyerMessage) {
        LeadReviewDto.DecisionResult r = new LeadReviewDto.DecisionResult();
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            return LeadReviewService.submitDecision(recordId, decision, notes, buyerMessage);
        } catch (LeadReviewService.ReviewException re) {
            r.success = false;
            r.message = re.getMessage();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'submitDecision failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            r.success = false;
            r.message = MSG_GENERIC;
        }
        return r;
    }
}