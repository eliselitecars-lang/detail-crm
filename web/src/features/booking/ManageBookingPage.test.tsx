import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { navigation } from '@/features/public-docs/shared/checkout';
import { edge, mockRpc, pgError, resetPublicMocks } from '@/features/public-docs/shared/testing';
import ManageBookingPage from './ManageBookingPage';
import { bookingDocFixture, TOKEN } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/features/public-docs/shared/testSupabase'));

function render(path = `/booking/${TOKEN}`) {
  return renderRoute(<ManageBookingPage />, { path, routePath: '/booking/:token', shop: null });
}

beforeEach(() => {
  resetPublicMocks();
});

describe('ManageBookingPage', () => {
  it('shows the booking, totals, deposit, forms and cancellation window', async () => {
    const calls = mockRpc({ public_get_booking: { data: bookingDocFixture() } });
    render();
    expect(
      await screen.findByRole('heading', { name: 'Booking #1042', level: 1 }),
    ).toBeInTheDocument();
    expect(calls[0]).toEqual({ fn: 'public_get_booking', args: { p_token: TOKEN } });
    expect(screen.getByText('2021 Toyota Camry · Blue')).toBeInTheDocument();
    expect(screen.getByText(/Central (Daylight|Standard) Time/)).toBeInTheDocument();
    const deposit = screen.getByRole('region', { name: 'Deposit' });
    expect(within(deposit).getByText('$30.00', { selector: 'span' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Sign Vehicle waiver/ })).toHaveAttribute(
      'href',
      '/f/dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    );
    expect(screen.getByText(/You can cancel online until/)).toBeInTheDocument();
  });

  it('starts the deposit checkout and redirects to Stripe', async () => {
    mockRpc({ public_get_booking: { data: bookingDocFixture() } });
    const assign = vi.spyOn(navigation, 'assign').mockImplementation(() => undefined);
    edge.invoke.mockResolvedValue({
      data: {
        url: 'https://checkout.stripe.com/c/pay/cs_dep',
        expires_at: 1,
        amount_cents: 3000,
        tip_cents: 0,
        currency: 'usd',
      },
      error: null,
    });
    const { user } = render();
    await user.click(await screen.findByRole('button', { name: 'Pay $30.00 deposit' }));
    await waitFor(() =>
      expect(assign).toHaveBeenCalledWith('https://checkout.stripe.com/c/pay/cs_dep'),
    );
    const body = (edge.invoke.mock.calls[0]?.[1] as { body: Record<string, unknown> }).body;
    expect(body).toMatchObject({ action: 'booking_deposit_checkout', token: TOKEN });
    expect(body).not.toHaveProperty('amount_cents');
    expect(String(body.request_nonce)).toMatch(/^[A-Za-z0-9_-]{8,64}$/);
  });

  it('never follows a non-https checkout url', async () => {
    mockRpc({ public_get_booking: { data: bookingDocFixture() } });
    const assign = vi.spyOn(navigation, 'assign').mockImplementation(() => undefined);
    edge.invoke.mockResolvedValue({
      data: {
        url: 'javascript:alert(1)',
        expires_at: 1,
        amount_cents: 1,
        tip_cents: 0,
        currency: 'usd',
      },
      error: null,
    });
    const { user } = render();
    await user.click(await screen.findByRole('button', { name: 'Pay $30.00 deposit' }));
    expect(await screen.findByText('Couldn’t open the payment page')).toBeInTheDocument();
    expect(assign).not.toHaveBeenCalled();
  });

  it('cancels with a reason and shows the cancelled state', async () => {
    const cancelled = bookingDocFixture({
      booking: {
        ...bookingDocFixture().booking,
        status: 'cancelled',
        cancelled_at: '2026-09-27T12:00:00Z',
        cancel_reason: 'Out of town',
      },
      cancellation: { ...bookingDocFixture().cancellation, allowed: false },
    });
    const calls = mockRpc({
      public_get_booking: { data: bookingDocFixture() },
      public_cancel_booking: { data: cancelled },
    });
    const { user } = render();
    await user.click(await screen.findByRole('button', { name: 'Cancel booking' }));
    const dialog = screen.getByRole('alertdialog');
    await user.type(within(dialog).getByLabelText('Reason (optional)'), 'Out of town');
    await user.click(within(dialog).getByRole('button', { name: 'Cancel booking' }));
    expect(await screen.findByText('This booking was cancelled')).toBeInTheDocument();
    expect(calls.find((c) => c.fn === 'public_cancel_booking')?.args).toEqual({
      p_token: TOKEN,
      p_reason: 'Out of town',
    });
    expect(screen.queryByRole('button', { name: /deposit/ })).not.toBeInTheDocument();
  });

  it('does not show the job total as a balance on a cancelled booking', async () => {
    const cancelled = bookingDocFixture({
      booking: { ...bookingDocFixture().booking, status: 'cancelled' },
      cancellation: { ...bookingDocFixture().cancellation, allowed: false },
    });
    mockRpc({ public_get_booking: { data: cancelled } });
    render();
    expect(await screen.findByText('This booking was cancelled')).toBeInTheDocument();
    expect(screen.queryByText('Balance')).not.toBeInTheDocument();
  });

  it('shows the balance on an open booking', async () => {
    mockRpc({ public_get_booking: { data: bookingDocFixture() } });
    render();
    expect(await screen.findByText('Balance')).toBeInTheDocument();
  });

  it('shows the server’s reason when cancelling is refused', async () => {
    mockRpc({
      public_get_booking: { data: bookingDocFixture() },
      public_cancel_booking: pgError(
        '22023',
        'online cancellation closed 24 hours before the appointment; please call the shop',
      ),
    });
    const { user } = render();
    await user.click(await screen.findByRole('button', { name: 'Cancel booking' }));
    await user.click(
      within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Cancel booking' }),
    );
    expect(
      await screen.findByText(
        'Online cancellation closed 24 hours before the appointment; please call the shop.',
      ),
    ).toBeInTheDocument();
  });

  it('confirms a returning deposit payment once the webhook has landed', async () => {
    const paid = bookingDocFixture({
      deposit: { ...bookingDocFixture().deposit, paid_cents: 3000, due_cents: 0, status: 'paid' },
    });
    mockRpc({ public_get_booking: { data: paid } });
    render(`/booking/${TOKEN}?paid=1`);
    expect(await screen.findByText('Deposit received — thank you!')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Pay .* deposit/ })).not.toBeInTheDocument();
  });

  it('polls while the deposit is still being confirmed', async () => {
    let n = 0;
    const paid = bookingDocFixture({
      deposit: { ...bookingDocFixture().deposit, paid_cents: 3000, due_cents: 0, status: 'paid' },
    });
    mockRpc({
      public_get_booking: () => {
        n += 1;
        return { data: n === 1 ? bookingDocFixture() : paid };
      },
    });
    render(`/booking/${TOKEN}?paid=1`);
    expect(await screen.findByText('Confirming your deposit…')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Pay .* deposit/ })).not.toBeInTheDocument();
    expect(
      await screen.findByText('Deposit received — thank you!', {}, { timeout: 5000 }),
    ).toBeInTheDocument();
  });

  it('explains a broken link without calling the server', async () => {
    const calls = mockRpc({});
    render('/booking/not-a-token');
    expect(await screen.findByText('We couldn’t find this booking')).toBeInTheDocument();
    expect(calls).toHaveLength(0);
  });
});
