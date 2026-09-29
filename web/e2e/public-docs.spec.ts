import { expect, test, type Page } from '@playwright/test';
import { mockSupabase, reply, type Handler } from './support/mockSupabase';

/** Public quote (/q), invoice (/i) and form (/f) pages against a mocked backend. */

const QUOTE_TOKEN = '51111111-1111-4111-8111-111111111111';
const INVOICE_TOKEN = '52222222-2222-4222-8222-222222222222';
const FORM_TOKEN = '53333333-3333-4333-8333-333333333333';
const SHOP_ID = '10000000-0000-4000-8000-000000000001';
const OPT_WHEELS = '54444444-4444-4444-8444-444444444441';
const OPT_GLASS = '54444444-4444-4444-8444-444444444442';
const CHECKOUT_URL = 'https://checkout.stripe.test/c/pay/cs_test_invoice';

const SHOP = {
  name: 'Glacier Detailing',
  slug: 'glacier',
  logo_path: null,
  brand_color: '#1F6FEB',
  email: 'hello@glacier.test',
  phone: '+12055550100',
  website: null,
  address_line1: '1 Main St',
  address_line2: null,
  city: 'Birmingham',
  region: 'AL',
  postal_code: '35203',
  country: 'US',
  timezone: 'America/Chicago',
  currency: 'usd',
  review_url: null,
};

const line = (name: string, cents: number) => ({
  name,
  description: null,
  vehicle_label: '2021 Toyota Camry',
  quantity: 1,
  unit_price_cents: cents,
  discount_cents: 0,
  taxable: true,
  total_cents: cents,
});

function quoteDoc(overrides: Record<string, unknown> = {}) {
  return {
    shop: SHOP,
    quote: {
      number: 301,
      status: 'viewed',
      valid_until: '2099-12-31',
      expires_at: null,
      notes: 'Thanks for the opportunity.',
      terms: null,
      subtotal_cents: 58000,
      discount_cents: 0,
      tax_rate_bps: 0,
      tax_cents: 0,
      total_cents: 58000,
      sent_at: '2026-09-20T15:00:00Z',
      viewed_at: '2026-09-21T15:00:00Z',
      approved_at: null,
      approved_by_name: null,
      declined_at: null,
      declined_reason: null,
      expired_at: null,
      can_respond: true,
      ...overrides,
    },
    customer: { first_name: 'Ana', last_name: 'Diaz', company: null },
    vehicle: { year: 2021, make: 'Toyota', model: 'Camry', trim: null, color: null },
    line_items: [
      {
        ...line('Paint correction', 50000),
        id: '54444444-4444-4444-8444-444444444440',
        optional: false,
        selected: true,
      },
      { ...line('Wheel coating', 15000), id: OPT_WHEELS, optional: true, selected: false },
      { ...line('Glass coating', 8000), id: OPT_GLASS, optional: true, selected: true },
    ],
  };
}

function invoiceDoc(overrides: Record<string, unknown> = {}) {
  return {
    shop: SHOP,
    invoice: {
      number: 2001,
      status: 'partially_paid',
      issued_at: '2026-09-20T15:00:00Z',
      due_at: '2099-10-20T15:00:00Z',
      paid_at: null,
      voided_at: null,
      notes: null,
      terms: 'Due on receipt.',
      subtotal_cents: 30000,
      discount_cents: 0,
      tax_rate_bps: 0,
      tax_cents: 0,
      total_cents: 30000,
      amount_paid_cents: 10000,
      balance_cents: 20000,
      tip_cents: 0,
      payable: true,
      card_payments_enabled: true,
      ...overrides,
    },
    customer: { first_name: 'Ana', last_name: 'Diaz', company: null },
    job: { number: 1042, scheduled_start: '2026-09-19T15:00:00Z', scheduled_end: null },
    vehicle: { year: 2021, make: 'Toyota', model: 'Camry', trim: null, color: null },
    line_items: [line('Full detail', 30000)],
    payments: [
      {
        kind: 'deposit',
        method: 'card',
        status: 'succeeded',
        amount_cents: 10000,
        tip_cents: 0,
        refunded_cents: 0,
        card_brand: 'visa',
        card_last4: '4242',
        paid_at: '2026-09-18T15:00:00Z',
      },
    ],
  };
}

