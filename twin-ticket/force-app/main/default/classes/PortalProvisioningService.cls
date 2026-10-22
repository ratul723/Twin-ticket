/**
 * Creates portal users for PAID purchases. Runs as the platform-event trigger's configured internal user.
 * SECURITY:
 *  - Never trusts an event: the purchase is re-read and must be Paid right now.
 *  - Idempotent: an existing user for the Contact is never duplicated, and no second welcome email is sent.
 *  - No passwords are ever created, stored, logged or emailed. Salesforce sends its own one-time set-password link.
 *  - Logs contain references, record ids and outcomes only, never emails or names.
 * Only SETUP objects (User, PermissionSetAssignment) are changed here. Logs are written by a Queueable afterwards.
 */
public without sharing class PortalProvisioningService {

    public class ProvisionResult {
        public Id purchaseId;
        public String outcome;      // CREATED | EXISTS | SKIPPED | FAILED
        public String detail;
    }

    public class PortalInfo {
        @AuraEnabled public String state;       // NOT_PAID | NONE | ACTIVE | INACTIVE
        @AuraEnabled public String username;
    }

    private static final String LOG = 'TT-PORTAL ';
    public static final String PERMISSION_SET = 'Twin_Ticket_Customer';
    private static final String corr = 'P' + String.valueOf(Math.abs(Crypto.getRandomLong()));
    @TestVisible private static List<ProvisionResult> lastResults = new List<ProvisionResult>();
    @TestVisible private static Integer emailsSent = 0;

    // ---------- publish ----------
    public static Boolean requestProvisioning(Id purchaseId) {
        try {
            Database.SaveResult sr = EventBus.publish(new Portal_Provision__e(Purchase_Id__c = String.valueOf(purchaseId)));
            if (!sr.isSuccess()) {
                IntegrationLogger.add('Salesforce', 'RequestPortalAccess', null, false, corr, 'Event publish refused', String.valueOf(purchaseId));
                return false;
            }
            return true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'requestProvisioning failed: ' + e.getTypeName());
            IntegrationLogger.add('Salesforce', 'RequestPortalAccess', null, false, corr, 'Event publish failed: ' + e.getTypeName(), String.valueOf(purchaseId));
            return false;
        }
    }

    // ---------- consume ----------
    public static void handleEvents(List<Portal_Provision__e> events) {
        lastResults = new List<ProvisionResult>();
        Set<Id> ids = new Set<Id>();
        for (Portal_Provision__e e : events) {
            Id pid = parseId(e.Purchase_Id__c);
            if (pid != null) { ids.add(pid); }
            else { System.debug(LoggingLevel.WARN, LOG + 'event with an invalid purchase id ignored'); }
        }
        if (ids.isEmpty()) { return; }

        Map<Id, Purchase__c> purchases = new Map<Id, Purchase__c>([
            SELECT Id, Name, Request_Reference__c, Payment_Status__c, Quantity__c, Total_Amount__c, Paid_On__c, Account__c, Contact__c,
                   Contact__r.FirstName, Contact__r.LastName, Contact__r.Email,
                   Event_Detail__r.Name, Event_Detail__r.Start_DateTime__c, Event_Detail__r.Time_Zone__c, Event_Detail__r.Venue_Name__c, Ticket_Category__r.Name
            FROM Purchase__c WHERE Id IN :ids]);

        Set<Id> contactIds = new Set<Id>();
        for (Purchase__c p : purchases.values()) { if (p.Contact__c != null) { contactIds.add(p.Contact__c); } }
        Map<Id, User> existing = new Map<Id, User>();
        for (User u : [SELECT Id, ContactId, IsActive, Username FROM User WHERE ContactId IN :contactIds]) { existing.put(u.ContactId, u); }

        List<Profile> profiles = [SELECT Id FROM Profile WHERE Name = :TwinTicketConfig.portalProfileName() LIMIT 1];
        List<PermissionSet> sets = [SELECT Id FROM PermissionSet WHERE Name = :PERMISSION_SET LIMIT 1];

        for (Id pid : ids) {
            Purchase__c p = purchases.get(pid);
            ProvisionResult r = new ProvisionResult();
            r.purchaseId = pid;
            try {
                if (p == null) { r.outcome = 'SKIPPED'; r.detail = 'Purchase not found'; }
                else { r = provisionOne(p, existing, profiles, sets); }
            } catch (Exception e) {
                r.outcome = 'FAILED';
                r.detail = 'Unexpected error: ' + e.getTypeName();
                System.debug(LoggingLevel.ERROR, LOG + 'provisionOne crashed: ' + e.getTypeName() + ' - ' + e.getMessage());
            }
            lastResults.add(r);
            IntegrationLogger.add('Salesforce', 'ProvisionPortalUser', null, r.outcome == 'CREATED' || r.outcome == 'EXISTS', corr,
                r.outcome + ': ' + r.detail, String.valueOf(pid));
        }
        List<Integration_Log__c> logs = IntegrationLogger.drain();
        if (!logs.isEmpty()) { System.enqueueJob(new PortalLogJob(logs)); }
    }

    private static ProvisionResult provisionOne(Purchase__c p, Map<Id, User> existing, List<Profile> profiles, List<PermissionSet> sets) {
        ProvisionResult r = new ProvisionResult();
        r.purchaseId = p.Id;
        if (!TwinTicketConfig.portalEnabled()) { r.outcome = 'SKIPPED'; r.detail = 'Portal provisioning is switched off'; return r; }
        // Never trust the event: the purchase must be Paid RIGHT NOW.
        if (p.Payment_Status__c != 'Paid') {
            System.debug(LoggingLevel.WARN, LOG + 'refused: purchase is not paid ref=' + p.Request_Reference__c);
            r.outcome = 'SKIPPED'; r.detail = 'Purchase is not paid'; return r;
        }
        String email = p.Contact__r == null ? null : p.Contact__r.Email;
        if (p.Contact__c == null || String.isBlank(email)) { r.outcome = 'FAILED'; r.detail = 'The buyer has no email address'; return r; }
        if (existing.containsKey(p.Contact__c)) { r.outcome = 'EXISTS'; r.detail = 'A portal user already exists for this contact'; return r; }
        if (profiles.isEmpty()) { r.outcome = 'FAILED'; r.detail = 'Profile "' + TwinTicketConfig.portalProfileName() + '" was not found'; return r; }
        if (sets.isEmpty()) { r.outcome = 'FAILED'; r.detail = 'Permission set ' + PERMISSION_SET + ' was not found'; return r; }

        String username = uniqueUsername(email);
        if (username == null) { r.outcome = 'FAILED'; r.detail = 'Could not generate a unique username'; return r; }

        String first = p.Contact__r.FirstName;
        String last = p.Contact__r.LastName;
        User u = new User(
            ContactId = p.Contact__c, ProfileId = profiles[0].Id, Username = username, Email = email,
            FirstName = first, LastName = last,
            Alias = ((String.isBlank(first) ? '' : first.left(1)) + last).left(5) + String.valueOf(Math.mod(Math.abs(Crypto.getRandomInteger()), 1000)),
            CommunityNickname = ('tt' + EncodingUtil.convertToHex(Crypto.generateAesKey(128))).left(40),
            TimeZoneSidKey = UserInfo.getTimeZone().getID(), LocaleSidKey = 'en_US', LanguageLocaleKey = 'en_US', EmailEncodingKey = 'UTF-8');
        try {
            insert u;
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = sets[0].Id);
        } catch (DmlException de) {
            // Typical causes: account owner has no role, no free license, profile not a member of the site.
            r.outcome = 'FAILED';
            r.detail = 'User could not be created: ' + de.getDmlStatusCode(0);
            System.debug(LoggingLevel.ERROR, LOG + 'user insert failed ref=' + p.Request_Reference__c + ' code=' + de.getDmlStatusCode(0));
            return r;
        }
        existing.put(p.Contact__c, u);

        String note = '';
        try {
            System.resetPassword(u.Id, true);       // Salesforce emails a secure link to set the password
        } catch (Exception e) {
            note += ' The set-password email could not be sent (' + e.getTypeName() + ').';
        }
        if (!sendWelcomeEmail(p, email, username)) { note += ' The confirmation email could not be sent.'; }
        r.outcome = 'CREATED';
        r.detail = 'Portal user created.' + note;
        System.debug(LoggingLevel.INFO, LOG + 'portal user created ref=' + p.Request_Reference__c);
        return r;
    }

    // ---------- staff support helpers ----------
    public static PortalInfo infoForPurchase(Id purchaseId) {
        PortalInfo info = new PortalInfo();
        List<Purchase__c> rows = [SELECT Payment_Status__c, Contact__c FROM Purchase__c WHERE Id = :purchaseId LIMIT 1];
        if (rows.isEmpty() || rows[0].Payment_Status__c != 'Paid') { info.state = 'NOT_PAID'; return info; }
        List<User> us = [SELECT Username, IsActive FROM User WHERE ContactId = :rows[0].Contact__c LIMIT 1];
        if (us.isEmpty()) { info.state = 'NONE'; return info; }
        info.state = us[0].IsActive ? 'ACTIVE' : 'INACTIVE';
        info.username = us[0].Username;
        return info;
    }

    public static Boolean resendPasswordEmail(Id purchaseId) {
        List<Purchase__c> rows = [SELECT Payment_Status__c, Contact__c FROM Purchase__c WHERE Id = :purchaseId LIMIT 1];
        if (rows.isEmpty() || rows[0].Payment_Status__c != 'Paid') { return false; }
        List<User> us = [SELECT Id FROM User WHERE ContactId = :rows[0].Contact__c AND IsActive = true LIMIT 1];
        if (us.isEmpty()) { return false; }
        try {
            System.resetPassword(us[0].Id, true);
            return true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'resend password email failed: ' + e.getTypeName());
            return false;
        }
    }

    // ---------- helpers ----------
    private static String uniqueUsername(String email) {
        String base = email.toLowerCase().trim() + '.tt';
        if (base.length() > 70) { return null; }
        Set<String> taken = new Set<String>();
        for (User u : [SELECT Username FROM User WHERE Username LIKE :(base + '%')]) { taken.add(u.Username.toLowerCase()); }
        if (!taken.contains(base)) { return base; }
        for (Integer i = 2; i <= 50; i++) {
            if (!taken.contains(base + i)) { return base + i; }
        }
        return null;
    }

    private static Boolean sendWelcomeEmail(Purchase__c p, String toAddress, String username) {
        if (Limits.getEmailInvocations() >= Limits.getLimitEmailInvocations()) { return false; }
        String login = TwinTicketConfig.portalLoginUrl();
        String targetDate = 'the event date';
        try {
            targetDate = p.Event_Detail__r.Start_DateTime__c.format('d MMM yyyy, HH:mm', String.isBlank(p.Event_Detail__r.Time_Zone__c) ? 'GMT' : p.Event_Detail__r.Time_Zone__c);
        } catch (Exception e) {
            targetDate = p.Event_Detail__r.Start_DateTime__c == null ? targetDate : p.Event_Detail__r.Start_DateTime__c.formatGmt('d MMM yyyy, HH:mm') + ' UTC';
        }
        String greeting = String.isBlank(p.Contact__r.FirstName) ? 'Hello' : 'Hello ' + p.Contact__r.FirstName;
        String summary = p.Quantity__c.intValue() + ' x ' + p.Ticket_Category__r.Name + ' for ' + p.Event_Detail__r.Name + ' (' + targetDate + ')';
        String total = TwinTicketConfig.paymentCurrency().toUpperCase() + ' ' + p.Total_Amount__c.setScale(2).format();

        String text = greeting + ',\n\nWe have received your payment. Thank you!\n\n' + summary + '\nTotal paid: ' + total
            + '\nReference: ' + p.Request_Reference__c + '\n\nYour secure customer portal is ready.\n'
            + 'Your username: ' + username + '\n'
            + 'Salesforce is sending you a SEPARATE email with a secure link to set your password. Use it once, then sign in here:\n'
            + login + '\n\nIn the portal you can view your purchase and download your confirmation. Twin Ticket will never ask for your password by email.\n\nTwin Ticket';

        String html = '<div style="font-family:Arial,sans-serif;max-width:560px;margin:0 auto;color:#111827;line-height:1.5">'
            + '<h2 style="color:#3b2a8c;margin-bottom:4px">Payment received</h2>'
            + '<p>' + greeting.escapeHtml4() + ', thank you!</p>'
            + '<table style="width:100%;border-collapse:collapse;margin:16px 0"><tr><td style="padding:10px;background:#f3f0ff">'
            + '<div style="font-weight:bold">' + summary.escapeHtml4() + '</div>'
            + '<div style="font-size:20px;font-weight:bold;color:#3b2a8c;margin-top:6px">' + total.escapeHtml4() + '</div>'
            + '<div style="color:#6b7280;font-size:13px">Reference ' + p.Request_Reference__c.escapeHtml4() + '</div></td></tr></table>'
            + '<p><strong>Your secure customer portal is ready.</strong><br/>Username: <strong>' + username.escapeHtml4() + '</strong></p>'
            + '<p>Salesforce is sending you a <strong>separate email</strong> with a secure link to set your password. Use it once, then sign in:</p>'
            + '<p><a href="' + login.escapeHtml4() + '" style="display:inline-block;background:#3b2a8c;color:#ffffff;padding:12px 24px;text-decoration:none;font-weight:bold">Open the portal</a></p>'
            + '<p style="font-size:13px;color:#6b7280">In the portal you can view your purchase and download your confirmation. Twin Ticket will never ask for your password by email.</p></div>';

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ toAddress });
        mail.setSubject('Payment received - Twin Ticket (' + p.Request_Reference__c + ')');
        mail.setPlainTextBody(text);
        mail.setHtmlBody(html);
        mail.setSaveAsActivity(false);
        mail.setSenderDisplayName('Twin Ticket');
        List<Messaging.SendEmailResult> results = Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail }, false);
        Boolean ok = !results.isEmpty() && results[0].isSuccess();
        if (ok) { emailsSent++; }
        return ok;
    }

    private static Id parseId(String raw) {
        if (String.isBlank(raw)) { return null; }
        try {
            Id parsed = Id.valueOf(raw.trim());
            return parsed.getSObjectType() == Purchase__c.SObjectType ? parsed : null;
        } catch (StringException e) {
            return null;
        }
    }
}