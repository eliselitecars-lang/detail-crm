import { afterEach, describe, expect, it } from 'vitest';
import {
  initTracking,
  isTrackingActive,
  resetTrackingForTests,
  sanitizedLocation,
  stopTracking,
  trackEvent,
  validTrackingIds,
} from './tracking';

type TrackingWindow = Window & {
  fbq?: { queue?: unknown[]; disablePushState?: boolean; callMethod?: unknown };
  dataLayer?: unknown[];
  gtag?: unknown;
};

afterEach(() => {
  resetTrackingForTests();
  document.head.querySelectorAll('script[src^="https://"]').forEach((s) => s.remove());
  const w = window as TrackingWindow;
  delete w.fbq;
  delete w.gtag;
  delete w.dataLayer;
});

describe('tracking', () => {
  it('accepts only ids in the database formats', () => {
    expect(
      validTrackingIds({ meta_pixel_id: ' 1234567890 ', ga4_measurement_id: 'g-abc123' }),
    ).toEqual({ metaPixelId: '1234567890', ga4MeasurementId: 'G-ABC123' });
    expect(validTrackingIds({ meta_pixel_id: 'x"><script>', ga4_measurement_id: 'UA-1' })).toEqual({
      metaPixelId: null,
      ga4MeasurementId: null,
    });
    expect(validTrackingIds(null)).toEqual({ metaPixelId: null, ga4MeasurementId: null });
  });

  it('never reports the query string or a booking token', () => {
    expect(sanitizedLocation('https://app.test/book/glacier?coupon=X&link=abc')).toBe(
      'https://app.test/book/glacier',
    );
    expect(
      sanitizedLocation('https://app.test/booking/cccccccc-cccc-4ccc-8ccc-cccccccccccc?paid=1'),
    ).toBe('https://app.test/booking');
  });

  it('sends events with the value in currency units, and nothing without tags', () => {
    trackEvent('booking_created', { valueCents: 12345, currency: 'usd' });
    const w = window as TrackingWindow;
    expect(w.fbq).toBeUndefined();
    initTracking({ metaPixelId: '1234567890', ga4MeasurementId: 'G-ABC123' });
    trackEvent('booking_created', { valueCents: 12345, currency: 'usd' });
    expect(w.fbq?.queue).toContainEqual(['track', 'Schedule', { value: 123.45, currency: 'USD' }]);
    const events = (w.dataLayer ?? []).map((a) => Array.from(a as ArrayLike<unknown>));
    expect(events).toContainEqual([
      'event',
      'generate_lead',
      expect.objectContaining({ value: 123.45, currency: 'USD', send_to: 'G-ABC123' }),
    ]);
  });

  it('can load GA4 without the Meta Pixel (booking pages)', () => {
    initTracking({ metaPixelId: '1234567890', ga4MeasurementId: 'G-ABC123' }, { allowMeta: false });
    expect((window as TrackingWindow).fbq).toBeUndefined();
    expect(document.head.querySelectorAll('script[src^="https://"]')).toHaveLength(1);
  });

  it('switches off Meta history page views and automatic configuration before init', () => {
    initTracking({ metaPixelId: '1234567890', ga4MeasurementId: null });
    const w = window as TrackingWindow;
    expect(w.fbq?.disablePushState).toBe(true);
    const queue = w.fbq?.queue ?? [];
    const autoConfig = queue.findIndex(
      (a) => JSON.stringify(a) === JSON.stringify(['set', 'autoConfig', false, '1234567890']),
    );
    const init = queue.findIndex(
      (a) => JSON.stringify(a) === JSON.stringify(['init', '1234567890']),
    );
    expect(autoConfig).toBeGreaterThanOrEqual(0);
    expect(init).toBeGreaterThan(autoConfig);
  });

  it('hands calls to fbevents.js once it has loaded', () => {
    initTracking({ metaPixelId: '1234567890', ga4MeasurementId: null });
    const w = window as TrackingWindow;
    const calls: unknown[][] = [];
    // What fbevents.js does on load.
    (w.fbq as { callMethod?: (...a: unknown[]) => void }).callMethod = (...a) => calls.push(a);
    trackEvent('page_view');
    expect(calls).toEqual([['track', 'PageView']]);
  });

  it('stops the tags after the event is delivered, and starts them again on the next page', () => {
    const w = window as unknown as TrackingWindow & Record<string, unknown>;
    initTracking({ metaPixelId: null, ga4MeasurementId: 'G-ABC123' }, { allowMeta: false });
    expect(isTrackingActive()).toBe(true);
    let delivered = 0;
    trackEvent(
      'deposit_paid',
      { valueCents: 5000, currency: 'usd' },
      {
        onDelivered: () => {
          delivered += 1;
          stopTracking();
        },
      },
    );
    const events = (w.dataLayer ?? []).map((a) => Array.from(a as ArrayLike<unknown>));
    const purchase = events.find((e) => e[0] === 'event' && e[1] === 'purchase');
    const params = purchase?.[2] as { event_callback?: () => void; event_timeout?: number };
    expect(params.event_timeout).toBeGreaterThan(0);
    expect(delivered).toBe(0);
    params.event_callback?.();
    params.event_callback?.();
    expect(delivered).toBe(1);
    expect(w['ga-disable-G-ABC123']).toBe(true);
    expect(isTrackingActive()).toBe(false);

    // Nothing more is sent while stopped.
    const before = (w.dataLayer ?? []).length;
    trackEvent('page_view');
    expect((w.dataLayer ?? []).length).toBe(before);

    initTracking({ metaPixelId: null, ga4MeasurementId: 'G-ABC123' });
    expect(w['ga-disable-G-ABC123']).toBeUndefined();
    expect(isTrackingActive()).toBe(true);
  });

  it('revokes Meta consent when stopped and runs onDelivered at once without GA4', () => {
    initTracking({ metaPixelId: '1234567890', ga4MeasurementId: null });
    let delivered = false;
    trackEvent('page_view', undefined, { onDelivered: () => (delivered = true) });
    expect(delivered).toBe(true);
    stopTracking();
    const w = window as TrackingWindow;
    expect(w.fbq?.queue).toContainEqual(['consent', 'revoke']);
    const length = w.fbq?.queue?.length ?? 0;
    trackEvent('booking_created', { valueCents: 100, currency: 'usd' });
    expect(w.fbq?.queue).toHaveLength(length);
  });
});
