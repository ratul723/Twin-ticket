public with sharing class PortalPurchaseController {
    private static final String LOG = 'TT-PORTAL ';
    @TestVisible private static Boolean simulateUnexpectedError = false;

    @AuraEnabled
    public static PortalPurchaseService.MyPurchases getMyPurchases() {
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            return PortalPurchaseService.listMine();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'getMyPurchases failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            String msg = 'We could not load your purchases right now. Please try again in a few minutes.';
            AuraHandledException ex = new AuraHandledException(msg);
            ex.setMessage(msg);
            throw ex;
        }
    }
}