import { screen, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue, signedInAuth } from '@/test/render';
import { resetSupabaseMock, setTableResult } from '@/test/supabaseMock';
import { InvoicesTab } from './HistoryTabs';

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
});
