import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue, signedInAuth } from '@/test/render';
import { builders, resetSupabaseMock, setTableResult } from '@/test/supabaseMock';
import { loadMoreLabel, truncationNotice } from '../model';
import { InvoicesTab, JobsTab } from './HistoryTabs';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

function cadShop() {
  const base = membership();
  return shopValue({ membership: { ...base, shop: { ...base.shop, currency: 'cad' } } });
}

describe('customer history tabs', () => {
  it('formats money in the shop currency, not USD', async () => {
    setTableResult('invoices', {
      data: [
        {
          id: 'inv-1',
          number: 1042,
          status: 'sent',
          issued_at: '2026-09-01T15:00:00Z',
          due_at: '2026-09-15T15:00:00Z',
          created_at: '2026-09-01T15:00:00Z',
          total_cents: 125000,
          balance_cents: 25000,
          job_id: null,
        },
      ],
    });
    renderRoute(<InvoicesTab customerId="c-1" />, {
      path: '/app/customers/c-1',
      routePath: '/app/customers/:customerId',
      auth: signedInAuth(),
      shop: cadShop(),
    });
    const table = await screen.findByRole('table', { name: 'Invoices' });
    expect(within(table).getByText('CA$1,250.00')).toBeInTheDocument();
    expect(within(table).getByText('CA$250.00')).toBeInTheDocument();
    expect(within(table).queryByText('$1,250.00')).not.toBeInTheDocument();
  });

  it('says how many jobs exist past the first page and loads the next range', async () => {
    const job = (n: number) => ({
      id: `job-${n}`,
      number: 1000 - n,
      status: 'completed',
      scheduled_start: '2026-09-01T15:00:00Z',
      scheduled_end: '2026-09-01T17:00:00Z',
      vehicle_id: null,
      total_cents: 10000,
      created_at: '2026-09-01T15:00:00Z',
    });
    setTableResult('jobs', { data: Array.from({ length: 50 }, (_, i) => job(i)), count: 80 });
    const { user } = renderRoute(<JobsTab customerId="c-1" />, {
      path: '/app/customers/c-1',
      routePath: '/app/customers/:customerId',
      auth: signedInAuth(),
      shop: shopValue(),
    });
    expect(await screen.findByText('Showing the 50 most recent of 80 jobs.')).toBeVisible();
    const first = builders.jobs?.[0];
    expect(first?.select).toHaveBeenCalledWith(expect.any(String), { count: 'exact' });
    expect(first?.range).toHaveBeenCalledWith(0, 49);
    expect(first?.limit).not.toHaveBeenCalled();

    setTableResult('jobs', {
      data: Array.from({ length: 30 }, (_, i) => job(50 + i)),
      count: 80,
    });
    await user.click(screen.getByRole('button', { name: 'Load 30 more' }));
    await waitFor(() =>
      expect(screen.queryByText(/most recent of 80 jobs/)).not.toBeInTheDocument(),
    );
    expect(builders.jobs?.at(-1)?.range).toHaveBeenCalledWith(50, 99);
    expect(screen.getAllByText('#921').length).toBeGreaterThan(0);
    expect(screen.queryByRole('button', { name: /Load .* more/ })).not.toBeInTheDocument();
  });

  it('shows no notice or Load more when every row fits one page', async () => {
    setTableResult('jobs', {
      data: [
        {
          id: 'job-1',
          number: 7,
          status: 'scheduled',
          scheduled_start: null,
          scheduled_end: null,
          vehicle_id: null,
          total_cents: 0,
          created_at: '2026-09-01T15:00:00Z',
        },
      ],
      count: 1,
    });
    renderRoute(<JobsTab customerId="c-1" />, {
      path: '/app/customers/c-1',
      routePath: '/app/customers/:customerId',
      auth: signedInAuth(),
      shop: shopValue(),
    });
    expect((await screen.findAllByText('#7')).length).toBeGreaterThan(0);
    expect(screen.queryByText(/most recent/)).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Load .* more/ })).not.toBeInTheDocument();
  });

  it('words the notice and the button like the iPhone', () => {
    expect(truncationNotice(50, 80, 'jobs')).toBe('Showing the 50 most recent of 80 jobs.');
    expect(truncationNotice(12, 12, 'jobs')).toBeNull();
    expect(loadMoreLabel(30)).toBe('Load 30 more');
    expect(loadMoreLabel(500)).toBe('Load 50 more');
  });
});
