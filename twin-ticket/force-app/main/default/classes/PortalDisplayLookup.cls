/**
 * System-mode reads used ONLY AFTER a purchase has already passed the three access checks.
 * Customers have no permission on Event Detail, Ticket Category or Ticket Payment, so this class fetches
 * a few display fields for the specific ids of purchases they own, and nothing else.
 */
public without sharing class PortalDisplayLookup {

    public class EventInfo {
        public String name;
        public Datetime startAt;
        public String timeZone;
        public String venue;
    }

    public static Map<Id, EventInfo> events(Set<Id> ids) {
        Map<Id, EventInfo> out = new Map<Id, EventInfo>();
        if (ids.isEmpty()) { return out; }
        for (Event_Detail__c e : [SELECT Id, Name, Start_DateTime__c, Time_Zone__c, Venue_Name__c FROM Event_Detail__c WHERE Id IN :ids WITH SYSTEM_MODE]) {
            EventInfo i = new EventInfo();
            i.name = e.Name; i.startAt = e.Start_DateTime__c; i.timeZone = e.Time_Zone__c; i.venue = e.Venue_Name__c;
            out.put(e.Id, i);
        }
        return out;
    }

    public static Map<Id, String> categoryNames(Set<Id> ids) {
        Map<Id, String> out = new Map<Id, String>();
        if (ids.isEmpty()) { return out; }
        for (Ticket_Category__c c : [SELECT Id, Name FROM Ticket_Category__c WHERE Id IN :ids WITH SYSTEM_MODE]) { out.put(c.Id, c.Name); }
        return out;
    }

    /** Only the last 8 characters of the payment id are ever shown to a customer. */
    public static String paymentReference(Id purchaseId) {
        List<Ticket_Payment__c> rows = [SELECT Capture_Id__c FROM Ticket_Payment__c
                                        WHERE Purchase__c = :purchaseId AND Status__c = 'Completed' AND Capture_Id__c != null
                                        WITH SYSTEM_MODE ORDER BY Verified_On__c DESC LIMIT 1];
        return rows.isEmpty() ? null : rows[0].Capture_Id__c.right(8).toUpperCase();
    }

    public static Map<String, String> buyer(Id purchaseId) {
        Map<String, String> out = new Map<String, String>();
        List<Purchase__c> rows = [SELECT Contact__r.FirstName, Contact__r.LastName, Account__r.Name FROM Purchase__c WHERE Id = :purchaseId WITH SYSTEM_MODE LIMIT 1];
        if (!rows.isEmpty()) {
            Purchase__c p = rows[0];
            String first = p.Contact__r == null || p.Contact__r.FirstName == null ? '' : p.Contact__r.FirstName + ' ';
            out.put('name', p.Contact__r == null ? '' : (first + p.Contact__r.LastName).trim());
            out.put('organization', p.Account__r == null ? '' : p.Account__r.Name);
        }
        return out;
    }
}