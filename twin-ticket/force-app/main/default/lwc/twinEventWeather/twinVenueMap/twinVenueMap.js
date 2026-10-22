import { LightningElement, api } from 'lwc';

const HALF_WIDTH_DEG = 0.01;
const HALF_HEIGHT_DEG = 0.006;
const LOAD_TIMEOUT_MS = 10000;

export default class TwinVenueMap extends LightningElement {
    @api latitude;
    @api longitude;
    @api venueName;
    @api venueAddress;

    state = 'loading';          // loading | loaded | failed
    _timer;

    connectedCallback() {
        // If the frame never reports "loaded" (blocked, offline, slow), show a text fallback instead of an empty box.
        this._timer = setTimeout(() => {
            if (this.state === 'loading') { this.state = 'failed'; }
        }, LOAD_TIMEOUT_MS);
    }

    disconnectedCallback() {
        clearTimeout(this._timer);
    }

    handleLoaded() {
        clearTimeout(this._timer);
        this.state = 'loaded';
    }

    get isLoading() { return this.state === 'loading'; }
    get hasFailed() { return this.state === 'failed'; }
    get lat() { return Number(this.latitude); }
    get lon() { return Number(this.longitude); }

    get hasLocation() {
        // Validate before building any URL: null, text or out-of-range values show the address fallback instead.
        return this.latitude !== null && this.latitude !== undefined &&
               this.longitude !== null && this.longitude !== undefined &&
               Number.isFinite(this.lat) && Number.isFinite(this.lon) &&
               Math.abs(this.lat) <= 90 && Math.abs(this.lon) <= 180;
    }

    get mapTitle() { return `Map showing ${this.venueName || 'the venue'}`; }

    get embedUrl() {
        const bbox = [this.lon - HALF_WIDTH_DEG, this.lat - HALF_HEIGHT_DEG,
                      this.lon + HALF_WIDTH_DEG, this.lat + HALF_HEIGHT_DEG].join(',');
        return 'https://www.openstreetmap.org/export/embed.html?bbox=' + encodeURIComponent(bbox) +
               '&layer=mapnik&marker=' + encodeURIComponent(`${this.lat},${this.lon}`);
    }

    get osmLink() {
        return `https://www.openstreetmap.org/?mlat=${this.lat}&mlon=${this.lon}#map=16/${this.lat}/${this.lon}`;
    }

    // Use the directions link you validated in Phase 2 (swap this URL if the OSM one did not work for you).
    get directionsLink() {
        return `https://www.openstreetmap.org/directions?to=${encodeURIComponent(`${this.lat},${this.lon}`)}`;
    }
}