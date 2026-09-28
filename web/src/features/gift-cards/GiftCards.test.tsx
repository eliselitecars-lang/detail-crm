import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import {
  builders,
  mockRpc,
  pgError,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import { navigation } from '@/features/public-docs/shared/checkout';
import GiftCardDetailPage from './GiftCardDetailPage';
import GiftCardOrderDonePage from './GiftCardOrderDonePage';
import GiftCardShopPage from './GiftCardShopPage';
import GiftCardsPage from './GiftCardsPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const TOKEN = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

function card(overrides: Record<string, unknown> = {}) {
  return {
    id: 'gc-1',
    kind: 'gift',
    code_last4: 'Q7ZK',
    initial_cents: 10000,
    balance_cents: 6000,
    sold_price_cents: null,
    status: 'active',
    owner_customer_id: null,
    purchaser_customer_id: null,
    recipient_name: 'Sam Lee',
    recipient_email: 'sam@example.com',
    message: null,
    issued_via: 'staff',
    expires_at: null,
    voided_at: null,
    void_reason: null,
    created_at: '2026-09-20T15:00:00Z',
    owner: null,
    purchaser: null,
    ...overrides,
  };
}

function staff(ui: React.ReactElement, path: string, routePath: string, role = 'owner' as const) {
  return renderRoute(ui, {
    path,
    routePath,
    shop: shopValue({ membership: membership({ role }) }),
  });
}

beforeEach(() => {
  resetSupabaseMock();
  supabase.functions.invoke.mockReset();
});

describe('GiftCardsPage', () => {
  it('lists cards with balances and searches by code', async () => {
    setTableResult('gift_cards', { data: [card()], count: 1 });
    setTableResult('gift_card_settings', {
      data: { online_enabled: true, offers: [], allow_custom_amount: true, expires_months: null },
    });
    const { user } = staff(<GiftCardsPage />, '/app/gift-cards', '/app/gift-cards');
    const table = await screen.findByRole('table', { name: 'Gift cards' });
    expect(within(table).getByText('…Q7ZK')).toBeInTheDocument();
    expect(within(table).getByText('$60.00')).toBeInTheDocument();
    expect(screen.getByText('Selling online')).toBeInTheDocument();
    await user.type(screen.getByRole('searchbox', { name: 'Search gift cards' }), 'q7z');
    await waitFor(() =>
      expect(
        builders.gift_cards?.some((b) =>
          b.or.mock.calls.some(([filter]) => String(filter).includes('code_last4.ilike.%Q7Z%')),
        ),
      ).toBe(true),
    );
  });

  it('issues a card and shows the code once', async () => {
    setTableResult('gift_cards', { data: [], count: 0 });
    setTableResult('gift_card_settings', { data: null });
    setTableResult('customers', { data: [] });
    const calls = mockRpc({
      issue_gift_card: {
        data: {
          gift_card_id: 'gc-9',
          code: 'ABCD-EFGH-JKMN-PQRS',
          last4: 'PQRS',
          balance_cents: 5000,
          delivery_queued: true,
        },
      },
    });
    const { user } = staff(<GiftCardsPage />, '/app/gift-cards', '/app/gift-cards');
    await user.click((await screen.findAllByRole('button', { name: 'Issue gift card' }))[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'Issue a gift card' });
    await user.type(within(dialog).getByLabelText(/^Value/), '50');
    await user.type(within(dialog).getByRole('textbox', { name: 'Email' }), 'sam@example.com');
    await user.click(within(dialog).getByRole('checkbox', { name: /Email the card/ }));
    await user.click(within(dialog).getByRole('button', { name: 'Issue $50.00' }));
    const issued = await screen.findByRole('dialog', { name: 'Gift card issued' });
    expect(within(issued).getByText('ABCD-EFGH-JKMN-PQRS')).toBeInTheDocument();
    expect(within(issued).getByText(/on its way to the recipient/)).toBeInTheDocument();
    expect(calls.find((c) => c.fn === 'issue_gift_card')?.args).toEqual({
      p_shop_id: 'shop-1',
      p_amount_cents: 5000,
      p_recipient: { email: 'sam@example.com' },
      p_kind: 'gift',
      p_send: true,
    });
  });
});

describe('GiftCardDetailPage', () => {
  it('shows the history and lets admins adjust the balance', async () => {
    setTableResult('gift_cards', { data: card() });
    setTableResult('gift_card_transactions', {
      data: [
        {
          id: 't-2',
          kind: 'redeem',
          amount_cents: -4000,
          balance_after_cents: 6000,
          payment_id: 'pay-1',
          note: 'Invoice #2001',
          created_at: '2026-09-22T15:00:00Z',
          payment: { id: 'pay-1', invoice_id: 'inv-1', invoice: { id: 'inv-1', number: 2001 } },
        },
        {
          id: 't-1',
          kind: 'issue',
          amount_cents: 10000,
          balance_after_cents: 10000,
          payment_id: null,
          note: 'Issued by staff',
          created_at: '2026-09-20T15:00:00Z',
          payment: null,
        },
      ],
    });
    const calls = mockRpc({ adjust_gift_card: { data: card({ balance_cents: 7000 }) } });
    const { user } = staff(
      <GiftCardDetailPage />,
      '/app/gift-cards/gc-1',
      '/app/gift-cards/:giftCardId',
    );
    const history = await screen.findByRole('list', { name: 'Card history' });
    expect(within(history).getByText('−$40.00')).toBeInTheDocument();
    expect(within(history).getByRole('link', { name: 'Invoice #2001' })).toHaveAttribute(
      'href',
      '/app/invoices/inv-1',
    );
    await user.click(screen.getByRole('button', { name: 'Adjust balance' }));
    const dialog = await screen.findByRole('dialog', { name: 'Adjust balance' });
    await user.type(within(dialog).getByLabelText(/^Amount/), '10');
    await user.type(within(dialog).getByLabelText(/^Note/), 'Goodwill');
    await user.click(within(dialog).getByRole('button', { name: 'Save adjustment' }));
    await waitFor(() =>
      expect(calls.find((c) => c.fn === 'adjust_gift_card')?.args).toEqual({
        p_gift_card_id: 'gc-1',
        p_delta_cents: 1000,
        p_note: 'Goodwill',
      }),
    );
  });

  it('managers see the card but cannot adjust or void it', async () => {
    setTableResult('gift_cards', { data: card() });
    setTableResult('gift_card_transactions', { data: [] });
    renderRoute(<GiftCardDetailPage />, {
      path: '/app/gift-cards/gc-1',
      routePath: '/app/gift-cards/:giftCardId',
      shop: shopValue({ membership: membership({ role: 'manager' }) }),
    });
    expect(await screen.findByRole('heading', { name: 'Gift card …Q7ZK' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Adjust balance' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Void card' })).not.toBeInTheDocument();
  });
});

describe('Public gift card pages', () => {
  const offer = {
    shop: { name: 'Glacier Detailing', logo_path: null, brand_color: null },
    enabled: true,
    offers: [
      { value_cents: 10000, price_cents: 9000 },
      { value_cents: 5000, price_cents: 5000 },
    ],
    allow_custom_amount: false,
    min_custom_cents: 1000,
    max_custom_cents: 50000,
    expires_months: 60,
    terms: null,
    currency: 'usd',
  };

  it('sells an offer through Stripe Checkout (the server prices it)', async () => {
    const assign = vi.spyOn(navigation, 'assign').mockImplementation(() => {});
    mockRpc({ public_gift_card_offer: { data: offer } });
    supabase.functions.invoke.mockResolvedValueOnce({
      data: {
        url: 'https://checkout.stripe.com/c/pay/cs_test_g',
        expires_at: 1790000000,
        price_cents: 9000,
        value_cents: 10000,
        currency: 'usd',
      },
      error: null,
    });
    const { user } = renderRoute(<GiftCardShopPage />, {
      path: '/gift/glacier',
      routePath: '/gift/:slug',
      shop: null,
    });
    expect(await screen.findByText('Valid for 5 years from purchase.')).toBeInTheDocument();
    expect(screen.getByText('for $90.00')).toBeInTheDocument();
    await user.type(screen.getByLabelText(/^Your name/), 'Ana Diaz');
    await user.type(screen.getByLabelText(/^Your email/), 'ana@example.com');
    await user.type(screen.getByLabelText(/^Recipient’s email/), 'sam@example.com');
    await user.click(screen.getByRole('button', { name: 'Pay $90.00' }));
    await waitFor(() =>
      expect(supabase.functions.invoke).toHaveBeenCalledWith('payments', {
        body: {
          action: 'gift_card_checkout',
          slug: 'glacier',
          offer_index: 0,
          purchaser: { name: 'Ana Diaz', email: 'ana@example.com' },
          recipient: { email: 'sam@example.com' },
          request_nonce: expect.any(String),
        },
      }),
    );
    expect(assign).toHaveBeenCalledWith('https://checkout.stripe.com/c/pay/cs_test_g');
  });

  it('says so when the shop sells no gift cards online', async () => {
    mockRpc({ public_gift_card_offer: { data: { ...offer, enabled: false } } });
    renderRoute(<GiftCardShopPage />, {
      path: '/gift/glacier',
      routePath: '/gift/:slug',
      shop: null,
    });
    expect(await screen.findByText('Gift cards aren’t sold online right now')).toBeInTheDocument();
  });

  it('confirms a paid order without showing the code', async () => {
    mockRpc({
      public_gift_card_order_status: {
        data: { status: 'paid', value_cents: 10000, recipient_name: 'Sam Lee', last4: 'PQRS' },
      },
      public_gift_card_offer: { data: offer },
    });
    renderRoute(<GiftCardOrderDonePage />, {
      path: `/gift/glacier/done?order=${TOKEN}`,
      routePath: '/gift/:slug/done',
      shop: null,
    });
    expect(await screen.findByText('Thank you — your gift card is on its way')).toBeInTheDocument();
    expect(screen.getByText(/ending PQRS\) is being emailed to Sam Lee/)).toBeInTheDocument();
  });

  it('shows the amount in the shop’s currency, never a guessed USD', async () => {
    mockRpc({
      public_gift_card_order_status: {
        data: { status: 'paid', value_cents: 5000, recipient_name: 'Sam Lee', last4: null },
      },
      public_gift_card_offer: { data: { ...offer, currency: 'eur' } },
    });
    renderRoute(<GiftCardOrderDonePage />, {
      path: `/gift/glacier/done?order=${TOKEN}`,
      routePath: '/gift/:slug/done',
      shop: null,
    });
    expect(
      await screen.findByText('A €50.00 gift card is being emailed to Sam Lee.'),
    ).toBeInTheDocument();
    expect(screen.queryByText(/\$50\.00/)).not.toBeInTheDocument();
  });

  it('leaves the amount out when the shop (and so its currency) can’t be loaded', async () => {
    mockRpc({
      public_gift_card_order_status: {
        data: { status: 'paid', value_cents: 5000, recipient_name: 'Sam Lee', last4: 'PQRS' },
      },
      public_gift_card_offer: pgError('PT404', 'shop not found'),
    });
    renderRoute(<GiftCardOrderDonePage />, {
      path: `/gift/renamed/done?order=${TOKEN}`,
      routePath: '/gift/:slug/done',
      shop: null,
    });
    expect(
      await screen.findByText('A gift card (ending PQRS) is being emailed to Sam Lee.'),
    ).toBeInTheDocument();
    expect(screen.queryByText(/\$/)).not.toBeInTheDocument();
  });
});
