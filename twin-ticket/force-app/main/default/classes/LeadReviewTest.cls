@IsTest
private class LeadReviewTest {

    @TestSetup
    static void setup() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        // Setup objects (User, PermissionSet) must be created inside runAs to avoid mixed-DML errors.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            User reviewer = makeUser(admin.Id, 'ttrev');
            User outsider = makeUser(admin.Id, 'ttout');
            insert new List<User>{ reviewer, outsider };
            PermissionSet ps = new PermissionSet(Name = 'TT_Test_Reviewer', Label = 'TT Test Reviewer');
            insert ps;
            CustomPermission cp = [SELECT Id FROM CustomPermission WHERE DeveloperName = 'Review_Bulk_Requests' LIMIT 1];
            insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cp.Id);
            insert new PermissionSetAssignment(AssigneeId = reviewer.Id, PermissionSetId = ps.Id);
        }
        Event_Detail__c ev = new Event_Detail__c(Name = 'Rev Summit', Status__c = 'Published',
            Start_DateTime__c = System.now().addDays(10), Time_Zone__c = 'Asia/Dhaka', Venue_Name__c = 'Test Hall');
        insert ev;
        insert new List<Ticket_Category__c>{
            new Ticket_Category__c(Name = 'Standard', Event_Detail__c = ev.Id, Price__c = 50, Total_Quantity__c = 300, Sold_Quantity__c = 0),
            new Ticket_Category__c(Name = 'Tiny', Event_Detail__c = ev.Id, Price__c = 90, Total_Quantity__c = 5, Sold_Quantity__c = 0)
        };
    }

    private static User makeUser(Id profileId, String alias) {
        String uniq = String.valueOf(Math.abs(Crypto.getRandomLong()));
        return new User(Alias = alias, Email = alias + uniq + '@example.com', EmailEncodingKey = 'UTF-8', LastName = alias,
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = profileId, TimeZoneSidKey = 'Asia/Dhaka',
            Username = alias + uniq + '@twinticket-test.example.com');
    }
    private static User reviewer() { return [SELECT Id FROM User WHERE Alias = 'ttrev' LIMIT 1]; }
    private static User outsider() { return [SELECT Id FROM User WHERE Alias = 'ttout' LIMIT 1]; }

    private static Lead makeLead(String suffix, String category, Integer qty, Boolean complete, Boolean withFile) {
        Lead l = new Lead(FirstName = 'Pat', LastName = 'Buyer' + suffix, Company = 'Org ' + suffix,
            Email = 'pat' + suffix + '@example.com', Phone = '+8801700000000',
            Event_Detail__c = [SELECT Id FROM Event_Detail__c WHERE Name = 'Rev Summit' LIMIT 1].Id,
            Ticket_Category__c = [SELECT Id FROM Ticket_Category__c WHERE Name = :category LIMIT 1].Id,
            Requested_Quantity__c = qty,
            Identity_Document_Type__c = Schema.Lead.Identity_Document_Type__c.getDescribe().getPicklistValues()[0].getValue(),
            Identity_Number_Last_4__c = 'AB12', Request_Reference__c = 'TT-20261021-AAAA' + suffix,
            Verification_Status__c = 'Pending', Submission_Complete__c = complete);
        insert l;
        if (withFile) {
            insert new ContentVersion(Title = 'doc', PathOnClient = 'doc.pdf', VersionData = Blob.valueOf('%PDF-1.4 test'),
                FirstPublishLocationId = l.Id);
        }
        return l;
    }
    private static Lead goodLead(String suffix) { return makeLead(suffix, 'Standard', 20, true, true); }

    private static String decisionError(Id leadId, String action, String notes, String msg) {
        try { LeadReviewService.submitDecision(leadId, action, notes, msg); }
        catch (LeadReviewService.ReviewException e) { return e.getMessage(); }
        return null;
    }

    // ---- approve and convert ----
    @IsTest
    static void approveConvertsLeadAndCreatesAllRecordsWithServerSidePrice() {
        Lead l = goodLead('A1');
        LeadReviewDto.DecisionResult r;
        System.runAs(reviewer()) {
            r = LeadReviewService.submitDecision(l.Id, 'APPROVE', 'Documents verified OK', null);
        }
        Assert.isTrue(r.success);
        Lead after = [SELECT IsConverted, Verification_Status__c, Review_Notes__c, Reviewed_By__c FROM Lead WHERE Id = :l.Id];
        Assert.isTrue(after.IsConverted);
        Assert.areEqual('Approved', after.Verification_Status__c);
        Assert.isTrue(after.Review_Notes__c.contains('Documents verified OK'));
        Assert.areEqual(reviewer().Id, after.Reviewed_By__c);

        Assert.areEqual('Org A1', [SELECT Name FROM Account WHERE Id = :r.accountId].Name);
        Assert.areEqual('pata1@example.com', [SELECT Email FROM Contact WHERE Id = :r.contactId].Email);
        Opportunity o = [SELECT StageName, Amount, Requested_Quantity__c, Unit_Price__c, Request_Reference__c, Event_Detail__c, Ticket_Category__c
                         FROM Opportunity WHERE Id = :r.opportunityId];
        Assert.areEqual('Awaiting Payment', o.StageName);
        Assert.areEqual(1000, o.Amount, '20 tickets x 50 from the database');
        Assert.areEqual(20, o.Requested_Quantity__c);
        Assert.areEqual(50, o.Unit_Price__c);
        Assert.areEqual(l.Event_Detail__c, o.Event_Detail__c);
        Purchase__c p = [SELECT Account__c, Contact__c, Opportunity__c, Quantity__c, Total_Amount__c, Payment_Status__c, Request_Reference__c
                         FROM Purchase__c WHERE Id = :r.purchaseId];
        Assert.areEqual(r.accountId, p.Account__c);
        Assert.areEqual(r.contactId, p.Contact__c);
        Assert.areEqual(r.opportunityId, p.Opportunity__c);
        Assert.areEqual(1000, p.Total_Amount__c);
        Assert.areEqual('Awaiting Payment', p.Payment_Status__c);
        Assert.areEqual('TT-20261021-AAAAA1', p.Request_Reference__c);
    }

    @IsTest
    static void secondApproveFailsSafelyAndCreatesNoDuplicates() {
        Lead l = goodLead('A2');
        System.runAs(reviewer()) {
            LeadReviewService.submitDecision(l.Id, 'APPROVE', 'First approval', null);
            Assert.areEqual('This request has already been processed.', decisionError(l.Id, 'APPROVE', 'Second click', null));
        }
        Assert.areEqual(1, [SELECT COUNT() FROM Purchase__c WHERE Request_Reference__c = 'TT-20261021-AAAAA2']);
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Name = 'Org A2']);
    }

    @IsTest
    static void approvalIsBlockedWhenBusinessChecksFail() {
        Lead incomplete = makeLead('B1', 'Standard', 20, false, true);
        Lead noFile = makeLead('B2', 'Standard', 20, true, false);
        Lead tooMany = makeLead('B3', 'Tiny', 10, true, true);        // only 5 available
        Lead draftEvt = goodLead('B4');
        update new Event_Detail__c(Id = draftEvt.Event_Detail__c, Status__c = 'Draft');
        System.runAs(reviewer()) {
            Assert.isTrue(decisionError(incomplete.Id, 'APPROVE', 'try approve', null).contains('not finished'));
            if (TwinTicketConfig.documentsRequired()) {
                Assert.isTrue(decisionError(noFile.Id, 'APPROVE', 'try approve', null).contains('no identity documents'));
            }
            Assert.isTrue(decisionError(tooMany.Id, 'APPROVE', 'try approve', null).contains('only 5 tickets'));
            Assert.isTrue(decisionError(draftEvt.Id, 'APPROVE', 'try approve', null).contains('no longer published'));
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Purchase__c], 'nothing may be created for blocked approvals');
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE IsConverted = true]);
    }

    // ---- reject / request info / return ----
    @IsTest
    static void rejectClosesRequestAndEmailsBuyerWithoutNotes() {
        Lead l = goodLead('C1');
        System.runAs(reviewer()) {
            LeadReviewService.emailsSent = 0;
            LeadReviewService.submitDecision(l.Id, 'REJECT', 'ID photo does not match', null);
            Assert.areEqual(1, LeadReviewService.emailsSent);
            Assert.isTrue(decisionError(l.Id, 'APPROVE', 'changed my mind', null).contains('closed'));
            Assert.isTrue(decisionError(l.Id, 'REQUEST_INFO', 'try again', 'Please send a clearer photo').contains('closed'));
        }
        Assert.areEqual('Rejected', [SELECT Verification_Status__c FROM Lead WHERE Id = :l.Id].Verification_Status__c);
    }

    @IsTest
    static void requestInfoNeedsMessageThenCanReturnToPending() {
        Lead l = goodLead('D1');
        System.runAs(reviewer()) {
            Assert.isNotNull(decisionError(l.Id, 'REQUEST_INFO', 'need a better scan', ''), 'message required');
            LeadReviewService.emailsSent = 0;
            LeadReviewService.submitDecision(l.Id, 'REQUEST_INFO', 'need a better scan', 'Please send a clearer photo of your ID.');
            Assert.areEqual(1, LeadReviewService.emailsSent);
            Lead s = [SELECT Verification_Status__c, Review_Notes__c FROM Lead WHERE Id = :l.Id];
            Assert.areEqual('Additional Information Required', s.Verification_Status__c);
            Assert.isTrue(s.Review_Notes__c.contains('Message to buyer'));
            Assert.isNotNull(decisionError(l.Id, 'REQUEST_INFO', 'again', 'Another message here please'), 'not allowed twice in a row');
            LeadReviewService.submitDecision(l.Id, 'RETURN_TO_PENDING', 'buyer replied by email', null);
        }
        Assert.areEqual('Pending', [SELECT Verification_Status__c FROM Lead WHERE Id = :l.Id].Verification_Status__c);
    }

    @IsTest
    static void inputValidationAndInvalidTransitions() {
        Lead l = goodLead('E1');
        System.runAs(reviewer()) {
            Assert.isNotNull(decisionError(l.Id, 'APPROVE', '', null), 'blank notes');
            Assert.isNotNull(decisionError(l.Id, 'APPROVE', 'abc', null), 'notes too short');
            Assert.isNotNull(decisionError(l.Id, 'APPROVE', 'x'.repeat(2001), null), 'notes too long');
            Assert.isNotNull(decisionError(l.Id, 'EXPLODE', 'valid notes here', null), 'unknown action');
            Assert.isNotNull(decisionError(l.Id, null, 'valid notes here', null), 'null action');
            Assert.isNotNull(decisionError(l.Id, 'RETURN_TO_PENDING', 'valid notes here', null), 'not allowed from Pending');
            Assert.isNotNull(decisionError(null, 'APPROVE', 'valid notes here', null), 'null id');
            Assert.isNotNull(decisionError(UserInfo.getUserId(), 'APPROVE', 'valid notes here', null), 'wrong object id');
        }
        Assert.areEqual('Pending', [SELECT Verification_Status__c FROM Lead WHERE Id = :l.Id].Verification_Status__c);
    }

    // ---- security ----
    @IsTest
    static void userWithoutTheCustomPermissionCannotDecideOrSeeActions() {
        Lead l = goodLead('F1');
        System.runAs(outsider()) {
            Assert.areEqual('You do not have permission to review requests.', decisionError(l.Id, 'APPROVE', 'sneaky approval', null));
            LeadReviewDto.ReviewData d = LeadReviewService.getReviewData(l.Id);
            Assert.isFalse(d.canDecide);
            Assert.isTrue(d.actions.isEmpty());
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Purchase__c]);
    }

    @IsTest
    static void validationRulesBlockStatusChangesOutsideThePanel() {
        Lead l = goodLead('G1');
        System.runAs(outsider()) {
            try {
                update new Lead(Id = l.Id, Verification_Status__c = 'Rejected', Review_Notes__c = 'direct edit');
                Assert.fail('Only reviewers may change the status');
            } catch (DmlException e) {
                Assert.isTrue(e.getMessage().contains('permission'));
            }
        }
        System.runAs(reviewer()) {
            try {
                update new Lead(Id = l.Id, Verification_Status__c = 'Rejected');
                Assert.fail('A decision without notes must be refused');
            } catch (DmlException e) {
                Assert.isTrue(e.getMessage().contains('notes'));
            }
        }
    }

    // ---- read model and controller ----
    @IsTest
    static void reviewDataShowsRequestFilesAndAllowedActions() {
        Lead l = goodLead('H1');
        System.runAs(reviewer()) {
            LeadReviewDto.ReviewData d = LeadReviewService.getReviewData(l.Id);
            Assert.areEqual('TT-20261021-AAAAH1', d.reference);
            Assert.areEqual('Pending', d.status);
            Assert.areEqual('Pat BuyerH1', d.buyerName);
            Assert.areEqual(1000, d.estimatedTotal);
            Assert.areEqual(1, d.files.size());
            Assert.isTrue(d.blockers.isEmpty());
            Assert.isTrue(d.canDecide);
            Assert.areEqual(3, d.actions.size(), 'approve, request info, reject');
            Lead bad = makeLead('H2', 'Tiny', 10, true, true);
            LeadReviewDto.ReviewData d2 = LeadReviewService.getReviewData(bad.Id);
            Assert.isFalse(d2.blockers.isEmpty());
            Assert.areEqual(2, d2.actions.size(), 'approve is hidden when blocked');
        }
    }

    @IsTest
    static void controllerReturnsSafeResultsAndHidesUnexpectedErrors() {
        Lead l = goodLead('I1');
        System.runAs(reviewer()) {
            Assert.isTrue(LeadReviewController.getReviewData(l.Id).canDecide);
            Assert.isFalse(LeadReviewController.submitDecision(l.Id, 'APPROVE', '', null).success, 'validation message returned, not thrown');
            Assert.isTrue(LeadReviewController.submitDecision(l.Id, 'APPROVE', 'All documents verified', null).success);
            try {
                LeadReviewController.getReviewData(UserInfo.getUserId());
                Assert.fail('expected a safe error');
            } catch (AuraHandledException e) {
                Assert.areEqual('This request could not be loaded.', e.getMessage());
            }
            LeadReviewController.simulateUnexpectedError = true;
            Assert.isTrue(LeadReviewController.submitDecision(l.Id, 'APPROVE', 'notes here ok', null).message.contains('Something went wrong'));
            try {
                LeadReviewController.getReviewData(l.Id);
                Assert.fail('expected a safe error');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Something went wrong'));
            }
        }
    }
}