@IsTest
private class BulkRequestTest {

    private static final String PDF_HEX = '255044462D312E34';  // %PDF-1.4
    private static final String PNG_HEX = '89504E470D0A1A0A';
    private static final String JPG_HEX = 'FFD8FFE000104A464946';

    @TestSetup
    static void setup() {
        Event_Detail__c open = new Event_Detail__c(Name = 'Req Summit', Status__c = 'Published',
            Start_DateTime__c = System.now().addDays(10), Time_Zone__c = 'Asia/Dhaka', Venue_Name__c = 'Test Hall');
        Event_Detail__c draft = new Event_Detail__c(Name = 'Req Draft', Status__c = 'Draft',
            Start_DateTime__c = System.now().addDays(10));
        insert new List<Event_Detail__c>{ open, draft };
        insert new List<Ticket_Category__c>{
            new Ticket_Category__c(Name = 'Standard', Event_Detail__c = open.Id, Price__c = 50, Total_Quantity__c = 300, Sold_Quantity__c = 0),
            new Ticket_Category__c(Name = 'Tiny', Event_Detail__c = open.Id, Price__c = 90, Total_Quantity__c = 5, Sold_Quantity__c = 0),
            new Ticket_Category__c(Name = 'DraftCat', Event_Detail__c = draft.Id, Price__c = 10, Total_Quantity__c = 100, Sold_Quantity__c = 0)
        };
    }

    // ---- helpers ----
    private static void useConfig() {
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(
            Min_Bulk_Quantity__c = 10, Max_Bulk_Quantity__c = 500, Max_Files__c = 2, Max_File_Size_KB__c = 1,
            Allowed_File_Types__c = 'pdf,jpg,jpeg,png', Max_Requests_Per_Email_Per_Day__c = 3);
    }
    private static Id eventId(String n) { return [SELECT Id FROM Event_Detail__c WHERE Name = :n LIMIT 1].Id; }
    private static Id catId(String n) { return [SELECT Id FROM Ticket_Category__c WHERE Name = :n LIMIT 1].Id; }
    private static String docType() {
        return Schema.Lead.Identity_Document_Type__c.getDescribe().getPicklistValues()[0].getValue();
    }
    private static String b64(String headerHex, Integer padBytes) {
        return EncodingUtil.base64Encode(EncodingUtil.convertFromHex(headerHex + '00'.repeat(padBytes)));
    }
    private static BulkRequestDto.RequestInput validInput() {
        BulkRequestDto.RequestInput i = new BulkRequestDto.RequestInput();
        i.fullName = 'Test Buyer'; i.email = 'Buyer@Example.com'; i.phone = '+880 1700-000000';
        i.organization = 'Test Org'; i.eventId = String.valueOf(eventId('Req Summit'));
        i.categoryId = String.valueOf(catId('Standard')); i.quantity = 20;
        i.identityDocType = docType(); i.identityLast4 = 'ab12'; i.consent = true;
        return i;
    }
    private static BulkRequestDto.SubmitResult submitOk() {
        BulkRequestDto.SubmitResult r = BulkRequestService.submit(validInput());
        Assert.isTrue(r.success, 'precondition: submit should succeed');
        return r;
    }
    private static Boolean hasError(BulkRequestDto.SubmitResult r, String field) {
        for (BulkRequestDto.FieldError e : r.fieldErrors) { if (e.field == field) { return true; } }
        return false;
    }
    private static String uploadError(String ref, String token, String name, String data) {
        try { BulkRequestService.uploadDocument(ref, token, name, data); }
        catch (BulkRequestService.RequestException e) { return e.getMessage(); }
        return null;
    }

