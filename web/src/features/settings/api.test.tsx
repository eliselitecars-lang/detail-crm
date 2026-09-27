import { QueryClientProvider, type QueryClient } from '@tanstack/react-query';
import { act, renderHook, waitFor } from '@testing-library/react';
import type { ReactNode } from 'react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ShopContext } from '@/features/shop/shopContext';
import { AppError } from '@/lib/errors';
import { createTestQueryClient, shopValue } from '@/test/render';
import { toEdgeError } from '@/features/quotes/shared/edge';
import {
  deleteShopErrorMessage,
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
import {
  builders,
  edgeHttpError,
  mockRpc,
  pgError,
  resetSupabaseMock,
  supabase,
} from '@/test/supabaseMock';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

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

beforeEach(() => resetSupabaseMock());

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
  const next = [
    { weekday: 1, opens_at: '08:00', closes_at: '17:00' },
    { weekday: 6, opens_at: '10:00', closes_at: '24:00' },
  ];

  it('replaces the week in one replace_business_hours call and refreshes hours', async () => {
    const calls = mockRpc({ replace_business_hours: { data: [] } });
    const { queryClient, wrapper } = setup();
    const calendarHours = ['shop', SHOP, 'settings', 'business_hours'];
    seed(queryClient, [calendarHours]);
    const { result } = renderHook(() => useSaveBusinessHours(), { wrapper });
    // Extra keys on a row (e.g. a stored id) are never sent: the RPC refuses them.
    await act(() =>
      result.current.mutateAsync({
        rows: [{ ...next[0]!, id: 'h-mon' } as (typeof next)[number], next[1]!],
      }),
    );
    expect(calls).toEqual([
      { fn: 'replace_business_hours', args: { p_shop_id: SHOP, p_rows: next } },
    ]);
    expect(builders.business_hours).toBeUndefined();
    expect(invalidated(queryClient, calendarHours)).toBe(true);
  });

  it('sends an empty week to close every day', async () => {
    const calls = mockRpc({ replace_business_hours: { data: [] } });
    const { wrapper } = setup();
    const { result } = renderHook(() => useSaveBusinessHours(), { wrapper });
    await act(() => result.current.mutateAsync({ rows: [] }));
    expect(calls[0]?.args).toEqual({ p_shop_id: SHOP, p_rows: [] });
  });

  it('reports a rejected week (the stored hours stay as they were)', async () => {
    mockRpc({
      replace_business_hours: pgError(
        '23P01',
        'conflicting key value violates exclusion constraint "business_hours_no_overlap"',
      ),
    });
    const { wrapper } = setup();
    const { result } = renderHook(() => useSaveBusinessHours(), { wrapper });
    let caught: unknown;
    await act(async () => {
      caught = await result.current.mutateAsync({ rows: next }).catch((e: unknown) => e);
    });
    expect(caught).toBeInstanceOf(AppError);
    expect((caught as AppError).message).toBe('That overlaps with an existing entry.');
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
  it('reports a refusal and keeps the memberships list as it was', async () => {
    supabase.functions.invoke.mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(403, {
        error: 'Your role does not allow this action.',
        code: 'forbidden',
      }),
    });
    const { wrapper, refetch } = setup();
    const { result } = renderHook(() => useDeleteShop(), { wrapper });
    let caught: unknown;
    await act(async () => {
      caught = await result.current.mutateAsync('Glacier Detailing').catch((e: unknown) => e);
    });
    expect((caught as AppError).kind).toBe('permission');
    expect(refetch).not.toHaveBeenCalled();
  });

  it('deletes through payments.delete_shop, refetches memberships and drops the shop cache', async () => {
    supabase.functions.invoke.mockResolvedValueOnce({
      data: { deleted: true, memberships_cancelled: 2, sessions_expired: 1 },
      error: null,
    });
    const { wrapper, refetch, queryClient } = setup();
    const jobs = ['shop', SHOP, 'jobs', 'list', {}];
    const other = ['shop', 'shop-2', 'jobs', 'list', {}];
    seed(queryClient, [jobs, other]);
    const { result } = renderHook(() => useDeleteShop(), { wrapper });
    await act(() => result.current.mutateAsync('Glacier Detailing'));
    expect(supabase.functions.invoke).toHaveBeenCalledWith('payments', {
      body: { action: 'delete_shop', shop_id: SHOP, confirm_name: 'Glacier Detailing' },
    });
    // No direct table delete: the server cancels billing first.
    expect(builders.shops).toBeUndefined();
    await waitFor(() => expect(refetch).toHaveBeenCalled());
    expect(queryClient.getQueryData(jobs)).toBeUndefined();
    expect(queryClient.getQueryData(other)).toEqual(['cached']);
  });

  it('explains payment_in_progress and name_mismatch refusals', async () => {
    const refusal = async (status: number, reason: string) =>
      toEdgeError(edgeHttpError(status, { error: 'server text', code: 'x', details: { reason } }));
    expect(deleteShopErrorMessage(await refusal(409, 'payment_in_progress'))).toMatch(
      /still being processed.*Nothing was deleted/,
    );
    expect(deleteShopErrorMessage(await refusal(422, 'name_mismatch'))).toBe(
      'The name you typed doesn’t match this shop’s name. Nothing was deleted.',
    );
    expect(deleteShopErrorMessage(await refusal(422, 'other'))).toBe('server text');
  });
});
