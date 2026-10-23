// Twin Ticket - one-shot diagnostic. Run as an admin:
//   sf apex run --file scripts/apex/diagnoseGuestLeadAndWeather.apex --target-org vscodeOrg
// Read the lines starting with "TT-DIAG". Nothing is saved: the test Lead is rolled back.

String P = 'TT-DIAG ';

// ---------- 1. Weather callout through the Named Credential (callout BEFORE any DML/savepoint) ----------
try {
    HttpRequest req = new HttpRequest();
    req.setEndpoint('callout:OpenMeteo/v1/forecast?latitude=23.8103&longitude=90.4125&daily=temperature_2m_max&forecast_days=1');
    req.setMethod('GET');
    req.setTimeout(8000);
    HttpResponse res = new Http().send(req);
    System.debug(LoggingLevel.ERROR, P + '1 WEATHER callout HTTP ' + res.getStatusCode() + ' body starts: ' + res.getBody().left(120));
} catch (Exception e) {
    System.debug(LoggingLevel.ERROR, P + '1 WEATHER callout FAILED: ' + e.getTypeName() + ' - ' + e.getMessage());
}
try {
    List<NamedCredential> nc = [SELECT DeveloperName, Endpoint FROM NamedCredential WHERE DeveloperName = 'OpenMeteo'];
    System.debug(LoggingLevel.ERROR, P + '1 Named Credential OpenMeteo exists=' + !nc.isEmpty() + (nc.isEmpty() ? '' : ' endpoint=' + nc[0].Endpoint));
} catch (Exception e) {
    System.debug(LoggingLevel.ERROR, P + '1 cannot read NamedCredential: ' + e.getMessage());
}

// ---------- 2. Guest user and what it is allowed to use ----------
User guest;
try {
    guest = [SELECT Id, Name, ProfileId, Profile.Name FROM User WHERE UserType = 'Guest' AND IsActive = true AND Name LIKE '%Twin%' LIMIT 1];
    System.debug(LoggingLevel.ERROR, P + '2 guest user=' + guest.Name + ' profile=' + guest.Profile.Name);
} catch (Exception e) {
    System.debug(LoggingLevel.ERROR, P + '2 NO active guest user with "Twin" in the name: ' + e.getMessage());
}
if (guest != null) {
    Set<Id> psIds = new Set<Id>();
    for (PermissionSetAssignment a : [SELECT PermissionSetId, PermissionSet.Name FROM PermissionSetAssignment WHERE AssigneeId = :guest.Id]) {
        psIds.add(a.PermissionSetId);
        System.debug(LoggingLevel.ERROR, P + '2 guest has permission set: ' + a.PermissionSet.Name);
    }
    Set<String> needed = new Set<String>{ 'PublicEventController', 'BulkRequestController', 'WeatherController', 'PaymentPageController' };
    Map<Id, ApexClass> classes = new Map<Id, ApexClass>([SELECT Id, Name FROM ApexClass WHERE Name IN :needed AND NamespacePrefix = null]);
    Set<String> granted = new Set<String>();
    Map<String, Integer> otherTypes = new Map<String, Integer>();
    for (SetupEntityAccess s : [SELECT SetupEntityId, SetupEntityType FROM SetupEntityAccess WHERE ParentId IN :psIds]) {
        if (classes.containsKey(s.SetupEntityId)) { granted.add(classes.get(s.SetupEntityId).Name); }
        if (s.SetupEntityType != 'ApexClass') {
            otherTypes.put(s.SetupEntityType, (otherTypes.containsKey(s.SetupEntityType) ? otherTypes.get(s.SetupEntityType) : 0) + 1);
        }
    }
    for (String c : needed) {
        System.debug(LoggingLevel.ERROR, P + '2 guest Apex class access ' + c + ' = ' + (granted.contains(c) ? 'YES' : 'MISSING'));
    }
    System.debug(LoggingLevel.ERROR, P + '2 guest other setup access (look for ExternalCredentialParameter): ' + otherTypes);
}

// ---------- 3. Lead routing ----------
try {
    List<Group> q = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'Bulk_Request_Review' LIMIT 1];
    Boolean leadOk = !q.isEmpty() && [SELECT COUNT() FROM QueueSobject WHERE QueueId = :q[0].Id AND SobjectType = 'Lead'] > 0;
    System.debug(LoggingLevel.ERROR, P + '3 queue Bulk_Request_Review exists=' + !q.isEmpty() + ' supportsLead=' + leadOk);
    System.debug(LoggingLevel.ERROR, P + '3 active Lead assignment rules=' + [SELECT COUNT() FROM AssignmentRule WHERE SobjectType = 'Lead' AND Active = true]);
} catch (Exception e) {
    System.debug(LoggingLevel.ERROR, P + '3 routing check failed: ' + e.getMessage());
}

