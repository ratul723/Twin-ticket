/**
 * Privileged gateway for GUEST bulk requests.
 * WHY 'without sharing': the guest profile has NO access to Lead or Files. This single class performs the writes,
 * but only after validating every input server-side, and it writes ONLY the whitelisted fields below.
 * Nothing sensitive is returned to the caller: just the reference and a one-time upload token.
 * Logs contain references and counts only, never names, emails, phones, ID digits or file contents.
 */
public without sharing class BulkRequestService {

    public class RequestException extends Exception {}

    private static final String LOG = 'TT-REQ ';
    private static final String QUEUE_DEV_NAME = 'Bulk_Request_Review';
    private static final String REF_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no I, O, 0, 1
    private static final Pattern REF_PATTERN = Pattern.compile('^TT-[0-9]{8}-[A-HJ-NP-Z2-9]{6}$');
    private static final Pattern EMAIL_PATTERN = Pattern.compile('^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$');
    private static final Pattern LAST4_PATTERN = Pattern.compile('^[A-Za-z0-9]{4}$');
    private static final Integer TOKEN_MINUTES = 60;
    @TestVisible private static final String MSG_LINK_INVALID =
        'This upload session has expired or is not valid. Please submit your request again.';

    // ---------- Form configuration: one source of truth for the UI and the server ----------
    public static BulkRequestDto.FormConfig getFormConfig() {
        BulkRequestDto.FormConfig cfg = new BulkRequestDto.FormConfig();
        cfg.minQuantity = TwinTicketConfig.minQuantity();
        cfg.maxQuantity = TwinTicketConfig.maxQuantity();
        cfg.maxFiles = TwinTicketConfig.maxFiles();
        cfg.maxFileKb = TwinTicketConfig.maxFileKb();
        cfg.allowedExtensions = new List<String>(TwinTicketConfig.allowedExtensions());
        cfg.docTypes = docTypeOptions();
        cfg.documentsRequired = TwinTicketConfig.documentsRequired();
        return cfg;
    }

    private static List<BulkRequestDto.Option> docTypeOptions() {
        List<BulkRequestDto.Option> opts = new List<BulkRequestDto.Option>();
        for (Schema.PicklistEntry pe : Schema.Lead.Identity_Document_Type__c.getDescribe().getPicklistValues()) {
            if (pe.isActive()) { opts.add(new BulkRequestDto.Option(pe.getLabel(), pe.getValue())); }
        }
        return opts;
    }

    // ---------- Step 1: validate and create the Lead ----------
    public static BulkRequestDto.SubmitResult submit(BulkRequestDto.RequestInput input) {
        BulkRequestDto.SubmitResult res = new BulkRequestDto.SubmitResult();
        res.success = false;
        res.fieldErrors = new List<BulkRequestDto.FieldError>();
        if (input == null) {
            res.message = 'Please complete the form and try again.';
            return res;
        }
        if (String.isNotBlank(input.website)) {
            System.debug(LoggingLevel.WARN, LOG + 'honeypot triggered, request discarded');
            res.message = 'We could not process this request. Please try again later.';
            return res;
        }
        List<BulkRequestDto.FieldError> errs = res.fieldErrors;

        // Normalise first, then validate. Never trust the browser.
        String fullName = clean(input.fullName);
        if (fullName.length() < 2 || fullName.length() > 80 || !Pattern.matches('.*\\p{L}.*', fullName)) {
            addError(errs, 'fullName', 'Please enter your full name (2 to 80 characters).');
        }
        String email = clean(input.email).toLowerCase();
        if (email.length() > 80 || !EMAIL_PATTERN.matcher(email).matches()) {
            addError(errs, 'email', 'Please enter a valid email address.');
        }
        String phoneRaw = clean(input.phone);
        String digits = phoneRaw.replaceAll('[^0-9]', '');
        String phone = (phoneRaw.startsWith('+') ? '+' : '') + digits;
        if (!Pattern.matches('^[0-9+()\\-\\s]{7,20}$', phoneRaw) || digits.length() < 7 || digits.length() > 15) {
            addError(errs, 'phone', 'Please enter a valid phone number, for example +8801700000000.');
        }
        String org = clean(input.organization);
        if (org.length() > 80) {
            addError(errs, 'organization', 'Organization name must be 80 characters or fewer.');
        }
        String docType = clean(input.identityDocType);
        System.debug(LoggingLevel.WARN, LOG + 'eventId=[' + input.eventId + '] categoryId=[' + input.categoryId + ']');
        System.debug(LoggingLevel.WARN, LOG + 'docType received=[' + docType + '] valid=' + isValidDocType(docType)
            + ' options=' + JSON.serialize(docTypeOptions()));                 // ← ADD
        if (!isValidDocType(docType)) {
            addError(errs, 'identityDocType', 'Please choose a document type.');
        }
        if (!isValidDocType(docType)) {
            addError(errs, 'identityDocType', 'Please choose a document type.');
        }
        String last4 = clean(input.identityLast4);
        if (!LAST4_PATTERN.matcher(last4).matches()) {
            addError(errs, 'identityLast4', 'Enter the last 4 characters of your ID number.');
        }
        if (input.consent != true) {
            addError(errs, 'consent', 'Please confirm that we may use your details to verify this request.');
        }

        Integer minQ = TwinTicketConfig.minQuantity();
        Integer maxQ = TwinTicketConfig.maxQuantity();
        Boolean qtyOk = input.quantity != null && input.quantity >= minQ && input.quantity <= maxQ;
        if (!qtyOk) {
            addError(errs, 'quantity', 'Quantity must be between ' + minQ + ' and ' + maxQ + ' tickets.');
        }

        // Event and category come from the DATABASE, never from the browser's claims.
        Id evId = parseId(input.eventId, Event_Detail__c.SObjectType);
        Id catId = parseId(input.categoryId, Ticket_Category__c.SObjectType);
        if (evId == null) { addError(errs, 'eventId', 'Please choose a valid event.'); }
        if (catId == null) { addError(errs, 'categoryId', 'Please choose a ticket category.'); }
        if (evId != null && catId != null) {
            Ticket_Category__c cat = findBookableCategory(evId, catId);
            if (cat == null) {
                addError(errs, 'categoryId', 'This ticket category is not available for the selected event.');
            } else if (qtyOk) {
                Decimal available = cat.Available_Quantity__c == null ? 0 : cat.Available_Quantity__c;
                if (input.quantity > available) {
                    addError(errs, 'quantity', 'Only ' + available.intValue() + ' tickets are available in this category.');
                }
            }
        }
        if (!errs.isEmpty()) {
            res.message = 'Please correct the highlighted fields.';
            return res;
        }

        // Abuse limit: requests per email per 24 hours.
        Datetime cutoff = Datetime.now().addHours(-24);
        Integer recent = [SELECT COUNT() FROM Lead WHERE Email = :email AND CreatedDate >= :cutoff AND Request_Reference__c != null];
        if (recent >= TwinTicketConfig.maxRequestsPerEmailPerDay()) {
            System.debug(LoggingLevel.WARN, LOG + 'rate limit hit, recent=' + recent);
            addError(errs, 'email', 'We have received several requests from this email today. Please contact us if you need help.');
            res.message = 'Please correct the highlighted fields.';
            return res;
        }

        // Build the Lead from whitelisted, validated values ONLY.
        Integer sp = fullName.lastIndexOf(' ');
        String firstName = sp > 0 ? fullName.substring(0, sp).left(40) : null;
        String lastName = (sp > 0 ? fullName.substring(sp + 1) : fullName).left(80);
        String token = EncodingUtil.convertToHex(Crypto.generateAesKey(256));

        Lead lead = new Lead(
            FirstName = firstName,
            LastName = lastName,
            Company = String.isBlank(org) ? ('Individual - ' + fullName).left(255) : org,
            Email = email,
            Phone = phone,
            LeadSource = 'Web',
            Event_Detail__c = evId,
            Ticket_Category__c = catId,
            Requested_Quantity__c = input.quantity,
            Identity_Document_Type__c = docType,
            Identity_Number_Last_4__c = last4.toUpperCase(),
            Verification_Status__c = 'Pending',
            Submission_Complete__c = !TwinTicketConfig.documentsRequired(), 
            Upload_Token_Hash__c = hash(token),
            Upload_Token_Expires_On__c = Datetime.now().addMinutes(TOKEN_MINUTES)
        );
        Id queueId = reviewQueueId();
        if (queueId != null) { lead.OwnerId = queueId; }

        Database.DMLOptions opts = new Database.DMLOptions();
        opts.optAllOrNone = false;                    // return errors instead of throwing
        opts.DuplicateRuleHeader.allowSave = true;    // repeat buyers must not be blocked by duplicate rules
        if (queueId == null) { opts.AssignmentRuleHeader.useDefaultRule = true; }   // route via the active Lead Assignment Rule
        for (Integer attempt = 1; attempt <= 3; attempt++) {
            lead.Request_Reference__c = generateReference();
            Database.SaveResult sr = Database.insert(lead, opts);
            if (sr.isSuccess()) {
                res.success = true;
                res.reference = lead.Request_Reference__c;
                res.uploadToken = token; // shown only once, only to this browser
                System.debug(LoggingLevel.INFO, LOG + 'lead created ref=' + res.reference + ' qty=' + input.quantity);
                return res;
            }
            Boolean duplicateRef = false;
            for (Database.Error err : sr.getErrors()) {
                System.debug(LoggingLevel.WARN, LOG + 'insert attempt ' + attempt + ' failed: ' + err.getStatusCode() + ' - ' + err.getMessage());
                if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) { duplicateRef = true; }
            }
            if (!duplicateRef) { break; }
        }
        res.message = 'We could not save your request right now. Please try again in a few minutes.';
        return res;
    }

    // ---------- Step 2: attach one validated file ----------
    public static BulkRequestDto.StepResult uploadDocument(String reference, String token, String fileName, String base64Data) {
        Lead lead = authorize(reference, token);
        String ref = clean(reference).toUpperCase();

        Integer existing = [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :lead.Id];
        if (existing >= TwinTicketConfig.maxFiles()) {
            throw new RequestException('You can upload at most ' + TwinTicketConfig.maxFiles() + ' documents.');
        }
        String ext = extensionOf(fileName);
        if (!TwinTicketConfig.allowedExtensions().contains(ext)) {
            throw new RequestException('Only PDF, JPG or PNG files are accepted.');
        }
        Integer maxBytes = TwinTicketConfig.maxFileKb() * 1024;
        // Cheap size check BEFORE decoding, so a huge payload cannot exhaust memory.
        if (String.isBlank(base64Data) || base64Data.length() > ((maxBytes / 3) + 1) * 4 + 8) {
            throw new RequestException('This file is too large. The maximum size is ' + TwinTicketConfig.maxFileKb() + ' KB.');
        }
        Blob data;
        try {
            data = EncodingUtil.base64Decode(base64Data);
        } catch (Exception e) {
            throw new RequestException('This file could not be read. Please try another file.');
        }
        if (data.size() == 0 || data.size() > maxBytes) {
            throw new RequestException('This file is empty or too large. The maximum size is ' + TwinTicketConfig.maxFileKb() + ' KB.');
        }
        // Do not trust the file name or extension: check the real file signature.
        if (!matchesSignature(base64Data, ext)) {
            throw new RequestException('The file content does not match its type. Please upload a genuine PDF, JPG or PNG.');
        }

        // The browser's file name is NEVER stored. We name the file ourselves.
        String title = ref + '-ID-' + (existing + 1);
        ContentVersion cv = new ContentVersion(Title = title, PathOnClient = title + '.' + ext, VersionData = data, IsMajorVersion = true);
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].ContentDocumentId;
        // Visibility InternalUsers: portal and community users can NEVER see identity documents.
        insert new ContentDocumentLink(ContentDocumentId = docId, LinkedEntityId = lead.Id, ShareType = 'V', Visibility = 'InternalUsers');

        System.debug(LoggingLevel.INFO, LOG + 'document stored ref=' + ref + ' n=' + (existing + 1) + ' type=' + ext + ' bytes=' + data.size());
        BulkRequestDto.StepResult r = new BulkRequestDto.StepResult();
        r.success = true;
        r.message = 'Document uploaded.';
        r.fileCount = existing + 1;
        return r;
    }

    // ---------- Step 3: seal the request ----------
    public static BulkRequestDto.StepResult completeSubmission(String reference, String token) {
        Lead lead = authorize(reference, token);
        Integer files = [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :lead.Id];
        if (files < 1) {
            throw new RequestException('Please upload at least one identity document.');
        }
        lead.Submission_Complete__c = true;
        lead.Upload_Token_Hash__c = null;        // burn the token: it cannot be used again
        lead.Upload_Token_Expires_On__c = null;
        update lead;
        System.debug(LoggingLevel.INFO, LOG + 'submission completed ref=' + clean(reference).toUpperCase() + ' files=' + files);
        BulkRequestDto.StepResult r = new BulkRequestDto.StepResult();
        r.success = true;
        r.message = 'Request submitted.';
        r.fileCount = files;
        return r;
    }

    // ---------- Helpers ----------
    /** Proves the caller is the browser that created this request. One generic message for every failure (no oracle). */
    private static Lead authorize(String reference, String token) {
        String ref = clean(reference).toUpperCase();
        if (!REF_PATTERN.matcher(ref).matches() || String.isBlank(token) || token.length() > 128) {
            throw new RequestException(MSG_LINK_INVALID);
        }
        List<Lead> rows = [SELECT Id, Upload_Token_Hash__c, Upload_Token_Expires_On__c, Submission_Complete__c
                           FROM Lead WHERE Request_Reference__c = :ref LIMIT 1];
        Boolean valid = !rows.isEmpty() && rows[0].Submission_Complete__c != true
            && rows[0].Upload_Token_Hash__c != null && rows[0].Upload_Token_Expires_On__c != null
            && rows[0].Upload_Token_Expires_On__c > Datetime.now()
            && rows[0].Upload_Token_Hash__c.equals(hash(token)); // equals() is case-sensitive, unlike ==
        if (!valid) {
            System.debug(LoggingLevel.WARN, LOG + 'authorize failed for ref=' + ref
                + ' found=' + !rows.isEmpty()
                + (rows.isEmpty() ? '' : ' complete=' + rows[0].Submission_Complete__c
                    + ' hashNull=' + (rows[0].Upload_Token_Hash__c == null)
                    + ' expiresNull=' + (rows[0].Upload_Token_Expires_On__c == null)
                    + ' expired=' + (rows[0].Upload_Token_Expires_On__c != null && rows[0].Upload_Token_Expires_On__c <= Datetime.now())
                    + ' hashMatch=' + (rows[0].Upload_Token_Hash__c != null && rows[0].Upload_Token_Hash__c.equals(hash(token)))));
        }
        return rows[0];
    }

    private static Ticket_Category__c findBookableCategory(Id evId, Id catId) {
        Datetime nowTs = Datetime.now();
        List<Ticket_Category__c> rows = [
            SELECT Id, Available_Quantity__c FROM Ticket_Category__c
            WHERE Id = :catId AND Event_Detail__c = :evId
              AND Event_Detail__r.Status__c = 'Published' AND Event_Detail__r.Start_DateTime__c > :nowTs
            LIMIT 1];
        return rows.isEmpty() ? null : rows[0];
    }

    private static Id reviewQueueId() {
        try {
            List<Group> q = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :QUEUE_DEV_NAME LIMIT 1];
            return q.isEmpty() ? null : q[0].Id;
        } catch (Exception e) {
            // Guest users can never query Group. The Lead Assignment Rule routes the Lead instead.
            System.debug(LoggingLevel.INFO, LOG + 'queue lookup not available for this user, using the assignment rule');
            return null;
        }
    }

    @TestVisible
    private static String generateReference() {
        String suffix = '';
        for (Integer i = 0; i < 6; i++) {
            Integer idx = Math.mod(Crypto.getRandomInteger(), REF_ALPHABET.length());
            if (idx < 0) { idx += REF_ALPHABET.length(); }
            suffix += REF_ALPHABET.substring(idx, idx + 1);
        }
        return 'TT-' + Datetime.now().formatGmt('yyyyMMdd') + '-' + suffix;
    }

    private static String hash(String token) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(token)));
    }

    private static String clean(String s) { return s == null ? '' : s.normalizeSpace(); }

    private static void addError(List<BulkRequestDto.FieldError> errs, String field, String message) {
        errs.add(new BulkRequestDto.FieldError(field, message));
    }

    private static Boolean isValidDocType(String value) {
        for (BulkRequestDto.Option o : docTypeOptions()) {
            if (o.value == value) { return true; }
        }
        return false;
    }

    private static Id parseId(String raw, Schema.SObjectType expected) {
        if (String.isBlank(raw)) { return null; }
        try {
            Id parsed = Id.valueOf(raw.trim());
            return parsed.getSObjectType() == expected ? parsed : null;
        } catch (StringException e) {
            return null;
        }
    }

    private static String extensionOf(String fileName) {
        String n = clean(fileName);
        Integer dot = n.lastIndexOf('.');
        return (dot > 0 && dot < n.length() - 1) ? n.substring(dot + 1).toLowerCase() : '';
    }

    /** Looks at the first 12 bytes only (16 base64 characters), so it is cheap even for large files. */
    private static Boolean matchesSignature(String base64Data, String ext) {
        if (base64Data.length() < 16) { return false; }
        String hex;
        try {
            hex = EncodingUtil.convertToHex(EncodingUtil.base64Decode(base64Data.left(16))).toUpperCase();
        } catch (Exception e) {
            return false;
        }
        if (ext == 'pdf') { return hex.startsWith('25504446'); }               // %PDF
        if (ext == 'png') { return hex.startsWith('89504E470D0A1A0A'); }       // PNG header
        if (ext == 'jpg' || ext == 'jpeg') { return hex.startsWith('FFD8FF'); } // JPEG header
        return false;
    }
}