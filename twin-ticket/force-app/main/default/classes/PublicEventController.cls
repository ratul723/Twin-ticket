/**
 * Read-only event data for the PUBLIC (guest) site.
 * SECURITY:
 *  - 'with sharing' applies record sharing (the guest sharing rule shows Published events only).
 *  - WITH USER_MODE enforces object permissions and field-level security of the running guest.
 *  - Returns DTOs, never sObjects, so only whitelisted fields leave the server.
 *  - Errors returned to the browser are fixed, safe messages. Details go to the debug log only.
 */
public with sharing class PublicEventController {

    private static final String LOG = 'TT-EVENT ';
    private static final String STATUS_PUBLISHED = 'Published';
    private static final Integer MAX_EVENTS = 50;
    @TestVisible private static final String MSG_NOT_FOUND = 'This event could not be found.';
    @TestVisible private static final String MSG_UNAVAILABLE = 'Events are temporarily unavailable. Please try again later.';

    public class CategoryDto {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal price;
        @AuraEnabled public Decimal available;
    }

    public class EventDto {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String description;
        @AuraEnabled public Datetime startDateTime;
        @AuraEnabled public String timeZone;
        @AuraEnabled public String venueName;
        @AuraEnabled public String venueAddress;
        @AuraEnabled public Decimal latitude;
        @AuraEnabled public Decimal longitude;
        @AuraEnabled public List<CategoryDto> categories = new List<CategoryDto>();
    }

    @AuraEnabled(cacheable=true)
    public static List<EventDto> getPublishedEvents() {
        Datetime nowTs = System.now();
        try {
            List<Event_Detail__c> rows = [
                SELECT Id, Name, Description__c, Start_DateTime__c, Time_Zone__c,
                       Venue_Name__c, Venue_Address__c, Venue_Latitude__c, Venue_Longitude__c,
                       (SELECT Id, Name, Price__c, Available_Quantity__c
                          FROM Ticket_Categories__r ORDER BY Price__c ASC)
                FROM Event_Detail__c
                WHERE Status__c = :STATUS_PUBLISHED AND Start_DateTime__c >= :nowTs
                WITH USER_MODE
                ORDER BY Start_DateTime__c ASC
                LIMIT :MAX_EVENTS
            ];
            List<EventDto> result = new List<EventDto>();
            for (Event_Detail__c row : rows) {
                result.add(toDto(row));
            }
            System.debug(LoggingLevel.INFO, LOG + 'getPublishedEvents returned ' + result.size() + ' events');
            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'getPublishedEvents failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            throw safeError(MSG_UNAVAILABLE);
        }
    }

    @AuraEnabled(cacheable=true)
    public static EventDto getEventDetail(String eventId) {
        // Never trust a browser-supplied Id: validate format and object type first.
        Id parsedId = parseEventId(eventId);
        try {
            List<Event_Detail__c> rows = [
                SELECT Id, Name, Description__c, Start_DateTime__c, Time_Zone__c,
                       Venue_Name__c, Venue_Address__c, Venue_Latitude__c, Venue_Longitude__c,
                       (SELECT Id, Name, Price__c, Available_Quantity__c
                          FROM Ticket_Categories__r ORDER BY Price__c ASC)
                FROM Event_Detail__c
                WHERE Id = :parsedId AND Status__c = :STATUS_PUBLISHED
                WITH USER_MODE
                LIMIT 1
            ];
            if (rows.isEmpty()) {
                // Same answer for "draft" and "does not exist" so nobody can probe for unpublished events.
                System.debug(LoggingLevel.WARN, LOG + 'getEventDetail: not found or not published, id=' + parsedId);
                throw safeError(MSG_NOT_FOUND);
            }
            System.debug(LoggingLevel.INFO, LOG + 'getEventDetail returned event ' + parsedId);
            return toDto(rows[0]);
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'getEventDetail failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            throw safeError(MSG_UNAVAILABLE);
        }
    }

    @TestVisible
    private static Id parseEventId(String rawId) {
        if (String.isBlank(rawId)) {
            System.debug(LoggingLevel.WARN, LOG + 'parseEventId: blank id');
            throw safeError(MSG_NOT_FOUND);
        }
        try {
            Id parsed = Id.valueOf(rawId.trim());
            if (parsed.getSObjectType() != Event_Detail__c.SObjectType) {
                System.debug(LoggingLevel.WARN, LOG + 'parseEventId: id of wrong object type');
                throw safeError(MSG_NOT_FOUND);
            }
            return parsed;
        } catch (StringException se) {
            System.debug(LoggingLevel.WARN, LOG + 'parseEventId: malformed id');
            throw safeError(MSG_NOT_FOUND);
        }
    }

    private static EventDto toDto(Event_Detail__c row) {
        EventDto dto = new EventDto();
        dto.id = row.Id;
        dto.name = row.Name;
        dto.description = row.Description__c;
        dto.startDateTime = row.Start_DateTime__c;
        dto.timeZone = row.Time_Zone__c;
        dto.venueName = row.Venue_Name__c;
        dto.venueAddress = row.Venue_Address__c;
        Boolean coordsOk = row.Venue_Latitude__c != null && row.Venue_Longitude__c != null
            && Math.abs(row.Venue_Latitude__c) <= 90 && Math.abs(row.Venue_Longitude__c) <= 180;
        dto.latitude = coordsOk ? row.Venue_Latitude__c : null;
        dto.longitude = coordsOk ? row.Venue_Longitude__c : null;
        if (row.Ticket_Categories__r != null) {
            for (Ticket_Category__c c : row.Ticket_Categories__r) {
                CategoryDto cd = new CategoryDto();
                cd.id = c.Id;
                cd.name = c.Name;
                cd.price = c.Price__c;
                cd.available = c.Available_Quantity__c == null ? 0 : c.Available_Quantity__c;
                dto.categories.add(cd);
            }
        }
        return dto;
    }

    private static AuraHandledException safeError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message); // otherwise the client sees "Script-thrown exception"
        return ex;
    }
}