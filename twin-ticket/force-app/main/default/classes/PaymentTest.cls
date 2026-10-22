@IsTest
private class PaymentTest {

    private static final String SID1 = 'cs_test_aaaaaaaaaa01';
    private static final String SID2 = 'cs_test_bbbbbbbbbb02';
    private static final String SID3 = 'cs_test_cccccccccc03';

    /** Routes by "METHOD /path". Records every call. The last queued response for a route repeats. */
    public class StripeMock implements HttpCalloutMock {
        public Map<String, List<HttpResponse>> routes = new Map<String, List<HttpResponse>>();
        public List<HttpRequest> calls = new List<HttpRequest>();
        public Integer transportFailures = 0;

        public void addResponse(String key, Integer status, String body) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(status);
            r.setBody(body);
            if (!routes.containsKey(key)) { routes.put(key, new List<HttpResponse>()); }
            routes.get(key).add(r);
        }
        public Integer count(String key) {
            Integer n = 0;
            for (HttpRequest c : calls) {
                if (c.getMethod() + ' ' + c.getEndpoint().substringAfter('callout:Stripe_API') == key) { n++; }
            }
            return n;
        }
        public HttpResponse respond(HttpRequest req) {
            calls.add(req);
            if (transportFailures > 0) {
                transportFailures--;
                throw new CalloutException('simulated network failure');
            }
            String key = req.getMethod() + ' ' + req.getEndpoint().substringAfter('callout:Stripe_API');
            List<HttpResponse> q = routes.get(key);
            if (q == null || q.isEmpty()) {
                HttpResponse nf = new HttpResponse();
                nf.setStatusCode(404);
                nf.setBody('{"error":{"type":"invalid_request_error","code":"resource_missing"}}');
                return nf;
            }
            return q.size() > 1 ? q.remove(0) : q[0];
        }
    }

    @TestSetup
    static void setup() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        System.runAs(new User(Id = UserInfo.getUserId())) {
            User reviewer = makeUser(admin.Id, 'ptrev');
            User outsider = makeUser(admin.Id, 'ptout');
            insert new List<User>{ reviewer, outsider };
            PermissionSet ps = new PermissionSet(Name = 'TT_Pay_Test_Reviewer', Label = 'TT Pay Test Reviewer');
            insert ps;
            CustomPermission cp = [SELECT Id FROM CustomPermission WHERE DeveloperName = 'Review_Bulk_Requests' LIMIT 1];
            insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cp.Id);
            insert new PermissionSetAssignment(AssigneeId = reviewer.Id, PermissionSetId = ps.Id);
        }
        Event_Detail__c ev = new Event_Detail__c(Name = 'Pay Summit', Status__c = 'Published',
            Start_DateTime__c = System.now().addDays(20), Time_Zone__c = 'Asia/Dhaka', Venue_Name__c = 'Test Hall');
        insert ev;
        insert new Ticket_Category__c(Name = 'Standard', Event_Detail__c = ev.Id, Price__c = 50, Total_Quantity__c = 300, Sold_Quantity__c = 0);
    }

    // ---------- helpers ----------
    private static User makeUser(Id profileId, String alias) {
        String uniq = String.valueOf(Math.abs(Crypto.getRandomLong()));
        return new User(Alias = alias, Email = alias + uniq + '@example.com', EmailEncodingKey = 'UTF-8', LastName = alias,
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = profileId, TimeZoneSidKey = 'Asia/Dhaka',
            Username = alias + uniq + '@twinticket-test.example.com');
    }
    private static User reviewer() { return [SELECT Id FROM User WHERE Alias = 'ptrev' LIMIT 1]; }
    private static User outsider() { return [SELECT Id FROM User WHERE Alias = 'ptout' LIMIT 1]; }

    private static void cfg() {
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(
            Site_Base_Url__c = 'https://example.my.site.com/twinticket', Payments_Enabled__c = true,
            Payment_Token_Hours__c = 168, Payment_Session_Minutes__c = 60, Payment_Currency__c = 'usd');
    }

    /** suffix must be 3 characters from A-H, J-N, P-Z, 2-9 so the full reference is valid. */
    private static Purchase__c makePurchase(String suffix, Integer qty) {
        Ticket_Category__c cat = [SELECT Id, Event_Detail__c FROM Ticket_Category__c LIMIT 1];
        Account a = new Account(Name = 'Pay Org ' + suffix);
        insert a;
        Contact c = new Contact(AccountId = a.Id, FirstName = 'Pat', LastName = 'Payer' + suffix, Email = 'payer' + suffix + '@example.com');
        insert c;
        Opportunity o = new Opportunity(Name = 'Opp ' + suffix, AccountId = a.Id, StageName = 'Awaiting Payment', CloseDate = Date.today().addDays(7));
        insert o;
        Purchase__c p = new Purchase__c(Account__c = a.Id, Contact__c = c.Id, Opportunity__c = o.Id,
            Event_Detail__c = cat.Event_Detail__c, Ticket_Category__c = cat.Id, Quantity__c = qty, Unit_Price__c = 50,
            Total_Amount__c = 50 * qty, Payment_Status__c = 'Awaiting Payment', Request_Reference__c = 'TT-20261021-PAY' + suffix);
        insert p;
        return p;
    }
    private static String issue(Purchase__c p) {
        PaymentLinkService.SendResult r = PaymentLinkService.issueAndSend(p.Id);
        Assert.isTrue(r.success, 'precondition: link issued');
        return PaymentLinkService.lastIssuedToken;
    }
    private static Ticket_Payment__c attempt(Purchase__c p, String sid, String status) {
        Ticket_Payment__c a = new Ticket_Payment__c(Purchase__c = p.Id, Provider__c = 'Stripe', Provider_Order_Id__c = sid,
            Amount__c = p.Total_Amount__c, Currency_Code__c = 'USD', Status__c = status, Idempotency_Key__c = 'TT-test-' + sid);
        insert a;
        return a;
    }
    private static String session(String id, String status, String payStatus, Long amount, String cur, String ref, String pi) {
        return JSON.serialize(new Map<String, Object>{
            'id' => id, 'status' => status, 'payment_status' => payStatus, 'amount_total' => amount, 'currency' => cur,
            'client_reference_id' => ref, 'payment_intent' => pi,
            'url' => status == 'open' ? 'https://checkout.stripe.com/c/pay/' + id : null });
    }
    private static StripeMock mock() {
        StripeMock m = new StripeMock();
        Test.setMock(HttpCalloutMock.class, m);
        return m;
    }
    private static String contextError(String ref, String token) {
        try { PaymentService.getContext(ref, token); }
        catch (PaymentService.PaymentException e) { return e.getMessage(); }
        return null;
    }
    private static Ticket_Payment__c reload(Id id) {
        return [SELECT Status__c, Status_Detail__c, Capture_Id__c, Verified_On__c, Provider_Order_Id__c, Idempotency_Key__c, Amount__c, Currency_Code__c
                FROM Ticket_Payment__c WHERE Id = :id];
    }
    private static String purchaseStatus(Id id) { return [SELECT Payment_Status__c FROM Purchase__c WHERE Id = :id].Payment_Status__c; }

    /** One paid-but-wrong session per test (a callout is only allowed before any DML in the same test). */
    private static void assertNeedsReview(String suffix, Long amount, String cur, String refOverride, String pi) {
        cfg();
        Purchase__c p = makePurchase(suffix, 20);
        String t = issue(p);
        Ticket_Payment__c a = attempt(p, SID1, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200,
            session(SID1, 'complete', 'paid', amount, cur, refOverride == null ? p.Request_Reference__c : refOverride, pi));
        Test.startTest();
        PaymentDto.VerifyResult r = PaymentService.verifyPayment(p.Request_Reference__c, t, SID1);
        Test.stopTest();
        Assert.areEqual('NEEDS_REVIEW', r.outcome, r.message);
        Assert.areEqual('Failed', reload(a.Id).Status__c);
        Assert.isTrue(reload(a.Id).Status_Detail__c.contains('Integrity check failed'));
        Assert.areEqual('Failed', purchaseStatus(p.Id));
        Assert.areEqual(0, [SELECT Sold_Quantity__c FROM Ticket_Category__c LIMIT 1].Sold_Quantity__c, 'nothing counted as sold');
    }

    /** Verifies one session in one test and checks how it was recorded. */
    private static void assertRecorded(String suffix, String status, String payStatus, String pi,
                                       String expectedOutcome, String expectedAttempt, String expectedPurchase) {
        cfg();
        Purchase__c p = makePurchase(suffix, 20);
        String t = issue(p);
        Ticket_Payment__c a = attempt(p, SID1, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, status, payStatus, 100000L, 'usd', p.Request_Reference__c, pi));
        Test.startTest();
        PaymentDto.VerifyResult r = PaymentService.verifyPayment(p.Request_Reference__c, t, SID1);
        Test.stopTest();
        Assert.areEqual(expectedOutcome, r.outcome, r.message);
        Assert.areEqual(expectedAttempt, reload(a.Id).Status__c);
        if (expectedPurchase != null) { Assert.areEqual(expectedPurchase, purchaseStatus(p.Id)); }
    }

    // ---------- payment link ----------
    @IsTest
    static void issuedLinkIsHashedExpiresAndOldTokensStopWorking() {
        cfg();
        Purchase__c p = makePurchase('AA2', 20);
        PaymentLinkService.emailsSent = 0;
        String t1 = issue(p);
        Purchase__c row = [SELECT Token_Hash__c, Token_Expires_On__c FROM Purchase__c WHERE Id = :p.Id];
        Assert.areEqual(64, row.Token_Hash__c.length());
        Assert.areNotEqual(t1, row.Token_Hash__c, 'raw token is never stored');
        Assert.isTrue(row.Token_Expires_On__c > Datetime.now().addHours(167));
        Assert.areEqual(1, PaymentLinkService.emailsSent);
        String t2 = issue(p);
        Assert.areNotEqual(t1, t2);
        Assert.isTrue(PaymentService.getContext(p.Request_Reference__c, t2).valid);
        Assert.areEqual(PaymentService.MSG_INVALID_LINK, contextError(p.Request_Reference__c, t1), 'the old link is dead');
    }

    @IsTest
    static void linkIsRefusedForPaidPurchaseMissingConfigOrMissingEmail() {
        cfg();
        Purchase__c paid = makePurchase('AB2', 20);
        update new Purchase__c(Id = paid.Id, Payment_Status__c = 'Paid');
        Assert.isFalse(PaymentLinkService.issueAndSend(paid.Id).success, 'already paid');
        Assert.isFalse(PaymentLinkService.issueAndSend(UserInfo.getUserId()).success, 'unknown purchase');

        Purchase__c p = makePurchase('AC2', 20);
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Site_Base_Url__c = '', Payments_Enabled__c = true);
        Assert.isFalse(PaymentLinkService.issueAndSend(p.Id).success, 'no site url');
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Site_Base_Url__c = 'https://example.my.site.com/x', Payments_Enabled__c = false);
        Assert.isFalse(PaymentLinkService.issueAndSend(p.Id).success, 'payments switched off');
        cfg();
        update new Contact(Id = p.Contact__c, Email = null);
        Assert.isFalse(PaymentLinkService.issueAndSend(p.Id).success, 'no email address');
        Assert.areEqual(0, PaymentLinkService.emailsSent);
    }

    // ---------- authorization and context ----------
    @IsTest
    static void contextNeedsAValidUnexpiredTokenForThatPurchase() {
        cfg();
        Purchase__c p = makePurchase('AD2', 20);
        String t = issue(p);
        PaymentDto.Context c = PaymentService.getContext(p.Request_Reference__c.toLowerCase(), t);
        Assert.isTrue(c.valid);
        Assert.areEqual('PAYABLE', c.state);
        Assert.areEqual(1000, c.amount);
        Assert.areEqual('USD', c.currencyCode);
        Assert.areEqual(PaymentService.MSG_INVALID_LINK, contextError(p.Request_Reference__c, 'wrong-token'));
        Assert.areEqual(PaymentService.MSG_INVALID_LINK, contextError(p.Request_Reference__c, ''));
        Assert.areEqual(PaymentService.MSG_INVALID_LINK, contextError('garbage', t));
        Assert.areEqual(PaymentService.MSG_INVALID_LINK, contextError('TT-20261021-ZZZZZ9', t));
        update new Purchase__c(Id = p.Id, Token_Expires_On__c = Datetime.now().addMinutes(-1));
        Assert.areEqual(PaymentService.MSG_INVALID_LINK, contextError(p.Request_Reference__c, t), 'expired');
        update new Purchase__c(Id = p.Id, Token_Expires_On__c = Datetime.now().addHours(1), Payment_Status__c = 'Paid');
        Assert.areEqual('PAID', PaymentService.getContext(p.Request_Reference__c, t).state);
        cfg();
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Site_Base_Url__c = 'https://x.example', Payments_Enabled__c = false);
        update new Purchase__c(Id = p.Id, Payment_Status__c = 'Awaiting Payment');
        Assert.areEqual('UNAVAILABLE', PaymentService.getContext(p.Request_Reference__c, t).state);
    }

    // ---------- start payment ----------
    @IsTest
    static void startCreatesSessionFromStoredAmountWithIdempotencyKeyAndLogsSafely() {
        cfg();
        Purchase__c p = makePurchase('AE2', 20);
        String t = issue(p);
        StripeMock m = mock();
        m.addResponse('POST /v1/checkout/sessions', 200, session(SID1, 'open', 'unpaid', 100000L, 'usd', p.Request_Reference__c, null));

        Test.startTest();
        PaymentDto.StartResult r = PaymentService.startPayment(p.Request_Reference__c, t);
        Test.stopTest();

        Assert.isTrue(r.success, 'start failed: ' + r.message);
        Assert.areEqual('https://checkout.stripe.com/c/pay/' + SID1, r.checkoutUrl);
        HttpRequest req = m.calls[0];
        String body = req.getBody();
        Assert.isTrue(body.contains('unit_amount%5D=5000'), 'unit price in cents comes from stored data');
        Assert.isTrue(body.contains('quantity%5D=20'));
        Assert.isTrue(body.contains('client_reference_id=' + p.Request_Reference__c));
        Assert.areEqual('TT-' + p.Id + '-1', req.getHeader('Idempotency-Key'));

        Ticket_Payment__c a = [SELECT Id FROM Ticket_Payment__c WHERE Purchase__c = :p.Id];
        Ticket_Payment__c row = reload(a.Id);
        Assert.areEqual('Created', row.Status__c);
        Assert.areEqual(SID1, row.Provider_Order_Id__c);
        Assert.areEqual(1000, row.Amount__c);
        Assert.areEqual('USD', row.Currency_Code__c);
        Assert.areEqual('Pending', purchaseStatus(p.Id));
        Integration_Log__c log = [SELECT Outcome__c, Message__c, Operation__c FROM Integration_Log__c WHERE Operation__c = 'CreateCheckoutSession'];
        Assert.areEqual('Success', log.Outcome__c);
        Assert.isFalse(String.valueOf(log.Message__c).containsIgnoreCase('sk_'), 'no secrets in logs');
    }

    @IsTest
    static void secondStartReusesTheOpenSessionInsteadOfCreatingAnother() {
        cfg();
        Purchase__c p = makePurchase('AF2', 20);
        String t = issue(p);
        attempt(p, SID1, 'Created');                      // what the first start left behind
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, 'open', 'unpaid', 100000L, 'usd', p.Request_Reference__c, null));

        Test.startTest();
        PaymentDto.StartResult again = PaymentService.startPayment(p.Request_Reference__c, t);
        Test.stopTest();

        Assert.isTrue(again.success, 'start failed: ' + again.message);
        Assert.areEqual('https://checkout.stripe.com/c/pay/' + SID1, again.checkoutUrl);
        Assert.areEqual(0, m.count('POST /v1/checkout/sessions'), 'no second session is created');
        Assert.areEqual(1, [SELECT COUNT() FROM Ticket_Payment__c WHERE Purchase__c = :p.Id]);
    }

    @IsTest
    static void expiredSessionIsClosedAndANewAttemptGetsANewIdempotencyKey() {
        cfg();
        Purchase__c p = makePurchase('AG2', 20);
        String t = issue(p);
        Ticket_Payment__c first = attempt(p, SID1, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, 'expired', 'unpaid', 100000L, 'usd', p.Request_Reference__c, null));
        m.addResponse('POST /v1/checkout/sessions', 200, session(SID2, 'open', 'unpaid', 100000L, 'usd', p.Request_Reference__c, null));

        Test.startTest();
        PaymentDto.StartResult r = PaymentService.startPayment(p.Request_Reference__c, t);
        Test.stopTest();

        Assert.isTrue(r.success, 'start failed: ' + r.message);
        Assert.areEqual('Cancelled', reload(first.Id).Status__c);
        Assert.areEqual(2, [SELECT COUNT() FROM Ticket_Payment__c WHERE Purchase__c = :p.Id]);
        Assert.areEqual('TT-' + p.Id + '-2', m.calls[1].getHeader('Idempotency-Key'));
    }

    @IsTest
    static void staleOpenSessionWithOldAmountIsExpiredNotReused() {
        cfg();
        Purchase__c p = makePurchase('AH2', 20);
        String t = issue(p);
        Ticket_Payment__c first = attempt(p, SID1, 'Pending');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, 'open', 'unpaid', 90000L, 'usd', p.Request_Reference__c, null));
        m.addResponse('POST /v1/checkout/sessions/' + SID1 + '/expire', 200, session(SID1, 'expired', 'unpaid', 90000L, 'usd', p.Request_Reference__c, null));
        m.addResponse('POST /v1/checkout/sessions', 200, session(SID2, 'open', 'unpaid', 100000L, 'usd', p.Request_Reference__c, null));

        Test.startTest();
        PaymentDto.StartResult r = PaymentService.startPayment(p.Request_Reference__c, t);
        Test.stopTest();

        Assert.isTrue(r.success, 'start failed: ' + r.message);
        Assert.areEqual(1, m.count('POST /v1/checkout/sessions/' + SID1 + '/expire'));
        Assert.areEqual('Cancelled', reload(first.Id).Status__c);
    }

    @IsTest
    static void startWhenAnOpenSessionWasAlreadyPaidRecordsItAndDoesNotCreateAnother() {
        cfg();
        Purchase__c p = makePurchase('AJ2', 20);
        String t = issue(p);
        attempt(p, SID1, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, 'complete', 'paid', 100000L, 'usd', p.Request_Reference__c, 'pi_test_paid1'));

        Test.startTest();
        PaymentDto.StartResult r = PaymentService.startPayment(p.Request_Reference__c, t);
        Test.stopTest();

        Assert.isFalse(r.success);
        Assert.isTrue(r.alreadyPaid, r.message);
        Assert.areEqual('Paid', purchaseStatus(p.Id));
        Assert.areEqual(0, m.count('POST /v1/checkout/sessions'));
    }

    @IsTest
    static void startIsRefusedWhenBusinessChecksFailAndNeverCallsStripe() {
        cfg();
        StripeMock m = mock();
        Purchase__c paid = makePurchase('AK2', 20);
        String tPaid = issue(paid);
        update new Purchase__c(Id = paid.Id, Payment_Status__c = 'Paid');
        Assert.isFalse(PaymentService.startPayment(paid.Request_Reference__c, tPaid).success, 'already paid');

        Purchase__c tampered = makePurchase('AL2', 20);
        String tTampered = issue(tampered);
        update new Purchase__c(Id = tampered.Id, Total_Amount__c = 999);
        Assert.isFalse(PaymentService.startPayment(tampered.Request_Reference__c, tTampered).success, 'stored total != price x quantity');

        Purchase__c noStock = makePurchase('AM2', 20);
        String tStock = issue(noStock);
        update new Ticket_Category__c(Id = noStock.Ticket_Category__c, Sold_Quantity__c = 295);
        Assert.isTrue(PaymentService.startPayment(noStock.Request_Reference__c, tStock).message.contains('no longer available'));
        update new Ticket_Category__c(Id = noStock.Ticket_Category__c, Sold_Quantity__c = 0);

        update new Event_Detail__c(Id = noStock.Event_Detail__c, Start_DateTime__c = System.now().addDays(-1));
        Assert.isTrue(PaymentService.startPayment(noStock.Request_Reference__c, tStock).message.contains('already started'));
        update new Event_Detail__c(Id = noStock.Event_Detail__c, Start_DateTime__c = System.now().addDays(20), Status__c = 'Draft');
        Assert.isTrue(PaymentService.startPayment(noStock.Request_Reference__c, tStock).message.contains('no longer available'));
        update new Event_Detail__c(Id = noStock.Event_Detail__c, Status__c = 'Published');

        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Site_Base_Url__c = 'https://x.example', Payments_Enabled__c = false);
        Assert.isFalse(PaymentService.startPayment(noStock.Request_Reference__c, tStock).success, 'feature flag off');
        Assert.isFalse(PaymentService.startPayment(noStock.Request_Reference__c, 'bad-token').success, 'bad token');
        Assert.areEqual(0, m.calls.size(), 'Stripe is never called for a refused request');
    }

    @IsTest
    static void stripeServerErrorsAreRetriedOnceAndShownSafely() {
        cfg();
        Purchase__c p = makePurchase('AN2', 20);
        String t = issue(p);
        StripeMock m = mock();
        m.addResponse('POST /v1/checkout/sessions', 500, '{"error":{"type":"api_error"}}');

        Test.startTest();
        PaymentDto.StartResult r = PaymentService.startPayment(p.Request_Reference__c, t);
        Test.stopTest();

        Assert.isFalse(r.success);
        Assert.areEqual(PaymentService.MSG_UNAVAILABLE, r.message);
        Assert.areEqual(2, m.count('POST /v1/checkout/sessions'), 'one automatic retry');
        Assert.areEqual(0, [SELECT COUNT() FROM Ticket_Payment__c WHERE Purchase__c = :p.Id]);
        Assert.isTrue([SELECT COUNT() FROM Integration_Log__c WHERE Outcome__c = 'Failure'] >= 1);
    }

    @IsTest
    static void aNetworkFailureIsRetriedAndTheRetrySucceeds() {
        cfg();
        Purchase__c p = makePurchase('AN3', 20);
        String t = issue(p);
        StripeMock m = mock();
        m.transportFailures = 1;                                    // network failure on the first call only
        m.addResponse('POST /v1/checkout/sessions', 200, session(SID1, 'open', 'unpaid', 100000L, 'usd', p.Request_Reference__c, null));

        Test.startTest();
        PaymentDto.StartResult r = PaymentService.startPayment(p.Request_Reference__c, t);
        Test.stopTest();

        Assert.isTrue(r.success, 'the retry succeeds: ' + r.message);
        Assert.areEqual(2, m.calls.size());
    }

    @IsTest
    static void anIdempotencyConflictShowsBusyAndLogsNoSecrets() {
        cfg();
        Purchase__c p2 = makePurchase('AP2', 20);
        String t2 = issue(p2);
        StripeMock m3 = mock();
        m3.addResponse('POST /v1/checkout/sessions', 400, '{"error":{"type":"idempotency_error","code":"idempotency_key_in_use"}}');

        Test.startTest();
        PaymentDto.StartResult r = PaymentService.startPayment(p2.Request_Reference__c, t2);
        Test.stopTest();

        Assert.areEqual(PaymentService.MSG_BUSY, r.message);
        Integration_Log__c fail = [SELECT Message__c FROM Integration_Log__c WHERE Message__c LIKE '%idempotency_error%' LIMIT 1];
        Assert.isFalse(fail.Message__c.containsIgnoreCase('sk_'));
    }

    @IsTest
    static void startWhenStripeCannotReportAnOpenSessionDoesNotOpenASecondOne() {
        cfg();
        Purchase__c p = makePurchase('AQ2', 20);
        String t = issue(p);
        attempt(p, SID1, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 503, '{}');
        Test.startTest();
        Assert.isFalse(PaymentService.startPayment(p.Request_Reference__c, t).success);
        Test.stopTest();
        Assert.areEqual(0, m.count('POST /v1/checkout/sessions'));
    }

    // ---------- verification ----------
    @IsTest
    static void verifyMarksPaidOnceAndIsIdempotent() {
        cfg();
        Purchase__c p = makePurchase('AR2', 20);
        String t = issue(p);
        Ticket_Payment__c a = attempt(p, SID1, 'Created');         // the session the buyer was sent to
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, 'complete', 'paid', 100000L, 'usd', p.Request_Reference__c, 'pi_test_one'));

        Test.startTest();
        PaymentDto.VerifyResult r1 = PaymentService.verifyPayment(p.Request_Reference__c, t, SID1);
        Integer getsBefore = m.count('GET /v1/checkout/sessions/' + SID1);
        // Refresh, second tab, replay: the attempt is Completed, so no callout is made.
        PaymentDto.VerifyResult r2 = PaymentService.verifyPayment(p.Request_Reference__c, t, SID1);
        Test.stopTest();

        Assert.areEqual('PAID', r1.outcome, r1.message);
        Ticket_Payment__c row = reload(a.Id);
        Assert.areEqual('Completed', row.Status__c);
        Assert.areEqual('pi_test_one', row.Capture_Id__c);
        Assert.isNotNull(row.Verified_On__c);
        Purchase__c paid = [SELECT Payment_Status__c, Paid_On__c FROM Purchase__c WHERE Id = :p.Id];
        Assert.areEqual('Paid', paid.Payment_Status__c);
        Assert.isNotNull(paid.Paid_On__c);
        Assert.areEqual('Closed Won', [SELECT StageName FROM Opportunity WHERE Id = :p.Opportunity__c].StageName);

        Assert.areEqual('PAID', r2.outcome);
        Assert.areEqual(getsBefore, m.count('GET /v1/checkout/sessions/' + SID1), 'no callout needed the second time');
        Assert.areEqual(20, [SELECT Sold_Quantity__c FROM Ticket_Category__c WHERE Id = :p.Ticket_Category__c].Sold_Quantity__c, 'tickets are not counted twice');
    }

    @IsTest
    static void verifyRejectsForgedMalformedAndForeignSessionIds() {
        cfg();
        Purchase__c p = makePurchase('AS2', 20);
        String t = issue(p);
        Purchase__c other = makePurchase('AT2', 20);
        attempt(other, SID3, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID3, 200, session(SID3, 'complete', 'paid', 100000L, 'usd', other.Request_Reference__c, 'pi_other'));
        for (String bad : new List<String>{ 'cs_test_unknownunknown1', 'not-a-session', '', SID3 }) {
            PaymentDto.VerifyResult r = PaymentService.verifyPayment(p.Request_Reference__c, t, bad);
            Assert.isFalse(r.success, 'rejected: ' + bad);
            Assert.areEqual(PaymentService.MSG_NOT_MATCHED, r.message);
        }
        Assert.areEqual('Awaiting Payment', purchaseStatus(p.Id));
        Assert.areEqual('Awaiting Payment', purchaseStatus(other.Id));
        Assert.areEqual(0, m.calls.size());
        Assert.isFalse(PaymentService.verifyPayment(p.Request_Reference__c, 'bad-token', SID1).success);
    }

    @IsTest
    static void paidSessionWithTheWrongAmountNeedsReview() {
        assertNeedsReview('AU2', 100L, 'usd', null, 'pi_1');
    }
    @IsTest
    static void paidSessionWithTheWrongCurrencyNeedsReview() {
        assertNeedsReview('AV2', 100000L, 'eur', null, 'pi_2');
    }
    @IsTest
    static void paidSessionWithAnotherReferenceNeedsReview() {
        assertNeedsReview('AW2', 100000L, 'usd', 'TT-20261021-OTHER2', 'pi_3');
    }
    @IsTest
    static void paidSessionWithoutAPaymentIdNeedsReview() {
        assertNeedsReview('AX2', 100000L, 'usd', null, null);
    }

    @IsTest
    static void anOpenSessionIsRecordedAsPending() {
        assertRecorded('AY2', 'open', 'unpaid', null, 'PENDING', 'Pending', 'Pending');
    }
    @IsTest
    static void anExpiredSessionIsRecordedAsCancelled() {
        assertRecorded('AZ2', 'expired', 'unpaid', null, 'CANCELLED', 'Cancelled', 'Cancelled');
    }
    @IsTest
    static void aCompleteButUnpaidSessionIsRecordedAsPending() {
        assertRecorded('BA2', 'complete', 'unpaid', 'pi_x', 'PENDING', 'Pending', null);
    }

    @IsTest
    static void verifyWhenStripeIsDownLeavesStateUntouched() {
        cfg();
        Purchase__c p = makePurchase('BB2', 20);
        String t = issue(p);
        Ticket_Payment__c a = attempt(p, SID1, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 503, '{}');
        Test.startTest();
        PaymentDto.VerifyResult r = PaymentService.verifyPayment(p.Request_Reference__c, t, SID1);
        Test.stopTest();
        Assert.areEqual('PENDING', r.outcome);
        Assert.areEqual('Created', reload(a.Id).Status__c);
        Assert.areEqual('Awaiting Payment', purchaseStatus(p.Id));
    }

    @IsTest
    static void aSecondPaidSessionOnAnAlreadyPaidPurchaseIsFlaggedNotCounted() {
        cfg();
        Purchase__c p = makePurchase('BC2', 20);
        String t = issue(p);
        // State after the first session was verified as paid.
        Ticket_Payment__c first = attempt(p, SID1, 'Completed');
        Ticket_Payment__c second = attempt(p, SID2, 'Created');
        update new Purchase__c(Id = p.Id, Payment_Status__c = 'Paid', Paid_On__c = Datetime.now());
        update new Ticket_Category__c(Id = p.Ticket_Category__c, Sold_Quantity__c = 20);
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID2, 200, session(SID2, 'complete', 'paid', 100000L, 'usd', p.Request_Reference__c, 'pi_second'));

        Test.startTest();
        PaymentDto.VerifyResult dup = PaymentService.verifyPayment(p.Request_Reference__c, t, SID2);
        Test.stopTest();

        Assert.areEqual('DUPLICATE', dup.outcome, dup.message);
        Assert.areEqual('Failed', reload(second.Id).Status__c);
        Assert.isTrue(reload(second.Id).Status_Detail__c.contains('Refund'));
        Assert.areEqual('Completed', reload(first.Id).Status__c);
        Assert.areEqual(20, [SELECT Sold_Quantity__c FROM Ticket_Category__c LIMIT 1].Sold_Quantity__c, 'not counted twice');
        Assert.areEqual('Paid', purchaseStatus(p.Id));
    }

    @IsTest
    static void paymentIsHonouredButFlaggedWhenTheLastTicketsWereTakenMeanwhile() {
        cfg();
        Purchase__c p = makePurchase('BD2', 20);
        String t = issue(p);
        Ticket_Payment__c a = attempt(p, SID1, 'Created');
        update new Ticket_Category__c(Id = p.Ticket_Category__c, Sold_Quantity__c = 290);
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, 'complete', 'paid', 100000L, 'usd', p.Request_Reference__c, 'pi_over'));

        Test.startTest();
        PaymentDto.VerifyResult r = PaymentService.verifyPayment(p.Request_Reference__c, t, SID1);
        Test.stopTest();

        Assert.areEqual('PAID', r.outcome, r.message);
        Assert.isTrue(reload(a.Id).Status_Detail__c.contains('oversold'));
        Assert.areEqual(1, [SELECT COUNT() FROM Integration_Log__c WHERE Operation__c = 'OversoldAlert']);
    }

    // ---------- cancel and staff re-verify ----------
    @IsTest
    static void cancelClosesTheStripeSessionBeforeRecordingIt() {
        cfg();
        Purchase__c p = makePurchase('BE2', 20);
        String t = issue(p);
        Ticket_Payment__c a = attempt(p, SID1, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, 'open', 'unpaid', 100000L, 'usd', p.Request_Reference__c, null));
        m.addResponse('POST /v1/checkout/sessions/' + SID1 + '/expire', 200, session(SID1, 'expired', 'unpaid', 100000L, 'usd', p.Request_Reference__c, null));

        Test.startTest();
        PaymentDto.VerifyResult r = PaymentService.cancelAttempt(p.Request_Reference__c, t);
        // Nothing is open any more, so the second cancel makes no callout.
        PaymentDto.VerifyResult again = PaymentService.cancelAttempt(p.Request_Reference__c, t);
        Test.stopTest();

        Assert.areEqual('CANCELLED', r.outcome, r.message);
        Assert.areEqual(1, m.count('POST /v1/checkout/sessions/' + SID1 + '/expire'));
        Assert.areEqual('Cancelled', reload(a.Id).Status__c);
        Assert.areEqual('Cancelled', purchaseStatus(p.Id));
        Assert.areEqual('CANCELLED', again.outcome, 'nothing left to cancel');
    }

    @IsTest
    static void cancelNeverOverwritesARealPayment() {
        cfg();
        Purchase__c p = makePurchase('BF2', 20);
        String t = issue(p);
        attempt(p, SID1, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, 'complete', 'paid', 100000L, 'usd', p.Request_Reference__c, 'pi_late'));

        Test.startTest();
        PaymentDto.VerifyResult r = PaymentService.cancelAttempt(p.Request_Reference__c, t);
        Test.stopTest();

        Assert.areEqual('PAID', r.outcome, r.message);
        Assert.areEqual('Paid', purchaseStatus(p.Id));
        Assert.areEqual(0, m.count('POST /v1/checkout/sessions/' + SID1 + '/expire'));
    }

    @IsTest
    static void cancelFailsSafelyWhenStripeCannotExpireTheSession() {
        cfg();
        Purchase__c p = makePurchase('BG2', 20);
        String t = issue(p);
        Ticket_Payment__c a = attempt(p, SID1, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, 'open', 'unpaid', 100000L, 'usd', p.Request_Reference__c, null));
        m.addResponse('POST /v1/checkout/sessions/' + SID1 + '/expire', 400, '{"error":{"type":"invalid_request_error"}}');
        Test.startTest();
        Assert.isFalse(PaymentService.cancelAttempt(p.Request_Reference__c, t).success);
        Test.stopTest();
        Assert.areEqual('Created', reload(a.Id).Status__c, 'we do not claim it is cancelled if it is not');
    }

    @IsTest
    static void staffReverifyCatchesAPaymentWhoseReturnWasMissed() {
        cfg();
        Purchase__c p = makePurchase('BH2', 20);
        Assert.areEqual('NONE', PaymentService.reverifyLatest(p.Id).outcome, 'no open attempt');
        Ticket_Payment__c a = attempt(p, SID1, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, 'complete', 'paid', 100000L, 'usd', p.Request_Reference__c, 'pi_missed'));

        Test.startTest();
        PaymentDto.VerifyResult r = PaymentService.reverifyLatest(p.Id);
        PaymentDto.VerifyResult again = PaymentService.reverifyLatest(p.Id);      // no open attempt left: no callout
        PaymentDto.VerifyResult unknown = PaymentService.reverifyLatest(UserInfo.getUserId());
        Test.stopTest();

        Assert.areEqual('PAID', r.outcome, r.message);
        Assert.areEqual('Completed', reload(a.Id).Status__c);
        Assert.areEqual('PAID', again.outcome, 'already paid');
        Assert.isFalse(unknown.success, 'unknown purchase');
    }

    // ---------- controllers ----------
    @IsTest
    static void guestControllerStartsAPaymentWithAValidLink() {
        cfg();
        Purchase__c p = makePurchase('BJ2', 20);
        String t = issue(p);
        StripeMock m = mock();
        m.addResponse('POST /v1/checkout/sessions', 200, session(SID1, 'open', 'unpaid', 100000L, 'usd', p.Request_Reference__c, null));
        Assert.isTrue(PaymentPageController.getContext(p.Request_Reference__c, t).valid);
        PaymentDto.Context bad = PaymentPageController.getContext(p.Request_Reference__c, 'nope');
        Assert.isFalse(bad.valid);
        Assert.areEqual(PaymentService.MSG_INVALID_LINK, bad.message);

        Test.startTest();
        PaymentDto.StartResult r = PaymentPageController.startPayment(p.Request_Reference__c, t);
        Test.stopTest();
        Assert.isTrue(r.success, 'start failed: ' + r.message);
    }

    @IsTest
    static void guestControllerVerifiesAndHidesUnexpectedErrors() {
        cfg();
        Purchase__c p = makePurchase('BJ3', 20);
        String t = issue(p);
        attempt(p, SID1, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, 'complete', 'paid', 100000L, 'usd', p.Request_Reference__c, 'pi_ctl'));

        Test.startTest();
        PaymentDto.VerifyResult v = PaymentPageController.verifyPayment(p.Request_Reference__c, t, SID1);
        PaymentDto.VerifyResult c = PaymentPageController.cancelAttempt(p.Request_Reference__c, t);   // already paid: no callout
        Test.stopTest();
        Assert.areEqual('PAID', v.outcome, v.message);
        Assert.areEqual('PAID', c.outcome);

        PaymentPageController.simulateUnexpectedError = true;
        Assert.areEqual(PaymentService.MSG_UNAVAILABLE, PaymentPageController.getContext('x', 'y').message);
        Assert.areEqual(PaymentService.MSG_UNAVAILABLE, PaymentPageController.startPayment('x', 'y').message);
        Assert.areEqual('ERROR', PaymentPageController.verifyPayment('x', 'y', 'z').outcome);
        Assert.areEqual('ERROR', PaymentPageController.cancelAttempt('x', 'y').outcome);
    }

    @IsTest
    static void staffControllerEnforcesThePermissionAndShowsAttempts() {
        cfg();
        Purchase__c p = makePurchase('BK2', 20);
        Ticket_Payment__c a = attempt(p, SID1, 'Created');
        StripeMock m = mock();
        m.addResponse('GET /v1/checkout/sessions/' + SID1, 200, session(SID1, 'complete', 'paid', 100000L, 'usd', p.Request_Reference__c, 'pi_staff'));

        Test.startTest();
        System.runAs(outsider()) {
            Assert.isFalse(PurchasePaymentController.sendPaymentLink(p.Id).success, 'no permission');
            Assert.areEqual('ERROR', PurchasePaymentController.reverifyPayment(p.Id).outcome, 'no permission');
            Assert.isFalse(PurchasePaymentController.getOverview(p.Id).canManage);
        }
        System.runAs(reviewer()) {
            PaymentDto.Overview o = PurchasePaymentController.getOverview(p.Id);
            Assert.isTrue(o.canManage);
            Assert.areEqual(1, o.attempts.size());
            Assert.areEqual(SID1.right(8), o.attempts[0].providerRef, 'only the last 8 characters are shown');
            Assert.areEqual('PAID', PurchasePaymentController.reverifyPayment(p.Id).outcome);
        }
        Test.stopTest();
        Assert.areEqual('Completed', reload(a.Id).Status__c);

        try {
            PurchasePaymentController.getOverview(UserInfo.getUserId());
            Assert.fail('expected a safe error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Something went wrong'));
        }
        PurchasePaymentController.simulateUnexpectedError = true;
        System.runAs(reviewer()) {
            Assert.isFalse(PurchasePaymentController.sendPaymentLink(p.Id).success);
            Assert.areEqual('ERROR', PurchasePaymentController.reverifyPayment(p.Id).outcome);
        }
    }

    @IsTest
    static void staffCanSendThePaymentLink() {
        cfg();
        Purchase__c p = makePurchase('BK3', 20);
        System.runAs(reviewer()) {
            PaymentLinkService.SendResult sent = PurchasePaymentController.sendPaymentLink(p.Id);
            Assert.isTrue(sent.success, sent.message);
            Assert.isTrue(sent.emailSent);
            Assert.isNull(sent.link, 'the link is only returned when the email failed');
        }
    }

    // ---------- logging and config ----------
    @IsTest
    static void logsNeverContainKeysOrBearerTokens() {
        String dirty = 'Bearer abc123 and sk_test_ABCdef123 and rk_live_XYZ789 plus ' + 'x'.repeat(400);
        String clean = IntegrationLogger.sanitize(dirty);
        Assert.isFalse(clean.contains('abc123'));
        Assert.isFalse(clean.contains('sk_test_'));
        Assert.isFalse(clean.contains('rk_live_'));
        Assert.isTrue(clean.length() <= 255);
        Assert.isNull(IntegrationLogger.sanitize(null));
        IntegrationLogger.add('Stripe', 'Test', 200, true, 'corr', 'ok', null);
        IntegrationLogger.flush();
        IntegrationLogger.flush();     // second flush is a no-op
        Assert.areEqual(1, [SELECT COUNT() FROM Integration_Log__c WHERE Operation__c = 'Test']);
    }

    @IsTest
    static void paymentConfigFallsBackToSafeDefaultsAndClamps() {
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt();
        Assert.areEqual(168, TwinTicketConfig.paymentTokenHours());
        Assert.areEqual(60, TwinTicketConfig.paymentSessionMinutes());
        Assert.areEqual('usd', TwinTicketConfig.paymentCurrency());
        Assert.areEqual('', TwinTicketConfig.siteBaseUrl());
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Payment_Session_Minutes__c = 5, Payment_Token_Hours__c = 99999,
            Payment_Currency__c = 'EUR', Site_Base_Url__c = 'https://x.example///');
        Assert.areEqual(30, TwinTicketConfig.paymentSessionMinutes(), 'Stripe minimum');
        Assert.areEqual(720, TwinTicketConfig.paymentTokenHours(), 'upper clamp');
        Assert.areEqual('eur', TwinTicketConfig.paymentCurrency());
        Assert.areEqual('https://x.example', TwinTicketConfig.siteBaseUrl());
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Payment_Session_Minutes__c = 5000, Payment_Currency__c = 'dollars');
        Assert.areEqual(1380, TwinTicketConfig.paymentSessionMinutes(), 'Stripe maximum minus rounding room');
        Assert.areEqual('usd', TwinTicketConfig.paymentCurrency(), 'invalid currency falls back');
    }
}