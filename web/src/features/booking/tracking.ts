/**
 * The shop's own Meta Pixel / GA4 tag on the public booking pages (P-10).
 * Loaded ONLY when public_shop_profile.tracking has an id (shops set them
 * in Settings -> Booking; both are null while online booking is off) and
 * only on the public booking page (never staff pages, never private booking
 * links). The deploy CSP allows the two script origins only on those paths
 * (WEB_TRACKING_PATHS, docs/DEPLOY.md 4.3); where it doesn't, the script is
 * blocked and nothing else changes.
 *
 * Events: page view on load; begin checkout when the date & time step opens;
 * a completed booking (with its total). GA4 also gets the deposit payment
 * after Stripe returns to the booking page. Never names, emails, phones,
 * coupon codes or booking links:
 *  - GA4 is given a page_location without the query or the booking token.
 *  - Meta always reports the page URL, so it is never loaded on
 *    /booking/<token>, its history (pushState) page views are switched off
 *    (fbq.disablePushState) and so is its automatic configuration (button
 *    and page metadata collection).
 *  - Both tags also listen to in-app navigation (GA4's enhanced measurement
 *    "page changes based on browser history events", outbound clicks), so
 *    while a tag is loaded, links to token pages leave the document instead
 *    (PublicLink, useTrackingActive) and signed file links are opened
 *    without an <a> the tag could record. Once the deposit purchase is
 *    reported on /booking/<token>, the tags are stopped (stopTracking).
 */

import { useSyncExternalStore } from 'react';

export interface TrackingIds {
  metaPixelId: string | null;
  ga4MeasurementId: string | null;
}

/** Same formats as the booking_settings CHECKs (settings validates them too). */
const META_PIXEL_RE = /^\d{5,20}$/;
const GA4_RE = /^G-[A-Z0-9]{4,16}$/;

export type TrackingEvent = 'page_view' | 'begin_checkout' | 'booking_created' | 'deposit_paid';

export interface TrackingValue {
  valueCents: number;
  currency: string;
}

type Fbq = ((...args: unknown[]) => void) & {
  callMethod?: (...args: unknown[]) => void;
  queue?: unknown[];
  push?: Fbq;
  loaded?: boolean;
  version?: string;
  /** Read by fbevents.js: no automatic PageView on history.pushState / replaceState. */
  disablePushState?: boolean;
};

interface TrackingWindow {
  fbq?: Fbq;
  _fbq?: Fbq;
  dataLayer?: unknown[];
  gtag?: (...args: unknown[]) => void;
}

interface TrackingState {
  /** The ids whose tags were loaded into this document. */
  meta: string | null;
  ga4: string | null;
  /** Whether each loaded tag may still send (false after stopTracking). */
  metaOn: boolean;
  ga4On: boolean;
  pageLocation: string;
}

const state: TrackingState = {
  meta: null,
  ga4: null,
  metaOn: false,
  ga4On: false,
  pageLocation: '',
};

const listeners = new Set<() => void>();

function emit(): void {
  for (const listener of listeners) listener();
}

function win(): Window & TrackingWindow {
  return window;
}

/** Google's documented per-property opt-out flag, checked on every hit. */
function ga4DisableKey(id: string): string {
  return `ga-disable-${id}`;
}

function setGa4Disabled(id: string, disabled: boolean): void {
  const w = window as unknown as Record<string, unknown>;
  if (disabled) w[ga4DisableKey(id)] = true;
  else delete w[ga4DisableKey(id)];
}

/** True while a shop tag in this document can still send events. */
export function isTrackingActive(): boolean {
  return (state.meta !== null && state.metaOn) || (state.ga4 !== null && state.ga4On);
}

function addScript(src: string): void {
  if (document.querySelector(`script[src="${src}"]`)) return;
  const script = document.createElement('script');
  script.async = true;
  script.src = src;
  script.referrerPolicy = 'strict-origin-when-cross-origin';
  document.head.appendChild(script);
}

/**
 * The page as analytics sees it: origin + path, never the query string
 * (coupon codes, private links) and never a booking token (/booking/<token>
 * becomes /booking).
 */
export function sanitizedLocation(href: string): string {
  try {
    const url = new URL(href);
    const path = url.pathname.startsWith('/booking/') ? '/booking' : url.pathname;
    return `${url.origin}${path}`;
  } catch {
    return '';
  }
}

export function validTrackingIds(
  raw:
    | {
        meta_pixel_id?: string | null;
        ga4_measurement_id?: string | null;
      }
    | null
    | undefined,
): TrackingIds {
  const meta = raw?.meta_pixel_id?.trim() ?? '';
  const ga4 = raw?.ga4_measurement_id?.trim().toUpperCase() ?? '';
  return {
    metaPixelId: META_PIXEL_RE.test(meta) ? meta : null,
    ga4MeasurementId: GA4_RE.test(ga4) ? ga4 : null,
  };
}

export function hasTracking(ids: TrackingIds): boolean {
  return ids.metaPixelId !== null || ids.ga4MeasurementId !== null;
}

/**
 * Loads the tags once per page load (idempotent). `allowMeta` is false on
 * pages whose URL carries a credential (the booking page after payment).
 * A tag stopped by stopTracking is switched back on by the next call.
 */
