import { expect, test } from '@playwright/test';
import { membershipRow, OWNER, SHOP } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

/** Gift cards: staff issue at /app/gift-cards and the public /gift/:slug shop. */

const CARD_ID = 'a1000000-0000-4000-8000-000000000001';
const ORDER_TOKEN = 'a2000000-0000-4000-8000-000000000001';
const CHECKOUT_URL = 'https://checkout.stripe.test/c/pay/cs_test_gift';

const OFFER = {
  shop: { name: 'Glacier Detailing', logo_path: null, brand_color: '#1F6FEB' },
  enabled: true,
  offers: [
    { value_cents: 10000, price_cents: 9000 },
    { value_cents: 5000, price_cents: 5000 },
  ],
  allow_custom_amount: true,
  min_custom_cents: 1000,
  max_custom_cents: 50000,
  expires_months: null,
  terms: null,
  currency: 'usd',
};

test('a customer buys a gift card online and sees the order confirmed', async ({ page }) => {
  const bodies: unknown[] = [];
  await mockSupabase(page, {
    rpc: {
      public_gift_card_offer: OFFER,
      public_gift_card_order_status: {
        status: 'paid',
        value_cents: 5000,
        recipient_name: 'Sam Lee',
        last4: 'PQRS',
      },
    },
    functions: {
      payments: ({ body }) => {
        bodies.push(body);
        return {
          url: CHECKOUT_URL,
          expires_at: 1790000000,
          price_cents: 2500,
          value_cents: 2500,
          currency: 'usd',
        };
      },
    },
  });
  await page.route(`${CHECKOUT_URL}**`, (route) =>
    route.fulfill({ status: 200, contentType: 'text/html', body: '<h1>Stripe checkout</h1>' }),
  );
  await page.goto('/gift/glacier');
  await expect(page.getByRole('heading', { name: 'Gift cards', level: 1 })).toBeVisible();
  await expect(page.getByText('Never expires.')).toBeVisible();
  await page.getByText('Other amount').click();
  await page.getByLabel('Your amount').fill('25');
  await page.getByLabel(/^Your name/).fill('Ana Diaz');
  await page.getByLabel(/^Your email/).fill('ana@example.com');
  await page.getByLabel(/^Recipient’s name/).fill('Sam Lee');
  await page.getByLabel(/^Recipient’s email/).fill('sam@example.com');
  await page.getByLabel('Message (optional)').fill('Happy birthday!');
  await page.getByRole('button', { name: 'Pay $25.00' }).click();
  await expect(page.getByRole('heading', { name: 'Stripe checkout' })).toBeVisible();
  expect(bodies[0]).toEqual({
    action: 'gift_card_checkout',
    slug: 'glacier',
    amount_cents: 2500,
    purchaser: { name: 'Ana Diaz', email: 'ana@example.com' },
    recipient: { email: 'sam@example.com', name: 'Sam Lee', message: 'Happy birthday!' },
    request_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/),
  });

  await page.goto(`/gift/glacier/done?order=${ORDER_TOKEN}`);
  await expect(page.getByText('Thank you — your gift card is on its way')).toBeVisible();
  await expect(page.getByText(/is being emailed to Sam Lee/)).toBeVisible();
});

test('staff issue a gift card and see its code exactly once', async ({ page }) => {
  let issued = false;
  const cardRow = {
    id: CARD_ID,
    kind: 'gift',
    code_last4: 'PQRS',
    initial_cents: 5000,
    balance_cents: 5000,
    sold_price_cents: null,
    status: 'active',
    owner_customer_id: null,
    purchaser_customer_id: null,
    recipient_name: 'Sam Lee',
    recipient_email: null,
    message: null,
    issued_via: 'staff',
    expires_at: null,
    voided_at: null,
    void_reason: null,
    created_at: '2026-09-28T15:00:00Z',
    owner: null,
    purchaser: null,
  };
  await mockSupabase(page, {
    user: OWNER,
    tables: {
      shop_members: [membershipRow(OWNER, 'owner', SHOP)],
      notifications: [],
      gift_cards: () => (issued ? [cardRow] : []),
      gift_card_settings: [
        { online_enabled: false, offers: [], allow_custom_amount: false, expires_months: null },
      ],
      gift_card_transactions: [],
      customers: [],
    },
    rpc: {
      issue_gift_card: () => {
        issued = true;
        return {
          gift_card_id: CARD_ID,
          code: 'ABCD-EFGH-JKMN-PQRS',
          last4: 'PQRS',
          balance_cents: 5000,
          delivery_queued: false,
        };
      },
    },
  });
  await page.goto('/app/gift-cards');
  await expect(page.getByText('No gift cards yet')).toBeVisible();
  await page.getByRole('button', { name: 'Issue gift card' }).first().click();
  const dialog = page.getByRole('dialog', { name: 'Issue a gift card' });
  await dialog.getByLabel(/^Value/).fill('50');
  await dialog.getByRole('textbox', { name: 'Name' }).fill('Sam Lee');
  await dialog.getByRole('button', { name: 'Issue $50.00' }).click();
  const done = page.getByRole('dialog', { name: 'Gift card issued' });
  await expect(done.getByText('ABCD-EFGH-JKMN-PQRS')).toBeVisible();
  await done.getByRole('button', { name: 'Done' }).click();
  await expect(page.getByText('ABCD-EFGH-JKMN-PQRS')).toHaveCount(0);
  await expect(page.getByRole('table', { name: 'Gift cards' }).getByText('…PQRS')).toBeVisible();
});
