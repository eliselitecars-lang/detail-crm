import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { addLocalDays, shopLocalToUtcIso, shopToday } from '@/lib/dates';
import { renderRoute } from '@/test/render';
import { mockRpc, resetSupabaseMock, supabase } from '@/test/supabaseMock';
import InvoicePage from './InvoicePage';
import QuotePage from './QuotePage';
import { quoteDocumentSchema } from './api';
import { QuoteScheduledPanel } from './components/QuoteSchedule';
import { navigation } from './shared/checkout';
import { DOC_TOKEN, invoiceFixture, quoteFixture } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const TZ = 'America/Chicago';

function renderQuote(path = `/q/${DOC_TOKEN}`) {
  return renderRoute(<QuotePage />, { path, routePath: '/q/:token', shop: null });
}

function renderInvoice(path = `/i/${DOC_TOKEN}`) {
  return renderRoute(<InvoicePage />, { path, routePath: '/i/:token', shop: null });
}

beforeEach(() => {
  resetSupabaseMock();
  supabase.functions.invoke.mockReset();
});

const option = (id: string, name: string, total: number) => ({
  id,
  name,
  description: null,
  sort: 1,
  subtotal_cents: total,
  discount_cents: 0,
  tax_cents: 0,
  total_cents: total,
});

function optionsQuote() {
  const base = quoteFixture({ has_options: true, selected_option_id: 'opt-a' });
  const line = (id: string, name: string, optionId: string | null, optional = false) => ({
    ...base.line_items[0]!,
    id,
    name,
    option_id: optionId,
    optional,
    selected: !optional,
  });
  return {
    ...base,
    options: [option('opt-a', 'Basic', 20000), option('opt-b', 'Premium', 45000)],
    line_items: [
      line('l-shared', 'Hand wash', null),
      line('l-a', 'Spray sealant', 'opt-a'),
      line('l-b', 'Ceramic coating', 'opt-b'),
      line('l-b-up', 'Glass coating', 'opt-b', true),
    ],
  };
}

describe('QuotePage — proposal options', () => {
  it('shows option cards and approves the chosen one', async () => {
    const approved = {
      ...optionsQuote(),
      quote: {
        ...optionsQuote().quote,
        status: 'approved' as const,
        can_respond: false,
        selected_option_id: 'opt-b',
      },
    };
    const calls = mockRpc({
      public_get_quote: { data: optionsQuote() },
      public_respond_quote: { data: approved },
    });
    const { user } = renderQuote();
    const options = await screen.findByRole('region', { name: 'Options' });
    expect(within(options).getByText('$450.00')).toBeInTheDocument();
    expect(screen.getByRole('list', { name: 'Included in every option' })).toHaveTextContent(
      'Hand wash',
    );
    // no option chosen yet: the approve button asks for one
    await user.type(screen.getByLabelText(/^Your full name/), 'Ana Diaz');
    await user.click(screen.getByRole('button', { name: 'Approve quote' }));
    expect(screen.getByText('Choose one of the options above first.')).toBeInTheDocument();
    // choosing Premium offers its add-on and shows its total
    await user.click(within(options).getByRole('button', { name: 'Choose Premium' }));
    await user.click(await screen.findByRole('checkbox', { name: 'Glass coating' }));
    await user.click(screen.getByRole('button', { name: 'Approve quote' }));
    await waitFor(() =>
      expect(calls.find((c) => c.fn === 'public_respond_quote')?.args).toEqual({
        p_token: DOC_TOKEN,
        p_action: 'approve',
        p_signer_name: 'Ana Diaz',
        p_selected_optional_line_ids: ['l-b-up'],
        p_option_id: 'opt-b',
      }),
    );
    expect(await screen.findByText('Your choice')).toBeInTheDocument();
  });

  it('shows no choice on a declined options quote (the server falls back to option 1)', async () => {
    const declined = {
      ...optionsQuote(),
      quote: {
        ...optionsQuote().quote,
        status: 'declined' as const,
        can_respond: false,
        selected_option_id: 'opt-a',
      },
    };
    mockRpc({ public_get_quote: { data: declined } });
    renderQuote();
    const options = await screen.findByRole('region', { name: 'Options' });
    expect(within(options).queryByText('Your choice')).not.toBeInTheDocument();
    expect(within(options).queryByRole('button', { name: /^Choose/ })).not.toBeInTheDocument();
    expect(screen.getByText('Each option’s total is shown on its card.')).toBeInTheDocument();
  });

  it('marks the accepted option on an approved options quote', async () => {
    const approved = {
      ...optionsQuote(),
      quote: {
        ...optionsQuote().quote,
        status: 'approved' as const,
        can_respond: false,
        selected_option_id: 'opt-b',
      },
    };
    mockRpc({ public_get_quote: { data: approved } });
    renderQuote();
    const options = await screen.findByRole('region', { name: 'Options' });
    expect(within(options).getByText('Your choice')).toBeInTheDocument();
    expect(screen.getByText('Premium', { selector: 'p' })).toBeInTheDocument();
  });
});

