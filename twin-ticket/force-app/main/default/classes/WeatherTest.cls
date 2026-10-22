@IsTest
private class WeatherTest {

    /** Returns a canned response, records every call, and can simulate a network failure. */
    public class MeteoMock implements HttpCalloutMock {
        public Integer status = 200;
        public String body;
        public String throwMessage;
        public List<HttpRequest> calls = new List<HttpRequest>();
        public HttpResponse respond(HttpRequest req) {
            calls.add(req);
            if (throwMessage != null) { throw new CalloutException(throwMessage); }
            HttpResponse r = new HttpResponse();
            r.setStatusCode(status);
            r.setBody(body == null ? '{}' : body);
            return r;
        }
    }

    @TestSetup
    static void setup() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String uniq = String.valueOf(Math.abs(Crypto.getRandomLong()));
        insert new User(Alias = 'wxna', Email = 'wxna' + uniq + '@example.com', EmailEncodingKey = 'UTF-8', LastName = 'NoAccess',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id,
            TimeZoneSidKey = 'Asia/Dhaka', Username = 'wxna' + uniq + '@twinticket-test.example.com');
        insert new List<Event_Detail__c>{
            new Event_Detail__c(Name = 'Wx Near', Status__c = 'Published', Start_DateTime__c = System.now().addDays(5), Time_Zone__c = 'Asia/Dhaka',
                Venue_Name__c = 'Hall', Venue_Latitude__c = 23.8103, Venue_Longitude__c = 90.4125),
            new Event_Detail__c(Name = 'Wx Far', Status__c = 'Published', Start_DateTime__c = System.now().addDays(60), Time_Zone__c = 'Asia/Dhaka',
                Venue_Latitude__c = 23.8103, Venue_Longitude__c = 90.4125),
            new Event_Detail__c(Name = 'Wx Past', Status__c = 'Published', Start_DateTime__c = System.now().addDays(-3), Time_Zone__c = 'Asia/Dhaka',
                Venue_Latitude__c = 23.8103, Venue_Longitude__c = 90.4125),
            new Event_Detail__c(Name = 'Wx NoLoc', Status__c = 'Published', Start_DateTime__c = System.now().addDays(5), Time_Zone__c = 'Asia/Dhaka'),
            new Event_Detail__c(Name = 'Wx BadLoc', Status__c = 'Published', Start_DateTime__c = System.now().addDays(5), Time_Zone__c = 'Asia/Dhaka',
                Venue_Latitude__c = 123.0, Venue_Longitude__c = 90.4125),
            new Event_Detail__c(Name = 'Wx Draft', Status__c = 'Draft', Start_DateTime__c = System.now().addDays(5), Time_Zone__c = 'Asia/Dhaka',
                Venue_Latitude__c = 23.8103, Venue_Longitude__c = 90.4125),
            new Event_Detail__c(Name = 'Wx BadTz', Status__c = 'Published', Start_DateTime__c = System.now().addDays(5), Time_Zone__c = 'Asia/Dhaka&latitude=1',
                Venue_Latitude__c = 23.8103, Venue_Longitude__c = 90.4125)
        };
    }

    // ---------- helpers ----------
    private static void cfg() {
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Weather_Enabled__c = true, Weather_Horizon_Days__c = 15, Weather_Backoff_Minutes__c = 10);
    }
    private static Event_Detail__c ev(String name) {
        return [SELECT Id, Start_DateTime__c, Time_Zone__c FROM Event_Detail__c WHERE Name = :name LIMIT 1];
    }
    private static String dayOf(Event_Detail__c e) {
        return e.Start_DateTime__c.format('yyyy-MM-dd', e.Time_Zone__c.contains('&') ? 'GMT' : e.Time_Zone__c);
    }
    private static String okBody(String day) {
        return '{"latitude":23.8,"longitude":90.4,"daily":{"time":["' + day + '"],"weather_code":[61],'
            + '"temperature_2m_max":[31.44],"temperature_2m_min":[24.86],"precipitation_probability_max":[70]}}';
    }
    private static MeteoMock mock(Integer status, String body) {
        MeteoMock m = new MeteoMock();
        m.status = status;
        m.body = body;
        Test.setMock(HttpCalloutMock.class, m);
        return m;
    }
    private static Event_Detail__c cacheOf(Id id) {
        return [SELECT Weather_Cache_Key__c, Weather_Fetched_On__c, Weather_Summary__c, Weather_Code__c, Weather_Max_Temp__c,
                       Weather_Min_Temp__c, Weather_Precip_Prob__c, Weather_Last_Error_On__c FROM Event_Detail__c WHERE Id = :id];
    }

    // ---------- success and cache ----------
    @IsTest
    static void aSuccessfulLookupReturnsRealDataAndCachesIt() {
        cfg();
        Event_Detail__c e = ev('Wx Near');
        MeteoMock m = mock(200, okBody(dayOf(e)));
        WeatherDto.Result r = WeatherService.getForecast(String.valueOf(e.Id));

        Assert.areEqual('AVAILABLE', r.state);
        Assert.areEqual('Rain', r.summary);
        Assert.areEqual(31.4, r.maxTemp);
        Assert.areEqual(24.9, r.minTemp);
        Assert.areEqual(70, r.precipProbability);
        Assert.isFalse(r.fromCache);
        Assert.areEqual('Weather data by Open-Meteo.com', r.attributionText);

        Assert.areEqual(1, m.calls.size());
        String url = m.calls[0].getEndpoint();
        Assert.isTrue(url.startsWith('callout:OpenMeteo/v1/forecast?'), 'goes through the Named Credential');
        Assert.isTrue(url.contains('latitude=23.8103') && url.contains('longitude=90.4125'));
        Assert.isTrue(url.contains('start_date=' + dayOf(e)) && url.contains('end_date=' + dayOf(e)));
        Assert.isTrue(url.contains('timezone=Asia%2FDhaka'));
        Assert.isFalse(url.toLowerCase().contains('key') || url.toLowerCase().contains('token'), 'no secrets exist or travel in the URL');

        Event_Detail__c c = cacheOf(e.Id);
        Assert.areEqual(Date.today(), c.Weather_Fetched_On__c);
        Assert.areEqual(61, c.Weather_Code__c);
        Assert.areEqual(31.4, c.Weather_Max_Temp__c);
        Assert.isNull(c.Weather_Last_Error_On__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Integration_Log__c WHERE Provider__c = 'Open-Meteo' AND Outcome__c = 'Success']);
    }

    @IsTest
    static void theSecondViewOfTheDayIsServedFromTheCacheWithoutACallout() {
        cfg();
        Event_Detail__c e = ev('Wx Near');
        MeteoMock m = mock(200, okBody(dayOf(e)));
        WeatherService.getForecast(String.valueOf(e.Id));
        WeatherDto.Result second = WeatherService.getForecast(String.valueOf(e.Id));
        Assert.areEqual('AVAILABLE', second.state);
        Assert.isTrue(second.fromCache);
        Assert.areEqual(1, m.calls.size(), 'only one external call per event per day');
    }

    @IsTest
    static void aChangedVenueDateOrAnOldCacheTriggersAFreshLookup() {
        cfg();
        Event_Detail__c e = ev('Wx Near');
        MeteoMock m = mock(200, okBody(dayOf(e)));
        WeatherService.getForecast(String.valueOf(e.Id));

        update new Event_Detail__c(Id = e.Id, Venue_Latitude__c = 22.3569);          // the venue moved
        WeatherService.getForecast(String.valueOf(e.Id));
        Assert.areEqual(2, m.calls.size(), 'cache key changed, so yesterday\'s data is not reused');

        update new Event_Detail__c(Id = e.Id, Weather_Fetched_On__c = Date.today().addDays(-1));   // cache is from yesterday
        WeatherService.getForecast(String.valueOf(e.Id));
        Assert.areEqual(3, m.calls.size(), 'a new day means a new lookup');
    }

    // ---------- no external call needed ----------
    @IsTest
    static void situationsThatNeedNoForecastNeverCallTheService() {
        cfg();
        MeteoMock m = mock(200, '{}');
        WeatherDto.Result far = WeatherService.getForecast(String.valueOf(ev('Wx Far').Id));
        Assert.areEqual('NOT_YET', far.state);
        Assert.isTrue(far.message.contains('15 days'));
        Assert.areEqual('PAST', WeatherService.getForecast(String.valueOf(ev('Wx Past').Id)).state);
        Assert.areEqual('NO_LOCATION', WeatherService.getForecast(String.valueOf(ev('Wx NoLoc').Id)).state);
        Assert.areEqual('NO_LOCATION', WeatherService.getForecast(String.valueOf(ev('Wx BadLoc').Id)).state, 'latitude 123 is invalid');
        Assert.areEqual(0, m.calls.size());
    }

    @IsTest
    static void draftUnknownAndMalformedEventsLookLikeAnOrdinaryFailure() {
        cfg();
        MeteoMock m = mock(200, '{}');
        Account notAnEvent = new Account(Name = 'Not an event');
        insert notAnEvent;
        for (String id : new List<String>{ String.valueOf(ev('Wx Draft').Id), 'not-an-id', '', null, String.valueOf(notAnEvent.Id) }) {
            WeatherDto.Result r = WeatherService.getForecast(id);
            Assert.areEqual('UNAVAILABLE', r.state, 'id: ' + id);
            Assert.areEqual(WeatherService.MSG_UNAVAILABLE, r.message);
        }
        Assert.areEqual(0, m.calls.size());
    }

    @IsTest
    static void aUserWithoutAccessToEventsGetsAFailureAndNoCallout() {
        cfg();
        MeteoMock m = mock(200, '{}');
        Id eventId = ev('Wx Near').Id;
        User wxnaUser = [SELECT Id FROM User WHERE Alias = 'wxna' LIMIT 1];
        System.runAs(wxnaUser) {
            Assert.areEqual('UNAVAILABLE', WeatherService.getForecast(String.valueOf(eventId)).state);
        }
        Assert.areEqual(0, m.calls.size());
    }

    @IsTest
    static void theFeatureFlagAndTheConfiguredHorizonAreRespected() {
        Event_Detail__c e = ev('Wx Near');
        MeteoMock m = mock(200, okBody(dayOf(e)));
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Weather_Enabled__c = false);
        Assert.areEqual('DISABLED', WeatherService.getForecast(String.valueOf(e.Id)).state);
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Weather_Enabled__c = true, Weather_Horizon_Days__c = 2);
        Assert.areEqual('NOT_YET', WeatherService.getForecast(String.valueOf(e.Id)).state, 'event is 5 days away, horizon is 2');
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Weather_Enabled__c = true, Weather_Horizon_Days__c = 99);
        Assert.areEqual(15, TwinTicketConfig.weatherHorizonDays(), 'config can only narrow the range');
        Assert.areEqual(0, m.calls.size());
    }

    // ---------- failures ----------
    @IsTest
    static void everyKindOfServiceFailureDegradesGracefullyAndNeverInventsData() {
        cfg();
        Map<String, Object[]> scenarios = new Map<String, Object[]>{
            'server error' => new Object[]{ 500, '{"error":true}' },
            'quota' => new Object[]{ 429, '{"error":true,"reason":"limit"}' },
            'bad request' => new Object[]{ 400, '{"error":true,"reason":"Date out of range"}' },
            'not json' => new Object[]{ 200, '<html>oops</html>' },
            'no daily block' => new Object[]{ 200, '{"latitude":1}' },
            'daily is not an object' => new Object[]{ 200, '{"daily":[1,2]}' },
            'unexpected status' => new Object[]{ 302, '{}' }
        };
        Integer n = 0;
        for (String name : scenarios.keySet()) {
            Event_Detail__c e = ev('Wx Near');
            update new Event_Detail__c(Id = e.Id, Weather_Last_Error_On__c = null, Weather_Fetched_On__c = null, Weather_Cache_Key__c = null);
            Object[] s = scenarios.get(name);
            mock((Integer) s[0], (String) s[1]);
            WeatherDto.Result r = WeatherService.getForecast(String.valueOf(e.Id));
            Assert.areEqual('UNAVAILABLE', r.state, name);
            Assert.isNull(r.maxTemp, name + ': no temperature may be invented');
            Assert.isNull(r.summary, name);
            Event_Detail__c c = cacheOf(e.Id);
            Assert.isNull(c.Weather_Max_Temp__c, name + ': nothing numeric is stored');
            Assert.isNotNull(c.Weather_Last_Error_On__c, name + ': the cooldown is recorded');
            n++;
        }
        Assert.isTrue([SELECT COUNT() FROM Integration_Log__c WHERE Provider__c = 'Open-Meteo' AND Outcome__c = 'Failure'] >= n);
        for (Integration_Log__c l : [SELECT Message__c FROM Integration_Log__c WHERE Provider__c = 'Open-Meteo']) {
            Assert.isFalse(String.valueOf(l.Message__c).toLowerCase().contains('latitude'), 'logs hold no coordinates');
        }
    }

    @IsTest
    static void incompleteDataIsRefusedRatherThanFilledIn() {
        cfg();
        Event_Detail__c e = ev('Wx Near');
        String d = dayOf(e);
        List<String> bad = new List<String>{
            '{"daily":{"time":["' + d + '"],"weather_code":[61],"temperature_2m_max":[null],"temperature_2m_min":[20],"precipitation_probability_max":[10]}}',
            '{"daily":{"time":["' + d + '"],"weather_code":[],"temperature_2m_max":[30],"temperature_2m_min":[20]}}',
            '{"daily":{"time":["' + d + '"],"weather_code":[61],"temperature_2m_max":["abc"],"temperature_2m_min":[20]}}',
            '{"daily":{"time":["2001-01-01"],"weather_code":[61],"temperature_2m_max":[30],"temperature_2m_min":[20]}}',   // wrong day
            '{"daily":{"time":[],"weather_code":[61],"temperature_2m_max":[30],"temperature_2m_min":[20]}}'
        };
        for (String body : bad) {
            update new Event_Detail__c(Id = e.Id, Weather_Last_Error_On__c = null);
            mock(200, body);
            Assert.areEqual('UNAVAILABLE', WeatherService.getForecast(String.valueOf(e.Id)).state, body);
        }
    }

    @IsTest
    static void missingRainProbabilityIsShownAsUnavailableNotGuessed() {
        cfg();
        Event_Detail__c e = ev('Wx Near');
        mock(200, '{"daily":{"time":["' + dayOf(e) + '"],"weather_code":[3],"temperature_2m_max":[30],"temperature_2m_min":[22]}}');
        WeatherDto.Result r = WeatherService.getForecast(String.valueOf(e.Id));
        Assert.areEqual('AVAILABLE', r.state);
        Assert.isNull(r.precipProbability, 'optional data stays empty');
        Assert.areEqual('Overcast', r.summary);
    }

    @IsTest
    static void networkAndCredentialProblemsAreClassifiedAndHandled() {
        cfg();
        Event_Detail__c e = ev('Wx Near');
        for (String message : new List<String>{ 'Read timed out', 'Named credential not found for OpenMeteo', 'Unauthorized endpoint, please check Setup' }) {
            update new Event_Detail__c(Id = e.Id, Weather_Last_Error_On__c = null);
            MeteoMock m = new MeteoMock();
            m.throwMessage = message;
            Test.setMock(HttpCalloutMock.class, m);
            Assert.areEqual('UNAVAILABLE', WeatherService.getForecast(String.valueOf(e.Id)).state, message);
        }
        Assert.isTrue([SELECT COUNT() FROM Integration_Log__c WHERE Message__c = 'Failure: CONFIG'] >= 2);
        Assert.isTrue([SELECT COUNT() FROM Integration_Log__c WHERE Message__c = 'Failure: NETWORK'] >= 1);
    }

    @IsTest
    static void afterAFailureTheCooldownStopsRepeatedCallsUntilItExpires() {
        cfg();
        Event_Detail__c e = ev('Wx Near');
        MeteoMock m = mock(500, '{}');
        WeatherService.getForecast(String.valueOf(e.Id));
        WeatherService.getForecast(String.valueOf(e.Id));
        WeatherService.getForecast(String.valueOf(e.Id));
        Assert.areEqual(1, m.calls.size(), 'during the cooldown the free service is not called again');

        update new Event_Detail__c(Id = e.Id, Weather_Last_Error_On__c = Datetime.now().addMinutes(-11));
        m.status = 200;
        m.body = okBody(dayOf(e));
        Assert.areEqual('AVAILABLE', WeatherService.getForecast(String.valueOf(e.Id)).state, 'service is retried after the cooldown');
        Assert.areEqual(2, m.calls.size());
        Assert.isNull(cacheOf(e.Id).Weather_Last_Error_On__c, 'a success clears the failure mark');
    }

    @IsTest
    static void aRefusedDayAtTheEdgeOfTheRangeIsReportedAsNotYet() {
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Weather_Enabled__c = true, Weather_Horizon_Days__c = 5);
        Event_Detail__c e = ev('Wx Near');                         // exactly 5 days ahead
        mock(400, '{"error":true,"reason":"out of range"}');
        WeatherDto.Result r = WeatherService.getForecast(String.valueOf(e.Id));
        Assert.areEqual('NOT_YET', r.state);
    }

    @IsTest
    static void aUnsafeTimeZoneValueNeverReachesTheUrl() {
        cfg();
        Event_Detail__c e = ev('Wx BadTz');
        MeteoMock m = mock(200, okBody(dayOf(e)));
        WeatherService.getForecast(String.valueOf(e.Id));
        Assert.isTrue(m.calls.isEmpty() || m.calls[0].getEndpoint().contains('timezone=auto'), 'unsafe values fall back to "auto"');
        if (!m.calls.isEmpty()) {
            Assert.isFalse(m.calls[0].getEndpoint().contains('latitude=1'), 'no parameter injection');
        }
    }

    @IsTest
    static void clientRejectsImpossibleInputsWithoutCalling() {
        MeteoMock m = mock(200, '{}');
        Assert.areEqual('BAD_REQUEST', WeatherClient.fetchDay(null, 10, 'GMT', Date.today()).failure);
        Assert.areEqual('BAD_REQUEST', WeatherClient.fetchDay(95, 10, 'GMT', Date.today()).failure);
        Assert.areEqual('BAD_REQUEST', WeatherClient.fetchDay(10, 190, 'GMT', Date.today()).failure);
        Assert.areEqual('BAD_REQUEST', WeatherClient.fetchDay(10, 10, 'GMT', null).failure);
        Assert.areEqual(0, m.calls.size());
    }

    // ---------- helpers, controller, config ----------
    @IsTest
    static void describeCoversEveryWeatherFamilyAndUnknownCodes() {
        Map<Integer, String> expected = new Map<Integer, String>{
            0 => 'Clear sky', 1 => 'Mostly clear', 2 => 'Partly cloudy', 3 => 'Overcast', 45 => 'Fog', 48 => 'Fog', 53 => 'Drizzle',
            63 => 'Rain', 73 => 'Snow', 81 => 'Rain showers', 85 => 'Snow showers', 95 => 'Thunderstorm', 99 => 'Thunderstorm with hail',
            4 => 'Forecast available', 1234 => 'Forecast available' };
        for (Integer code : expected.keySet()) { Assert.areEqual(expected.get(code), WeatherService.describe(code), 'code ' + code); }
        Assert.areEqual('Forecast available', WeatherService.describe(null));
        Assert.areEqual('Thunderstorm with hail', WeatherService.describe(96));
    }

    @IsTest
    static void localDateHelpersAreSafe() {
        Assert.isTrue(WeatherService.validLocation(10, 10));
        Assert.isFalse(WeatherService.validLocation(0, 0), '0,0 is the classic "missing data" value');
        Assert.isFalse(WeatherService.validLocation(null, 10));
        Assert.isNotNull(WeatherService.localDate(Datetime.now(), 'Not/AZone'), 'a bad zone falls back instead of failing');
        Assert.isNotNull(WeatherService.localDate(Datetime.now(), null));
        Assert.areEqual('23.8103|90.4125|2026-10-27', WeatherService.cacheKey(23.8103, 90.4125, Date.newInstance(2026, 10, 27)));
    }

    @IsTest
    static void controllerReturnsStatesAndHidesUnexpectedErrors() {
        cfg();
        Event_Detail__c e = ev('Wx Near');
        mock(200, okBody(dayOf(e)));
        Assert.areEqual('AVAILABLE', WeatherController.getWeather(String.valueOf(e.Id)).state);
        WeatherController.simulateUnexpectedError = true;
        WeatherDto.Result r = WeatherController.getWeather(String.valueOf(e.Id));
        Assert.areEqual('UNAVAILABLE', r.state);
        Assert.areEqual(WeatherService.MSG_UNAVAILABLE, r.message);
    }

    @IsTest
    static void weatherConfigFallsBackToSafeDefaults() {
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt();
        Assert.isTrue(TwinTicketConfig.weatherEnabled());
        Assert.areEqual(15, TwinTicketConfig.weatherHorizonDays());
        Assert.areEqual(10, TwinTicketConfig.weatherBackoffMinutes());
        TwinTicketConfig.testRecord = new Twin_Ticket_Config__mdt(Weather_Backoff_Minutes__c = 9999, Weather_Horizon_Days__c = -4);
        Assert.areEqual(120, TwinTicketConfig.weatherBackoffMinutes());
        Assert.areEqual(0, TwinTicketConfig.weatherHorizonDays());
    }
}