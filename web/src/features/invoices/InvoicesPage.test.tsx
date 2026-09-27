import { screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { builders, resetSupabaseMock, setTableResult } from '@/test/supabaseMock';
import { customerRow, invoiceRow } from '@/features/quotes/testFixtures';
import { areInvoiceLinesEditable, isInvoiceOverdue } from './api';
import InvoicesPage from './InvoicesPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

describe('invoice rules', () => {
  const now = new Date('2026-09-27T12:00:00Z');
  it('is overdue only when unpaid with a past due date', () => {
    expect(isInvoiceOverdue(invoiceRow({ due_at: '2026-09-01T00:00:00Z' }), now)).toBe(true);
    expect(isInvoiceOverdue(invoiceRow({ due_at: '2026-10-01T00:00:00Z' }), now)).toBe(false);
    expect(isInvoiceOverdue(invoiceRow({ due_at: null }), now)).toBe(false);
    expect(
      isInvoiceOverdue(
        invoiceRow({ status: 'paid', balance_cents: 0, due_at: '2026-09-01T00:00:00Z' }),
        now,
      ),
    ).toBe(false);
    expect(
      isInvoiceOverdue(invoiceRow({ status: 'draft', due_at: '2026-09-01T00:00:00Z' }), now),
    ).toBe(false);
  });

  it('allows line changes only before money is received (SQL guard)', () => {
    expect(areInvoiceLinesEditable({ status: 'draft', amount_paid_cents: 0 })).toBe(true);
    expect(areInvoiceLinesEditable({ status: 'open', amount_paid_cents: 0 })).toBe(true);
    expect(areInvoiceLinesEditable({ status: 'paid', amount_paid_cents: 0 })).toBe(true);
    expect(areInvoiceLinesEditable({ status: 'partially_paid', amount_paid_cents: 500 })).toBe(
      false,
    );
    expect(areInvoiceLinesEditable({ status: 'paid', amount_paid_cents: 500 })).toBe(false);
    expect(areInvoiceLinesEditable({ status: 'void', amount_paid_cents: 0 })).toBe(false);
  });
});

describe('InvoicesPage', () => {
  it('lists invoices with balance and overdue badges', async () => {
    setTableResult('invoices', {
      data: [{ ...invoiceRow({ due_at: '2020-01-01T00:00:00Z' }), customer: customerRow() }],
      count: 1,
    });
    renderRoute(<InvoicesPage />, { path: '/app/invoices', routePath: '/app/invoices' });
    expect((await screen.findAllByText('Invoice #2001')).length).toBeGreaterThan(0);
    expect(screen.getAllByText('$200.00').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Overdue').length).toBeGreaterThanOrEqual(2); // tab + badge
  });

  it('filters overdue invoices by status, balance and due date', async () => {
    setTableResult('invoices', { data: [], count: 0 });
    renderRoute(<InvoicesPage />, {
      path: '/app/invoices?status=overdue',
      routePath: '/app/invoices',
    });
    expect(await screen.findByText('No invoices match these filters')).toBeInTheDocument();
    const b = builders.invoices?.[0];
    expect(b?.in).toHaveBeenCalledWith('status', ['open', 'partially_paid']);
    expect(b?.gt).toHaveBeenCalledWith('balance_cents', 0);
    expect(b?.lt.mock.calls[0]?.[0]).toBe('due_at');
  });

  it('shows the empty state with a create action', async () => {
    setTableResult('invoices', { data: [], count: 0 });
    renderRoute(<InvoicesPage />, { path: '/app/invoices', routePath: '/app/invoices' });
    expect(await screen.findByText('No invoices yet')).toBeInTheDocument();
    expect(screen.getAllByRole('link', { name: /New invoice/ }).length).toBeGreaterThan(0);
  });
});
