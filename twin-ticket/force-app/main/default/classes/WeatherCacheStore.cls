/**
 * Reads and writes ONLY the weather cache fields of ONE event, and only after WeatherService has proven that the
 * caller is allowed to see that event. 'without sharing' is deliberate: guests have no access to these fields.
 */
public without sharing class WeatherCacheStore {

    public class Cache {
        public String key;
        public Date fetchedOn;
        public String summary;
        public Integer code;
        public Decimal maxTemp;
        public Decimal minTemp;
        public Integer precipProbability;
        public Datetime lastErrorOn;
    }

    public static Cache read(Id eventId) {
        Event_Detail__c e = [SELECT Weather_Cache_Key__c, Weather_Fetched_On__c, Weather_Summary__c, Weather_Code__c,
                                    Weather_Max_Temp__c, Weather_Min_Temp__c, Weather_Precip_Prob__c, Weather_Last_Error_On__c
                             FROM Event_Detail__c WHERE Id = :eventId LIMIT 1];
        Cache c = new Cache();
        c.key = e.Weather_Cache_Key__c;
        c.fetchedOn = e.Weather_Fetched_On__c;
        c.summary = e.Weather_Summary__c;
        c.code = e.Weather_Code__c == null ? null : e.Weather_Code__c.intValue();
        c.maxTemp = e.Weather_Max_Temp__c;
        c.minTemp = e.Weather_Min_Temp__c;
        c.precipProbability = e.Weather_Precip_Prob__c == null ? null : e.Weather_Precip_Prob__c.intValue();
        c.lastErrorOn = e.Weather_Last_Error_On__c;
        return c;
    }

    public static void saveSuccess(Id eventId, String key, String summary, WeatherClient.Forecast f) {
        update new Event_Detail__c(Id = eventId, Weather_Cache_Key__c = key, Weather_Fetched_On__c = Date.today(),
            Weather_Summary__c = summary, Weather_Code__c = f.weatherCode, Weather_Max_Temp__c = f.maxTemp,
            Weather_Min_Temp__c = f.minTemp, Weather_Precip_Prob__c = f.precipProbability, Weather_Last_Error_On__c = null);
    }

    /** A failure stores ONLY the time of the failure. Old values are left alone and never mixed with new ones. */
    public static void saveFailure(Id eventId) {
        update new Event_Detail__c(Id = eventId, Weather_Last_Error_On__c = Datetime.now());
    }
}