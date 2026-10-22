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
    public static Integer paymentTokenHours() { return Math.min(720, Math.max(1, intValue('Payment_Token_Hours__c', 168))); }

    /** Stripe allows 30 minutes to 24 hours. We stay inside that range even after rounding. */
    public static Integer paymentSessionMinutes() { return Math.min(1380, Math.max(30, intValue('Payment_Session_Minutes__c', 60))); }

        /** Identity documents on bulk requests. OFF for now: set to true when the upload step is ready. */
    public static Boolean documentsRequired() { return false; }
    
    public static String paymentCurrency() {
        Object v = value('Payment_Currency__c');
        String c = v == null ? 'usd' : String.valueOf(v).trim().toLowerCase();
        return Pattern.matches('^[a-z]{3}$', c) ? c : 'usd';
    }

    /** Feature flag. If the field is missing entirely, payments stay ON. */
    public static Boolean paymentsEnabled() {
        Object v = value('Payments_Enabled__c');
        return v == null ? true : (Boolean) v;
    }
        public static String portalProfileName() {
        Object v = value('Portal_Profile_Name__c');
        String s = v == null ? '' : String.valueOf(v).trim();
        return String.isBlank(s) ? 'Customer Community User' : s;
    }
    public static Boolean weatherEnabled() {
        Object v = value('Weather_Enabled__c');
        return v == null ? true : (Boolean) v;
    }

    /** 16 forecast days counting today = 15 days ahead at most. Config can only narrow this. */
    public static Integer weatherHorizonDays() {
        return Math.min(15, Math.max(0, intValue('Weather_Horizon_Days__c', 15)));
    }

    public static Integer weatherBackoffMinutes() {
        return Math.min(120, Math.max(1, intValue('Weather_Backoff_Minutes__c', 10)));
    }

    /** Feature flag. If the field is missing entirely, portal provisioning stays ON. */
    public static Boolean portalEnabled() {
        Object v = value('Portal_Enabled__c');
        return v == null ? true : (Boolean) v;
    }

    public static String portalLoginUrl() {
        String base = siteBaseUrl();
        return String.isBlank(base) ? '' : base + '/login';
    }

    public static String siteBaseUrl() {
        Object v = value('Site_Base_Url__c');
        String u = v == null ? '' : String.valueOf(v).trim();
        while (u.endsWith('/')) { u = u.removeEnd('/'); }
        return u;
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