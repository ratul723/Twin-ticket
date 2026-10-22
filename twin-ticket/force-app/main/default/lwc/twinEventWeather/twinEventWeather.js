import { LightningElement, api } from 'lwc';
import getWeather from '@salesforce/apex/WeatherController.getWeather';

const FALLBACK = 'We could not load the forecast right now. Please check back a little later.';

// WMO weather codes grouped to a picture. The words come from the server. This is decoration only.
function iconFor(code) {
    if (code === 0) { return '☀️'; }
    if (code === 1) { return '🌤️'; }
    if (code === 2) { return '⛅'; }
    if (code === 3) { return '☁️'; }
    if (code === 45 || code === 48) { return '🌫️'; }
    if (code >= 51 && code <= 57) { return '🌦️'; }
    if (code >= 61 && code <= 67) { return '🌧️'; }
    if (code >= 71 && code <= 77) { return '🌨️'; }
    if (code >= 80 && code <= 82) { return '🌦️'; }
    if (code === 85 || code === 86) { return '🌨️'; }
    if (code >= 95) { return '⛈️'; }
    return '🌡️';
}

export default class TwinEventWeather extends LightningElement {
    _eventId;
    r;
    isLoading = true;
    retried = false;

    @api
    get eventId() { return this._eventId; }
    set eventId(value) {
        if (value && value !== this._eventId) {
            this._eventId = value;
            this.load();
        }
    }

    async load() {
        this.isLoading = true;
        try {
            this.r = await getWeather({ eventId: this._eventId });
        } catch (e) {
            // The server never throws for weather, so this means a network problem. Still never break the page.
            this.r = { state: 'UNAVAILABLE', message: FALLBACK };
        } finally {
            this.isLoading = false;
        }
    }

    get hidden() { return !this.isLoading && this.r && this.r.state === 'DISABLED'; }
    get isAvailable() { return this.r && this.r.state === 'AVAILABLE'; }
    get isInfo() { return this.r && ['NOT_YET', 'PAST', 'NO_LOCATION'].includes(this.r.state); }
    get showAttribution() { return this.isAvailable; }
    get messageText() { return (this.r && this.r.message) || FALLBACK; }
    get canRetry() { return !this.retried; }
    get icon() { return iconFor(this.r.weatherCode); }
    get tempRange() {
        const fmt = (n) => `${Math.round(Number(n))}°C`;
        return `${fmt(this.r.minTemp)} to ${fmt(this.r.maxTemp)}`;
    }
    get rainLabel() { return this.r.precipProbability == null ? 'Not available' : `${this.r.precipProbability}%`; }
    get dayLabel() {
        return this.r.forecastDate
            ? new Intl.DateTimeFormat('en-GB', { weekday: 'long', day: 'numeric', month: 'long' }).format(new Date(this.r.forecastDate + 'T12:00:00'))
            : '';
    }
    get cacheNote() { return this.r.fromCache ? 'Forecast updated earlier today.' : 'Forecast updated just now.'; }
    get infoIcon() {
        if (this.r.state === 'NOT_YET') { return 'utility:event'; }
        if (this.r.state === 'PAST') { return 'utility:check'; }
        return 'utility:location';
    }

    handleRetry() {
        this.retried = true;      // one retry only: the server has a cooldown after failures, so spamming helps nobody
        this.load();
    }
}