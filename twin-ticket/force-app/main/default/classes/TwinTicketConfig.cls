/** Reads NON-SECRET settings from Custom Metadata. Falls back to safe defaults if the record or a field is missing. */
public with sharing class TwinTicketConfig {
    @TestVisible private static Twin_Ticket_Config__mdt testRecord;
    private static final Set<String> SUPPORTED = new Set<String>{ 'pdf', 'jpg', 'jpeg', 'png' };
    private static final Integer HARD_MAX_FILE_KB = 2560; // payload ceiling: config can only go lower
    private static final Integer HARD_MAX_FILES = 5;

    private static Object value(String field) {
        try {
            Twin_Ticket_Config__mdt r = testRecord != null ? testRecord : Twin_Ticket_Config__mdt.getInstance('Default');
            return r == null ? null : r.get(field);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'TT-CONFIG cannot read ' + field + ': ' + e.getMessage());
            return null;
        }
    }

    private static Integer intValue(String field, Integer fallback) {
        Object v = value(field);
        return v == null ? fallback : ((Decimal) v).intValue();
    }

    public static Integer minQuantity() { return Math.max(1, intValue('Min_Bulk_Quantity__c', 10)); }
    public static Integer maxQuantity() { return Math.max(minQuantity(), intValue('Max_Bulk_Quantity__c', 500)); }
    public static Integer maxFiles() { return Math.min(HARD_MAX_FILES, Math.max(1, intValue('Max_Files__c', 3))); }
    public static Integer maxFileKb() { return Math.min(HARD_MAX_FILE_KB, Math.max(1, intValue('Max_File_Size_KB__c', 2048))); }
    public static Integer maxRequestsPerEmailPerDay() { return Math.max(1, intValue('Max_Requests_Per_Email_Per_Day__c', 3)); }

    /** Config can only NARROW the supported types: the signature check only knows PDF, JPG and PNG. */
    public static Set<String> allowedExtensions() {
        Set<String> result = new Set<String>();
        Object raw = value('Allowed_File_Types__c');
        if (raw != null) {
            for (String part : String.valueOf(raw).toLowerCase().split(',')) {
                String t = part.trim();
                if (SUPPORTED.contains(t)) { result.add(t); }
            }
        }
        return result.isEmpty() ? new Set<String>(SUPPORTED) : result;
    }
}