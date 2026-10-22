public class WeatherDto {
    public class Result {
        /** AVAILABLE | NOT_YET | PAST | NO_LOCATION | DISABLED | UNAVAILABLE */
        @AuraEnabled public String state;
        @AuraEnabled public String message;
        @AuraEnabled public String summary;
        @AuraEnabled public Integer weatherCode;
        @AuraEnabled public Decimal maxTemp;
        @AuraEnabled public Decimal minTemp;
        @AuraEnabled public Integer precipProbability;
        @AuraEnabled public Date forecastDate;
        @AuraEnabled public Boolean fromCache = false;
        @AuraEnabled public String attributionText = 'Weather data by Open-Meteo.com';
        @AuraEnabled public String attributionUrl = 'https://open-meteo.com/';
    }
}