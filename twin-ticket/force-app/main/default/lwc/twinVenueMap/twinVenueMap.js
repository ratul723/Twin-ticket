import { LightningElement, api } from 'lwc';

const HALF_WIDTH_DEG = 0.01;
const HALF_HEIGHT_DEG = 0.006;

export default class TwinVenueMap extends LightningElement {
    @api latitude;
    @api longitude;
    @api venueName;
    @api venueAddress;

    get lat() { return Number(this.latitude); }
    get lon() { return Number(this.longitude); }

    get hasLocation() {
        // Validate before building any URL: null, text, or out-of-range values show the fallback instead.
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