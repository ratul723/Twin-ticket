@IsTest
private class PortalTest {

    @TestSetup
    static void setup() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        List<Profile> ext = [SELECT Id FROM Profile WHERE Name = :TwinTicketConfig.portalProfileName() LIMIT 1];
        Assert.isFalse(ext.isEmpty(), 'External profile "' + TwinTicketConfig.portalProfileName()
            + '" not found. Set Portal_Profile_Name__c or enable the license.');
        List<PermissionSet> custPs = [SELECT Id FROM PermissionSet WHERE Name = 'Twin_Ticket_Customer' LIMIT 1];
        Assert.isFalse(custPs.isEmpty(), 'Permission set Twin_Ticket_Customer is missing.');

        User owner; User reviewer; User outsider;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            UserRole role = new UserRole(Name = 'TT Test Owner Role', DeveloperName = 'TT_Test_Owner_Role');
            insert role;
            owner = makeUser(admin.Id, 'ptown'); owner.UserRoleId = role.Id;
            reviewer = makeUser(admin.Id, 'ptrv');
            outsider = makeUser(admin.Id, 'ptout');
            insert new List<User>{ owner, reviewer, outsider };
            PermissionSet ps = new PermissionSet(Name = 'TT_Portal_Test_Reviewer', Label = 'TT Portal Test Reviewer');
            insert ps;
            CustomPermission cp = [SELECT Id FROM CustomPermission WHERE DeveloperName = 'Review_Bulk_Requests' LIMIT 1];
            insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cp.Id);
            insert new PermissionSetAssignment(AssigneeId = reviewer.Id, PermissionSetId = ps.Id);
        }

        Event_Detail__c ev = new Event_Detail__c(Name = 'Portal Summit', Status__c = 'Published', Start_DateTime__c = System.now().addDays(30),
            Time_Zone__c = 'Asia/Dhaka', Venue_Name__c = 'Test Hall');
        insert ev;
        Ticket_Category__c cat = new Ticket_Category__c(Name = 'Standard', Event_Detail__c = ev.Id, Price__c = 50, Total_Quantity__c = 300, Sold_Quantity__c = 0);
        insert cat;

        // Buyers. Accounts owned by a user WITH a role, except G (owner without a role).
        Map<String, Contact> contacts = new Map<String, Contact>();
        List<Purchase__c> purchases = new List<Purchase__c>();
        System.runAs(owner) {
            for (String k : new List<String>{ 'A', 'B', 'C', 'D', 'E', 'F' }) {
                Account a = new Account(Name = 'Portal Org ' + k, OwnerId = owner.Id);
                insert a;
                Contact c = new Contact(AccountId = a.Id, FirstName = 'Pat', LastName = 'Buyer' + k,
                    Email = k == 'E' ? null : 'buyer' + k.toLowerCase() + '@example.com');
                insert c;
                contacts.put(k, c);
            }
        }
        Account ag = new Account(Name = 'Portal Org G', OwnerId = reviewer.Id);     // owner without a role
        insert ag;
        Contact cg = new Contact(AccountId = ag.Id, FirstName = 'Pat', LastName = 'BuyerG', Email = 'buyerg@example.com');
        insert cg;
        contacts.put('G', cg);

        Map<String, String> refs = new Map<String, String>{
            'A1' => 'PTLA01', 'A2' => 'PTLA02', 'B1' => 'PTLB01', 'C1' => 'PTLC01', 'D1' => 'PTLD01', 'E1' => 'PTLE01', 'F1' => 'PTLF01', 'G1' => 'PTLG01' };
        Set<String> unpaid = new Set<String>{ 'A2', 'D1' };
        for (String key : refs.keySet()) {
            Contact c = contacts.get(key.left(1));
            purchases.add(new Purchase__c(Account__c = c.AccountId, Contact__c = c.Id, Event_Detail__c = ev.Id, Ticket_Category__c = cat.Id,
                Quantity__c = 20, Unit_Price__c = 50, Total_Amount__c = 1000, Request_Reference__c = 'TT-20261021-' + refs.get(key),
                Payment_Status__c = unpaid.contains(key) ? 'Awaiting Payment' : 'Paid', Paid_On__c = unpaid.contains(key) ? null : System.now()));
        }
        insert purchases;
        Purchase__c a1 = [SELECT Id FROM Purchase__c WHERE Request_Reference__c = 'TT-20261021-PTLA01'];
        insert new Ticket_Payment__c(Purchase__c = a1.Id, Provider__c = 'Stripe', Provider_Order_Id__c = 'cs_test_portal000001',
            Capture_Id__c = 'pi_test_abcd1234', Amount__c = 1000, Currency_Code__c = 'USD', Status__c = 'Completed', Verified_On__c = System.now());

        // Existing portal users for A, B and F. Manual shares stand in for the Sharing Set (layer 1).
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<User> portal = new List<User>();
            for (String k : new List<String>{ 'A', 'B', 'F' }) {
                Contact c = contacts.get(k);
                User u = makeUser(ext[0].Id, 'ptp' + k.toLowerCase());
                u.ContactId = c.Id;
                u.Username = 'portal' + k.toLowerCase() + String.valueOf(Math.abs(Crypto.getRandomLong())) + '@twinticket-test.example.com';
                u.Email = 'buyer' + k.toLowerCase() + '@example.com';
                u.LastName = 'Buyer' + k;
                u.CommunityNickname = 'ttnick' + k + String.valueOf(Math.abs(Crypto.getRandomLong()));
                portal.add(u);
            }
            insert portal;
            List<PermissionSetAssignment> psa = new List<PermissionSetAssignment>();
            for (User u : portal) { psa.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = custPs[0].Id)); }
            insert psa;
        }
        Map<String, Id> userByAlias = new Map<String, Id>();
        for (User u : [SELECT Id, Alias FROM User WHERE Alias IN ('ptpa', 'ptpb', 'ptpf')]) { userByAlias.put(u.Alias, u.Id); }
        List<Purchase__Share> shares = new List<Purchase__Share>();
        for (Purchase__c p : [SELECT Id, Request_Reference__c FROM Purchase__c WHERE Request_Reference__c IN ('TT-20261021-PTLA01', 'TT-20261021-PTLA02')]) {
            shares.add(new Purchase__Share(ParentId = p.Id, UserOrGroupId = userByAlias.get('ptpa'), AccessLevel = 'Read', RowCause = 'Manual'));
        }
        shares.add(new Purchase__Share(ParentId = [SELECT Id FROM Purchase__c WHERE Request_Reference__c = 'TT-20261021-PTLB01'].Id,
            UserOrGroupId = userByAlias.get('ptpb'), AccessLevel = 'Read', RowCause = 'Manual'));
        insert shares;
    }

    // ---------- helpers ----------
    private static User makeUser(Id profileId, String alias) {
        String uniq = String.valueOf(Math.abs(Crypto.getRandomLong()));
        return new User(Alias = alias, Email = alias + uniq + '@example.com', EmailEncodingKey = 'UTF-8', LastName = alias,
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = profileId, TimeZoneSidKey = 'Asia/Dhaka',
            Username = alias + uniq + '@twinticket-test.example.com');
    }
    private static User byAlias(String alias) { return [SELECT Id, ContactId FROM User WHERE Alias = :alias LIMIT 1]; }
    private static Purchase__c pur(String suffix) {
        return [SELECT Id, Contact__c, Payment_Status__c, Request_Reference__c FROM Purchase__c WHERE Request_Reference__c = :('TT-20261021-PTL' + suffix) LIMIT 1];
    }
    private static Portal_Provision__e evt(Id purchaseId) { return new Portal_Provision__e(Purchase_Id__c = String.valueOf(purchaseId)); }
    private static String loadError(Id purchaseId, Boolean requirePaid) {
        try { PortalPurchaseService.loadAuthorized(purchaseId, requirePaid); }
        catch (PortalPurchaseService.PortalException e) { return e.getMessage(); }
        return null;
    }
    private static ConfirmationPdfController pdfFor(Id purchaseId) {
        Test.setCurrentPage(Page.TwinTicketConfirmation);
        if (purchaseId != null) { ApexPages.currentPage().getParameters().put('id', String.valueOf(purchaseId)); }
        ConfirmationPdfController c = new ConfirmationPdfController();
        c.init();
        return c;
    }
    private static void cfg() {
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Site_Base_Url__c = 'https://example.my.site.com/twinticket/s',
            Payment_Currency__c = 'usd', Portal_Enabled__c = true);
    }

    // ================= record-level access =================
    @IsTest
    static void aCustomerSeesOnlyTheirOwnPurchases() {
        System.runAs(byAlias('ptpa')) {
            PortalPurchaseService.MyPurchases r = PortalPurchaseController.getMyPurchases();
            Assert.isTrue(r.isCustomer);
            Assert.areEqual(2, r.items.size());
            Set<String> refs = new Set<String>();
            for (PortalPurchaseService.PurchaseView v : r.items) {
                refs.add(v.reference);
                Assert.areEqual('Portal Summit', v.eventName);
                Assert.areEqual('Standard', v.categoryName);
                Assert.areEqual(v.statusCode == 'Paid', v.canDownload, 'only paid purchases can be downloaded');
            }
            Assert.isTrue(refs.contains('TT-20261021-PTLA01'));
            Assert.isTrue(refs.contains('TT-20261021-PTLA02'));
            Assert.isFalse(refs.contains('TT-20261021-PTLB01'), 'never another customer\'s purchase');
        }
        System.runAs(byAlias('ptpb')) {
            Assert.areEqual(1, PortalPurchaseService.listMine().items.size());
        }
    }

    @IsTest
    static void aCustomerCannotOpenAnotherCustomersPurchaseByIdOrUrl() {
        Id foreign = pur('B1').Id;
        System.runAs(byAlias('ptpa')) {
            Assert.areEqual(PortalPurchaseService.MSG_NOT_FOUND, loadError(foreign, true), 'layers 1 to 3 block it');
            Assert.areEqual(PortalPurchaseService.MSG_NOT_FOUND, loadError(null, true));
            Assert.areEqual(PortalPurchaseService.MSG_NOT_FOUND, loadError(UserInfo.getUserId(), true), 'wrong object type');
            Assert.areEqual(PortalPurchaseService.MSG_NOT_FOUND, loadError(pur('G1').Id, true));
        }
    }

    @IsTest
    static void aMistakenShareStillCannotLeakAnotherCustomersPurchase() {
        Id foreign = pur('B1').Id;
        Id userA = byAlias('ptpa').Id;
        insert new Purchase__Share(ParentId = foreign, UserOrGroupId = userA, AccessLevel = 'Read', RowCause = 'Manual');   // misconfiguration
        System.runAs(byAlias('ptpa')) {
            Assert.areEqual(PortalPurchaseService.MSG_NOT_FOUND, loadError(foreign, true), 'layer 3: the explicit Account filter holds');
            for (PortalPurchaseService.PurchaseView v : PortalPurchaseService.listMine().items) {
                Assert.areNotEqual('TT-20261021-PTLB01', v.reference);
            }
        }
    }

    @IsTest
    static void withoutPlatformSharingTheCustomerSeesNothing() {
        delete [SELECT Id FROM Purchase__Share WHERE UserOrGroupId = :byAlias('ptpa').Id];
        System.runAs(byAlias('ptpa')) {
            Assert.areEqual(0, PortalPurchaseService.listMine().items.size(), 'layer 1 and 2: no share, no data');
            Assert.areEqual(PortalPurchaseService.MSG_NOT_FOUND, loadError(pur('A1').Id, true));
        }
    }

    @IsTest
    static void internalUsersWithoutThePermissionAndStaffWithItBehaveCorrectly() {
        User outsider = byAlias('ptout');
        System.runAs(outsider) {
            PortalPurchaseService.MyPurchases r = PortalPurchaseService.listMine();
            Assert.isFalse(r.isCustomer);
            Assert.isTrue(r.items.isEmpty(), 'an internal user gets no purchases from the portal method');
            Assert.areEqual(PortalPurchaseService.MSG_NOT_FOUND, loadError(pur('A1').Id, true));
        }
        System.runAs(byAlias('ptrv')) {
            Assert.isNotNull(PortalPurchaseService.loadAuthorized(pur('A1').Id, true), 'a reviewer may preview');
        }
    }

    @IsTest
    static void unpaidPurchasesHaveNoConfirmation() {
        System.runAs(byAlias('ptpa')) {
            Assert.areEqual(PortalPurchaseService.MSG_NOT_PAID, loadError(pur('A2').Id, true));
            Assert.isNotNull(PortalPurchaseService.loadAuthorized(pur('A2').Id, false), 'viewing is allowed, downloading is not');
        }
    }

    @IsTest
    static void portalControllerHidesUnexpectedErrors() {
        PortalPurchaseController.simulateUnexpectedError = true;
        System.runAs(byAlias('ptpa')) {
            try {
                PortalPurchaseController.getMyPurchases();
                Assert.fail('expected a safe error');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('could not load'));
            }
        }
    }

    // ================= PDF =================
    @IsTest
    static void ownerOfAPaidPurchaseGetsAConfirmationWithMaskedPaymentReference() {
        System.runAs(byAlias('ptpa')) {
            ConfirmationPdfController c = pdfFor(pur('A1').Id);
            Assert.isTrue(c.available, c.message);
            Assert.areEqual('TT-20261021-PTLA01', c.reference);
            Assert.areEqual('Portal Summit', c.eventName);
            Assert.areEqual('Standard', c.categoryName);
            Assert.areEqual('20', c.quantity);
            Assert.areEqual('USD 1,000.00', c.total);
            Assert.areEqual('ABCD1234', c.paymentReference, 'only the last 8 characters, never the full id');
            Assert.areEqual('Portal Org A', c.organization);
            Assert.isNotNull(c.paidOn);
            Assert.isTrue(ApexPages.currentPage().getHeaders().get('Content-Disposition').contains('attachment'));
        }
    }

    @IsTest
    static void confirmationIsRefusedForForeignUnpaidMissingAndMalformedIds() {
        System.runAs(byAlias('ptpa')) {
            Assert.isFalse(pdfFor(pur('B1').Id).available, 'someone else\'s purchase');
            ConfirmationPdfController unpaid = pdfFor(pur('A2').Id);
            Assert.isFalse(unpaid.available);
            Assert.areEqual(PortalPurchaseService.MSG_NOT_PAID, unpaid.message);
            Assert.isFalse(pdfFor(null).available, 'no id');
            Test.setCurrentPage(Page.TwinTicketConfirmation);
            ApexPages.currentPage().getParameters().put('id', 'not-an-id');
            ConfirmationPdfController bad = new ConfirmationPdfController();
            bad.init();
            Assert.isFalse(bad.available);
            Assert.areEqual('This confirmation is not available.', bad.message, 'one neutral message, no detail');
        }
        Assert.isFalse(pdfFor(pur('A1').Id).available, 'the running admin is neither a customer nor a reviewer');
    }

    @IsTest
    static void reviewersCanPreviewAConfirmation() {
        System.runAs(byAlias('ptrv')) {
            Assert.isTrue(pdfFor(pur('A1').Id).available);
        }
    }

    // ================= provisioning =================
    @IsTest
    static void aPaidPurchaseGetsAPortalUserPermissionSetAndOneEmail() {
        cfg();
        Purchase__c c = pur('C1');
        PortalProvisioningService.emailsSent = 0;
        Test.startTest();
        PortalProvisioningService.handleEvents(new List<Portal_Provision__e>{ evt(c.Id) });
        Test.stopTest();

        Assert.areEqual('CREATED', PortalProvisioningService.lastResults[0].outcome, PortalProvisioningService.lastResults[0].detail);
        User u = [SELECT Id, Username, IsActive, Profile.Name FROM User WHERE ContactId = :c.Contact__c];
        Assert.isTrue(u.IsActive);
        Assert.isTrue(u.Username.endsWith('.tt'));
        Assert.areEqual(TwinTicketConfig.portalProfileName(), u.Profile.Name);
        Assert.areEqual(1, [SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :u.Id AND PermissionSet.Name = 'Twin_Ticket_Customer']);
        Assert.areEqual(1, PortalProvisioningService.emailsSent);
        Assert.areEqual(1, [SELECT COUNT() FROM Integration_Log__c WHERE Operation__c = 'ProvisionPortalUser' AND Outcome__c = 'Success'],
            'the log is written by the queueable');
    }

    @IsTest
    static void aRepeatedEventNeverCreatesASecondUserOrEmail() {
        cfg();
        Purchase__c c = pur('C1');
        PortalProvisioningService.emailsSent = 0;
        Test.startTest();
        PortalProvisioningService.handleEvents(new List<Portal_Provision__e>{ evt(c.Id) });
        PortalProvisioningService.handleEvents(new List<Portal_Provision__e>{ evt(c.Id) });
        Test.stopTest();
        Assert.areEqual('EXISTS', PortalProvisioningService.lastResults[0].outcome);
        Assert.areEqual(1, [SELECT COUNT() FROM User WHERE ContactId = :c.Contact__c]);
        Assert.areEqual(1, PortalProvisioningService.emailsSent);
    }

    @IsTest
    static void aForgedEventForAnUnpaidPurchaseProvisionsNobody() {
        cfg();
        Purchase__c d = pur('D1');
        Test.startTest();
        PortalProvisioningService.handleEvents(new List<Portal_Provision__e>{ evt(d.Id), new Portal_Provision__e(Purchase_Id__c = 'garbage'),
            new Portal_Provision__e(Purchase_Id__c = String.valueOf(UserInfo.getUserId())) });
        Test.stopTest();
        Assert.areEqual(0, [SELECT COUNT() FROM User WHERE ContactId = :d.Contact__c]);
        Assert.areEqual('SKIPPED', PortalProvisioningService.lastResults[0].outcome);
    }

    @IsTest
    static void existingPortalUsersAreRecognised() {
        cfg();
        Purchase__c f = pur('F1');
        Test.startTest();
        PortalProvisioningService.handleEvents(new List<Portal_Provision__e>{ evt(f.Id) });
        Test.stopTest();
        Assert.areEqual('EXISTS', PortalProvisioningService.lastResults[0].outcome);
        Assert.areEqual(1, [SELECT COUNT() FROM User WHERE ContactId = :f.Contact__c]);
    }

    @IsTest
    static void configurationProblemsFailSafelyWithAClearReason() {
        Purchase__c e = pur('E1');
        Purchase__c c = pur('C1');
        cfg();
        Test.startTest();
        PortalProvisioningService.handleEvents(new List<Portal_Provision__e>{ evt(e.Id) });
        Assert.areEqual('FAILED', PortalProvisioningService.lastResults[0].outcome);
        Assert.isTrue(PortalProvisioningService.lastResults[0].detail.contains('no email'));

        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Portal_Profile_Name__c = 'No Such Profile Anywhere', Portal_Enabled__c = true);
        PortalProvisioningService.handleEvents(new List<Portal_Provision__e>{ evt(c.Id) });
        Assert.areEqual('FAILED', PortalProvisioningService.lastResults[0].outcome);
        Assert.isTrue(PortalProvisioningService.lastResults[0].detail.contains('was not found'));

        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Portal_Enabled__c = false);
        PortalProvisioningService.handleEvents(new List<Portal_Provision__e>{ evt(c.Id) });
        Assert.areEqual('SKIPPED', PortalProvisioningService.lastResults[0].outcome);
        Test.stopTest();
        Assert.areEqual(0, [SELECT COUNT() FROM User WHERE ContactId = :c.Contact__c]);
    }

    @IsTest
    static void anAccountOwnerWithoutARoleIsHandledWithoutCrashing() {
        cfg();
        Purchase__c g = pur('G1');
        Test.startTest();
        PortalProvisioningService.handleEvents(new List<Portal_Provision__e>{ evt(g.Id) });
        Test.stopTest();
        PortalProvisioningService.ProvisionResult r = PortalProvisioningService.lastResults[0];
        Assert.isTrue(r.outcome == 'FAILED' || r.outcome == 'CREATED', 'never an unhandled exception');
        if (r.outcome == 'FAILED') { Assert.isTrue(r.detail.contains('could not be created')); }
        Assert.isTrue([SELECT COUNT() FROM Integration_Log__c WHERE Operation__c = 'ProvisionPortalUser'] >= 1);
    }

    @IsTest
    static void aPublishedEventIsHandledByTheTrigger() {
        cfg();
        Purchase__c c = pur('C1');
        Test.startTest();
        Assert.isTrue(PortalProvisioningService.requestProvisioning(c.Id));
        Test.getEventBus().deliver();
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM User WHERE ContactId = :c.Contact__c]);
    }

    // ================= staff support =================
    @IsTest
    static void staffCanSeeStateRequestAccessAndSendPasswordEmails() {
        cfg();
        Purchase__c c = pur('C1');
        Purchase__c f = pur('F1');
        Purchase__c d = pur('D1');
        Assert.areEqual('NONE', PortalProvisioningService.infoForPurchase(c.Id).state);
        Assert.areEqual('NOT_PAID', PortalProvisioningService.infoForPurchase(d.Id).state);
        PortalProvisioningService.PortalInfo info = PortalProvisioningService.infoForPurchase(f.Id);
        Assert.areEqual('ACTIVE', info.state);
        Assert.isNotNull(info.username);
        Assert.areEqual('NOT_PAID', PortalProvisioningService.infoForPurchase(UserInfo.getUserId()).state);

        Assert.isTrue(PortalProvisioningService.resendPasswordEmail(f.Id));
        Assert.isFalse(PortalProvisioningService.resendPasswordEmail(c.Id), 'no user yet');
        Assert.isFalse(PortalProvisioningService.resendPasswordEmail(d.Id), 'unpaid');

        System.runAs(byAlias('ptout')) {
            Assert.areEqual('ERROR', PurchasePaymentController.requestPortalAccess(c.Id).outcome, 'no permission');
            Assert.areEqual('ERROR', PurchasePaymentController.sendPasswordReset(f.Id).outcome, 'no permission');
        }
        Test.startTest();
        System.runAs(byAlias('ptrv')) {
            PaymentDto.Overview before = PurchasePaymentController.getOverview(c.Id);
            Assert.areEqual('NONE', before.portalAccess);
            Assert.isTrue(before.canPreviewPdf);
            Assert.areEqual('ERROR', PurchasePaymentController.requestPortalAccess(d.Id).outcome, 'unpaid');
            Assert.areEqual('OK', PurchasePaymentController.requestPortalAccess(c.Id).outcome);
            Assert.areEqual('OK', PurchasePaymentController.sendPasswordReset(f.Id).outcome);
            Assert.areEqual('ERROR', PurchasePaymentController.sendPasswordReset(c.Id).outcome, 'no user to email');
        }
        Test.getEventBus().deliver();
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM User WHERE ContactId = :c.Contact__c]);
    }

    @IsTest
    static void staffControllerHidesUnexpectedErrors() {
        PurchasePaymentController.simulateUnexpectedError = true;
        System.runAs(byAlias('ptrv')) {
            Assert.areEqual('ERROR', PurchasePaymentController.requestPortalAccess(pur('C1').Id).outcome);
            Assert.areEqual('ERROR', PurchasePaymentController.sendPasswordReset(pur('F1').Id).outcome);
        }
    }

    // ================= config and logging =================
    @IsTest
    static void portalConfigFallsBackToSafeDefaults() {
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt();
        Assert.areEqual('Customer Community User', TwinTicketConfig.portalProfileName());
        Assert.isTrue(TwinTicketConfig.portalEnabled());
        Assert.areEqual('', TwinTicketConfig.portalLoginUrl());
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Portal_Profile_Name__c = ' Custom Profile ', Portal_Enabled__c = false,
            Site_Base_Url__c = 'https://x.example/s/');
        Assert.areEqual('Custom Profile', TwinTicketConfig.portalProfileName());
        Assert.isFalse(TwinTicketConfig.portalEnabled());
        Assert.areEqual('https://x.example/s/login', TwinTicketConfig.portalLoginUrl());
    }

    @IsTest
    static void loggerDrainHandsOverRowsOnce() {
        IntegrationLogger.add('Salesforce', 'DrainTest', 200, true, 'c', 'ok', null);
        Assert.areEqual(1, IntegrationLogger.drain().size());
        Assert.areEqual(0, IntegrationLogger.drain().size());
    }
}