// ---------- 4. Bookable events (what the form and weather card can use) ----------
Ticket_Category__c bookable;
for (Event_Detail__c ev : [SELECT Id, Name, Start_DateTime__c, Venue_Latitude__c, Venue_Longitude__c,
                                  (SELECT Id, Available_Quantity__c FROM Ticket_Categories__r)
                           FROM Event_Detail__c WHERE Status__c = 'Published' AND Start_DateTime__c > :Datetime.now()
                           ORDER BY Start_DateTime__c LIMIT 10]) {
    Integer days = Date.today().daysBetween(ev.Start_DateTime__c.date());
    System.debug(LoggingLevel.ERROR, P + '4 event "' + ev.Name + '" daysAhead=' + days
        + (days > 15 ? ' (TOO FAR for a forecast)' : '')
        + ' hasLocation=' + (ev.Venue_Latitude__c != null && ev.Venue_Longitude__c != null)
        + ' categories=' + ev.Ticket_Categories__r.size());
    for (Ticket_Category__c c : ev.Ticket_Categories__r) {
        if (bookable == null && c.Available_Quantity__c != null && c.Available_Quantity__c >= 10) {
            bookable = new Ticket_Category__c(Id = c.Id, Event_Detail__c = ev.Id);
        }
    }
}

// ---------- 5. Recent weather outcomes ----------
try {
    for (Integration_Log__c l : [SELECT CreatedDate, HTTP_Status__c, Message__c FROM Integration_Log__c
                                 WHERE Operation__c = 'GetForecast' ORDER BY CreatedDate DESC LIMIT 5]) {
        System.debug(LoggingLevel.ERROR, P + '5 weather log ' + l.CreatedDate + ' http=' + l.HTTP_Status__c + ' ' + l.Message__c);
    }
} catch (Exception e) {
    System.debug(LoggingLevel.ERROR, P + '5 cannot read Integration_Log__c: ' + e.getMessage());
}

// ---------- 6. Dry-run the exact Lead insert the form performs (rolled back) ----------
if (bookable == null) {
    System.debug(LoggingLevel.ERROR, P + '6 SKIPPED: no published upcoming event has a category with 10+ tickets');
} else {
    Savepoint sp = Database.setSavepoint();
    try {
        Lead l = new Lead(FirstName = 'Diag', LastName = 'Check', Company = 'Individual - Diag Check',
            Email = 'diag.' + Crypto.getRandomInteger() + '@example.com', Phone = '+8801700000000', LeadSource = 'Web',
            Event_Detail__c = bookable.Event_Detail__c, Ticket_Category__c = bookable.Id, Requested_Quantity__c = 10,
            Identity_Document_Type__c = 'National ID', Identity_Number_Last_4__c = 'AB12', Verification_Status__c = 'Pending',
            Submission_Complete__c = true, Request_Reference__c = 'TT-20990101-DIAG23',
            Upload_Token_Hash__c = 'x', Upload_Token_Expires_On__c = Datetime.now().addMinutes(60));
        List<Group> q = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'Bulk_Request_Review' LIMIT 1];
        if (!q.isEmpty()) { l.OwnerId = q[0].Id; }
        Database.DMLOptions o = new Database.DMLOptions();
        o.optAllOrNone = false;
        o.DuplicateRuleHeader.allowSave = true;
        if (q.isEmpty()) { o.AssignmentRuleHeader.useDefaultRule = true; }
        Database.SaveResult sr = Database.insert(l, o);
        if (sr.isSuccess()) {
            System.debug(LoggingLevel.ERROR, P + '6 LEAD INSERT OK (owner=' + (q.isEmpty() ? 'assignment rule' : 'queue') + ')');
        }
        for (Database.Error err : sr.getErrors()) {
            System.debug(LoggingLevel.ERROR, P + '6 LEAD INSERT FAILED: ' + err.getStatusCode() + ' - ' + err.getMessage() + ' fields=' + err.getFields());
        }
    } catch (Exception e) {
        System.debug(LoggingLevel.ERROR, P + '6 LEAD INSERT threw: ' + e.getTypeName() + ' - ' + e.getMessage());
    } finally {
        Database.rollback(sp);
    }
}