function formDoc(overrides: Record<string, unknown> = {}, signed = false) {
  return {
    shop: {
      name: 'Glacier Detailing',
      slug: 'glacier',
      logo_path: null,
      brand_color: null,
      timezone: 'America/Chicago',
    },
    form: {
      title: 'Vehicle waiver',
      body: '# Waiver\n\nI agree to **the terms**.\n\n- Remove valuables\n- <img src=x onerror=alert(1)>',
      requires_signature: true,
      status: signed ? 'signed' : 'pending',
      signer_name: signed ? 'Ana Diaz' : null,
      signed_at: signed ? '2026-09-22T15:00:00Z' : null,
      ...overrides,
    },
    job: {
      number: 1042,
      scheduled_start: '2099-10-01T14:00:00Z',
      scheduled_end: null,
      vehicle: '2021 Toyota Camry',
    },
    customer: null,
    signature_upload_prefix: signed ? null : `${SHOP_ID}/forms/${FORM_TOKEN}/`,
  };
}

/** payments.invoice_checkout: records the bodies it received. */
function checkout(calls: unknown[]): Handler {
  return ({ body }) => {
    calls.push(body);
    return {
      url: CHECKOUT_URL,
      expires_at: 1_900_000_000,
      amount_cents: 20000,
      tip_cents: (body as { tip_cents: number }).tip_cents,
      currency: 'usd',
    };
  };
}

async function mockStripeCheckout(page: Page) {
  await page.route('https://checkout.stripe.test/**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'text/html',
      body: '<!doctype html><title>Stripe Checkout</title><h1>Stripe Checkout</h1>',
    }),
  );
}

