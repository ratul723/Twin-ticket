/**
 * Decides what a visitor sees for an event's weather. NEVER throws and NEVER invents data.
 * ORDER (callout first, database writes last): visibility proof -> decision -> cache -> cooldown -> callout -> cache write -> logs.
 * SECURITY: the event is first read 'with sharing' + WITH USER_MODE, so the guest only gets forecasts for events
 * they may already see (Published). Cache fields are touched only by WeatherCacheStore.
 */
public with sharing class WeatherService {

    private static final String LOG = 'TT-WEATHER ';
    private static final String corr = 'W' + String.valueOf(Math.abs(Crypto.getRandomLong()));
    @TestVisible private static final String MSG_UNAVAILABLE = 'We could not load the forecast right now. Please check back a little later.';
    @TestVisible private static final String MSG_NOT_YET = 'Forecast not available yet. Forecasts appear up to {0} days before the event.';
    @TestVisible private static final String MSG_PAST = 'This event has already taken place.';
    @TestVisible private static final String MSG_NO_LOCATION = 'The venue location is not available, so we cannot show a forecast.';

    public static WeatherDto.Result getForecast(String rawEventId) {
        WeatherDto.Result r = new WeatherDto.Result();
        try {
            if (!TwinTicketConfig.weatherEnabled()) { r.state = 'DISABLED'; return r; }

            Id eventId = parseEventId(rawEventId);
            if (eventId == null) { return unavailable(r); }

            // 1. Visibility proof, as the CURRENT (guest) user. A Draft or unknown event looks exactly like a failure.
            List<Event_Detail__c> rows = [
                SELECT Id, Start_DateTime__c, Time_Zone__c, Venue_Latitude__c, Venue_Longitude__c
                FROM Event_Detail__c WHERE Id = :eventId AND Status__c = 'Published' WITH USER_MODE LIMIT 1];
            if (rows.isEmpty()) { return unavailable(r); }
            Event_Detail__c ev = rows[0];

            // 2. Decisions that need no external call.
            if (!validLocation(ev.Venue_Latitude__c, ev.Venue_Longitude__c) || ev.Start_DateTime__c == null) {
                r.state = 'NO_LOCATION'; r.message = MSG_NO_LOCATION; return r;
            }
            String tz = ev.Time_Zone__c;
            Date eventDay = localDate(ev.Start_DateTime__c, tz);
            Date today = localDate(Datetime.now(), tz);
            Integer daysAhead = today.daysBetween(eventDay);
            r.forecastDate = eventDay;
            if (daysAhead < 0) { r.state = 'PAST'; r.message = MSG_PAST; return r; }
            Integer horizon = TwinTicketConfig.weatherHorizonDays();
            if (daysAhead > horizon) {
                r.state = 'NOT_YET';
                r.message = String.format(MSG_NOT_YET, new List<String>{ String.valueOf(horizon) });
                return r;
            }

            // 3. Cache: one successful lookup per event per day, and only for the same place and date.
            String key = cacheKey(ev.Venue_Latitude__c, ev.Venue_Longitude__c, eventDay);
            WeatherCacheStore.Cache cache = WeatherCacheStore.read(eventId);
            if (cache.key == key && cache.fetchedOn == Date.today() && cache.maxTemp != null && cache.minTemp != null && cache.code != null) {
                return fill(r, cache.summary, cache.code, cache.maxTemp, cache.minTemp, cache.precipProbability, true);
            }

            // 4. Cooldown after a recent failure: protects the free service and keeps the page fast during an outage.
            if (cache.lastErrorOn != null && cache.lastErrorOn > Datetime.now().addMinutes(-TwinTicketConfig.weatherBackoffMinutes())) {
                System.debug(LoggingLevel.INFO, LOG + 'in cooldown after a recent failure, event=' + eventId);
                return unavailable(r);
            }

            // 5. The callout, then (and only then) database writes.
            WeatherClient.Forecast f = WeatherClient.fetchDay(ev.Venue_Latitude__c, ev.Venue_Longitude__c, tz, eventDay);
            IntegrationLogger.add('Open-Meteo', 'GetForecast', f.httpStatus, f.ok, corr,
                f.ok ? 'OK' : 'Failure: ' + f.failure, String.valueOf(eventId));
            if (!f.ok) {
                WeatherCacheStore.saveFailure(eventId);
                if (f.failure == 'BAD_REQUEST' && daysAhead >= horizon) {
                    // The API refused a day at the edge of its range. That is "not yet", not an outage.
                    r.state = 'NOT_YET';
                    r.message = String.format(MSG_NOT_YET, new List<String>{ String.valueOf(Math.max(0, horizon - 1)) });
                    return r;
                }
                return unavailable(r);
            }
            String summary = describe(f.weatherCode);
            WeatherCacheStore.saveSuccess(eventId, key, summary, f);
            System.debug(LoggingLevel.INFO, LOG + 'forecast fetched and cached, event=' + eventId + ' daysAhead=' + daysAhead);
            return fill(r, summary, f.weatherCode, f.maxTemp, f.minTemp, f.precipProbability, false);
        } catch (Exception e) {
            // Weather must never break the page, whatever goes wrong.
            System.debug(LoggingLevel.ERROR, LOG + 'getForecast failed: ' + e.getTypeName() + ' - ' + e.getMessage());
            return unavailable(r);
        } finally {
            IntegrationLogger.flush();
        }
    }

    // ---------- helpers ----------
    private static WeatherDto.Result fill(WeatherDto.Result r, String summary, Integer code, Decimal max, Decimal min, Integer pop, Boolean cached) {
        r.state = 'AVAILABLE';
        r.summary = String.isBlank(summary) ? describe(code) : summary;
        r.weatherCode = code;
        r.maxTemp = max;
        r.minTemp = min;
        r.precipProbability = pop;
        r.fromCache = cached;
        return r;
    }

    private static WeatherDto.Result unavailable(WeatherDto.Result r) {
        r.state = 'UNAVAILABLE';
        r.message = MSG_UNAVAILABLE;
        return r;
    }

    @TestVisible
    private static Boolean validLocation(Decimal lat, Decimal lon) {
        return lat != null && lon != null && Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && !(lat == 0 && lon == 0);
    }

    /** "Today" and "the event day" are both measured in the VENUE's time zone. */
    @TestVisible
    private static Date localDate(Datetime moment, String tz) {
        String zone = String.isBlank(tz) ? 'GMT' : tz;
        try {
            return Date.valueOf(moment.format('yyyy-MM-dd', zone));
        } catch (Exception e) {
            return Date.valueOf(moment.formatGmt('yyyy-MM-dd'));
        }
    }

    @TestVisible
    private static String cacheKey(Decimal lat, Decimal lon, Date day) {
        return (lat.setScale(4).toPlainString() + '|' + lon.setScale(4).toPlainString() + '|' + String.valueOf(day)).left(80);
    }

    private static Id parseEventId(String raw) {
        if (String.isBlank(raw)) { return null; }
        try {
            Id parsed = Id.valueOf(raw.trim());
            return parsed.getSObjectType() == Event_Detail__c.SObjectType ? parsed : null;
        } catch (StringException e) {
            return null;
        }
    }

    /** WMO weather interpretation codes, in plain words. Unknown codes get a neutral label, never a guess. */
    @TestVisible
    private static String describe(Integer code) {
        if (code == null) { return 'Forecast available'; }
        if (code == 0) { return 'Clear sky'; }
        if (code == 1) { return 'Mostly clear'; }
        if (code == 2) { return 'Partly cloudy'; }
        if (code == 3) { return 'Overcast'; }
        if (code == 45 || code == 48) { return 'Fog'; }
        if (code >= 51 && code <= 57) { return 'Drizzle'; }
        if (code >= 61 && code <= 67) { return 'Rain'; }
        if (code >= 71 && code <= 77) { return 'Snow'; }
        if (code >= 80 && code <= 82) { return 'Rain showers'; }
        if (code == 85 || code == 86) { return 'Snow showers'; }
        if (code == 95) { return 'Thunderstorm'; }
        if (code == 96 || code == 99) { return 'Thunderstorm with hail'; }
        return 'Forecast available';
    }
}