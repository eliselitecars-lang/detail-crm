import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue, signedInAuth } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import CustomersPage from './CustomersPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

const jane = {
  id: 'c-1',
  first_name: 'Jane',
  last_name: 'Doe',
  company: null,
  email: 'jane@example.com',
  phone: '+12055550123',
  tags: ['VIP'],
  lifecycle: 'customer',
  source: 'staff',
  archived_at: null,
  portal_user_id: null,
  created_at: '2026-03-01T15:00:00Z',
  updated_at: '2026-03-01T15:00:00Z',
};
const acme = {
  ...jane,
  id: 'c-2',
  first_name: null,
  last_name: null,
  company: 'Acme Fleet',
  email: null,
  phone: null,
  tags: [],
  lifecycle: 'lead',
};

function setup(role: 'owner' | 'technician' = 'owner', path = '/app/customers') {
  return renderRoute(<CustomersPage />, {
    path,
    routePath: '/app/customers',
    auth: signedInAuth(),
    shop: shopValue({ membership: membership({ role }) }),
    routes: [{ path: '/app/customers/:id', element: <p>Customer detail page</p> }],
  });
}

describe('CustomersPage', () => {
  it('lists customers with contact info, tags and lifecycle', async () => {
    setTableResult('customers', { data: [jane, acme], count: 2 });
    setup();
    const table = await screen.findByRole('table', { name: 'Customers' });
    expect(within(table).getByRole('link', { name: 'Jane Doe' })).toHaveAttribute(
      'href',
      '/app/customers/c-1',
    );
    expect(within(table).getByText('(205) 555-0123')).toBeInTheDocument();
    expect(within(table).getByText('Acme Fleet')).toBeInTheDocument();
    expect(within(table).getByText('Lead')).toBeInTheDocument();
    expect(screen.getByText('Showing 1–2 of 2')).toBeInTheDocument();

    const list = builders.customers?.find((b) => b.range.mock.calls.length > 0);
    expect(list?.eq).toHaveBeenCalledWith('shop_id', 'shop-1');
    expect(list?.is).toHaveBeenCalledWith('archived_at', null);
    expect(list?.range).toHaveBeenCalledWith(0, 24);
  });

  it('searches with escaped patterns and resets to page 1', async () => {
    setTableResult('customers', { data: [jane], count: 1 });
    const { user, router } = setup('owner', '/app/customers?page=2');
    await screen.findByRole('table', { name: 'Customers' });
    await user.type(screen.getByRole('searchbox', { name: 'Search customers' }), '50%{Enter}');
    await waitFor(() => expect(router.state.location.search).toBe('?q=50%25'));
    await waitFor(() =>
      expect(builders.customers?.some((b) => b.ilike.mock.calls.length > 0)).toBe(true),
    );
    const searched = builders.customers?.find((b) => b.ilike.mock.calls.length > 0);
    expect(searched?.ilike).toHaveBeenCalledWith('search_text', '%50\\%%');
  });

  it('sorts by the Added column', async () => {
    setTableResult('customers', { data: [jane], count: 1 });
    const { user, router } = setup();
    await screen.findByRole('table', { name: 'Customers' });
    await user.click(screen.getByRole('button', { name: /Added/ }));
    await waitFor(() => expect(router.state.location.search).toBe('?sort=created_at&dir=asc'));
  });

  it('shows the empty state and hides create for technicians', async () => {
    setTableResult('customers', { data: [], count: 0 });
    setup('technician');
    expect(await screen.findByText('No customers to show')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'New customer' })).not.toBeInTheDocument();
  });

  it('shows an error with retry', async () => {
    setTableResult('customers', {
      data: null,
      error: { code: '42501', message: 'permission denied for table customers' },
    });
    setup();
    expect(await screen.findByText(/permission to do that/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument();
  });

  it('creates a customer and opens it', async () => {
    setTableResult('customers', { data: [], count: 0 });
    const { user } = setup();
    await screen.findByText('No customers yet');
    await user.click(screen.getByRole('button', { name: 'New customer' }));
    const dialog = await screen.findByRole('dialog', { name: 'New customer' });

    await user.click(within(dialog).getByRole('button', { name: 'Add customer' }));
    expect(
      await within(dialog).findByText('Enter a first name, last name or company.'),
    ).toBeInTheDocument();

    const insertBuilder = createBuilder({ data: { id: 'c-new' } });
    supabase.from.mockImplementationOnce(() => insertBuilder);
    await user.type(within(dialog).getByLabelText('First name'), 'Jane');
    await user.type(within(dialog).getByLabelText('Mobile phone'), '2055550123');
    await user.type(within(dialog).getByLabelText('Tags'), 'VIP{Enter}');
    await user.click(within(dialog).getByRole('switch', { name: 'Text message opt-in' }));
    await user.click(within(dialog).getByRole('button', { name: 'Add customer' }));

    expect(await screen.findByText('Customer detail page')).toBeInTheDocument();
    expect(insertBuilder.insert).toHaveBeenCalledWith(
      expect.objectContaining({
        shop_id: 'shop-1',
        first_name: 'Jane',
        phone: '+12055550123',
        tags: ['VIP'],
        sms_opt_in: true,
        lifecycle: 'customer',
      }),
    );
  });
});