export function initTracking(ids: TrackingIds, { allowMeta = true }: { allowMeta?: boolean } = {}) {
  if (typeof window === 'undefined') return;
  const w = win();
  const before = isTrackingActive();
  state.pageLocation = sanitizedLocation(window.location.href);
  if (allowMeta && ids.metaPixelId) {
    if (state.meta === null) {
      state.meta = ids.metaPixelId;
      state.metaOn = true;
      if (!w.fbq) {
        // Meta's standard stub: queue until fbevents.js takes over (callMethod).
        const fbq: Fbq = (...args: unknown[]) => {
          if (fbq.callMethod) fbq.callMethod.call(fbq, ...args);
          else fbq.queue?.push(args);
        };
        fbq.push = fbq;
        fbq.queue = [];
        fbq.loaded = true;
        fbq.version = '2.0';
        w.fbq = fbq;
        w._fbq = fbq;
      }
      // Both before 'init': no history page views (they would carry the new
      // URL), no automatic button / page metadata collection.
      w.fbq.disablePushState = true;
      w.fbq('set', 'autoConfig', false, ids.metaPixelId);
      w.fbq('init', ids.metaPixelId);
      addScript('https://connect.facebook.net/en_US/fbevents.js');
    } else if (state.meta === ids.metaPixelId && !state.metaOn && w.fbq) {
      state.metaOn = true;
      w.fbq('consent', 'grant');
    }
  }
  if (ids.ga4MeasurementId) {
    const config = {
      send_page_view: false,
      page_location: state.pageLocation,
      allow_google_signals: false,
      allow_ad_personalization_signals: false,
    };
    if (state.ga4 === null) {
      state.ga4 = ids.ga4MeasurementId;
      state.ga4On = true;
      setGa4Disabled(ids.ga4MeasurementId, false);
      w.dataLayer = w.dataLayer ?? [];
      if (!w.gtag) {
        const dataLayer = w.dataLayer;
        // gtag.js reads the Arguments objects it queued, exactly as its snippet does.
        w.gtag = function gtag() {
          // eslint-disable-next-line prefer-rest-params
          dataLayer.push(arguments);
        };
      }
      w.gtag('js', new Date());
      w.gtag('config', ids.ga4MeasurementId, config);
      addScript(
        `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(ids.ga4MeasurementId)}`,
      );
    } else if (state.ga4 === ids.ga4MeasurementId && w.gtag) {
      // Another public page in the same document: its own page location.
      if (!state.ga4On) {
        state.ga4On = true;
        setGa4Disabled(ids.ga4MeasurementId, false);
      }
      w.gtag('config', ids.ga4MeasurementId, config);
    }
  }
  if (isTrackingActive() !== before) emit();
}

/**
 * Stops the loaded tags for the rest of this document (until initTracking
 * runs again): GA4 through its opt-out flag, Meta by revoking consent. Used
 * once the page's only event has been delivered, so the tags cannot record
 * what the customer does next (links with tokens, signed file links).
 */
export function stopTracking(): void {
  if (typeof window === 'undefined') return;
  const w = win();
  const before = isTrackingActive();
  if (state.ga4 !== null) {
    state.ga4On = false;
    setGa4Disabled(state.ga4, true);
  }
  if (state.meta !== null && state.metaOn) {
    state.metaOn = false;
    w.fbq?.('consent', 'revoke');
  }
  if (isTrackingActive() !== before) emit();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** Re-renders when the tags start or stop (links switch to full page loads). */
export function useTrackingActive(): boolean {
  return useSyncExternalStore(subscribe, isTrackingActive, () => false);
}

const META_EVENTS: Record<TrackingEvent, string> = {
  page_view: 'PageView',
  begin_checkout: 'InitiateCheckout',
  booking_created: 'Schedule',
  deposit_paid: 'Purchase',
};

const GA4_EVENTS: Record<TrackingEvent, string> = {
  page_view: 'page_view',
  begin_checkout: 'begin_checkout',
  booking_created: 'generate_lead',
  deposit_paid: 'purchase',
};

/**
 * Sends one event to whichever tags are on (no-op without tracking).
 * `onDelivered` runs once GA4 has sent it (or given up after its timeout),
 * or right away when GA4 is not on.
 */
export function trackEvent(
  event: TrackingEvent,
  value?: TrackingValue,
  { onDelivered }: { onDelivered?: () => void } = {},
): void {
  if (typeof window === 'undefined') return;
  const w = win();
  const money =
    value && Number.isFinite(value.valueCents)
      ? { value: Math.round(value.valueCents) / 100, currency: value.currency.toUpperCase() }
      : undefined;
  if (state.meta && state.metaOn && w.fbq) {
    if (money) w.fbq('track', META_EVENTS[event], money);
    else w.fbq('track', META_EVENTS[event]);
  }
  if (state.ga4 && state.ga4On && w.gtag) {
    let done = false;
    const delivered = () => {
      if (done) return;
      done = true;
      onDelivered?.();
    };
    w.gtag('event', GA4_EVENTS[event], {
      send_to: state.ga4,
      page_location: state.pageLocation,
      ...(money ?? {}),
      ...(onDelivered ? { event_callback: delivered, event_timeout: 3000 } : {}),
    });
    return;
  }
  onDelivered?.();
}

/** Test hook: forget what was loaded. */
export function resetTrackingForTests(): void {
  if (state.ga4 !== null) setGa4Disabled(state.ga4, false);
  state.meta = null;
  state.ga4 = null;
  state.metaOn = false;
  state.ga4On = false;
  state.pageLocation = '';
  emit();
}
