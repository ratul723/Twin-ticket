/**
 * Buffers integration log rows and writes them together at the end of a request.
 * WHY buffered: a database write BEFORE a callout is illegal in Apex, so we log after all callouts are done.
 * Messages are sanitised: keys and bearer tokens are redacted, and text is capped at 255 characters.
 */
public without sharing class IntegrationLogger {
    private static final List<Integration_Log__c> buffer = new List<Integration_Log__c>();

    public static void add(String provider, String operation, Integer httpStatus, Boolean success,
                           String correlationId, String message, String relatedId) {
        buffer.add(new Integration_Log__c(
            Provider__c = provider, Operation__c = operation, HTTP_Status__c = httpStatus,
            Outcome__c = success ? 'Success' : 'Failure', Correlation_Id__c = correlationId,
            Message__c = sanitize(message), Related_Id__c = relatedId == null ? null : relatedId.left(18)));
    }

    public static void flush() {
        if (buffer.isEmpty()) { return; }
        List<Integration_Log__c> toWrite = buffer.clone();
        buffer.clear();
        try {
            insert toWrite;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'TT-LOG could not write integration logs: ' + e.getMessage());
        }
    }

    @TestVisible
    private static String sanitize(String message) {
        if (message == null) { return null; }
        String m = message.replaceAll('(?i)(sk|rk|pk)_(test|live)_[A-Za-z0-9]+', '[redacted]')
                          .replaceAll('(?i)bearer\\s+\\S+', '[redacted]');
        return m.left(255);
    }
}