    // ---- submit: success ----
    @IsTest
    static void submitCreatesPendingIncompleteLeadWithHashedToken() {
        useConfig();
        BulkRequestDto.SubmitResult r = submitOk();
        Assert.isTrue(Pattern.matches('^TT-[0-9]{8}-[A-HJ-NP-Z2-9]{6}$', r.reference), 'reference format');
        Assert.isNotNull(r.uploadToken);
        Lead l = [SELECT Company, Email, Phone, Verification_Status__c, Submission_Complete__c, Requested_Quantity__c,
                         Upload_Token_Hash__c, Identity_Number_Last_4__c, Event_Detail__c
                  FROM Lead WHERE Request_Reference__c = :r.reference];
        Assert.areEqual('Pending', l.Verification_Status__c);
        Assert.isFalse(l.Submission_Complete__c);
        Assert.areEqual(20, l.Requested_Quantity__c);
        Assert.areEqual('buyer@example.com', l.Email, 'email normalised');
        Assert.areEqual('+8801700000000', l.Phone, 'phone normalised');
        Assert.areEqual('AB12', l.Identity_Number_Last_4__c);
        Assert.areEqual('Test Org', l.Company);
        Assert.areEqual(64, l.Upload_Token_Hash__c.length(), 'SHA-256 hex');
        Assert.areNotEqual(r.uploadToken, l.Upload_Token_Hash__c, 'raw token is never stored');
    }

    @IsTest
    static void blankOrganizationBecomesIndividual() {
        useConfig();
        BulkRequestDto.RequestInput i = validInput();
        i.organization = '  ';
        i.fullName = 'Single';
        BulkRequestDto.SubmitResult r = BulkRequestService.submit(i);
        Assert.isTrue(r.success);
        Lead l = [SELECT Company, LastName, FirstName FROM Lead WHERE Request_Reference__c = :r.reference];
        Assert.areEqual('Individual - Single', l.Company);
        Assert.areEqual('Single', l.LastName);
        Assert.isNull(l.FirstName);
    }

