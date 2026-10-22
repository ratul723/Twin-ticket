@IsTest(SeeAllData=true)   // uses your real events and your real guest user; test data is never saved
private class BulkRequestGuestCheck {
    @IsTest
    static void guestCanSubmitUploadAndComplete() {
        User guest = [SELECT Id, Name FROM User WHERE UserType = 'Guest' AND IsActive = true AND Name LIKE '%Twin%' LIMIT 1];
        Event_Detail__c ev = [SELECT Id FROM Event_Detail__c WHERE Status__c = 'Published' AND Start_DateTime__c > :System.now() LIMIT 1];
        Ticket_Category__c cat = [SELECT Id FROM Ticket_Category__c WHERE Event_Detail__c = :ev.Id LIMIT 1];

        System.runAs(guest) {
            BulkRequestDto.RequestInput i = new BulkRequestDto.RequestInput();
            i.fullName = 'Guest Check'; i.email = 'guest.check' + Crypto.getRandomInteger() + '@example.com';
            i.phone = '+8801700000000'; i.organization = '';
            i.eventId = String.valueOf(ev.Id); i.categoryId = String.valueOf(cat.Id); i.quantity = 10;
            i.identityDocType = 'National ID'; i.identityLast4 = 'AB12'; i.consent = true;

            // Go through the CONTROLLER, exactly like the browser does.
            BulkRequestDto.SubmitResult s = BulkRequestController.submitRequest(JSON.serialize(i));
            Assert.isTrue(s.success, 'SUBMIT as guest failed: ' + s.message + ' ' + JSON.serialize(s.fieldErrors));

            String pdf = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4\n% test identity document\n'));
            BulkRequestDto.StepResult u = BulkRequestController.uploadDocument(s.reference, s.uploadToken, 'id.pdf', pdf);
            Assert.isTrue(u.success, 'UPLOAD as guest failed: ' + u.message);

            BulkRequestDto.StepResult c = BulkRequestController.completeSubmission(s.reference, s.uploadToken);
            Assert.isTrue(c.success, 'COMPLETE as guest failed: ' + c.message);
        }
    }
}