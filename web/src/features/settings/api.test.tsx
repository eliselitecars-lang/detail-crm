import { QueryClientProvider, type QueryClient } from '@tanstack/react-query';
import { act, renderHook, waitFor } from '@testing-library/react';
import type { ReactNode } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ShopContext } from '@/features/shop/shopContext';
import { AppError } from '@/lib/errors';
import { createTestQueryClient, shopValue } from '@/test/render';
import {
  settingsKeys,
  stripeLinkSchema,
  useArchiveResource,
  useDeleteBlockedTime,
  useDeleteCoupon,
  useDeleteFormTemplate,
  useDeleteShop,
  useDeleteTemplate,
  useDeleteVehicleCategory,
  useSaveBusinessHours,
} from './api';
import { HOURS_NOT_RESTORED_MESSAGE } from './hoursPlan';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  supabase,
  type MockResult,
} from './testing/supabaseMock';

vi.mock('@/lib/supabase', () => import('./testing/supabaseMock'));

const SHOP = 'shop-1';

function setup() {
  const queryClient = createTestQueryClient();
  const refetch = vi.fn(() => Promise.resolve());
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={queryClient}>
      <ShopContext value={shopValue({ refetch })}>{children}</ShopContext>
    </QueryClientProvider>
  );
  return { queryClient, refetch, wrapper };
}

/** Seeds cache entries (as other features would) so invalidation can be observed. */
function seed(queryClient: QueryClient, keys: readonly (readonly unknown[])[]) {
  for (const key of keys) queryClient.setQueryData(key, ['cached']);
}

function invalidated(queryClient: QueryClient, key: readonly unknown[]): boolean {
  return queryClient.getQueryState(key)?.isInvalidated ?? false;
}

/** Makes successive `supabase.from(table)` calls resolve to `results` in order. */
const defaultFrom = supabase.from.getMockImplementation();
function queueTable(table: string, results: MockResult[]) {
  const queue = [...results];
  supabase.from.mockImplementation((name: string) => {
    if (name === table && queue.length > 0) {
      const builder = createBuilder(queue.shift());
      (builders[name] ??= []).push(builder);
      return builder;
    }
    if (!defaultFrom) throw new Error('supabase.from has no default implementation');
    return defaultFrom(name);
  });
}

beforeEach(() => resetSupabaseMock());
afterEach(() => {
  if (defaultFrom) supabase.from.mockImplementation(defaultFrom);
});

describe('query keys', () => {
  it('does not share the jobs feature resource-picker key', () => {
    // jobs/api.ts caches all resources (incl. archived, no `sort`) here.
    expect(settingsKeys.resources(SHOP)).not.toEqual(['shop', SHOP, 'settings', 'resources']);
    expect(settingsKeys.resources(SHOP).slice(0, 3)).toEqual(settingsKeys.all(SHOP));
  });
});

