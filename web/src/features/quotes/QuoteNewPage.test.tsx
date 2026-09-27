import { screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { builders, resetSupabaseMock, setTableResult } from '@/test/supabaseMock';
import QuoteNewPage from './QuoteNewPage';
import { CUSTOMER_ID, customerRow, quoteRow } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

describe('QuoteNewPage', () => {
  it('creates a draft for the preset customer with the shop’s default terms', async () => {
    setTableResult('customers', { data: customerRow() });
    setTableResult('vehicles', { data: [] });
    setTableResult('shops', {
      data: {
        quote_terms: 'Valid for 30 days.',
        invoice_terms: null,
        invoice_due_days: 14,
        tax_rate_bps: 0,
        name: 'Glacier',
        phone: null,
      },
    });
    setTableResult('quotes', { data: quoteRow({ id: 'quote-new', number: 1002 }) });
    const { user } = renderRoute(<QuoteNewPage />, {
      path: `/app/quotes/new?customerId=${CUSTOMER_ID}`,
      routePath: '/app/quotes/new',
      routes: [{ path: '/app/quotes/:quoteId', element: <p>Quote builder</p> }],
    });
    expect(await screen.findByDisplayValue('Valid for 30 days.')).toBeInTheDocument();
    await waitFor(() =>
      expect(screen.getByRole('combobox', { name: /Customer/ })).toHaveValue('Jane Doe'),
    );
    await user.click(screen.getByRole('button', { name: 'Create quote' }));
    expect(await screen.findByText('Quote builder')).toBeInTheDocument();
    const insert = builders.quotes?.find((b) => b.insert.mock.calls.length > 0)?.insert;
    expect(insert).toHaveBeenCalledWith(
      expect.objectContaining({
        shop_id: 'shop-1',
        customer_id: CUSTOMER_ID,
        vehicle_id: null,
        valid_until: null,
        terms: 'Valid for 30 days.',
      }),
    );
  });

  it('requires a customer', async () => {
    setTableResult('shops', {
      data: {
        quote_terms: null,
        invoice_terms: null,
        invoice_due_days: 0,
        tax_rate_bps: 0,
        name: 'G',
        phone: null,
      },
    });
    setTableResult('customers', { data: [] });
    const { user } = renderRoute(<QuoteNewPage />, {
      path: '/app/quotes/new',
      routePath: '/app/quotes/new',
    });
    await user.click(await screen.findByRole('button', { name: 'Create quote' }));
    expect(await screen.findByText('Choose a customer.')).toBeInTheDocument();
    expect(builders.quotes).toBeUndefined();
  });
});