    // ---- submit: validation ----
    @IsTest
    static void emptyInputReportsEveryRequiredField() {
        useConfig();
        BulkRequestDto.SubmitResult r = BulkRequestService.submit(new BulkRequestDto.RequestInput());
        Assert.isFalse(r.success);
        for (String f : new List<String>{ 'fullName', 'email', 'phone', 'identityDocType', 'identityLast4',
                                          'consent', 'quantity', 'eventId', 'categoryId' }) {
            Assert.isTrue(hasError(r, f), 'expected an error for ' + f);
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Lead], 'no Lead may be created');
    }

    @IsTest
    static void nullInputAndHoneypotCreateNothing() {
        useConfig();
        Assert.isFalse(BulkRequestService.submit(null).success);
        BulkRequestDto.RequestInput bot = validInput();
        bot.website = 'http://spam.example';
        Assert.isFalse(BulkRequestService.submit(bot).success);
        Assert.areEqual(0, [SELECT COUNT() FROM Lead]);
    }

    @IsTest
    static void quantityRulesAreEnforcedOnTheServer() {
        useConfig();
        BulkRequestDto.RequestInput i = validInput();
        i.quantity = 9;
        Assert.isTrue(hasError(BulkRequestService.submit(i), 'quantity'), 'below minimum');
        i.quantity = 501;
        Assert.isTrue(hasError(BulkRequestService.submit(i), 'quantity'), 'above maximum');
        i.quantity = null;
        Assert.isTrue(hasError(BulkRequestService.submit(i), 'quantity'), 'missing');
        i.quantity = 10;
        i.categoryId = String.valueOf(catId('Tiny'));   // only 5 available
        Assert.isTrue(hasError(BulkRequestService.submit(i), 'quantity'), 'more than available');
    }

    @IsTest
    static void draftEventAndMismatchedCategoryAreRejected() {
        useConfig();
        BulkRequestDto.RequestInput i = validInput();
        i.eventId = String.valueOf(eventId('Req Draft'));
        i.categoryId = String.valueOf(catId('DraftCat'));
        Assert.isTrue(hasError(BulkRequestService.submit(i), 'categoryId'), 'draft event');
        i = validInput();
        i.categoryId = String.valueOf(catId('DraftCat')); // belongs to a different event
        Assert.isTrue(hasError(BulkRequestService.submit(i), 'categoryId'), 'category from another event');
        i = validInput();
        i.eventId = 'not-an-id';
        Assert.isTrue(hasError(BulkRequestService.submit(i), 'eventId'), 'malformed id');
        i = validInput();
        i.eventId = String.valueOf(catId('Standard')); // valid Id, wrong object type
        Assert.isTrue(hasError(BulkRequestService.submit(i), 'eventId'), 'wrong object type');
    }

    @IsTest
    static void emailRateLimitBlocksTheFourthRequest() {
        useConfig();
        for (Integer n = 0; n < 3; n++) { submitOk(); }
        BulkRequestDto.SubmitResult r = BulkRequestService.submit(validInput());
        Assert.isFalse(r.success);
        Assert.isTrue(hasError(r, 'email'));
    }

    @IsTest
    static void referencesAreWellFormedAndDifferent() {
        String a = BulkRequestService.generateReference();
        String b = BulkRequestService.generateReference();
        Assert.isTrue(Pattern.matches('^TT-[0-9]{8}-[A-HJ-NP-Z2-9]{6}$', a));
        Assert.areNotEqual(a, b);
    }

    // ---- upload ----
    @IsTest
    static void uploadStoresInternalOnlyFilesAndEnforcesLimits() {
        useConfig();
        BulkRequestDto.SubmitResult r = submitOk();
        Assert.isTrue(BulkRequestService.uploadDocument(r.reference, r.uploadToken, 'passport.PDF', b64(PDF_HEX, 8)).success);
        Assert.isTrue(BulkRequestService.uploadDocument(r.reference, r.uploadToken, 'front.png', b64(PNG_HEX, 8)).success);

        Id leadId = [SELECT Id FROM Lead WHERE Request_Reference__c = :r.reference].Id;
        List<ContentDocumentLink> links = [SELECT Visibility, ShareType FROM ContentDocumentLink WHERE LinkedEntityId = :leadId];
        Assert.areEqual(2, links.size());
        for (ContentDocumentLink l : links) {
            Assert.areEqual('InternalUsers', l.Visibility, 'identity files must never be visible to external users');
        }
        Assert.areEqual(r.reference + '-ID-1',
            [SELECT Title FROM ContentVersion WHERE Title LIKE :(r.reference + '-ID-1') LIMIT 1].Title, 'our name, not the browser name');
        Assert.isNotNull(uploadError(r.reference, r.uploadToken, 'third.jpg', b64(JPG_HEX, 8)), 'file limit reached');
    }

    @IsTest
    static void uploadRejectsBadTokensWrongTypesAndFakeContent() {
        useConfig();
        BulkRequestDto.SubmitResult r = submitOk();
        String good = b64(PDF_HEX, 8);
        Assert.areEqual(BulkRequestService.MSG_LINK_INVALID, uploadError(r.reference, 'wrong-token', 'a.pdf', good), 'wrong token');
        Assert.areEqual(BulkRequestService.MSG_LINK_INVALID, uploadError('TT-20260101-AAAAAA', r.uploadToken, 'a.pdf', good), 'unknown reference');
        Assert.areEqual(BulkRequestService.MSG_LINK_INVALID, uploadError('garbage', r.uploadToken, 'a.pdf', good), 'malformed reference');
        Assert.areEqual(BulkRequestService.MSG_LINK_INVALID, uploadError(r.reference, '', 'a.pdf', good), 'blank token');
        Assert.isNotNull(uploadError(r.reference, r.uploadToken, 'malware.exe', good), 'extension not allowed');
        Assert.isNotNull(uploadError(r.reference, r.uploadToken, 'noext', good), 'no extension');
        Assert.isNotNull(uploadError(r.reference, r.uploadToken, 'fake.png', good), 'PDF bytes pretending to be PNG');
        Assert.isNotNull(uploadError(r.reference, r.uploadToken, 'tiny.pdf', EncodingUtil.base64Encode(Blob.valueOf('%PDF'))), 'too short for signature');
        Assert.isNotNull(uploadError(r.reference, r.uploadToken, 'bad.pdf', '***not base64***'), 'invalid base64');
        Assert.isNotNull(uploadError(r.reference, r.uploadToken, 'empty.pdf', ''), 'empty');
        Assert.isNotNull(uploadError(r.reference, r.uploadToken, 'huge.pdf', b64(PDF_HEX, 3000)), 'over the size limit');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId IN (SELECT Id FROM Lead)]);
    }

    @IsTest
    static void expiredTokenIsRejected() {
        useConfig();
        BulkRequestDto.SubmitResult r = submitOk();
        Lead l = [SELECT Id FROM Lead WHERE Request_Reference__c = :r.reference];
        l.Upload_Token_Expires_On__c = Datetime.now().addMinutes(-5);
        update l;
        Assert.areEqual(BulkRequestService.MSG_LINK_INVALID, uploadError(r.reference, r.uploadToken, 'a.pdf', b64(PDF_HEX, 8)));
    }

    // ---- complete ----
    @IsTest
    static void completeNeedsAFileThenBurnsTheToken() {
        useConfig();
        BulkRequestDto.SubmitResult r = submitOk();
        try {
            BulkRequestService.completeSubmission(r.reference, r.uploadToken);
            Assert.fail('Completing without a file must fail');
        } catch (BulkRequestService.RequestException e) {
            Assert.isNotNull(e.getMessage());
        }
        BulkRequestService.uploadDocument(r.reference, r.uploadToken, 'id.jpg', b64(JPG_HEX, 8));
        BulkRequestDto.StepResult done = BulkRequestService.completeSubmission(r.reference, r.uploadToken);
        Assert.isTrue(done.success);
        Lead l = [SELECT Submission_Complete__c, Upload_Token_Hash__c FROM Lead WHERE Request_Reference__c = :r.reference];
        Assert.isTrue(l.Submission_Complete__c);
        Assert.isNull(l.Upload_Token_Hash__c, 'token burned');
        Assert.areEqual(BulkRequestService.MSG_LINK_INVALID, uploadError(r.reference, r.uploadToken, 'again.pdf', b64(PDF_HEX, 8)), 'no uploads after completion');
    }

    // ---- controller and config ----
    @IsTest
    static void controllerMapsResultsAndHidesUnexpectedErrors() {
        useConfig();
        BulkRequestDto.FormConfig cfg = BulkRequestController.getFormConfig();
        Assert.areEqual(10, cfg.minQuantity);
        Assert.isFalse(cfg.docTypes.isEmpty());

        BulkRequestDto.SubmitResult r = BulkRequestController.submitRequest(validInput());
        Assert.isTrue(r.success);
        Assert.isFalse(BulkRequestController.uploadDocument(r.reference, 'bad-token', 'a.pdf', b64(PDF_HEX, 8)).success);
        Assert.isTrue(BulkRequestController.uploadDocument(r.reference, r.uploadToken, 'a.pdf', b64(PDF_HEX, 8)).success);
        Assert.isTrue(BulkRequestController.completeSubmission(r.reference, r.uploadToken).success);

        BulkRequestController.simulateUnexpectedError = true;
        Assert.isFalse(BulkRequestController.submitRequest(validInput()).success);
        Assert.isFalse(BulkRequestController.uploadDocument('x', 'y', 'a.pdf', 'z').success);
        Assert.isFalse(BulkRequestController.completeSubmission('x', 'y').success);
        try {
            BulkRequestController.getFormConfig();
            Assert.fail('expected a safe error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Something went wrong'));
        }
    }

    @IsTest
    static void configFallsBackToSafeDefaults() {
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt();   // every value blank
        Assert.areEqual(10, TwinTicketConfig.minQuantity());
        Assert.areEqual(500, TwinTicketConfig.maxQuantity());
        Assert.areEqual(3, TwinTicketConfig.maxFiles());
        Assert.areEqual(2048, TwinTicketConfig.maxFileKb());
        Assert.areEqual(3, TwinTicketConfig.maxRequestsPerEmailPerDay());
        Assert.areEqual(4, TwinTicketConfig.allowedExtensions().size());
    }
}