describe('QuotePage — self-scheduling', () => {
  const approved = () =>
    quoteFixture({
      status: 'approved',
      can_respond: false,
      approved_by_name: 'Ana Diaz',
      approved_at: '2026-09-27T15:00:00Z',
    });

  it('offers times from the booking engine and books one', async () => {
    const tomorrow = addLocalDays(shopToday(TZ), 1);
    const start = shopLocalToUtcIso(tomorrow, '09:00', TZ);
    const doc = { ...approved(), self_schedule: { ...approved().self_schedule, available: true } };
    const calls = mockRpc({
      public_get_quote: { data: doc },
      public_shop_profile: {
        data: {
          business_type: 'fixed',
          booking: { max_days_ahead: 30, booking_message: null, cancellation_policy: null },
        },
      },
      public_quote_slots: {
        data: [{ starts_at: start, ends_at: shopLocalToUtcIso(tomorrow, '12:00', TZ) }],
      },
      public_schedule_quote: {
        data: {
          job_token: 'jjjjjjjj-jjjj-4jjj-8jjj-jjjjjjjjjjjj',
          job_number: 1050,
          status: 'scheduled',
          total_cents: 54000,
          deposit_required_cents: 10000,
          deposit_due_cents: 10000,
        },
      },
    });
    const { user } = renderQuote();
    expect(await screen.findByText(/Pick a time for the work below/)).toBeInTheDocument();
    const days = await screen.findByRole('radiogroup', { name: 'Days' });
    const day = await within(days).findByRole('radio', { name: /1 times/ });
    await user.click(day);
    await user.click(screen.getByRole('radio', { name: '9:00 AM' }));
    await user.click(screen.getByRole('button', { name: /^Book / }));
    await waitFor(() =>
      expect(calls.find((c) => c.fn === 'public_schedule_quote')?.args).toEqual({
        p_token: DOC_TOKEN,
        p_starts_at: start,
        p_location: { type: 'shop' },
      }),
    );
    const slotsCall = calls.find((c) => c.fn === 'public_quote_slots');
    expect(slotsCall?.args).toMatchObject({ p_token: DOC_TOKEN, p_from: shopToday(TZ) });
  });

  it('asks for the deposit once scheduled, and never while a payment is on its way', async () => {
    const assign = vi.spyOn(navigation, 'assign').mockImplementation(() => {});
    const scheduled = {
      ...quoteFixture({ status: 'converted', can_respond: false }),
      self_schedule: {
        available: false,
        converted: true,
        job_token: 'jjjjjjjj-jjjj-4jjj-8jjj-jjjjjjjjjjjj',
        deposit_due_cents: 10000,
        payment_pending: false,
      },
    };
    mockRpc({ public_get_quote: { data: scheduled } });
    supabase.functions.invoke.mockResolvedValueOnce({
      data: {
        url: 'https://checkout.stripe.com/c/pay/cs_test_q',
        expires_at: 1790000000,
        amount_cents: 10000,
        tip_cents: 0,
        currency: 'usd',
      },
      error: null,
    });
    const { user } = renderQuote();
    expect(await screen.findByText('You’re booked')).toBeInTheDocument();
    expect(screen.getByText(/saves your card securely with Stripe/)).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Pay $100.00 deposit' }));
    await waitFor(() =>
      expect(supabase.functions.invoke).toHaveBeenCalledWith('payments', {
        body: {
          action: 'quote_deposit_checkout',
          token: DOC_TOKEN,
          request_nonce: expect.any(String),
        },
      }),
    );
    expect(assign).toHaveBeenCalledWith('https://checkout.stripe.com/c/pay/cs_test_q');
    expect(screen.getByRole('link', { name: 'Manage your appointment' })).toHaveAttribute(
      'href',
      '/booking/jjjjjjjj-jjjj-4jjj-8jjj-jjjjjjjjjjjj',
    );
  });

  it('shows a clearing deposit instead of a pay button', async () => {
    mockRpc({
      public_get_quote: {
        data: {
          ...quoteFixture({ status: 'converted', can_respond: false }),
          self_schedule: {
            available: false,
            converted: true,
            job_token: 'jjjjjjjj-jjjj-4jjj-8jjj-jjjjjjjjjjjj',
            deposit_due_cents: 10000,
            payment_pending: true,
          },
        },
      },
    });
    renderQuote();
    expect(await screen.findByText('Your deposit payment is processing')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /deposit/ })).not.toBeInTheDocument();
  });
});

