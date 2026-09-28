import { act, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import { builders, resetSupabaseMock, setTableResult } from '@/test/supabaseMock';
import { CUSTOMER_ID, paymentRow } from '@/features/quotes/testFixtures';
import { UnappliedPaymentsCard } from './UnappliedPaymentsCard';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

const note = 'Received for void invoice #2001: apply it to another invoice or refund it';

function setup(role: 'owner' | 'manager' | 'technician' = 'owner') {
  return renderRoute(<UnappliedPaymentsCard customerId={CUSTOMER_ID} />, {
    shop: shopValue({ membership: membership({ role }) }),
  });
}

describe('UnappliedPaymentsCard', () => {
  it('lists the customer’s unapplied money with the server note and both actions', async () => {
    setTableResult('payments', {
      data: [paymentRow({ id: 'pay-u', invoice_id: null, tip_cents: 0, note })],
    });
    setup();
    expect(await screen.findByRole('heading', { name: 'Unapplied payments' })).toBeInTheDocument();
    expect(screen.getByText(note)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Apply $100.00 to an invoice' })).toBeInTheDocument();
    expect(
      screen.getByRole('button', { name: 'Refund Visa •••• 4242 payment of $100.00' }),
    ).toBeInTheDocument();
    const query = builders.payments?.[0];
    expect(query?.eq).toHaveBeenCalledWith('customer_id', CUSTOMER_ID);
    expect(query?.is).toHaveBeenCalledWith('invoice_id', null);
    expect(query?.is).toHaveBeenCalledWith('job_id', null);
    expect(query?.is).toHaveBeenCalledWith('membership_id', null);
    expect(query?.in).toHaveBeenCalledWith('status', ['succeeded', 'partially_refunded']);
  });

  it('renders nothing when the customer has no unapplied money', async () => {
    setTableResult('payments', { data: [] });
    setup();
    await waitFor(() => expect(builders.payments?.length).toBeGreaterThan(0));
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 10));
    });
    expect(screen.queryByText('Unapplied payments')).toBeNull();
    expect(screen.queryByText('Couldn’t check for unapplied payments')).toBeNull();
  });

  it('says so when the check fails instead of hiding the money', async () => {
    setTableResult('payments', { data: null, error: { message: 'x', code: 'XX000' } });
    setup();
    expect(await screen.findByText('Couldn’t check for unapplied payments')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument();
  });

  it('is not shown to technicians (no query)', () => {
    setup('technician');
    expect(builders.payments).toBeUndefined();
  });
});
