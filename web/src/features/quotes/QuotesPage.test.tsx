import { screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { builders, resetSupabaseMock, setTableResult } from '@/test/supabaseMock';
import QuotesPage from './QuotesPage';
import { customerRow, quoteRow } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

const listRow = (overrides: Parameters<typeof quoteRow>[0] = {}) => {
  const q = quoteRow(overrides);
  return { ...q, customer: customerRow() };
};

function renderPage(path = '/app/quotes') {
  return renderRoute(<QuotesPage />, { path, routePath: '/app/quotes' });
}

describe('QuotesPage', () => {
  it('lists quotes with customer, server total and status', async () => {
    setTableResult('quotes', {
      data: [listRow({ status: 'sent', valid_until: '2099-01-01', total_cents: 27000 })],
      count: 1,
    });
    renderPage();
    expect(await screen.findAllByText('Quote #1001')).not.toHaveLength(0);
    expect(screen.getAllByText('Jane Doe').length).toBeGreaterThan(0);
    expect(screen.getAllByText('$270.00').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Sent').length).toBeGreaterThan(0);
    expect(screen.getByRole('link', { name: /New quote/ })).toHaveAttribute(
      'href',
      '/app/quotes/new',
    );
  });

  it('shows a sent quote past its validity date as expired', async () => {
    setTableResult('quotes', {
      data: [listRow({ status: 'viewed', valid_until: '2020-01-01' })],
      count: 1,
    });
    renderPage();
    await screen.findAllByText('Quote #1001');
    // the tab + the badge
    expect(screen.getAllByText('Expired').length).toBeGreaterThanOrEqual(2);
  });

  it('filters by the expired status (including lapsed sent quotes)', async () => {
    setTableResult('quotes', { data: [], count: 0 });
    renderPage('/app/quotes?status=expired');
    expect(await screen.findByText('No quotes match these filters')).toBeInTheDocument();
    const orCall = builders.quotes?.[0]?.or.mock.calls[0]?.[0] as string;
    expect(orCall).toMatch(
      /^status\.eq\.expired,and\(status\.in\.\(sent,viewed\),valid_until\.lt\.\d{4}-\d{2}-\d{2}\)$/,
    );
  });

  it('searches by number', async () => {
    setTableResult('quotes', { data: [], count: 0 });
    const { user } = renderPage();
    await screen.findByText('No quotes yet');
    await user.type(screen.getByRole('searchbox', { name: 'Search quotes' }), '#1001');
    await waitFor(() =>
      expect(
        builders.quotes?.some((b) =>
          b.eq.mock.calls.some((c) => c[0] === 'number' && c[1] === 1001),
        ),
      ).toBe(true),
    );
  });

  it('shows an error with retry', async () => {
    setTableResult('quotes', { data: null, error: { message: 'boom', code: 'XX000' } });
    renderPage();
    expect(await screen.findByRole('button', { name: 'Try again' })).toBeInTheDocument();
  });
});
