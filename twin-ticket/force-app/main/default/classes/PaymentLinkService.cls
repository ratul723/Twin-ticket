/**
 * Creates the payment link and emails it. SECURITY:
 *  - The token is 256 random bits. Only its SHA-256 HASH is stored, and it expires.
 *  - Issuing a new link replaces the hash, so every older link stops working.
 *  - The email is NOT saved as an activity, so the raw token is not kept in any record.
 *  - A failed email never throws. The caller is told and can resend, or copy the link once.
 */
public without sharing class PaymentLinkService {

    public class SendResult {
        @AuraEnabled public Boolean success = false;
        @AuraEnabled public Boolean emailSent = false;
        @AuraEnabled public String message;
        @AuraEnabled public String link;           // filled ONLY targetDate the email could not be sent
        @AuraEnabled public Datetime expiresOn;
    }

    private static final String LOG = 'TT-LINK ';
    @TestVisible private static Integer emailsSent = 0;
    @TestVisible private static String lastIssuedToken;   // memory only, never persisted

    public static String hash(String token) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(token)));
    }

    public static SendResult issueAndSend(Id purchaseId) {
        SendResult res = new SendResult();
        Purchase__c p = PaymentService.loadById(purchaseId);
        if (p == null) { res.message = 'The purchase could not be found.'; return res; }
        if (p.Payment_Status__c == 'Paid') { res.message = 'This purchase is already paid.'; return res; }
        if (!TwinTicketConfig.paymentsEnabled()) { res.message = 'Payments are switched off in the configuration.'; return res; }
        String base = TwinTicketConfig.siteBaseUrl();
        if (String.isBlank(base)) { res.message = 'The site URL is not configured, so no link can be created.'; return res; }
        String email = p.Contact__r == null ? null : p.Contact__r.Email;
        if (String.isBlank(email)) { res.message = 'The buyer has no email address on file.'; return res; }

        String token = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
        Datetime expires = Datetime.now().addHours(TwinTicketConfig.paymentTokenHours());
        update new Purchase__c(Id = p.Id, Token_Hash__c = hash(token), Token_Expires_On__c = expires);
        lastIssuedToken = token;

        String link = base + '/pay?c__ref=' + EncodingUtil.urlEncode(p.Request_Reference__c, 'UTF-8') + '&c__t=' + token;
        Boolean sent = sendEmail(p, email, link, expires);

        res.success = true;
        res.emailSent = sent;
        res.expiresOn = expires;
        if (sent) {
            res.message = 'The payment link was emailed to the buyer.';
        } else {
            res.message = 'The link was created but the email could not be sent. Copy it now and send it to the buyer manually.';
            res.link = link;
        }
        System.debug(LoggingLevel.INFO, LOG + 'link issued ref=' + p.Request_Reference__c + ' emailed=' + sent);
        return res;
    }

    private static Boolean sendEmail(Purchase__c p, String toAddress, String link, Datetime expires) {
        if (Limits.getEmailInvocations() >= Limits.getLimitEmailInvocations()) { return false; }
        String greeting = String.isBlank(p.Contact__r.FirstName) ? 'Hello' : 'Hello ' + p.Contact__r.FirstName;
        String total = TwinTicketConfig.paymentCurrency().toUpperCase() + ' ' + p.Total_Amount__c.setScale(2).format();
        String targetDate = expires.formatGmt('d MMM yyyy HH:mm') + ' UTC';
        String summary = p.Quantity__c.intValue() + ' x ' + p.Ticket_Category__r.Name + ' for ' + p.Event_Detail__r.Name;

        String text = greeting + ',\n\nYour bulk ticket request ' + p.Request_Reference__c + ' has been approved.\n\n'
            + summary + '\nTotal: ' + total + '\n\nPay securely here:\n' + link + '\n\nThis link expires on ' + targetDate
            + '. If you did not request tickets from Twin Ticket, you can ignore this email.\n\nTwin Ticket';

        String html = '<div style="font-family:Arial,sans-serif;max-width:560px;margin:0 auto;color:#111827;line-height:1.5">'
            + '<h2 style="color:#3b2a8c;margin-bottom:4px">Your request is approved</h2>'
            + '<p>' + greeting.escapeHtml4() + ',</p>'
            + '<p>Your bulk ticket request <strong>' + p.Request_Reference__c.escapeHtml4() + '</strong> has been approved.</p>'
            + '<table style="width:100%;border-collapse:collapse;margin:16px 0"><tr><td style="padding:10px;background:#f3f0ff;border-radius:8px">'
            + '<div style="font-weight:bold">' + summary.escapeHtml4() + '</div>'
            + '<div style="font-size:22px;font-weight:bold;color:#3b2a8c;margin-top:6px">' + total.escapeHtml4() + '</div></td></tr></table>'
            + '<p><a href="' + link.escapeHtml4() + '" style="display:inline-block;background:#3b2a8c;color:#ffffff;padding:12px 24px;'
            + 'border-radius:8px;text-decoration:none;font-weight:bold">Pay securely</a></p>'
            + '<p style="font-size:13px;color:#6b7280">This link expires on ' + targetDate.escapeHtml4() + '. If you did not request tickets from Twin Ticket, '
            + 'you can ignore this email.</p></div>';

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ toAddress });
        mail.setSubject('Complete your Twin Ticket payment (' + p.Request_Reference__c + ')');
        mail.setPlainTextBody(text);
        mail.setHtmlBody(html);
        mail.setSaveAsActivity(false);
        mail.setSenderDisplayName('Twin Ticket');
        mail.setReplyTo(UserInfo.getUserEmail());
        List<Messaging.SendEmailResult> results = Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail }, false);
        Boolean ok = !results.isEmpty() && results[0].isSuccess();
        if (ok) { emailsSent++; }
        return ok;
    }
}