describe('cross-feature invalidation', () => {
  const calendarEvents = ['shop', SHOP, 'jobs', 'calendar', '2026-09-01', '2026-10-01', false];

  it('business hours refresh the calendar hours shading and events', async () => {
    const { queryClient, wrapper } = setup();
    const calendarHours = ['shop', SHOP, 'settings', 'business_hours'];
    seed(queryClient, [calendarHours, calendarEvents]);
    const { result } = renderHook(() => useSaveBusinessHours(), { wrapper });
    await act(() => result.current.mutateAsync({ rows: [] }));
    expect(invalidated(queryClient, calendarHours)).toBe(true);
    expect(invalidated(queryClient, calendarEvents)).toBe(true);
  });

  it('blocked times refresh calendar events', async () => {
    const { queryClient, wrapper } = setup();
    seed(queryClient, [calendarEvents]);
    const { result } = renderHook(() => useDeleteBlockedTime(), { wrapper });
    await act(() => result.current.mutateAsync('bt-1'));
    expect(invalidated(queryClient, calendarEvents)).toBe(true);
  });

  it('resources refresh the job resource picker and the calendar', async () => {
    const { queryClient, wrapper } = setup();
    const jobsResources = ['shop', SHOP, 'settings', 'resources'];
    seed(queryClient, [jobsResources, calendarEvents, settingsKeys.resources(SHOP)]);
    const { result } = renderHook(() => useArchiveResource(), { wrapper });
    await act(() => result.current.mutateAsync('res-1'));
    expect(invalidated(queryClient, jobsResources)).toBe(true);
    expect(invalidated(queryClient, settingsKeys.resources(SHOP))).toBe(true);
    expect(invalidated(queryClient, calendarEvents)).toBe(true);
  });

  it('vehicle categories refresh the job editor picker', async () => {
    const { queryClient, wrapper } = setup();
    const jobsCategories = ['shop', SHOP, 'settings', 'vehicle_categories'];
    seed(queryClient, [jobsCategories]);
    const { result } = renderHook(() => useDeleteVehicleCategory(), { wrapper });
    await act(() => result.current.mutateAsync('cat-1'));
    expect(invalidated(queryClient, jobsCategories)).toBe(true);
  });

  it('coupons refresh the job coupon picker', async () => {
    const { queryClient, wrapper } = setup();
    const jobsCoupons = ['shop', SHOP, 'catalog', 'coupons', 'active'];
    seed(queryClient, [jobsCoupons]);
    const { result } = renderHook(() => useDeleteCoupon(), { wrapper });
    await act(() => result.current.mutateAsync('coupon-1'));
    expect(invalidated(queryClient, jobsCoupons)).toBe(true);
  });

  it('form templates refresh the job form picker', async () => {
    const { queryClient, wrapper } = setup();
    const jobsForms = ['shop', SHOP, 'settings', 'form_templates', 'active'];
    seed(queryClient, [jobsForms]);
    const { result } = renderHook(() => useDeleteFormTemplate(), { wrapper });
    await act(() => result.current.mutateAsync('form-1'));
    expect(invalidated(queryClient, jobsForms)).toBe(true);
  });

  it('message templates refresh the inbox template list and previews', async () => {
    const { queryClient, wrapper } = setup();
    const inboxTemplates = ['shop', SHOP, 'messages', 'templates'];
    const preview = ['shop', SHOP, 'messages', 'preview', 'job-1', 'job_reminder', 'sms'];
    const inbox = ['shop', SHOP, 'messages', 'inbox', 300];
    seed(queryClient, [inboxTemplates, preview, inbox]);
    const { result } = renderHook(() => useDeleteTemplate(), { wrapper });
    await act(() => result.current.mutateAsync('tpl-1'));
    expect(invalidated(queryClient, inboxTemplates)).toBe(true);
    expect(invalidated(queryClient, preview)).toBe(true);
    expect(invalidated(queryClient, inbox)).toBe(false);
  });
});