describe('QuoteScheduledPanel — back from Stripe', () => {
  const scheduledDoc = (paymentPending: boolean) =>
    quoteDocumentSchema.parse({
      ...quoteFixture({ status: 'converted', can_respond: false }),
      self_schedule: {
        available: false,
        converted: true,
        job_token: 'jjjjjjjj-jjjj-4jjj-8jjj-jjjjjjjjjjjj',
        deposit_due_cents: 10000,
        payment_pending: paymentPending,
      },
    });
  const panel = (paymentPending: boolean, pollingDone: boolean) =>
    renderRoute(
      <QuoteScheduledPanel
        token={DOC_TOKEN}
        doc={scheduledDoc(paymentPending)}
        paidReturn
        pollingDone={pollingDone}
        canceledReturn={false}
        refreshing={false}
        onRefresh={() => {}}
      />,
      { path: `/q/${DOC_TOKEN}?paid=1`, routePath: '/q/:token', shop: null },
    );

  it('waits while the deposit is being confirmed', () => {
    panel(false, false);
    expect(screen.getByText('Confirming your deposit…')).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'Pay the deposit' })).not.toBeInTheDocument();
  });

  it('offers a way to pay once re-checking ends and no deposit arrived', () => {
    panel(false, true);
    expect(screen.getByText('We’re still confirming your deposit')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Pay the deposit' })).toHaveAttribute(
      'href',
      `/q/${DOC_TOKEN}`,
    );
    expect(screen.getByRole('button', { name: 'Check again' })).toBeInTheDocument();
  });

  it('shows a clearing payment, not a pay link, once re-checking ends', () => {
    panel(true, true);
    expect(screen.getByText('Your deposit payment is processing')).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'Pay the deposit' })).not.toBeInTheDocument();
  });
});

describe('InvoicePage — parity', () => {
  it('groups a fleet invoice by appointment and links the PDF', async () => {
    const doc = invoiceFixture();
    mockRpc({
      public_get_invoice: {
        data: {
          ...doc,
          job: null,
          jobs: [
            { number: 1042, date: '2026-09-19', vehicle_label: '2021 Toyota Camry' },
            { number: 1043, date: '2026-09-20', vehicle_label: '2019 Ford F-150' },
          ],
          line_items: [
            { ...doc.line_items[0]!, name: 'Camry detail', job_number: 1042 },
            { ...doc.line_items[0]!, name: 'F-150 detail', job_number: 1043 },
          ],
        },
      },
    });
    renderInvoice();
    expect(
      await screen.findByRole('list', { name: /Appointment #1042 · 2021 Toyota Camry/ }),
    ).toHaveTextContent('Camry detail');
    expect(
      screen.getByRole('list', { name: /Appointment #1043 · 2019 Ford F-150/ }),
    ).toHaveTextContent('F-150 detail');
    expect(screen.getByRole('link', { name: 'Download PDF' })).toHaveAttribute(
      'href',
      expect.stringContaining(`/functions/v1/pdf?action=invoice&token=${DOC_TOKEN}`),
    );
  });

  it('pays part of the balance with a gift card', async () => {
    const doc = invoiceFixture({ gift_card_redeemable: true });
    const after = invoiceFixture({ balance_cents: 15000, amount_paid_cents: 15000 });
    const calls = mockRpc({
      public_get_invoice: { data: doc },
      public_redeem_gift_card: {
        data: {
          ...after,
          gift_card_result: {
            redeemed: true,
            message: null,
            amount_cents: 5000,
            remaining_cents: 0,
            last4: 'Q7ZK',
          },
        },
      },
    });
    const { user } = renderInvoice();
    await user.type(await screen.findByLabelText(/Gift card code/), 'ABCD-EFGH-JKMN-Q7ZK');
    await user.click(screen.getByRole('button', { name: 'Apply gift card' }));
    expect(await screen.findByText('Gift card applied')).toBeInTheDocument();
    expect(screen.getByText(/\$50\.00 was paid from card …Q7ZK/)).toBeInTheDocument();
    expect(calls.find((c) => c.fn === 'public_redeem_gift_card')?.args).toEqual({
      p_token: DOC_TOKEN,
      p_code: 'ABCD-EFGH-JKMN-Q7ZK',
    });
  });

  it('explains a code that didn’t work', async () => {
    mockRpc({
      public_get_invoice: { data: invoiceFixture({ gift_card_redeemable: true }) },
      public_redeem_gift_card: {
        data: {
          ...invoiceFixture({ gift_card_redeemable: true }),
          gift_card_result: {
            redeemed: false,
            message: 'this gift card has expired',
            amount_cents: 0,
            remaining_cents: 2000,
            last4: 'Q7ZK',
          },
        },
      },
    });
    const { user } = renderInvoice();
    await user.type(await screen.findByLabelText(/Gift card code/), 'ABCD');
    await user.click(screen.getByRole('button', { name: 'Apply gift card' }));
    expect(await screen.findByText('This gift card has expired.')).toBeInTheDocument();
  });

  it('shows clearing bank payments and hides Pay while they cover the balance', async () => {
    mockRpc({
      public_get_invoice: {
        data: invoiceFixture({ processing_cents: 20000, payable: false }),
      },
    });
    renderInvoice();
    expect(await screen.findByText('A bank payment is clearing')).toBeInTheDocument();
    expect(screen.getByText(/nothing more to pay for now/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^Pay \$/ })).not.toBeInTheDocument();
  });
});
