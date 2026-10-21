/**
 * Server-side payment logic. Runs in system mode for the GUEST payment page, because guests have no object access.
 * That is safe because EVERY entry point first proves the caller holds a valid, unexpired token for exactly one purchase.
 * RULES: the amount is always recomputed from stored purchase data. Browser redirects are hints, never proof.
 * ORDER: callouts first, database changes last (Apex forbids a callout after uncommitted DML).
 * Logs contain references, ids and statuses only.
 */
public without sharing class PaymentService {

    public class PaymentException extends Exception {}

    private static final String LOG = 'TT-PAY ';
    private static final Pattern REF_PATTERN = Pattern.compile('^TT-[0-9]{8}-[A-HJ-NP-Z2-9]{6}$');
    private static final Pattern SESSION_PATTERN = Pattern.compile('^cs_(test|live)_[A-Za-z0-9]{10,200}$');
    private static final Set<String> OPEN_STATUSES = new Set<String>{ 'Created', 'Pending' };
    private static final String corr = 'C' + String.valueOf(Math.abs(Crypto.getRandomLong()));

    @TestVisible private static final String MSG_INVALID_LINK =
        'This payment link is not valid or has expired. Please contact Twin Ticket for a new link.';
    @TestVisible public static final String MSG_UNAVAILABLE = 'Payments are temporarily unavailable. Please try again in a few minutes.';
    @TestVisible private static final String MSG_BUSY = 'Your payment is being prepared. Please try again in a moment.';
    @TestVisible private static final String MSG_NOT_MATCHED = 'We could not match this payment to your purchase.';
    @TestVisible private static final String MSG_PAID = 'Payment received. Thank you!';
    @TestVisible private static final String MSG_RECORDING =
        'We received your payment but could not finish recording it. Please do not pay again. Our team will confirm it shortly.';

    public static final String PURCHASE_FIELDS =
        'Id, Name, Request_Reference__c, Payment_Status__c, Quantity__c, Unit_Price__c, Total_Amount__c, '
        + 'Token_Hash__c, Token_Expires_On__c, Opportunity__c, Contact__c, Contact__r.Email, Contact__r.FirstName, '
        + 'Event_Detail__c, Event_Detail__r.Name, Event_Detail__r.Status__c, Event_Detail__r.Start_DateTime__c, Event_Detail__r.Venue_Name__c, '
        + 'Ticket_Category__c, Ticket_Category__r.Name, Ticket_Category__r.Available_Quantity__c';

    private class SessionView {
        String id;
        String status;
        String paymentStatus;
        String currencyCode;
        String clientRef;
        String paymentIntent;
        String url;
        Long amountTotal;
    }

    // =====================================================================
    // Entry points
    // =====================================================================

    public static PaymentDto.Context getContext(String reference, String token) {
        Purchase__c p = authorize(reference, token);
        PaymentDto.Context c = new PaymentDto.Context();
        c.valid = true;
        c.reference = p.Request_Reference__c;
        c.eventName = p.Event_Detail__r.Name;
        c.eventStart = p.Event_Detail__r.Start_DateTime__c;
        c.venue = p.Event_Detail__r.Venue_Name__c;
        c.categoryName = p.Ticket_Category__r.Name;
        c.quantity = p.Quantity__c == null ? null : p.Quantity__c.intValue();
        c.amount = p.Total_Amount__c;
        c.currencyCode = TwinTicketConfig.paymentCurrency().toUpperCase();
        if (p.Payment_Status__c == 'Paid') {
            c.state = 'PAID';
        } else if (!TwinTicketConfig.paymentsEnabled()) {
            c.state = 'UNAVAILABLE';
            c.message = MSG_UNAVAILABLE;
        } else {
            c.state = 'PAYABLE';
        }
        return c;
    }

    public static PaymentDto.StartResult startPayment(String reference, String token) {
        PaymentDto.StartResult out = new PaymentDto.StartResult();
        try {
            Purchase__c p = authorize(reference, token);
            requirePayable(p);

            // The amount comes from STORED purchase data and is cross-checked. There is no amount parameter anywhere.
            Integer qty = p.Quantity__c.intValue();
            Long unitCents = toCents(p.Unit_Price__c);
            Long totalCents = unitCents * qty;
            if (unitCents <= 0 || qty < 1 || toCents(p.Total_Amount__c) != totalCents) {
                System.debug(LoggingLevel.ERROR, LOG + 'stored amount does not match price x quantity, ref=' + p.Request_Reference__c);
                throw new PaymentException(MSG_UNAVAILABLE);
            }
            String cur = TwinTicketConfig.paymentCurrency();

            // ---------- PHASE A: callouts only. Learn the real state of every open attempt. ----------
            List<Ticket_Payment__c> openAttempts = [
                SELECT Id, Status__c, Provider_Order_Id__c, Amount__c, Currency_Code__c
                FROM Ticket_Payment__c WHERE Purchase__c = :p.Id AND Status__c IN :OPEN_STATUSES ORDER BY CreatedDate DESC];
            Integer allAttempts = [SELECT COUNT() FROM Ticket_Payment__c WHERE Purchase__c = :p.Id];

            Map<Id, SessionView> views = new Map<Id, SessionView>();
            for (Ticket_Payment__c a : openAttempts) {
                StripeClient.StripeResponse r = StripeClient.getCheckoutSession(a.Provider_Order_Id__c);
                logCall('GetCheckoutSession', r, p.Id);
                if (!r.ok()) { throw new PaymentException(MSG_UNAVAILABLE); } // never open a second session while unsure
                views.put(a.Id, toView(r.body));
            }

            Ticket_Payment__c paidAttempt;
            SessionView paidView;
            Ticket_Payment__c reuse;
            SessionView reuseView;
            Map<Id, String> closeAs = new Map<Id, String>();
            for (Ticket_Payment__c a : openAttempts) {
                SessionView v = views.get(a.Id);
                if (v.status == 'complete' && v.paymentStatus == 'paid') {
                    if (paidAttempt == null) { paidAttempt = a; paidView = v; }
                } else if (v.status == 'open' && reuse == null && v.url != null
                           && v.amountTotal == totalCents && cur.equalsIgnoreCase(v.currencyCode)) {
                    reuse = a;
                    reuseView = v;
                } else if (v.status == 'open') {
                    // stale (price or currency changed) or an extra open session: close it so it can never be paid
                    StripeClient.StripeResponse er = StripeClient.expireCheckoutSession(a.Provider_Order_Id__c);
                    logCall('ExpireCheckoutSession', er, p.Id);
                    closeAs.put(a.Id, 'Cancelled');
                } else {
                    closeAs.put(a.Id, 'Cancelled'); // expired, or finished without payment
                }
            }

            if (paidAttempt != null) {
                // ---------- PHASE B: database only ----------
                applyClosures(closeAs, 'Session no longer open');
                PaymentDto.VerifyResult vr = applyOutcome(p, paidAttempt, paidView);
                out.alreadyPaid = vr.outcome == 'PAID';
                out.message = vr.message;
                return out;
            }
            if (reuse != null) {
                applyClosures(closeAs, 'Session no longer open');
                out.success = true;
                out.checkoutUrl = reuseView.url;
                System.debug(LoggingLevel.INFO, LOG + 'reusing open session for ref=' + p.Request_Reference__c);
                return out;
            }

            Integer attemptNo = allAttempts + 1;
            String idemKey = 'TT-' + p.Id + '-' + attemptNo;
            StripeClient.StripeResponse cr = StripeClient.createCheckoutSession(
                buildSessionParams(p, token, qty, unitCents, cur, attemptNo), idemKey);
            logCall('CreateCheckoutSession', cr, p.Id);
            if (!cr.ok()) {
                throw new PaymentException(cr.errorType == 'idempotency_error' ? MSG_BUSY : MSG_UNAVAILABLE);
            }
            SessionView nv = toView(cr.body);
            if (String.isBlank(nv.id) || String.isBlank(nv.url)) { throw new PaymentException(MSG_UNAVAILABLE); }

            // ---------- PHASE B: database only ----------
            applyClosures(closeAs, 'Session no longer open');
            Ticket_Payment__c created = new Ticket_Payment__c(
                Purchase__c = p.Id, Provider__c = 'Stripe', Provider_Order_Id__c = nv.id,
                Amount__c = Decimal.valueOf(totalCents).divide(100, 2), Currency_Code__c = cur.toUpperCase(),
                Status__c = 'Created', Idempotency_Key__c = idemKey, Correlation_Id__c = corr,
                Status_Detail__c = 'Checkout session created, waiting for the buyer');
            Database.SaveResult sr = Database.insert(created, false);
            if (!sr.isSuccess()) {
                // A concurrent request with the same idempotency key already stored this very session.
                Integer existing = [SELECT COUNT() FROM Ticket_Payment__c WHERE Provider_Order_Id__c = :nv.id];
                if (existing == 0) { throw new PaymentException(MSG_UNAVAILABLE); }
            }
            update new Purchase__c(Id = p.Id, Payment_Status__c = 'Pending');
            out.success = true;
            out.checkoutUrl = nv.url;
            System.debug(LoggingLevel.INFO, LOG + 'session created ref=' + p.Request_Reference__c + ' attempt=' + attemptNo);
        } catch (PaymentException pe) {
            out.success = false;
            out.message = pe.getMessage();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'startPayment failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            out.success = false;
            out.message = MSG_UNAVAILABLE;
        } finally {
            IntegrationLogger.flush();
        }
        return out;
    }

    public static PaymentDto.VerifyResult verifyPayment(String reference, String token, String sessionId) {
        PaymentDto.VerifyResult r = new PaymentDto.VerifyResult();
        try {
            Purchase__c p = authorize(reference, token);
            String sid = sessionId == null ? '' : sessionId.trim();
            if (!SESSION_PATTERN.matcher(sid).matches()) { throw new PaymentException(MSG_NOT_MATCHED); }
            // The session must belong to an attempt WE created for THIS purchase. A forged id matches nothing.
            List<Ticket_Payment__c> rows = [
                SELECT Id, Status__c, Amount__c, Currency_Code__c, Provider_Order_Id__c
                FROM Ticket_Payment__c WHERE Purchase__c = :p.Id AND Provider_Order_Id__c = :sid LIMIT 1];
            if (rows.isEmpty()) { throw new PaymentException(MSG_NOT_MATCHED); }
            return verifyAttempt(p, rows[0]);
        } catch (PaymentException pe) {
            r.success = false;
            r.outcome = 'ERROR';
            r.message = pe.getMessage();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'verifyPayment failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            r.success = false;
            r.outcome = 'ERROR';
            r.message = MSG_UNAVAILABLE;
        } finally {
            IntegrationLogger.flush();
        }
        return r;
    }

    /** The buyer pressed back on Stripe's page. Close the session first, so it can never be paid later. */
    public static PaymentDto.VerifyResult cancelAttempt(String reference, String token) {
        PaymentDto.VerifyResult r = new PaymentDto.VerifyResult();
        try {
            Purchase__c p = authorize(reference, token);
            List<Ticket_Payment__c> open = latestOpenAttempt(p.Id);
            if (open.isEmpty()) {
                r.success = true;
                r.outcome = p.Payment_Status__c == 'Paid' ? 'PAID' : 'CANCELLED';
                r.message = p.Payment_Status__c == 'Paid' ? MSG_PAID : 'Payment cancelled. You have not been charged.';
                return r;
            }
            Ticket_Payment__c a = open[0];
            StripeClient.StripeResponse g = StripeClient.getCheckoutSession(a.Provider_Order_Id__c);
            logCall('GetCheckoutSession', g, p.Id);
            if (!g.ok()) { throw new PaymentException(MSG_UNAVAILABLE); }
            SessionView v = toView(g.body);
            if (v.status == 'open') {
                StripeClient.StripeResponse e = StripeClient.expireCheckoutSession(a.Provider_Order_Id__c);
                logCall('ExpireCheckoutSession', e, p.Id);
                if (!e.ok()) { throw new PaymentException(MSG_UNAVAILABLE); }
                markAttempt(a.Id, 'Cancelled', 'Cancelled by the buyer');
                setPurchaseStatusUnlessPaid(p.Id, 'Cancelled');
                r.success = true;
                r.outcome = 'CANCELLED';
                r.message = 'Payment cancelled. You have not been charged. You can try again at any time.';
                return r;
            }
            return applyOutcome(p, a, v);     // already paid, expired or finished: record what really happened
        } catch (PaymentException pe) {
            r.success = false;
            r.outcome = 'ERROR';
            r.message = pe.getMessage();
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, LOG + 'cancelAttempt failed: ' + ex.getTypeName() + ' - ' + ex.getMessage());
            r.success = false;
            r.outcome = 'ERROR';
            r.message = MSG_UNAVAILABLE;
        } finally {
            IntegrationLogger.flush();
        }
        return r;
    }

    /** Staff path (no token): re-check the newest open attempt with Stripe. Covers a buyer who paid and closed the tab. */
    public static PaymentDto.VerifyResult reverifyLatest(Id purchaseId) {
        PaymentDto.VerifyResult r = new PaymentDto.VerifyResult();
        try {
            Purchase__c p = loadById(purchaseId);
            if (p == null) { throw new PaymentException('The purchase could not be found.'); }
            List<Ticket_Payment__c> open = latestOpenAttempt(p.Id);
            if (open.isEmpty()) {
                r.success = true;
                r.outcome = p.Payment_Status__c == 'Paid' ? 'PAID' : 'NONE';
                r.message = p.Payment_Status__c == 'Paid' ? 'This purchase is already paid.' : 'There is no open payment attempt to verify.';
                return r;
            }
            return verifyAttempt(p, open[0]);
        } catch (PaymentException pe) {
            r.success = false;
            r.outcome = 'ERROR';
            r.message = pe.getMessage();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'reverifyLatest failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            r.success = false;
            r.outcome = 'ERROR';
            r.message = MSG_UNAVAILABLE;
        } finally {
            IntegrationLogger.flush();
        }
        return r;
    }

    public static Purchase__c loadById(Id purchaseId) {
        if (purchaseId == null) { return null; }
        List<Purchase__c> rows = (List<Purchase__c>) Database.queryWithBinds(
            'SELECT ' + PURCHASE_FIELDS + ' FROM Purchase__c WHERE Id = :pid LIMIT 1',
            new Map<String, Object>{ 'pid' => purchaseId }, AccessLevel.SYSTEM_MODE);
        return rows.isEmpty() ? null : rows[0];
    }

    // =====================================================================
    // Verification
    // =====================================================================

    private static PaymentDto.VerifyResult verifyAttempt(Purchase__c p, Ticket_Payment__c a) {
        if (a.Status__c == 'Completed') {         // idempotent: nothing to do, no callout
            PaymentDto.VerifyResult done = new PaymentDto.VerifyResult();
            done.success = true;
            done.outcome = 'PAID';
            done.message = MSG_PAID;
            return done;
        }
        StripeClient.StripeResponse g = StripeClient.getCheckoutSession(a.Provider_Order_Id__c);
        logCall('GetCheckoutSession', g, p.Id);
        if (!g.ok()) {
            PaymentDto.VerifyResult unsure = new PaymentDto.VerifyResult();
            unsure.success = true;
            unsure.outcome = 'PENDING';
            unsure.message = 'We could not confirm your payment yet. Please check again in a moment.';
            return unsure;                         // state is left untouched
        }
        return applyOutcome(p, a, toView(g.body));
    }

    /** Turns Stripe's real answer into our records. Database changes only. */
    private static PaymentDto.VerifyResult applyOutcome(Purchase__c p, Ticket_Payment__c a, SessionView v) {
        PaymentDto.VerifyResult r = new PaymentDto.VerifyResult();
        r.success = true;

        if (v.paymentStatus == 'paid' && v.status == 'complete') {
            String problem = integrityProblem(p, a, v);
            if (problem != null) {
                markAttempt(a.Id, 'Failed', 'Integrity check failed: ' + problem + '. Review in Stripe.');
                setPurchaseStatusUnlessPaid(p.Id, 'Failed');
                IntegrationLogger.add('Stripe', 'IntegrityCheck', null, false, corr, 'Integrity check failed: ' + problem, String.valueOf(p.Id));
                System.debug(LoggingLevel.ERROR, LOG + 'integrity check failed ref=' + p.Request_Reference__c + ': ' + problem);
                r.outcome = 'NEEDS_REVIEW';
                r.message = 'We received your payment but need to confirm it manually. Our team will contact you shortly.';
                return r;
            }
            return finalizePaid(p.Id, a.Id, v);
        }
        if (v.status == 'expired') {
            markAttempt(a.Id, 'Cancelled', 'Checkout session expired without payment');
            setPurchaseStatusUnlessPaid(p.Id, 'Cancelled');
            r.outcome = 'CANCELLED';
            r.message = 'This payment session expired and you have not been charged. You can start a new payment.';
            return r;
        }
        markAttempt(a.Id, 'Pending', v.status == 'open' ? 'Waiting for the buyer to finish paying' : 'Payment is still processing');
        setPurchaseStatusUnlessPaid(p.Id, 'Pending');
        r.outcome = 'PENDING';
        r.message = 'Your payment has not been completed yet. If you already paid, please check again in a moment.';
        return r;
    }

    private static String integrityProblem(Purchase__c p, Ticket_Payment__c a, SessionView v) {
        Long expected = toCents(p.Total_Amount__c);
        if (v.amountTotal == null || v.amountTotal != expected || toCents(a.Amount__c) != expected) { return 'amount mismatch'; }
        if (String.isBlank(v.currencyCode) || !v.currencyCode.equalsIgnoreCase(a.Currency_Code__c)) { return 'currency mismatch'; }
        if (String.isBlank(v.clientRef) || !v.clientRef.equals(p.Request_Reference__c)) { return 'reference mismatch'; }
        if (String.isBlank(v.paymentIntent)) { return 'missing payment id'; }
        return null;
    }

    /** The one place where "paid" is recorded. Locked, re-checked, all or nothing. */
    private static PaymentDto.VerifyResult finalizePaid(Id purchaseId, Id attemptId, SessionView v) {
        PaymentDto.VerifyResult r = new PaymentDto.VerifyResult();
        r.success = true;
        Savepoint sp = Database.setSavepoint();
        try {
            Purchase__c locked = [SELECT Id, Request_Reference__c, Payment_Status__c, Quantity__c, Opportunity__c, Ticket_Category__c
                                  FROM Purchase__c WHERE Id = :purchaseId FOR UPDATE];
            Ticket_Payment__c a = [SELECT Id, Status__c FROM Ticket_Payment__c WHERE Id = :attemptId FOR UPDATE];

            if (a.Status__c == 'Completed') {                       // a parallel verify already did the work
                r.outcome = 'PAID';
                r.message = MSG_PAID;
                return r;
            }
            if (locked.Payment_Status__c == 'Paid') {               // a DIFFERENT session already paid this purchase
                update new Ticket_Payment__c(Id = a.Id, Status__c = 'Failed',
                    Status_Detail__c = 'Duplicate payment: this purchase was already paid. Refund this charge in Stripe.');
                IntegrationLogger.add('Stripe', 'DuplicatePayment', null, false, corr,
                    'Second paid session for an already paid purchase', String.valueOf(purchaseId));
                System.debug(LoggingLevel.ERROR, LOG + 'DUPLICATE payment for ref=' + locked.Request_Reference__c);
                r.outcome = 'DUPLICATE';
                r.message = 'This purchase was already paid. The extra charge will be refunded by our team.';
                return r;
            }

            Integer qty = locked.Quantity__c.intValue();
            Ticket_Category__c cat = [SELECT Id, Total_Quantity__c, Sold_Quantity__c FROM Ticket_Category__c
                                      WHERE Id = :locked.Ticket_Category__c FOR UPDATE];
            Decimal sold = cat.Sold_Quantity__c == null ? 0 : cat.Sold_Quantity__c;
            Decimal total = cat.Total_Quantity__c == null ? 0 : cat.Total_Quantity__c;
            Boolean oversold = (sold + qty) > total;                 // possible only if two buyers paid for the last tickets
            update new Ticket_Category__c(Id = cat.Id, Sold_Quantity__c = sold + qty);

            update new Ticket_Payment__c(Id = a.Id, Status__c = 'Completed', Capture_Id__c = v.paymentIntent,
                Verified_On__c = Datetime.now(),
                Status_Detail__c = oversold ? 'Verified with Stripe. WARNING: category is oversold, staff review needed.'
                                            : 'Payment verified with Stripe');
            update new Purchase__c(Id = purchaseId, Payment_Status__c = 'Paid', Paid_On__c = Datetime.now());
            if (locked.Opportunity__c != null) {
                update new Opportunity(Id = locked.Opportunity__c, StageName = 'Closed Won', CloseDate = Date.today());
            }
            if (oversold) {
                IntegrationLogger.add('Stripe', 'OversoldAlert', null, false, corr, 'Paid purchase exceeds category capacity', String.valueOf(purchaseId));
            }
            IntegrationLogger.add('Stripe', 'PaymentVerified', 200, true, corr, 'Payment verified', String.valueOf(purchaseId));
            System.debug(LoggingLevel.INFO, LOG + 'PAID ref=' + locked.Request_Reference__c + ' oversold=' + oversold);
            // Slice (e): enqueue portal provisioning for the Contact here, after verified payment.
            r.outcome = 'PAID';
            r.message = MSG_PAID;
            return r;
        } catch (Exception e) {
            Database.rollback(sp);
            System.debug(LoggingLevel.ERROR, LOG + 'finalizePaid failed, rolled back: ' + e.getTypeName() + ' - ' + e.getMessage());
            throw new PaymentException(MSG_RECORDING);
        }
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    private static Purchase__c authorize(String reference, String token) {
        String ref = reference == null ? '' : reference.trim().toUpperCase();
        if (!REF_PATTERN.matcher(ref).matches() || String.isBlank(token) || token.length() > 128) {
            throw new PaymentException(MSG_INVALID_LINK);
        }
        List<Purchase__c> rows = (List<Purchase__c>) Database.queryWithBinds(
            'SELECT ' + PURCHASE_FIELDS + ' FROM Purchase__c WHERE Request_Reference__c = :ref LIMIT 1',
            new Map<String, Object>{ 'ref' => ref }, AccessLevel.SYSTEM_MODE);
        Boolean ok = !rows.isEmpty() && rows[0].Token_Hash__c != null && rows[0].Token_Expires_On__c != null
            && rows[0].Token_Expires_On__c > Datetime.now()
            && rows[0].Token_Hash__c.equals(PaymentLinkService.hash(token));   // equals() is case-sensitive
        if (!ok) {
            System.debug(LoggingLevel.WARN, LOG + 'authorize failed for ref=' + ref);
            throw new PaymentException(MSG_INVALID_LINK);                      // one message for every failure
        }
        return rows[0];
    }

    private static void requirePayable(Purchase__c p) {
        if (p.Payment_Status__c == 'Paid') { throw new PaymentException('This purchase has already been paid. Thank you!'); }
        if (!TwinTicketConfig.paymentsEnabled()) { throw new PaymentException(MSG_UNAVAILABLE); }
        if (p.Event_Detail__r == null || p.Event_Detail__r.Status__c != 'Published') {
            throw new PaymentException('This Event_Detail is no longer available. Please contact Twin Ticket.');
        }
        if (p.Event_Detail__r.Start_DateTime__c != null && p.Event_Detail__r.Start_DateTime__c <= Datetime.now()) {
            throw new PaymentException('This Event_Detail has already started. Please contact Twin Ticket.');
        }
        Decimal available = p.Ticket_Category__r.Available_Quantity__c == null ? 0 : p.Ticket_Category__r.Available_Quantity__c;
        if (p.Quantity__c == null || available < p.Quantity__c) {
            throw new PaymentException('Sorry, these tickets are no longer available. Our team will contact you.');
        }
    }

    private static Map<String, String> buildSessionParams(Purchase__c p, String token, Integer qty, Long unitCents, String cur, Integer attemptNo) {
        String base = TwinTicketConfig.siteBaseUrl();
        if (String.isBlank(base)) { throw new PaymentException(MSG_UNAVAILABLE); }
        String page = base + '/pay?c__ref=' + EncodingUtil.urlEncode(p.Request_Reference__c, 'UTF-8') + '&c__t=' + token;
        // Rounded to 5 minutes so two requests with the same idempotency key send identical parameters.
        Long nowSec = Datetime.now().getTime() / 1000;
        Long expiresAt = ((nowSec + (TwinTicketConfig.paymentSessionMinutes() * 60) + 300) / 300) * 300;
        Map<String, String> params = new Map<String, String>{
            'mode' => 'payment',
            'success_url' => page + '&c__r=success&c__sid={CHECKOUT_SESSION_ID}',
            'cancel_url' => page + '&c__r=cancel',
            'client_reference_id' => p.Request_Reference__c,
            'expires_at' => String.valueOf(expiresAt),
            'line_items[0][quantity]' => String.valueOf(qty),
            'line_items[0][price_data][currency]' => cur,
            'line_items[0][price_data][unit_amount]' => String.valueOf(unitCents),
            'line_items[0][price_data][product_data][name]' => (p.Ticket_Category__r.Name + ' - ' + p.Event_Detail__r.Name).left(120),
            'line_items[0][price_data][product_data][description]' => 'Twin Ticket bulk purchase ' + p.Request_Reference__c,
            'metadata[purchase_ref]' => p.Request_Reference__c,
            'metadata[attempt]' => String.valueOf(attemptNo),
            'payment_intent_data[metadata][purchase_ref]' => p.Request_Reference__c
        };
        if (p.Contact__r != null && String.isNotBlank(p.Contact__r.Email)) { params.put('customer_email', p.Contact__r.Email); }
        return params;
    }

    private static SessionView toView(Map<String, Object> b) {
        SessionView v = new SessionView();
        v.id = (String) b.get('id');
        v.status = (String) b.get('status');
        v.paymentStatus = (String) b.get('payment_status');
        v.currencyCode = (String) b.get('currency');
        v.clientRef = (String) b.get('client_reference_id');
        v.url = (String) b.get('url');
        Object pi = b.get('payment_intent');
        v.paymentIntent = pi instanceof String ? (String) pi : null;
        Object amt = b.get('amount_total');
        v.amountTotal = amt == null ? null : Long.valueOf(String.valueOf(amt));
        return v;
    }

    private static List<Ticket_Payment__c> latestOpenAttempt(Id purchaseId) {
        return [SELECT Id, Status__c, Amount__c, Currency_Code__c, Provider_Order_Id__c FROM Ticket_Payment__c
                WHERE Purchase__c = :purchaseId AND Status__c IN :OPEN_STATUSES ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static void applyClosures(Map<Id, String> closeAs, String detail) {
        if (closeAs.isEmpty()) { return; }
        List<Ticket_Payment__c> upd = new List<Ticket_Payment__c>();
        for (Id attemptId : closeAs.keySet()) {
            upd.add(new Ticket_Payment__c(Id = attemptId, Status__c = closeAs.get(attemptId), Status_Detail__c = detail));
        }
        update upd;
    }

    private static void markAttempt(Id attemptId, String status, String detail) {
        update new Ticket_Payment__c(Id = attemptId, Status__c = status, Status_Detail__c = detail.left(255));
    }

    /** Re-reads the purchase under lock so a late "cancelled" can never overwrite a real "Paid". */
    private static void setPurchaseStatusUnlessPaid(Id purchaseId, String status) {
        Purchase__c locked = [SELECT Id, Payment_Status__c FROM Purchase__c WHERE Id = :purchaseId FOR UPDATE];
        if (locked.Payment_Status__c != 'Paid' && locked.Payment_Status__c != status) {
            update new Purchase__c(Id = purchaseId, Payment_Status__c = status);
        }
    }

    private static void logCall(String operation, StripeClient.StripeResponse r, Id purchaseId) {
        String msg = r.ok() ? 'OK' : ('type=' + r.errorType + ' code=' + r.errorCode + (r.transportFailure ? ' network failure' : ''));
        IntegrationLogger.add('Stripe', operation, r.status, r.ok(), corr, msg, String.valueOf(purchaseId));
    }

    public static Long toCents(Decimal d) {
        return d == null ? 0L : (d * 100).setScale(0, RoundingMode.HALF_UP).longValue();
    }
}