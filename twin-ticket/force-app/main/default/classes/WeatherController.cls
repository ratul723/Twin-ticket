public with sharing class WeatherController {
    private static final String LOG = 'TT-WEATHER ';
    @TestVisible private static Boolean simulateUnexpectedError = false;

    /** Not cacheable on purpose: it may refresh the daily cache. It never throws, it always returns a state the page can show. */
    @AuraEnabled
    public static WeatherDto.Result getWeather(String eventId) {
        try {
            if (simulateUnexpectedError) { throw new DmlException('simulated'); }
            return WeatherService.getForecast(eventId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG + 'controller failed: ' + e.getTypeName());
            WeatherDto.Result r = new WeatherDto.Result();
            r.state = 'UNAVAILABLE';
            r.message = WeatherService.MSG_UNAVAILABLE;
            return r;
        }
    }
}