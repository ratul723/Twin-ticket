/**
 * The ONLY class that talks to Open-Meteo. It uses the Named Credential 'OpenMeteo' (no secrets exist for this provider).
 * It never throws: every outcome is returned as a classified result so callers can degrade gracefully.
 * It NEVER invents data. If any required value is missing or inconsistent, the result is a failure.
 */
public without sharing class WeatherClient {

    public class Forecast {
        public Boolean ok = false;
        public Integer httpStatus;
        public String failure;          // CONFIG | NETWORK | QUOTA | BAD_REQUEST | SERVER | BAD_RESPONSE | MISSING_DATA
        public Date forecastDate;
        public Integer weatherCode;
        public Decimal maxTemp;
        public Decimal minTemp;
        public Integer precipProbability;   // may stay null: precipitation probability is not always available. Never guessed.
    }

    private static final String LOG = 'TT-WEATHER ';
    private static final Integer TIMEOUT_MS = 8000;      // weather is optional, so we never make a visitor wait long
    private static final Pattern TZ_PATTERN = Pattern.compile('^[A-Za-z0-9_+\\-/]{1,64}$');

    public static Forecast fetchDay(Decimal latitude, Decimal longitude, String timeZone, Date day) {
        Forecast f = new Forecast();
        if (latitude == null || longitude == null || day == null
            || Math.abs(latitude) > 90 || Math.abs(longitude) > 180) {
            f.failure = 'BAD_REQUEST';
            return f;
        }
        // The time zone value comes from a record, so it is validated before it goes anywhere near a URL.
        String tz = (String.isNotBlank(timeZone) && TZ_PATTERN.matcher(timeZone.trim()).matches()) ? timeZone.trim() : 'auto';
        String dayText = String.valueOf(day);          // yyyy-MM-dd

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:OpenMeteo/v1/forecast'
            + '?latitude=' + latitude.setScale(4).toPlainString()
            + '&longitude=' + longitude.setScale(4).toPlainString()
            + '&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max'
            + '&timezone=' + EncodingUtil.urlEncode(tz, 'UTF-8')
            + '&start_date=' + dayText + '&end_date=' + dayText);
        req.setMethod('GET');
        req.setTimeout(TIMEOUT_MS);

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException ce) {
            String m = ce.getMessage() == null ? '' : ce.getMessage().toLowerCase();
            // A missing Named Credential, a missing principal permission or a blocked endpoint are CONFIG problems for admins.
            f.failure = (m.contains('credential') || m.contains('unauthorized endpoint') || m.contains('principal')) ? 'CONFIG' : 'NETWORK';
            System.debug(LoggingLevel.ERROR, LOG + 'callout failed: ' + f.failure);
            return f;
        }

        f.httpStatus = res.getStatusCode();
        if (f.httpStatus == 429) { f.failure = 'QUOTA'; return f; }
        if (f.httpStatus >= 500) { f.failure = 'SERVER'; return f; }
        if (f.httpStatus >= 400) { f.failure = 'BAD_REQUEST'; return f; }   // e.g. the day is outside the supported range
        if (f.httpStatus < 200 || f.httpStatus >= 300) { f.failure = 'BAD_RESPONSE'; return f; }

        try {
            Object parsed = JSON.deserializeUntyped(res.getBody());
            if (!(parsed instanceof Map<String, Object>)) { f.failure = 'BAD_RESPONSE'; return f; }
            Object dailyObj = ((Map<String, Object>) parsed).get('daily');
            if (!(dailyObj instanceof Map<String, Object>)) { f.failure = 'BAD_RESPONSE'; return f; }
            Map<String, Object> daily = (Map<String, Object>) dailyObj;

            // The response must be for exactly the day we asked about.
            String returnedDay = firstString(daily.get('time'));
            if (returnedDay == null || !returnedDay.startsWith(dayText)) { f.failure = 'BAD_RESPONSE'; return f; }

            Decimal max = firstNumber(daily.get('temperature_2m_max'));
            Decimal min = firstNumber(daily.get('temperature_2m_min'));
            Decimal code = firstNumber(daily.get('weather_code'));
            if (max == null || min == null || code == null) { f.failure = 'MISSING_DATA'; return f; }   // never fill the gap with a guess

            Decimal pop = firstNumber(daily.get('precipitation_probability_max'));
            f.forecastDate = day;
            f.maxTemp = max.setScale(1);
            f.minTemp = min.setScale(1);
            f.weatherCode = code.intValue();
            f.precipProbability = pop == null ? null : Math.min(100, Math.max(0, pop.intValue()));
            f.ok = true;
        } catch (Exception e) {
            f.failure = 'BAD_RESPONSE';
            System.debug(LoggingLevel.ERROR, LOG + 'could not parse the response: ' + e.getTypeName());
        }
        return f;
    }

    private static String firstString(Object listObj) {
        if (listObj instanceof List<Object> && !((List<Object>) listObj).isEmpty()) {
            Object first = ((List<Object>) listObj)[0];
            return first == null ? null : String.valueOf(first);
        }
        return null;
    }

    private static Decimal firstNumber(Object listObj) {
        if (listObj instanceof List<Object> && !((List<Object>) listObj).isEmpty()) {
            Object first = ((List<Object>) listObj)[0];
            if (first == null) { return null; }
            try { return Decimal.valueOf(String.valueOf(first)); } catch (Exception e) { return null; }
        }
        return null;
    }
}