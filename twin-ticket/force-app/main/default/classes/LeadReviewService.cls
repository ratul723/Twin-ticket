/**
 * Staff review logic: decisions, state machine, and Lead conversion.
 * SECURITY: 'with sharing'. Reads use WITH USER_MODE and writes use 'as user', so the reviewer's own
 * record access, CRUD and field-level security apply. The Custom Permission is checked on every decision.
 * Logs contain references and record Ids only, never names, emails, notes or document content.
 */
public with sharing class LeadReviewService {

    public class ReviewException extends Exception {}

    private static final String LOG = 'TT-REVIEW ';
    public static final String PERMISSION = 'Review_Bulk_Requests';
    private static final Integer NOTES_FIELD_MAX = 5000;
    @TestVisible private static Integer emailsSent = 0;

    private static final Map<String, String> TARGET_STATUS = new Map<String, String>{
        'APPROVE' => 'Approved', 'REJECT' => 'Rejected',
        'REQUEST_INFO' => 'Additional Information Required', 'RETURN_TO_PENDING' => 'Pending'
    };
    private static final Map<String, Set<String>> ALLOWED = new Map<String, Set<String>>{
        'Pending' => new Set<String>{ 'APPROVE', 'REJECT', 'REQUEST_INFO' },
        'Additional Information Required' => new Set<String>{ 'APPROVE', 'REJECT', 'RETURN_TO_PENDING' }
    };

    public static Boolean canReview() {
        return FeatureManagement.checkPermission(PERMISSION);
    }

    // ---------- Read model for the review panel ----------
    public static LeadReviewDto.ReviewData getReviewData(Id leadId) {
        Lead l = loadLead(leadId);
        LeadReviewDto.ReviewData d = new LeadReviewDto.ReviewData();
        d.leadId = l.Id;
        d.reference = l.Request_Reference__c;
        d.status = l.Verification_Status__c;
        d.isConverted = l.IsConverted;
        d.submissionComplete = l.Submission_Complete__c == true;
        d.buyerName = ((String.isBlank(l.FirstName) ? '' : l.FirstName + ' ') + l.LastName).trim();
        d.email = l.Email;
        d.phone = l.Phone;
        d.organization = l.Company;
        d.eventName = l.Event_Detail__r.Name;
        d.eventStart = l.Event_Detail__r.Start_DateTime__c;
        d.venue = l.Event_Detail__r.Venue_Name__c;
        d.categoryName = l.Ticket_Category__r.Name;
        d.quantity = l.Requested_Quantity__c == null ? null : l.Requested_Quantity__c.intValue();
        d.unitPrice = l.Ticket_Category__r.Price__c;
        d.estimatedTotal = totalFor(l);
        d.availableNow = l.Ticket_Category__r.Available_Quantity__c;
        d.docType = l.Identity_Document_Type__c;
        d.last4 = l.Identity_Number_Last_4__c;
        d.notes = l.Review_Notes__c;
        d.reviewedBy = l.Reviewed_By__r.Name;
        d.reviewedOn = l.Reviewed_On__c;
        d.canDecide = canReview();
        d.files = loadFiles(l.Id);

        if (l.IsConverted) {
            d.accountId = l.ConvertedAccountId;
            d.contactId = l.ConvertedContactId;
            d.opportunityId = l.ConvertedOpportunityId;
            List<Purchase__c> p = [SELECT Id FROM Purchase__c WHERE Opportunity__c = :l.ConvertedOpportunityId WITH USER_MODE LIMIT 1];
            d.purchaseId = p.isEmpty() ? null : p[0].Id;
        } else {
            d.blockers = approvalBlockers(l, d.files.size());
            d.actions = actionsFor(l, d.canDecide, d.blockers.isEmpty());
        }
        System.debug(LoggingLevel.INFO, LOG + 'review data loaded ref=' + d.reference + ' status=' + d.status
            + ' files=' + d.files.size() + ' blockers=' + d.blockers.size());
        return d;
    }

    // ---------- Decisions ----------
    public static LeadReviewDto.DecisionResult submitDecision(Id leadId, String decision, String notes, String buyerMessage) {
        if (!canReview()) {
            System.debug(LoggingLevel.WARN, LOG + 'decision refused: missing permission');
            throw new ReviewException('You do not have permission to review requests.');
        }
        String action = decision == null ? '' : decision.trim().toUpperCase();
        if (!TARGET_STATUS.containsKey(action)) {
            throw new ReviewException('Please choose a valid action.');
        }
        String note = notes == null ? '' : notes.trim();
        if (note.length() < 5 || note.length() > 2000) {
            throw new ReviewException('Review notes are required (5 to 2000 characters).');
        }
        Lead l = loadLead(leadId);
        if (l.IsConverted) {
            throw new ReviewException('This request has already been processed.');
        }
        Set<String> allowed = ALLOWED.get(l.Verification_Status__c);
        if (allowed == null) {
            throw new ReviewException('This request is closed and can no longer be changed.');
        }
        if (!allowed.contains(action)) {
            throw new ReviewException('That action is not available for a request with status "' + l.Verification_Status__c + '".');
        }
        String message = buyerMessage == null ? '' : buyerMessage.trim();
        if (action == 'REQUEST_INFO' && (message.length() < 10 || message.length() > 1000)) {
            throw new ReviewException('Please write the message to the buyer (10 to 1000 characters).');
        }

        LeadReviewDto.DecisionResult result = new LeadReviewDto.DecisionResult();
        if (action == 'APPROVE') {
            List<String> blockers = approvalBlockers(l, countFiles(l.Id));
            if (!blockers.isEmpty()) {
                throw new ReviewException('Cannot approve: ' + blockers[0]);
            }
            approveAndConvert(l, note, result);
            result.message = 'Approved and converted. The Account, Contact, Opportunity and purchase record are ready.';
            // The approval is already saved. Sending the payment link must NEVER be able to undo it.
            try {
                PaymentLinkService.SendResult sent = PaymentLinkService.issueAndSend(result.purchaseId);
                result.message += sent.emailSent
                    ? ' The payment link was emailed to the buyer.'
                    : ' The payment link could not be emailed. Open the purchase and use "Send payment link".';
            } catch (Exception linkError) {
                System.debug(LoggingLevel.ERROR, LOG + 'payment link step failed: ' + linkError.getTypeName() + ' - ' + linkError.getMessage());
                result.message += ' The payment link could not be created. Open the purchase and use "Send payment link".';
            }
        } else {
            String logged = action == 'REQUEST_INFO' ? note + ' | Message to buyer: ' + message : note;
            Lead upd = new Lead(Id = l.Id,
                Verification_Status__c = TARGET_STATUS.get(action),
                Review_Notes__c = appendNote(l.Review_Notes__c, action, logged),
                Reviewed_By__c = UserInfo.getUserId(),
                Reviewed_On__c = Datetime.now());
            update as user upd;
            result.message = 'Status updated to "' + TARGET_STATUS.get(action) + '".';
            // Email only AFTER the database change succeeded. Email failure never undoes a decision.
            if (action == 'REJECT' || action == 'REQUEST_INFO') {
                Boolean sent = notifyBuyer(l, action, message);
                if (!sent) { result.message += ' The email to the buyer could not be sent, so please contact them directly.'; }
            }
        }
        result.success = true;
        System.debug(LoggingLevel.INFO, LOG + 'decision ' + action + ' applied ref=' + l.Request_Reference__c);
        return result;
    }

    // ---------- Conversion: all or nothing ----------
    private static void approveAndConvert(Lead l, String note, LeadReviewDto.DecisionResult result) {
        Decimal total = totalFor(l);
        Decimal unitPrice = l.Ticket_Category__r.Price__c;
        Integer qty = l.Requested_Quantity__c.intValue();
        Savepoint sp = Database.setSavepoint();
        try {
            // 1. Record the decision first, so the Lead is Approved when the conversion rule runs.
            Lead upd = new Lead(Id = l.Id,
                Verification_Status__c = 'Approved',
                Review_Notes__c = appendNote(l.Review_Notes__c, 'APPROVE', note),
                Reviewed_By__c = UserInfo.getUserId(),
                Reviewed_On__c = Datetime.now());
            update as user upd;

            // 2. Convert. ALWAYS a new Account and Contact (no auto-matching), so portal sharing can never mix customers.
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(l.Id);
            lc.setConvertedStatus(convertedStatus());
            lc.setDoNotCreateOpportunity(false);
            lc.setOpportunityName((l.Request_Reference__c + ' | ' + l.Event_Detail__r.Name + ' | ' + qty + ' tickets').left(120));
            lc.setOwnerId(UserInfo.getUserId());
            Database.DMLOptions dmo = new Database.DMLOptions();
            dmo.DuplicateRuleHeader.allowSave = true;
            Database.LeadConvertResult lcr = Database.convertLead(lc, dmo);
            if (!lcr.isSuccess()) {
                for (Database.Error err : lcr.getErrors()) {
                    System.debug(LoggingLevel.ERROR, LOG + 'convert failed: ' + err.getStatusCode() + ' ' + err.getMessage());
                }
                throw new ReviewException('The request could not be converted. No changes were saved. Please check the Lead and try again.');
            }

            // 3. Complete the Opportunity: purchase details come from the DATABASE, never from the browser.
            update as user new Opportunity(
                Id = lcr.getOpportunityId(),
                StageName = 'Awaiting Payment',
                CloseDate = Date.today().addDays(7),
                Amount = total,
                Event_Detail__c = l.Event_Detail__c,
                Ticket_Category__c = l.Ticket_Category__c,
                Requested_Quantity__c = qty,
                Unit_Price__c = unitPrice,
                Request_Reference__c = l.Request_Reference__c);

            // 4. The customer-facing purchase record. Unique Request_Reference__c makes a second conversion fail and roll back.
            Purchase__c purchase = new Purchase__c(
                Account__c = lcr.getAccountId(),
                Contact__c = lcr.getContactId(),
                Opportunity__c = lcr.getOpportunityId(),
                Event_Detail__c = l.Event_Detail__c,
                Ticket_Category__c = l.Ticket_Category__c,
                Quantity__c = qty,
                Unit_Price__c = unitPrice,
                Total_Amount__c = total,
                Payment_Status__c = 'Awaiting Payment',
                Request_Reference__c = l.Request_Reference__c);
            insert as user purchase;

            result.accountId = lcr.getAccountId();
            result.contactId = lcr.getContactId();
            result.opportunityId = lcr.getOpportunityId();
            result.purchaseId = purchase.Id;
            System.debug(LoggingLevel.INFO, LOG + 'converted ref=' + l.Request_Reference__c + ' opp=' + result.opportunityId
                + ' purchase=' + result.purchaseId);
        } catch (Exception e) {
            Database.rollback(sp);
            System.debug(LoggingLevel.ERROR, LOG + 'approve failed, rolled back: ' + e.getTypeName() + ' - ' + e.getMessage());
            if (e instanceof ReviewException) { throw e; }
            throw new ReviewException('The request could not be approved. No changes were saved. Please try again or contact an administrator.');
        }
    }

    // ---------- Helpers ----------
    private static Lead loadLead(Id leadId) {
        if (leadId == null || leadId.getSObjectType() != Lead.SObjectType) {
            throw new ReviewException('This request could not be loaded.');
        }
        List<Lead> rows = [
        SELECT Id, FirstName, LastName, Company, Email, Phone, 
               Request_Reference__c, Verification_Status__c, Review_Notes__c, 
               Reviewed_By__r.Name, Reviewed_On__c, Submission_Complete__c, 
               IsConverted, ConvertedAccountId, ConvertedContactId, ConvertedOpportunityId,
               Event_Detail__c, Event_Detail__r.Name, Event_Detail__r.Status__c, 
               Event_Detail__r.Start_DateTime__c, Event_Detail__r.Venue_Name__c,
               Ticket_Category__c, Ticket_Category__r.Name, Ticket_Category__r.Price__c, 
               Ticket_Category__r.Available_Quantity__c,
               Requested_Quantity__c, Identity_Document_Type__c, Identity_Number_Last_4__c
        FROM Lead 
        WHERE Id = :leadId 
        WITH USER_MODE 
        LIMIT 1
    ];
        if (rows.isEmpty()) {
            throw new ReviewException('This request could not be loaded.');
        }
        return rows[0];
    }

    private static List<LeadReviewDto.FileDto> loadFiles(Id leadId) {
        List<LeadReviewDto.FileDto> out = new List<LeadReviewDto.FileDto>();
        for (ContentDocumentLink cdl : [
                SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension, ContentDocument.ContentSize
                FROM ContentDocumentLink WHERE LinkedEntityId = :leadId WITH USER_MODE
                ORDER BY ContentDocument.CreatedDate ASC]) {
            LeadReviewDto.FileDto f = new LeadReviewDto.FileDto();
            f.documentId = cdl.ContentDocumentId;
            f.title = cdl.ContentDocument.Title;
            f.extension = cdl.ContentDocument.FileExtension;
            f.sizeKb = Math.max(1, ((cdl.ContentDocument.ContentSize == null ? 0 : cdl.ContentDocument.ContentSize) / 1024));
            out.add(f);
        }
        return out;
    }

    private static Integer countFiles(Id leadId) {
        return [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :leadId WITH USER_MODE];
    }

    /** Everything that must be true BEFORE we may approve. Checked again at the moment of approval. */
    private static List<String> approvalBlockers(Lead l, Integer fileCount) {
        List<String> b = new List<String>();
        if (l.Submission_Complete__c != true) { b.add('the buyer has not finished submitting their request.'); }
        if (fileCount < 1) { b.add('no identity documents are attached.'); }
        if (l.Event_Detail__c == null || l.Event_Detail__r.Status__c != 'Published') { b.add('the event is no longer published.'); }
        else if (l.Event_Detail__r.Start_DateTime__c != null && l.Event_Detail__r.Start_DateTime__c <= Datetime.now()) { b.add('the event has already started.'); }
        if (l.Ticket_Category__c == null || l.Ticket_Category__r.Price__c == null || l.Ticket_Category__r.Price__c <= 0) {
            b.add('the ticket category has no valid price.');
        }
        Integer qty = l.Requested_Quantity__c == null ? 0 : l.Requested_Quantity__c.intValue();
        if (qty < 1) { b.add('the requested quantity is missing.'); }
        else if (l.Ticket_Category__c != null) {
            Decimal avail = l.Ticket_Category__r.Available_Quantity__c == null ? 0 : l.Ticket_Category__r.Available_Quantity__c;
            if (avail < qty) { b.add('only ' + avail.intValue() + ' tickets are available (requested ' + qty + ').'); }
        }
        return b;
    }

    private static List<LeadReviewDto.ActionOption> actionsFor(Lead l, Boolean canDecide, Boolean approveOk) {
        List<LeadReviewDto.ActionOption> out = new List<LeadReviewDto.ActionOption>();
        Set<String> allowed = ALLOWED.get(l.Verification_Status__c);
        if (!canDecide || allowed == null) { return out; }
        if (allowed.contains('APPROVE') && approveOk) {
            out.add(new LeadReviewDto.ActionOption('APPROVE', 'Approve and convert',
                'Creates the Account, Contact, Opportunity and purchase record from the stored ticket price.'));
        }
        if (allowed.contains('REQUEST_INFO')) {
            out.add(new LeadReviewDto.ActionOption('REQUEST_INFO', 'Request more information',
                'Emails your message to the buyer. Internal notes are never sent.'));
        }
        if (allowed.contains('RETURN_TO_PENDING')) {
            out.add(new LeadReviewDto.ActionOption('RETURN_TO_PENDING', 'Return to pending',
                'Use after the buyer has replied and you are ready to review again.'));
        }
        if (allowed.contains('REJECT')) {
            out.add(new LeadReviewDto.ActionOption('REJECT', 'Reject request',
                'Final. The buyer receives a neutral email without your notes.'));
        }
        return out;
    }

    private static Decimal totalFor(Lead l) {
        if (l.Ticket_Category__c == null || l.Ticket_Category__r.Price__c == null || l.Requested_Quantity__c == null) { return null; }
        return (l.Ticket_Category__r.Price__c * l.Requested_Quantity__c).setScale(2, RoundingMode.HALF_UP);
    }

    private static String convertedStatus() {
        List<LeadStatus> s = [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1];
        if (s.isEmpty()) { throw new ReviewException('Lead conversion is not configured. Please contact an administrator.'); }
        return s[0].MasterLabel;
    }

    private static String appendNote(String existing, String action, String note) {
        String entry = Datetime.now().formatGmt('yyyy-MM-dd HH:mm') + ' UTC | ' + UserInfo.getName() + ' | ' + action + ': ' + note;
        String combined = String.isBlank(existing) ? entry : existing + '\n' + entry;
        if (combined.length() > NOTES_FIELD_MAX) {
            throw new ReviewException('The review notes are full. Please shorten your note or contact an administrator.');
        }
        return combined;
    }

    private static Boolean notifyBuyer(Lead l, String action, String staffMessage) {
        if (String.isBlank(l.Email)) { return false; }
        String greeting = 'Hello' + (String.isBlank(l.FirstName) ? '' : ' ' + l.FirstName) + ',\n\n';
        String body;
        String subject = 'Update on your Twin Ticket request ' + l.Request_Reference__c;
        if (action == 'REJECT') {
            body = greeting + 'Thank you for your interest. After review, we are unable to approve your bulk ticket request '
                + l.Request_Reference__c + '. If you believe this is a mistake, please reply to this email quoting your reference.\n\nTwin Ticket';
        } else {
            body = greeting + 'We need a little more information to continue with your bulk ticket request '
                + l.Request_Reference__c + ':\n\n' + staffMessage + '\n\nPlease reply to this email. We will continue the review as soon as we hear from you.\n\nTwin Ticket';
        }
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ l.Email });
        mail.setSubject(subject);
        mail.setPlainTextBody(body);
        mail.setSaveAsActivity(false);
        mail.setReplyTo(UserInfo.getUserEmail());
        mail.setSenderDisplayName('Twin Ticket');
        List<Messaging.SendEmailResult> results = Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail }, false);
        Boolean ok = !results.isEmpty() && results[0].isSuccess();
        if (ok) { emailsSent++; }
        System.debug(LoggingLevel.INFO, LOG + 'buyer email ' + (ok ? 'sent' : 'FAILED') + ' ref=' + l.Request_Reference__c);
        return ok;
    }
}