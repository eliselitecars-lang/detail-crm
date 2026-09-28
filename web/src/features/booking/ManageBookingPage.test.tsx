import { screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { navigation } from '@/features/public-docs/shared/checkout';
import {
  edgeHttpError,
  mockRpc,
  resetSupabaseMock,
  setFunctionResult,
  supabase,
} from '@/test/supabaseMock';
import ManageBookingPage from './ManageBookingPage';
import { bookingDocFixture, profileFixture, TOKEN } from './testFixtures';
import { resetTrackingForTests } from './tracking';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

function render(path = `/booking/${TOKEN}`) {
  return renderRoute(<ManageBookingPage />, { path, routePath: '/booking/:token', shop: null });
}

beforeEach(() => {
  resetSupabaseMock();
  resetTrackingForTests();
  sessionStorage.clear();
});

afterEach(() => {
  document.head.querySelectorAll('script[src^="https://"]').forEach((s) => s.remove());
  const w = window as Window & { fbq?: unknown; gtag?: unknown; dataLayer?: unknown };
  delete w.fbq;
  delete w.gtag;
  delete w.dataLayer;
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
    supabase.functions.invoke.mockResolvedValue({
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
    const body = (supabase.functions.invoke.mock.calls[0]?.[1] as { body: Record<string, unknown> })
      .body;
    expect(body).toMatchObject({ action: 'booking_deposit_checkout', token: TOKEN });
    expect(body).not.toHaveProperty('amount_cents');
    expect(String(body.request_nonce)).toMatch(/^[A-Za-z0-9_-]{8,64}$/);
  });

  it('never follows a non-https checkout url', async () => {
    mockRpc({ public_get_booking: { data: bookingDocFixture() } });
    const assign = vi.spyOn(navigation, 'assign').mockImplementation(() => undefined);
    supabase.functions.invoke.mockResolvedValue({
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

  it('cancels with a reason through the payments edge (booking_cancel) and shows the cancelled state', async () => {
    const cancelled = bookingDocFixture({
      booking: {
        ...bookingDocFixture().booking,
        status: 'cancelled',
        cancelled_at: '2026-09-27T12:00:00Z',
        cancel_reason: 'Out of town',
      },
      cancellation: { ...bookingDocFixture().cancellation, allowed: false },
    });
    const calls = mockRpc({ public_get_booking: { data: bookingDocFixture() } });
    setFunctionResult('payments', { data: cancelled });
    const { user } = render();
    await user.click(await screen.findByRole('button', { name: 'Cancel booking' }));
    const dialog = screen.getByRole('alertdialog');
    await user.type(within(dialog).getByLabelText('Reason (optional)'), '  Out of town ');
    await user.click(within(dialog).getByRole('button', { name: 'Cancel booking' }));
    expect(await screen.findByText('This booking was cancelled')).toBeInTheDocument();
    // The edge expires the booking's open payment pages, then cancels as the
    // caller; the RPC is never called directly (it would refuse while a
    // deposit page the customer opened is still alive — 0106).
    expect(supabase.functions.invoke).toHaveBeenCalledWith('payments', {
      body: { action: 'booking_cancel', token: TOKEN, reason: 'Out of town' },
    });
    expect(calls.some((c) => c.fn === 'public_cancel_booking')).toBe(false);
    expect(screen.queryByRole('button', { name: /deposit/ })).not.toBeInTheDocument();
  });

  it('sends no reason when none was typed', async () => {
    const cancelled = bookingDocFixture({
      booking: { ...bookingDocFixture().booking, status: 'cancelled' },
      cancellation: { ...bookingDocFixture().cancellation, allowed: false },
    });
    mockRpc({ public_get_booking: { data: bookingDocFixture() } });
    setFunctionResult('payments', { data: cancelled });
    const { user } = render();
    await user.click(await screen.findByRole('button', { name: 'Cancel booking' }));
    await user.click(
      within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Cancel booking' }),
    );
    expect(await screen.findByText('This booking was cancelled')).toBeInTheDocument();
    expect(supabase.functions.invoke).toHaveBeenCalledWith('payments', {
      body: { action: 'booking_cancel', token: TOKEN },
    });
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
    // "Book again" opens the booking page in a new document without a referrer,
    // so the booking page's tags never see this page's token.
    const again = screen.getByRole('link', { name: 'Book again' });
    expect(again).toHaveAttribute('href', '/book/glacier');
    expect(again).toHaveAttribute('rel', 'noreferrer');
  });

  it('shows the balance on an open booking', async () => {
    mockRpc({ public_get_booking: { data: bookingDocFixture() } });
    render();
    expect(await screen.findByText('Balance')).toBeInTheDocument();
  });

  it('shows the server’s reason when cancelling is refused', async () => {
    const calls = mockRpc({ public_get_booking: { data: bookingDocFixture() } });
    setFunctionResult('payments', {
      error: edgeHttpError(422, {
        error: 'Online cancellation closed 24 hours before the appointment; please call the shop.',
        code: 'unprocessable',
      }),
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
    // The page reloads the booking so its cancellation window is current.
    await waitFor(() =>
      expect(calls.filter((c) => c.fn === 'public_get_booking').length).toBeGreaterThan(1),
    );
  });

  it('shows the server’s reason when a payment page opened meanwhile blocks the cancel (409)', async () => {
    mockRpc({ public_get_booking: { data: bookingDocFixture() } });
    setFunctionResult('payments', {
      error: edgeHttpError(409, {
        error:
          'A payment page for this booking is still open; please close it and try again in a few minutes, or call the shop.',
        code: 'conflict',
        details: { reason: 'checkout_open' },
      }),
    });
    const { user } = render();
    await user.click(await screen.findByRole('button', { name: 'Cancel booking' }));
    await user.click(
      within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Cancel booking' }),
    );
    expect(
      await screen.findByText(
        'A payment page for this booking is still open; please close it and try again in a few minutes, or call the shop.',
      ),
    ).toBeInTheDocument();
  });

  it('holds online cancelling while a deposit payment is still going through', async () => {
    const pending = bookingDocFixture({
      deposit: { ...bookingDocFixture().deposit, payment_pending: true },
    });
    const calls = mockRpc({ public_get_booking: { data: pending } });
    render();
    const button = await screen.findByRole('button', { name: 'Cancel booking' });
    expect(button).toBeDisabled();
    expect(button).toHaveAccessibleDescription(
      expect.stringContaining('A payment for this booking is still going through'),
    );
    expect(calls.some((c) => c.fn === 'public_cancel_booking')).toBe(false);
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

  it('lists documents the shop shared, with short-lived download links', async () => {
    mockRpc({
      public_get_booking: { data: bookingDocFixture() },
      public_booking_documents: {
        data: [
          {
            id: 'doc-1',
            file_name: 'Coating warranty.pdf',
            content_type: 'application/pdf',
            size_bytes: 204800,
            created_at: '2026-09-02T15:00:00Z',
          },
        ],
      },
    });
    setFunctionResult('public-media', {
      data: {
        expires_in: 600,
        items: [
          {
            ref_id: 'doc-1',
            kind: 'document',
            url: 'https://unit-test.supabase.co/storage/v1/object/sign/documents/x?token=t',
          },
        ],
      },
    });
    render();
    const card = await screen.findByRole('region', { name: 'Documents' });
    expect(within(card).getByText('Coating warranty.pdf')).toBeInTheDocument();
    expect(within(card).getByText(/PDF · 200 KB/)).toBeInTheDocument();
    const open = await within(card).findByRole('link', { name: /Open Coating warranty\.pdf/ });
    expect(open).toHaveAttribute(
      'href',
      'https://unit-test.supabase.co/storage/v1/object/sign/documents/x?token=t',
    );
    expect(supabase.functions.invoke).toHaveBeenCalledWith('public-media', {
      body: { action: 'booking_documents', token: TOKEN },
    });
  });

  it('shows nothing extra when no documents were shared', async () => {
    mockRpc({
      public_get_booking: { data: bookingDocFixture() },
      public_booking_documents: { data: [] },
    });
    render();
    await screen.findByRole('heading', { name: 'Booking #1042', level: 1 });
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('public_booking_documents', { p_token: TOKEN }),
    );
    expect(screen.queryByRole('region', { name: 'Documents' })).not.toBeInTheDocument();
    expect(supabase.functions.invoke).not.toHaveBeenCalledWith('public-media', expect.anything());
  });

  it('reports a paid deposit to GA4, then stops the tag; token links leave the page meanwhile', async () => {
    mockRpc({
      public_get_booking: {
        data: bookingDocFixture({
          deposit: {
            required_cents: 3000,
            paid_cents: 3000,
            due_cents: 0,
            status: 'paid',
            payment_pending: false,
            card_payments_enabled: true,
          },
        }),
      },
      public_shop_profile: {
        data: profileFixture({
          tracking: { meta_pixel_id: '1234567890', ga4_measurement_id: 'G-ABC123' },
        }),
      },
      public_booking_documents: {
        data: [
          {
            id: 'doc-1',
            file_name: 'Coating warranty.pdf',
            content_type: 'application/pdf',
            size_bytes: 204800,
            created_at: '2026-09-02T15:00:00Z',
          },
        ],
      },
    });
    setFunctionResult('public-media', {
      data: {
        expires_in: 600,
        items: [
          {
            ref_id: 'doc-1',
            kind: 'document',
            url: 'https://unit-test.supabase.co/storage/v1/object/sign/documents/x?token=t',
          },
        ],
      },
    });
    const { user, router } = render(`/booking/${TOKEN}?paid=1`);
    const w = window as unknown as Window & {
      fbq?: unknown;
      dataLayer?: unknown[];
    } & Record<string, unknown>;
    const events = () => (w.dataLayer ?? []).map((a) => Array.from(a as ArrayLike<unknown>));
    await waitFor(() => expect(events().some((e) => e[1] === 'purchase')).toBe(true));
    // Only GA4, and with a page location that has no token.
    expect(w.fbq).toBeUndefined();
    expect(JSON.stringify(events())).not.toContain(TOKEN);

    // While the tag is on: the signed file link is a button and the form
    // link is a full page load (never pushed into this document).
    const card = await screen.findByRole('region', { name: 'Documents' });
    const open = await within(card).findByRole('button', { name: /Open Coating warranty\.pdf/ });
    const windowOpen = vi.spyOn(window, 'open').mockReturnValue(null);
    await user.click(open);
    expect(windowOpen).toHaveBeenCalledWith(
      'https://unit-test.supabase.co/storage/v1/object/sign/documents/x?token=t',
      '_blank',
      'noopener,noreferrer',
    );
    let prevented: boolean | null = null;
    const record = (event: Event) => {
      prevented = event.defaultPrevented;
      event.preventDefault();
    };
    window.addEventListener('click', record);
    try {
      await user.click(screen.getByRole('link', { name: /Sign Vehicle waiver/ }));
    } finally {
      window.removeEventListener('click', record);
    }
    expect(prevented).toBe(false);
    expect(router.state.location.pathname).toBe(`/booking/${TOKEN}`);

    // GA4 confirms the hit: the tag is switched off and links are normal again.
    const purchase = events().find((e) => e[1] === 'purchase');
    (purchase?.[2] as { event_callback: () => void }).event_callback();
    expect(w['ga-disable-G-ABC123']).toBe(true);
    expect(
      await within(card).findByRole('link', { name: /Open Coating warranty\.pdf/ }),
    ).toBeInTheDocument();
    await user.click(screen.getByRole('link', { name: /Sign Vehicle waiver/ }));
    expect(router.state.location.pathname).toBe('/f/dddddddd-dddd-4ddd-8ddd-dddddddddddd');
  });
});
