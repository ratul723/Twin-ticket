@IsTest
private class PublicEventControllerTest {

    @TestSetup
    static void setup() {
        Event_Detail__c published = new Event_Detail__c(
            Name = 'Test Summit', Status__c = 'Published', Start_DateTime__c = System.now().addDays(5),
            Time_Zone__c = 'Asia/Dhaka', Venue_Name__c = 'Test Hall', Venue_Address__c = '1 Test Road',
            Venue_Latitude__c = 23.8103, Venue_Longitude__c = 90.4125, Description__c = 'Synthetic test event');
        Event_Detail__c draft = new Event_Detail__c(
            Name = 'Test Draft', Status__c = 'Draft', Start_DateTime__c = System.now().addDays(6));
        Event_Detail__c past = new Event_Detail__c(
            Name = 'Test Past', Status__c = 'Published', Start_DateTime__c = System.now().addDays(-3));
        insert new List<Event_Detail__c>{ published, draft, past };

        insert new List<Ticket_Category__c>{
            new Ticket_Category__c(Name = 'VIP', Event_Detail__c = published.Id,
                Price__c = 120, Total_Quantity__c = 50, Sold_Quantity__c = 50),
            new Ticket_Category__c(Name = 'Standard', Event_Detail__c = published.Id,
                Price__c = 50, Total_Quantity__c = 300, Sold_Quantity__c = 10)
        };
    }

    private static Id idOf(String eventName) {
        return [SELECT Id FROM Event_Detail__c WHERE Name = :eventName LIMIT 1].Id;
    }

    private static String detailError(String eventId) {
        try {
            PublicEventController.getEventDetail(eventId);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static User noAccessUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = String.valueOf(Math.abs(Crypto.getRandomLong()));
        User u = new User(Alias = 'ttna', Email = 'ttna' + uniq + '@example.com', EmailEncodingKey = 'UTF-8',
            LastName = 'NoAccess', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka', Username = 'ttna' + uniq + '@twinticket-test.example.com');
        insert u;
        return u;
    }

    @IsTest
    static void listReturnsOnlyPublishedUpcomingWithSortedCategories() {
        Test.startTest();
        List<PublicEventController.EventDto> events = PublicEventController.getPublishedEvents();
        Test.stopTest();

        Assert.areEqual(1, events.size(), 'Draft and past events must not be returned');
        Assert.areEqual('Test Summit', events[0].name);
        Assert.areEqual(2, events[0].categories.size());
        Assert.areEqual('Standard', events[0].categories[0].name, 'Categories sorted by price ascending');
        Assert.areEqual(290, events[0].categories[0].available);
        Assert.areEqual(0, events[0].categories[1].available, 'VIP is sold out');
    }

    @IsTest
    static void listIsEmptyWhenNothingPublished() {
        delete [SELECT Id FROM Event_Detail__c];
        Assert.areEqual(0, PublicEventController.getPublishedEvents().size());
    }

    @IsTest
    static void detailReturnsPublishedEvent() {
        PublicEventController.EventDto dto = PublicEventController.getEventDetail(String.valueOf(idOf('Test Summit')));
        Assert.areEqual('Test Summit', dto.name);
        Assert.areEqual('Test Hall', dto.venueName);
        Assert.areEqual(23.8103, dto.latitude);
        Assert.areEqual(2, dto.categories.size());
    }

    @IsTest
    static void detailOfDraftEventReturnsSafeNotFound() {
        Assert.areEqual(PublicEventController.MSG_NOT_FOUND, detailError(String.valueOf(idOf('Test Draft'))));
    }

    @IsTest
    static void detailRejectsBlankMalformedAndWrongTypeIds() {
        Account a = new Account(Name = 'TT Test Account');
        insert a;
        Assert.areEqual(PublicEventController.MSG_NOT_FOUND, detailError(null), 'null id');
        Assert.areEqual(PublicEventController.MSG_NOT_FOUND, detailError('  '), 'blank id');
        Assert.areEqual(PublicEventController.MSG_NOT_FOUND, detailError('not-an-id'), 'malformed id');
        Assert.areEqual(PublicEventController.MSG_NOT_FOUND, detailError(String.valueOf(a.Id)), 'wrong object type');
    }

    @IsTest
    static void userWithoutObjectAccessGetsSafeErrorNotData() {
        User u = noAccessUser();
        Id summitId = idOf('Test Summit');
        System.runAs(u) {
            try {
                PublicEventController.getPublishedEvents();
                Assert.fail('Expected a safe error for a user without access');
            } catch (AuraHandledException e) {
                Assert.areEqual(PublicEventController.MSG_UNAVAILABLE, e.getMessage());
            }
            Assert.areEqual(PublicEventController.MSG_UNAVAILABLE, detailError(String.valueOf(summitId)));
        }
    }
}