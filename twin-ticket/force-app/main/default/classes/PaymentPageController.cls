public with sharing class PaymentPageController {
    private static final String LOG = 'TT-PAY ';
    @TestVisible private static Boolean simulateUnexpectedError = false;

    @AuraEnabled
    public static PaymentDto.Context getContext(String reference, String token) {
        PaymentDto.Context c = new PaymentDto.Context();
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            return PaymentService.getContext(reference, token);
        } catch (PaymentService.PaymentException pe) {
            c.message = pe.getMessage();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'getContext failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            c.message = PaymentService.MSG_UNAVAILABLE;
        }
        return c;
    }

    @AuraEnabled
    public static PaymentDto.StartResult startPayment(String reference, String token) {
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            return PaymentService.startPayment(reference, token);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'startPayment controller failed: ' + e.getTypeName());
            PaymentDto.StartResult r = new PaymentDto.StartResult();
            r.message = PaymentService.MSG_UNAVAILABLE;
            return r;
        }
    }

    @AuraEnabled
    public static PaymentDto.VerifyResult verifyPayment(String reference, String token, String sessionId) {
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            return PaymentService.verifyPayment(reference, token, sessionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'verifyPayment controller failed: ' + e.getTypeName());
            return failure();
        }
    }

    @AuraEnabled
    public static PaymentDto.VerifyResult cancelAttempt(String reference, String token) {
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            return PaymentService.cancelAttempt(reference, token);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'cancelAttempt controller failed: ' + e.getTypeName());
            return failure();
        }
    }

    private static PaymentDto.VerifyResult failure() {
        PaymentDto.VerifyResult r = new PaymentDto.VerifyResult();
        r.outcome = 'ERROR';
        r.message = PaymentService.MSG_UNAVAILABLE;
        return r;
    }
}