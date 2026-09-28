import { expect, test, type Page } from '@playwright/test';
import { mockSupabase, reply } from './support/mockSupabase';

/** The customer's booking page (/booking/:token) against a mocked backend. */

const TOKEN = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const FORM_TOKEN = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const START = '2099-10-01T15:00:00Z';

type Doc = ReturnType<typeof bookingDoc>;

function bookingDoc() {
  return {
    shop: {
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
    },
    booking_message: null,
    booking: {
      number: 1042,
      status: 'scheduled',
      scheduled_start: START,
      scheduled_end: '2099-10-01T17:30:00Z',
      location_type: 'shop',
      service_address: null,
      notes: null,
      created_at: '2099-09-01T00:00:00Z',
      confirmed_at: null,
      completed_at: null,
      cancelled_at: null as string | null,
      cancel_reason: null as string | null,
    },
    vehicle: { year: 2021, make: 'Toyota', model: 'Camry', trim: null, color: 'Blue' },
    line_items: [
      {
        name: 'Full detail',
        description: null,
        vehicle_label: '2021 Toyota Camry',
        quantity: 1,
        unit_price_cents: 15000,
        discount_cents: 0,
        taxable: true,
        total_cents: 15000,
      },
    ],
    totals: {
      subtotal_cents: 15000,
      discount_cents: 0,
      coupon_code: null,
      tax_rate_bps: 0,
      tax_cents: 0,
      total_cents: 15000,
      paid_cents: 0,
      balance_cents: 15000,
    },
    deposit: {
      required_cents: 3000,
      paid_cents: 0,
      due_cents: 3000,
      status: 'due',
      payment_pending: false,
      card_payments_enabled: true,
    },
    cancellation: {
      allowed: true,
      deadline: '2099-09-30T15:00:00Z',
      allow_client_cancel_hours: 24,
      policy: 'Cancel at least 24 hours ahead.',
    },
    forms: [
      {
        title: 'Vehicle waiver',
        requires_signature: true,
        status: 'pending',
        signed_at: null,
        token: FORM_TOKEN,
      },
    ],
    invoice: null,
  };
}

function depositPaid(doc: Doc): Doc {
  return {
    ...doc,
    totals: { ...doc.totals, paid_cents: 3000, balance_cents: 12000 },
    deposit: { ...doc.deposit, paid_cents: 3000, due_cents: 0, status: 'paid' },
  };
}

async function setup(page: Page, getBooking: (call: number) => Doc) {
  const calls: { name: string; body: unknown }[] = [];
  let loads = 0;
  await mockSupabase(page, {
    rpc: {
      public_get_booking: ({ body }) => {
        calls.push({ name: 'public_get_booking', body });
        loads += 1;
        return getBooking(loads);
      },
      public_cancel_booking: ({ body }) => {
        calls.push({ name: 'public_cancel_booking', body });
        const doc = bookingDoc();
        return {
          ...doc,
          booking: {
            ...doc.booking,
            status: 'cancelled',
            cancelled_at: '2099-09-02T15:00:00Z',
            cancel_reason: 'Out of town',
          },
          cancellation: { ...doc.cancellation, allowed: false },
          forms: doc.forms.map((f) => ({ ...f, status: 'void' })),
        };
      },
    },
    functions: {
      payments: ({ body }) => {
        calls.push({ name: 'payments', body });
        return reply(409, { error: 'This shop cannot take card payments yet.', code: 'conflict' });
      },
    },
  });
  return calls;
}

test.describe('manage booking', () => {
  test('shows the booking and cancels it within the window', async ({ page }) => {
    const calls = await setup(page, () => bookingDoc());
    await page.goto(`/booking/${TOKEN}`);
    await expect(page.getByRole('heading', { name: 'Booking #1042', level: 1 })).toBeVisible();
    await expect(page.getByText('2021 Toyota Camry · Blue')).toBeVisible();
    await expect(page.getByText('Central Daylight Time')).toBeVisible();
    await expect(page.getByRole('link', { name: /Sign\s+Vehicle waiver/ })).toHaveAttribute(
      'href',
      `/f/${FORM_TOKEN}`,
    );
    await expect(page.getByText('Remaining')).toBeVisible();
    await expect(page.getByText('Balance', { exact: true })).toBeVisible();

    // A deposit checkout failure is explained, not swallowed.
    await page.getByRole('button', { name: 'Pay $30.00 deposit' }).click();
    await expect(page.getByText('This shop cannot take card payments yet.')).toBeVisible();

    await page.getByRole('button', { name: 'Cancel booking' }).click();
    const dialog = page.getByRole('alertdialog', { name: 'Cancel this booking?' });
    await dialog.getByLabel('Reason (optional)').fill('Out of town');
    await dialog.getByRole('button', { name: 'Cancel booking' }).click();
    await expect(page.getByText('This booking was cancelled')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Cancel booking' })).toHaveCount(0);
    // Nothing is owed on a cancelled booking, whatever total − paid comes to.
    await expect(page.getByText('Balance', { exact: true })).toHaveCount(0);
    const again = page.getByRole('link', { name: 'Book again' });
    await expect(again).toHaveAttribute('href', '/book/glacier');
    // A new document without a referrer (the booking page may load the shop's tags).
    await expect(again).toHaveAttribute('rel', 'noreferrer');
    expect(calls.find((c) => c.name === 'public_cancel_booking')?.body).toEqual({
      p_token: TOKEN,
      p_reason: 'Out of town',
    });
    expect(calls.find((c) => c.name === 'payments')?.body).toMatchObject({
      action: 'booking_deposit_checkout',
      token: TOKEN,
    });
  });

  test('after Stripe returns with ?paid=1 it polls until the deposit lands', async ({ page }) => {
    await setup(page, (call) =>
      call < 3
        ? { ...bookingDoc(), deposit: { ...bookingDoc().deposit, payment_pending: true } }
        : depositPaid(bookingDoc()),
    );
    await page.goto(`/booking/${TOKEN}?paid=1`);
    await expect(page.getByText('Confirming your deposit…')).toBeVisible();
    await expect(page.getByRole('button', { name: /deposit/ })).toHaveCount(0);
    await expect(page.getByText('Deposit received — thank you!')).toBeVisible({ timeout: 15_000 });
  });

  test('a broken link explains itself instead of retrying forever', async ({ page }) => {
    await setup(page, () => bookingDoc());
    await page.goto('/booking/not-a-token');
    await expect(page.getByText('We couldn’t find this booking')).toBeVisible();
  });
});
