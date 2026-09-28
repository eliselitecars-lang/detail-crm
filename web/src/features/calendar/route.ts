/**
 * Day map (P-18) — pure helpers: the day's mobile stops in route order
 * (jobs.route_position, set with set_route_order), and the multi-stop
 * Google Maps hand-off. Coordinates come from the iPhone app's geocoder
 * (set_job_coordinates); the browser never geocodes.
 */
import { utcToShopLocal, type LocalDate } from '@/lib/dates';
import type { CalendarRow } from './model';

export interface RouteStop {
  jobId: string;
  number: number | null;
  title: string;
  startsAt: string;
  endsAt: string;
  /** "1 Main St, Birmingham" (calendar_events: line 1 + city). */
  address: string | null;
  lat: number | null;
  lng: number | null;
  /** 0-based manual order, null when never ordered. */
  position: number | null;
}

/** A place Google Maps can route through: coordinates or an address. */
export type RoutePlace = { lat: number; lng: number } | string;

function isVisibleMobileJob(r: CalendarRow): boolean {
  return (
    r.event_type === 'job' &&
    !r.is_busy_block &&
    r.location_type === 'mobile' &&
    r.status !== 'cancelled' &&
    r.status !== 'no_show'
  );
}

/** Does the job start on `date` (shop wall clock)? A route is one shop-local day. */
function startsOn(r: CalendarRow, date: LocalDate, timeZone: string): boolean {
  return utcToShopLocal(r.starts_at, timeZone).date === date;
}

/**
 * The route of `date`: the mobile jobs the viewer may see in full that START
 * that day (shop wall clock), in route order. set_route_order (0057) orders
 * one day's jobs only, so a multi-day or overnight job that began earlier is
 * not a stop of this route (see `continuingStops`).
 */
export function routeStops(
  rows: readonly CalendarRow[],
  positions: ReadonlyMap<string, number | null>,
  date: LocalDate,
  timeZone: string,
): RouteStop[] {
  return rows
    .filter((r) => isVisibleMobileJob(r) && startsOn(r, date, timeZone))
    .map((r) => toStop(r, positions.get(r.id) ?? null))
    .sort((a, b) => {
      if (a.position !== null && b.position !== null && a.position !== b.position) {
        return a.position - b.position;
      }
      if (a.position !== null && b.position === null) return -1;
      if (a.position === null && b.position !== null) return 1;
      return a.startsAt.localeCompare(b.startsAt) || a.jobId.localeCompare(b.jobId);
    });
}

/** Mobile jobs still running on `date` that started on an earlier day, by start. */
export function continuingStops(
  rows: readonly CalendarRow[],
  date: LocalDate,
  timeZone: string,
): RouteStop[] {
  return rows
    .filter((r) => isVisibleMobileJob(r) && utcToShopLocal(r.starts_at, timeZone).date < date)
    .map((r) => toStop(r, null))
    .sort((a, b) => a.startsAt.localeCompare(b.startsAt) || a.jobId.localeCompare(b.jobId));
}

function toStop(r: CalendarRow, position: number | null): RouteStop {
  return {
    jobId: r.id,
    number: r.job_number,
    title: r.title ?? (r.job_number !== null ? `Job #${r.job_number}` : 'Job'),
    startsAt: r.starts_at,
    endsAt: r.ends_at,
    address: r.service_address,
    lat: r.service_lat,
    lng: r.service_lng,
    position,
  };
}

export function isLocated<T extends { lat: number | null; lng: number | null }>(
  stop: T,
): stop is T & { lat: number; lng: number } {
  return typeof stop.lat === 'number' && typeof stop.lng === 'number';
}

/** Moves one id in a list (drag-and-drop / up-down buttons). */
export function moveInList<T>(list: readonly T[], from: number, to: number): T[] {
  if (from === to || from < 0 || to < 0 || from >= list.length || to >= list.length) {
    return [...list];
  }
  const next = [...list];
  const [item] = next.splice(from, 1);
  if (item !== undefined) next.splice(to, 0, item);
  return next;
}

function placeParam(place: RoutePlace): string {
  return typeof place === 'string' ? place : `${place.lat},${place.lng}`;
}

/** Google Maps' URL API routes through at most 9 waypoints between origin and destination. */
export const MAX_WAYPOINTS = 9;

export interface GoogleRoute {
  url: string;
  /** Stops the link covers (from the first), and how many the day has. */
  included: number;
  total: number;
}

/**
 * https://www.google.com/maps/dir/?api=1 link through the stops in order.
 * Starts at `origin` (the shop) when given, else at the first stop. Stops
 * without coordinates route by their address; stops with neither are left
 * out. null when there is nowhere to go.
 */
export function googleRouteUrl(
  stops: readonly Pick<RouteStop, 'lat' | 'lng' | 'address'>[],
  origin: RoutePlace | null,
): GoogleRoute | null {
  const places: RoutePlace[] = [];
  for (const stop of stops) {
    if (isLocated(stop)) places.push({ lat: stop.lat, lng: stop.lng });
    else if (stop.address) places.push(stop.address);
  }
  if (places.length === 0) return null;
  const start = origin ?? places[0];
  const rest = origin ? places : places.slice(1);
  if (start === undefined || rest.length === 0) {
    // one stop and no shop address: just point at it
    const only = places[0];
    if (only === undefined) return null;
    const params = new URLSearchParams({ api: '1', destination: placeParam(only) });
    return {
      url: `https://www.google.com/maps/dir/?${params.toString()}`,
      included: 1,
      total: places.length,
    };
  }
  const route = rest.slice(0, MAX_WAYPOINTS + 1);
  const destination = route[route.length - 1];
  if (destination === undefined) return null;
  const waypoints = route.slice(0, -1);
  const params = new URLSearchParams({
    api: '1',
    origin: placeParam(start),
    destination: placeParam(destination),
    travelmode: 'driving',
  });
  if (waypoints.length > 0) params.set('waypoints', waypoints.map(placeParam).join('|'));
  return {
    url: `https://www.google.com/maps/dir/?${params.toString()}`,
    included: route.length + (origin ? 0 : 1),
    total: places.length,
  };
}