test.describe('public quote', () => {
  test('client picks optional items and approves with a typed name', async ({ page }) => {
    const calls: unknown[] = [];
    await mockSupabase(page, {
      rpc: {
        public_get_quote: quoteDoc(),
        public_respond_quote: ({ body }) => {
          calls.push(body);
          return quoteDoc({
            status: 'approved',
            can_respond: false,
            approved_by_name: 'Ana Diaz',
            approved_at: '2026-09-22T15:00:00Z',
            subtotal_cents: 65000,
            total_cents: 65000,
          });
        },
      },
    });
    await page.goto(`/q/${QUOTE_TOKEN}`);
    await expect(page.getByRole('heading', { name: 'Quote #301', level: 1 })).toBeVisible();
    // Each of a shop's links names itself in the tab (WCAG 2.4.2).
    await expect(page).toHaveTitle(/^Quote #301 · \S/);
    await expect(page.getByText('$580.00').last()).toBeVisible();
    const optional = page.getByRole('list', { name: 'Optional add-ons' });
    await optional.getByRole('checkbox', { name: /Wheel coating/ }).check();
    await optional.getByRole('checkbox', { name: /Glass coating/ }).uncheck();
    await expect(page.getByText(/priced by the shop when you approve/)).toBeVisible();

    await page.getByRole('button', { name: 'Approve quote' }).click();
    await expect(page.getByText('Type your full name to approve.')).toBeVisible();
    await page.getByLabel(/^Your full name/).fill('Ana Diaz');
    await page.getByRole('button', { name: 'Approve quote' }).click();

    await expect(page.getByText('Quote approved', { exact: true })).toBeVisible();
    await expect(page.getByText(/Approved by Ana Diaz/)).toBeVisible();
    await expect(page.getByText('$650.00').last()).toBeVisible();
    await expect(page.getByRole('button', { name: 'Approve quote' })).toHaveCount(0);
    expect(calls).toEqual([
      {
        p_token: QUOTE_TOKEN,
        p_action: 'approve',
        p_signer_name: 'Ana Diaz',
        p_selected_optional_line_ids: [OPT_WHEELS],
      },
    ]);
  });

  test('client declines with a reason', async ({ page }) => {
    const calls: unknown[] = [];
    await mockSupabase(page, {
      rpc: {
        public_get_quote: quoteDoc(),
        public_respond_quote: ({ body }) => {
          calls.push(body);
          return quoteDoc({
            status: 'declined',
            can_respond: false,
            declined_at: '2026-09-22T15:00:00Z',
            declined_reason: 'Went with a smaller package',
          });
        },
      },
    });
    await page.goto(`/q/${QUOTE_TOKEN}`);
    await page.getByRole('button', { name: 'Decline' }).click();
    const dialog = page.getByRole('dialog', { name: 'Decline this quote?' });
    await dialog.getByLabel('Reason').fill('Went with a smaller package');
    await dialog.getByRole('button', { name: 'Decline quote' }).click();
    await expect(page.getByText('Quote declined')).toBeVisible();
    await expect(page.getByText(/Reason: Went with a smaller package/)).toBeVisible();
    expect(calls).toEqual([
      {
        p_token: QUOTE_TOKEN,
        p_action: 'decline',
        p_declined_reason: 'Went with a smaller package',
      },
    ]);
  });

  test('an expired quote cannot be answered', async ({ page }) => {
    await mockSupabase(page, {
      rpc: { public_get_quote: quoteDoc({ status: 'expired', can_respond: false }) },
    });
    await page.goto(`/q/${QUOTE_TOKEN}`);
    await expect(page.getByText('This quote has expired')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Approve quote' })).toHaveCount(0);
    await expect(page.getByRole('checkbox')).toHaveCount(0);
  });
});

test.describe('public links that no longer exist (PT404)', () => {
  const notFound = (message: string) =>
    reply(404, { code: 'PT404', message, details: null, hint: null });

  test('an unknown quote link shows the not-found page', async ({ page }) => {
    await mockSupabase(page, { rpc: { public_get_quote: notFound('quote not found') } });
    await page.goto(`/q/${QUOTE_TOKEN}`);
    await expect(page.getByText('We couldn’t find this quote')).toBeVisible();
    await expect(page).toHaveTitle('Quote not found · Detail CRM');
    await expect(page.getByRole('button', { name: 'Approve quote' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: /Try again/ })).toHaveCount(0);
  });

  test('an unknown invoice link shows the not-found page', async ({ page }) => {
    await mockSupabase(page, { rpc: { public_get_invoice: notFound('invoice not found') } });
    await page.goto(`/i/${INVOICE_TOKEN}`);
    await expect(page.getByText('We couldn’t find this invoice')).toBeVisible();
    await expect(page.getByRole('button', { name: /^Pay/ })).toHaveCount(0);
    await expect(page.getByRole('button', { name: /Try again/ })).toHaveCount(0);
  });
});

test.describe('public invoice', () => {
  test('pays the balance with a 20% tip via Stripe Checkout', async ({ page }) => {
    const calls: unknown[] = [];
    await mockSupabase(page, {
      rpc: { public_get_invoice: invoiceDoc() },
      functions: { payments: checkout(calls) },
    });
    await mockStripeCheckout(page);
    await page.goto(`/i/${INVOICE_TOKEN}`);
    await expect(page.getByRole('heading', { name: 'Invoice #2001', level: 1 })).toBeVisible();
    await expect(page).toHaveTitle(/^Invoice #2001 · \S/);
    await expect(page.getByText('Visa •••• 4242')).toBeVisible();
    await page.getByText('20%', { exact: true }).click();
    await page.getByRole('button', { name: 'Pay $200.00 + $40.00 tip' }).click();
    await page.waitForURL(CHECKOUT_URL);
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({
      action: 'invoice_checkout',
      token: INVOICE_TOKEN,
      tip_cents: 4000,
    });
  });

  test('a custom tip above the balance is refused before checkout', async ({ page }) => {
    const calls: unknown[] = [];
    await mockSupabase(page, {
      rpc: { public_get_invoice: invoiceDoc() },
      functions: { payments: checkout(calls) },
    });
    await mockStripeCheckout(page);
    await page.goto(`/i/${INVOICE_TOKEN}`);
    await page.getByText('Custom', { exact: true }).click();
    await page.getByLabel('Tip amount').fill('500');
    await page.getByRole('button', { name: /^Pay \$200\.00/ }).click();
    await expect(page.getByText(/Enter a tip between/)).toBeVisible();
    expect(calls).toHaveLength(0);
  });

  test('returning with ?paid=1 polls until the payment lands', async ({ page }) => {
    let loads = 0;
    await mockSupabase(page, {
      rpc: {
        public_get_invoice: () => {
          loads += 1;
          return loads < 3
            ? invoiceDoc()
            : invoiceDoc({
                status: 'paid',
                amount_paid_cents: 30000,
                balance_cents: 0,
                payable: false,
                paid_at: '2026-09-22T15:00:00Z',
              });
        },
      },
    });
    await page.goto(`/i/${INVOICE_TOKEN}?paid=1`);
    await expect(page.getByText('Confirming your payment…')).toBeVisible();
    await expect(page.getByRole('button', { name: /^Pay / })).toHaveCount(0);
    await expect(page.getByText('Payment received — thank you!')).toBeVisible({ timeout: 15_000 });
  });

  test('backing out of card checkout closes that page, so a gift card works right away', async ({
    page,
  }) => {
    // The hold the abandoned Checkout Session keeps on the invoice (0109)
    // refuses gift cards until the payments edge expires the session.
    let held = true;
    const calls: unknown[] = [];
    await mockSupabase(page, {
      rpc: {
        public_get_invoice: invoiceDoc({ gift_card_redeemable: true }),
        public_redeem_gift_card: () =>
          held
            ? reply(400, {
                code: '55000',
                message:
                  'a card payment page for this invoice is still open (until 3:40 PM); cancel the open payments first, or wait until then',
                details: null,
                hint: 'checkout_open',
              })
            : {
                ...invoiceDoc({ amount_paid_cents: 15000, balance_cents: 15000 }),
                gift_card_result: {
                  redeemed: true,
                  message: null,
                  amount_cents: 5000,
                  remaining_cents: 0,
                  last4: 'Q7ZK',
                },
              },
      },
      functions: {
        payments: ({ body }) => {
          calls.push(body);
          held = false;
          return {
            invoice_id: null,
            cancelled: 0,
            succeeded: 0,
            in_progress: 0,
            sessions_expired: 1,
          };
        },
      },
    });
    await page.goto(`/i/${INVOICE_TOKEN}?canceled=1`);
    await expect(page.getByText('Payment cancelled')).toBeVisible();
    await expect
      .poll(() => calls)
      .toEqual([{ action: 'invoice_checkout_cancel', token: INVOICE_TOKEN }]);
    await page.getByLabel('Gift card code').fill('ABCD-EFGH-JKMN-Q7ZK');
    await page.getByRole('button', { name: 'Apply gift card' }).click();
    await expect(page.getByText('Gift card applied')).toBeVisible();
    await expect(page.getByText(/still open/)).toHaveCount(0);
  });

  test('a void invoice shows nothing owed and no pay button', async ({ page }) => {
    await mockSupabase(page, {
      rpc: {
        public_get_invoice: invoiceDoc({
          status: 'void',
          payable: false,
          voided_at: '2026-09-22T15:00:00Z',
        }),
      },
    });
    await page.goto(`/i/${INVOICE_TOKEN}`);
    await expect(page.getByText('This invoice was voided')).toBeVisible();
    await expect(page.getByRole('button', { name: /^Pay / })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Print' })).toBeVisible();
  });
});

test.describe('public form', () => {
  test('renders the body safely, uploads the drawn signature and signs', async ({ page }) => {
    const uploads: string[] = [];
    const signCalls: { p_token: string; p_signer_name: string; p_signature_path: string }[] = [];
    let dialogs = 0;
    page.on('dialog', (dialog) => {
      dialogs += 1;
      void dialog.dismiss();
    });
    await mockSupabase(page, {
      rpc: {
        public_get_form: formDoc(),
        public_sign_form: ({ body }) => {
          signCalls.push(body as (typeof signCalls)[number]);
          return formDoc({}, true);
        },
      },
      storage: ({ url }) => {
        const path = url.pathname.replace('/storage/v1/object/signatures/', '');
        uploads.push(decodeURIComponent(path));
        return { Key: `signatures/${path}`, Id: 'obj-1' };
      },
    });

    await page.goto(`/f/${FORM_TOKEN}`);
    await expect(page.getByRole('heading', { name: 'Vehicle waiver', level: 1 })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Waiver', level: 2 })).toBeVisible();
    await expect(page.locator('strong', { hasText: 'the terms' })).toBeVisible();
    // Raw HTML in the body is shown as text, never rendered.
    await expect(page.getByText('<img src=x onerror=alert(1)>')).toBeVisible();

    await page.getByRole('button', { name: 'Sign form' }).click();
    await expect(page.getByText('Type your full name.')).toBeVisible();
    await expect(
      page.getByText('Sign in the box: draw your signature, or choose Type and type it.'),
    ).toBeVisible();

    await page.getByLabel(/^Your full name/).fill('Ana Diaz');
    const pad = page.getByRole('img', { name: /Your signature/ });
    const box = await pad.boundingBox();
    if (!box) throw new Error('signature pad not visible');
    await page.mouse.move(box.x + 30, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + 90, box.y + box.height / 3, { steps: 5 });
    await page.mouse.move(box.x + 160, box.y + (box.height * 2) / 3, { steps: 5 });
    await page.mouse.up();
    await expect(page.getByRole('img', { name: /Your signature \(signed\)/ })).toBeVisible();
    await page.getByRole('button', { name: 'Sign form' }).click();

    await expect(page.getByText('Signed — thank you!')).toBeVisible();
    await expect(page.getByText(/Signed by Ana Diaz/)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Sign form' })).toHaveCount(0);
    expect(uploads).toHaveLength(1);
    expect(uploads[0]).toMatch(new RegExp(`^${SHOP_ID}/forms/${FORM_TOKEN}/[^/]+\\.png$`));
    expect(signCalls).toEqual([
      { p_token: FORM_TOKEN, p_signer_name: 'Ana Diaz', p_signature_path: uploads[0] },
    ]);
    expect(dialogs).toBe(0);
  });

  test('signs with the keyboard only: a typed signature is rendered and uploaded (WCAG 2.1.1)', async ({
    page,
  }) => {
    const uploads: { path: string; bytes: number }[] = [];
    const signCalls: { p_signer_name: string; p_signature_path: string }[] = [];
    await mockSupabase(page, {
      rpc: {
        public_get_form: formDoc(),
        public_sign_form: ({ body }) => {
          signCalls.push(body as (typeof signCalls)[number]);
          return formDoc({}, true);
        },
      },
      storage: ({ url, body }) => {
        const path = url.pathname.replace('/storage/v1/object/signatures/', '');
        const bytes =
          body instanceof Uint8Array ? body.byteLength : typeof body === 'string' ? body.length : 0;
        uploads.push({ path: decodeURIComponent(path), bytes });
        return { Key: `signatures/${path}`, Id: 'obj-1' };
      },
    });

    await page.goto(`/f/${FORM_TOKEN}`);
    const name = page.getByLabel(/^Your full name/);
    await name.focus();
    await page.keyboard.type('Ana Diaz');
    // Name → the "how to sign" radios (Draw is checked) → Type with an arrow key.
    await page.keyboard.press('Tab');
    await expect(page.getByRole('radio', { name: 'Draw' })).toBeFocused();
    await page.keyboard.press('ArrowRight');
    await expect(page.getByRole('radio', { name: 'Type' })).toBeChecked();
    // The typed signature starts as the signer's name and can be edited.
    await page.keyboard.press('Tab');
    const typed = page.getByLabel('Type your signature');
    await expect(typed).toBeFocused();
    await expect(typed).toHaveValue('Ana Diaz');
    await page.keyboard.press('ControlOrMeta+A');
    await page.keyboard.type('Ana M. Diaz');
    await expect(
      page.getByRole('img', { name: 'Your signature (typed: Ana M. Diaz)' }),
    ).toBeVisible();
    // The typed signature is drawn on the canvas (non-transparent pixels).
    const inked = await page.locator('canvas').evaluate((canvas: HTMLCanvasElement) => {
      const ctx = canvas.getContext('2d');
      if (!ctx) return 0;
      const { data } = ctx.getImageData(0, 0, canvas.width, canvas.height);
      let count = 0;
      for (let i = 3; i < data.length; i += 4) if (data[i]! > 0) count += 1;
      return count;
    });
    expect(inked).toBeGreaterThan(100);

    await typed.press('Enter');
    await expect(page.getByText('Signed — thank you!')).toBeVisible();
    expect(uploads).toHaveLength(1);
    expect(uploads[0]!.path).toMatch(new RegExp(`^${SHOP_ID}/forms/${FORM_TOKEN}/[^/]+\\.png$`));
    expect(uploads[0]!.bytes).toBeGreaterThan(500);
    expect(signCalls).toMatchObject([
      { p_signer_name: 'Ana Diaz', p_signature_path: uploads[0]!.path },
    ]);
  });
});