describe('useSaveBusinessHours', () => {
  const stored = [
    { id: 'h-mon', weekday: 1, opens_at: '08:00:00', closes_at: '17:00:00' },
    { id: 'h-tue', weekday: 2, opens_at: '08:00:00', closes_at: '17:00:00' },
  ];
  const next = [
    { weekday: 1, opens_at: '08:00', closes_at: '17:00' },
    { weekday: 2, opens_at: '09:00', closes_at: '18:00' },
  ];
  const constraintError = {
    code: '23P01',
    message: 'conflicting key value violates exclusion constraint "business_hours_no_overlap"',
  };

  it('re-reads stored rows and only replaces the intervals that changed', async () => {
    queueTable('business_hours', [{ data: stored }, { data: null }, { data: null }]);
    const { wrapper } = setup();
    const { result } = renderHook(() => useSaveBusinessHours(), { wrapper });
    await act(() => result.current.mutateAsync({ rows: next }));

    const [read, del, ins] = builders.business_hours ?? [];
    expect(read?.select).toHaveBeenCalledWith('id, weekday, opens_at, closes_at');
    expect(read?.eq).toHaveBeenCalledWith('shop_id', SHOP);
    expect(del?.delete).toHaveBeenCalled();
    expect(del?.eq).toHaveBeenCalledWith('shop_id', SHOP);
    expect(del?.in).toHaveBeenCalledWith('id', ['h-tue']);
    expect(ins?.insert).toHaveBeenCalledWith([
      { weekday: 2, opens_at: '09:00', closes_at: '18:00', shop_id: SHOP },
    ]);
  });

  it('writes nothing when the week is unchanged', async () => {
    queueTable('business_hours', [{ data: stored }]);
    const { wrapper } = setup();
    const { result } = renderHook(() => useSaveBusinessHours(), { wrapper });
    await act(() =>
      result.current.mutateAsync({
        rows: [
          { weekday: 1, opens_at: '08:00', closes_at: '17:00' },
          { weekday: 2, opens_at: '08:00', closes_at: '17:00' },
        ],
      }),
    );
    expect(builders.business_hours).toHaveLength(1);
  });

  it('puts the removed rows back when the insert fails and reports the insert error', async () => {
    queueTable('business_hours', [
      { data: stored },
      { data: null },
      { data: null, error: constraintError },
      { data: null },
    ]);
    const { wrapper } = setup();
    const { result } = renderHook(() => useSaveBusinessHours(), { wrapper });
    let caught: unknown;
    await act(async () => {
      caught = await result.current.mutateAsync({ rows: next }).catch((e: unknown) => e);
    });
    const restore = builders.business_hours?.[3];
    expect(restore?.insert).toHaveBeenCalledWith([
      { weekday: 2, opens_at: '08:00:00', closes_at: '17:00:00', shop_id: SHOP },
    ]);
    expect(caught).toBeInstanceOf(AppError);
    expect((caught as AppError).message).not.toBe(HOURS_NOT_RESTORED_MESSAGE);
  });

  it('says the changed days are closed when the restore also fails', async () => {
    queueTable('business_hours', [
      { data: stored },
      { data: null },
      { data: null, error: constraintError },
      { data: null, error: { code: '08006', message: 'connection failure' } },
    ]);
    const { queryClient, wrapper } = setup();
    const calendarHours = ['shop', SHOP, 'settings', 'business_hours'];
    seed(queryClient, [calendarHours]);
    const { result } = renderHook(() => useSaveBusinessHours(), { wrapper });
    let caught: unknown;
    await act(async () => {
      caught = await result.current.mutateAsync({ rows: next }).catch((e: unknown) => e);
    });
    expect((caught as AppError).message).toBe(HOURS_NOT_RESTORED_MESSAGE);
    // …and everything showing hours refetches the (now partial) week.
    expect(invalidated(queryClient, calendarHours)).toBe(true);
  });
});

describe('stripeLinkSchema', () => {
  it.each([
    'https://connect.stripe.com/setup/e/acct_123/abc',
    'https://connect.stripe.com/express/acct_123/xyz',
    'https://stripe.com/login',
  ])('accepts %s', (url) => {
    expect(stripeLinkSchema.safeParse({ url }).success).toBe(true);
  });

  it.each([
    'javascript:alert(1)',
    'data:text/html,<script>alert(1)</script>',
    'http://connect.stripe.com/setup/abc',
    'https://evilstripe.com/setup',
    'https://connect.stripe.com.evil.test/setup',
    'https://example.com/?next=stripe.com',
  ])('rejects %s', (url) => {
    expect(stripeLinkSchema.safeParse({ url }).success).toBe(false);
  });
});

describe('useDeleteShop', () => {
  it('reports a permission error when RLS deleted nothing', async () => {
    queueTable('shops', [{ data: [] }]);
    const { wrapper, refetch } = setup();
    const { result } = renderHook(() => useDeleteShop(), { wrapper });
    let caught: unknown;
    await act(async () => {
      caught = await result.current.mutateAsync().catch((e: unknown) => e);
    });
    expect((caught as AppError).kind).toBe('permission');
    expect(refetch).not.toHaveBeenCalled();
  });

  it('deletes the shop, refetches memberships and drops the shop cache', async () => {
    queueTable('shops', [{ data: [{ id: SHOP }] }]);
    const { wrapper, refetch, queryClient } = setup();
    const jobs = ['shop', SHOP, 'jobs', 'list', {}];
    const other = ['shop', 'shop-2', 'jobs', 'list', {}];
    seed(queryClient, [jobs, other]);
    const { result } = renderHook(() => useDeleteShop(), { wrapper });
    await act(() => result.current.mutateAsync());
    const del = builders.shops?.[0];
    expect(del?.delete).toHaveBeenCalled();
    expect(del?.eq).toHaveBeenCalledWith('id', SHOP);
    expect(del?.select).toHaveBeenCalledWith('id');
    await waitFor(() => expect(refetch).toHaveBeenCalled());
    expect(queryClient.getQueryData(jobs)).toBeUndefined();
    expect(queryClient.getQueryData(other)).toEqual(['cached']);
  });
});
