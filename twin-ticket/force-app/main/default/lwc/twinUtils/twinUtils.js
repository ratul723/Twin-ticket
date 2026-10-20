const LOW_STOCK_THRESHOLD = 20;
const CURRENCY = 'USD';

export function formatDate(isoValue, timeZone, options) {
    const date = new Date(isoValue);
    if (isNaN(date.getTime())) {
        return 'Date to be announced';
    }
    try {
        return new Intl.DateTimeFormat('en-GB', { ...options, timeZone: timeZone || undefined }).format(date);
    } catch (e) {
        // Invalid time zone value in the data: fall back to the browser's zone, never crash the page.
        return new Intl.DateTimeFormat('en-GB', options).format(date);
    }
}

export function formatPrice(value) {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: CURRENCY }).format(Number(value) || 0);
}

export function decorateCategory(c) {
    const available = Number(c.available) || 0;
    let badgeClass = 'badge badge--ok';
    let badgeText = `${available} available`;
    if (available <= 0) {
        badgeClass = 'badge badge--out';
        badgeText = 'Sold out';
    } else if (available <= LOW_STOCK_THRESHOLD) {
        badgeClass = 'badge badge--low';
        badgeText = `Only ${available} left`;
    }
    return { ...c, priceLabel: formatPrice(c.price), badgeClass, badgeText, soldOut: available <= 0 };
}

export function decorateEvent(ev) {
    const categories = (ev.categories || []).map(decorateCategory);
    const description = ev.description || '';
    return {
        ...ev,
        monthLabel: formatDate(ev.startDateTime, ev.timeZone, { month: 'short' }).toUpperCase(),
        dayLabel: formatDate(ev.startDateTime, ev.timeZone, { day: '2-digit' }),
        whenLabel: formatDate(ev.startDateTime, ev.timeZone, {
            weekday: 'short', day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit'
        }),
        shortDescription: description.length > 150 ? description.substring(0, 147) + '…' : description,
        categories,
        hasCategories: categories.length > 0,
        bulkDisabled: categories.length === 0 || categories.every((c) => c.soldOut)
    };
}