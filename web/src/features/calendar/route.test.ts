import { describe, expect, it } from 'vitest';
import type { CalendarRow } from './model';
import {
  continuingStops,
  googleRouteUrl,
  isLocated,
  MAX_WAYPOINTS,
  moveInList,
  routeStops,
} from './route';

const TZ = 'America/Chicago';

function job(id: string, overrides: Partial<CalendarRow> = {}): CalendarRow {
  return {
    event_type: 'job',
    id,
    job_number: 1000,
    status: 'scheduled',
    starts_at: '2026-09-28T14:00:00Z',
    ends_at: '2026-09-28T15:00:00Z',
    is_busy_block: false,
    customer_id: 'c',
    customer_name: 'Jane Doe',
    vehicle_id: null,
    vehicle_label: null,
    location_type: 'mobile',
    service_address: '1 Main St, Birmingham',
    resource_id: null,
    assigned_member_ids: [],
    member_id: null,
    title: `Stop ${id}`,
    event_kind: 'job',
    series_id: null,
    color: null,
    service_lat: 33.5,
    service_lng: -86.8,
    ...overrides,
  };
}

describe('routeStops', () => {
  it('keeps the day’s visible mobile jobs, ordered by route position then time', () => {
    const rows = [
      job('late', { starts_at: '2026-09-28T18:00:00Z' }),
      job('early', { starts_at: '2026-09-28T13:00:00Z' }),
      job('first', { starts_at: '2026-09-28T20:00:00Z' }),
      job('shop', { location_type: 'shop' }),
      job('busy', { is_busy_block: true, location_type: null }),
      job('gone', { status: 'cancelled' }),
      job('blk', { event_type: 'blocked_time', event_kind: 'meeting' }),
    ];
    const stops = routeStops(rows, new Map([['first', 0]]), '2026-09-28', TZ);
    expect(stops.map((s) => s.jobId)).toEqual(['first', 'early', 'late']);
    expect(stops[0]).toMatchObject({ position: 0, lat: 33.5, address: '1 Main St, Birmingham' });
  });

  it('routes only the jobs that start that day (shop clock); earlier ones are continuing', () => {
    const rows = [
      job('today', { starts_at: '2026-09-28T15:00:00Z', ends_at: '2026-09-28T17:00:00Z' }),
      // a two-day coating that began yesterday
      job('coating', { starts_at: '2026-09-27T14:00:00Z', ends_at: '2026-09-28T22:00:00Z' }),
      // 9:30 PM Sunday in Chicago (02:30Z Monday), running past midnight
      job('overnight', { starts_at: '2026-09-28T02:30:00Z', ends_at: '2026-09-28T06:00:00Z' }),
      // 11 PM Monday in Chicago is still that day, though 04:00Z is Tuesday
      job('late', { starts_at: '2026-09-29T04:00:00Z', ends_at: '2026-09-29T05:00:00Z' }),
      job('gone', { starts_at: '2026-09-27T14:00:00Z', status: 'cancelled' }),
    ];
    expect(routeStops(rows, new Map(), '2026-09-28', TZ).map((s) => s.jobId)).toEqual([
      'today',
      'late',
    ]);
    expect(continuingStops(rows, '2026-09-28', TZ).map((s) => s.jobId)).toEqual([
      'coating',
      'overnight',
    ]);
  });

  it('moves stops for drag-and-drop and the arrow buttons', () => {
    expect(moveInList(['a', 'b', 'c'], 2, 0)).toEqual(['c', 'a', 'b']);
    expect(moveInList(['a', 'b', 'c'], 0, 1)).toEqual(['b', 'a', 'c']);
    expect(moveInList(['a', 'b'], 0, 5)).toEqual(['a', 'b']);
    expect(isLocated({ lat: 1, lng: 2 })).toBe(true);
    expect(isLocated({ lat: null, lng: 2 })).toBe(false);
  });
});

describe('googleRouteUrl', () => {
  const stop = (lat: number | null, lng: number | null, address: string | null = null) => ({
    lat,
    lng,
    address,
  });

  it('routes from the shop through every stop in order', () => {
    const route = googleRouteUrl(
      [stop(1, 2), stop(null, null, '5 Oak Ave, Homewood'), stop(3, 4)],
      { lat: 9, lng: 8 },
    );
    expect(route).not.toBeNull();
    const url = new URL(route?.url ?? '');
    expect(url.origin + url.pathname).toBe('https://www.google.com/maps/dir/');
    expect(url.searchParams.get('api')).toBe('1');
    expect(url.searchParams.get('origin')).toBe('9,8');
    expect(url.searchParams.get('waypoints')).toBe('1,2|5 Oak Ave, Homewood');
    expect(url.searchParams.get('destination')).toBe('3,4');
    expect(route).toMatchObject({ included: 3, total: 3 });
  });

  it('starts at the first stop without a shop address and skips unknown places', () => {
    const route = googleRouteUrl([stop(1, 2), stop(null, null), stop(3, 4)], null);
    const url = new URL(route?.url ?? '');
    expect(url.searchParams.get('origin')).toBe('1,2');
    expect(url.searchParams.get('destination')).toBe('3,4');
    expect(url.searchParams.has('waypoints')).toBe(false);
    expect(googleRouteUrl([stop(null, null)], null)).toBeNull();
    expect(
      new URL(googleRouteUrl([stop(1, 2)], null)?.url ?? '').searchParams.get('destination'),
    ).toBe('1,2');
  });

  it('caps the link at the waypoints Google Maps accepts', () => {
    const many = Array.from({ length: 14 }, (_, i) => stop(i, i));
    const fromShop = googleRouteUrl(many, 'The shop, Birmingham');
    const params = new URL(fromShop?.url ?? '').searchParams;
    expect(params.get('waypoints')?.split('|')).toHaveLength(MAX_WAYPOINTS);
    expect(params.get('destination')).toBe('9,9');
    expect(fromShop).toMatchObject({ included: 10, total: 14 });
    const noShop = googleRouteUrl(many, null);
    expect(noShop).toMatchObject({ included: 11, total: 14 });
  });
});
