import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, SHOP } from './support/fixtures';
import { mockSupabase, SUPABASE_URL } from './support/mockSupabase';

const CUSTOMER = {
  id: '30000000-0000-4000-8000-000000000001',
  first_name: 'Jane',
  last_name: 'Doe',
  company: null,
  email: 'jane@example.com',
  phone: '+12055550123',
  archived_at: null,
  sms_opted_out_at: null,
  email_opted_out_at: null,
};

function quote(overrides: Record<string, unknown> = {}) {
  return {
    id: '60000000-0000-4000-8000-000000000001',
    shop_id: SHOP.id,
    number: 1001,
    customer_id: CUSTOMER.id,
    vehicle_id: null,
    status: 'draft',
    valid_until: null,
    notes: null,
    terms: null,
    internal_notes: null,
    discount_kind: 'none',
    discount_value: 0,
    tax_rate_bps: 800,
    subtotal_cents: 25000,
    discount_cents: 0,
    tax_cents: 2000,
    total_cents: 27000,
    public_token: '40000000-0000-4000-8000-000000000001',
    sent_at: null,
    viewed_at: null,
    approved_at: null,
    approved_by_name: null,
    declined_at: null,
    declined_reason: null,
    expired_at: null,
    converted_at: null,
    converted_job_id: null,
    created_by: null,
    created_at: '2026-09-20T15:00:00Z',
    updated_at: '2026-09-20T15:00:00Z',
    customer: CUSTOMER,
    ...overrides,
  };
}

const LINE = {
  id: '70000000-0000-4000-8000-000000000001',
  shop_id: SHOP.id,
  quote_id: quote().id,
  service_id: null,
  vehicle_id: null,
  name: 'Full detail',
  description: null,
  quantity: 1,
  unit_price_cents: 25000,
  discount_cents: 0,
  taxable: true,
  duration_minutes: 180,
  optional: false,
  selected: true,
  sort: 1,
  total_cents: 25000,
  created_at: '2026-09-20T15:00:00Z',
  updated_at: '2026-09-20T15:00:00Z',
};

interface Captured {
  rpc: { name: string; body: unknown }[];
  functions: { name: string; body: unknown }[];
}

async function setup(page: Page, current: ReturnType<typeof quote>) {
  const captured: Captured = { rpc: [], functions: [] };
  const rpc =
    (name: string, result: unknown) =>
    ({ body }: { body: unknown }) => {
      captured.rpc.push({ name, body });
      return result as never;
    };
  await mockSupabase(page, {
    user: OWNER,
    tables: {
      shop_members: [membershipRow(OWNER, 'owner')],
      notifications: [],
      quotes: [current],
      quote_line_items: [LINE],
      customers: [CUSTOMER],
      vehicles: [],
      shops: [
        {
          quote_terms: null,
          invoice_terms: null,
          invoice_due_days: 14,
          tax_rate_bps: 800,
          name: SHOP.name,
          phone: null,
        },
      ],
      message_templates: [
        {
          subject: null,
          body: 'Hi {{customer_first_name}}, review your quote: {{quote_link}}',
          enabled: true,
        },
      ],
    },
    rpc: {
      render_template: rpc(
        'render_template',
        'Hi Jane, review your quote: https://app.test/q/token',
      ),
      mark_quote_sent: rpc('mark_quote_sent', { ...current, status: 'sent' }),
      convert_quote_to_job: rpc('convert_quote_to_job', {
        id: '80000000-0000-4000-8000-000000000009',
        number: 77,
      }),
    },
  });
  await page.route(`${SUPABASE_URL}/functions/v1/**`, async (route) => {
    const request = route.request();
    if (request.method() === 'OPTIONS') {
      return route.fulfill({
        status: 204,
        headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*' },
      });
    }
    const name = new URL(request.url()).pathname.split('/').pop() ?? '';
    captured.functions.push({ name, body: request.postDataJSON() as unknown });
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      headers: { 'access-control-allow-origin': '*' },
      body: JSON.stringify({ message_id: 'm-1', channel: 'sms', status: 'sent', error: null }),
    });
  });
  return captured;
}

test.describe('quotes', () => {
  test('owner opens a draft quote from the list and sends it by text', async ({ page }) => {
    const captured = await setup(page, quote());
    await page.goto('/app/quotes');
    await expect(page.getByRole('heading', { name: 'Quotes', level: 1 })).toBeVisible();
    await page.getByRole('link', { name: 'Quote #1001' }).first().click();

    await expect(page.getByRole('heading', { name: 'Quote #1001', level: 1 })).toBeVisible();
    await expect(
      page.getByRole('list', { name: 'Line items' }).getByText('Full detail'),
    ).toBeVisible();
    await expect(page.getByText('$270.00')).toBeVisible();

    await page.getByRole('button', { name: 'Send quote' }).click();
    const dialog = page.getByRole('dialog', { name: /Send quote #1001/ });
    await expect(dialog.getByRole('textbox', { name: 'Message' })).toHaveValue(
      'Hi Jane, review your quote: https://app.test/q/token',
    );
    await dialog.getByRole('button', { name: 'Send text' }).click();
    await expect(page.getByText('Quote #1001 sent by text')).toBeVisible();

    expect(captured.rpc.map((c) => c.name)).toContain('mark_quote_sent');
    expect(captured.functions).toEqual([
      {
        name: 'messaging',
        body: {
          action: 'send',
          shop_id: SHOP.id,
          customer_id: CUSTOMER.id,
          channel: 'sms',
          body: 'Hi Jane, review your quote: https://app.test/q/token',
        },
      },
    ]);
  });

  test('approved quote converts to a scheduled job', async ({ page }) => {
    const captured = await setup(
      page,
      quote({ status: 'approved', approved_at: '2026-09-21T10:00:00Z' }),
    );
    await page.goto(`/app/quotes/${quote().id}`);
    await expect(page.getByRole('button', { name: 'Edit Full detail' })).toHaveCount(0);
    await page.getByRole('button', { name: 'Convert to job' }).click();
    const dialog = page.getByRole('dialog');
    await dialog.getByLabel('Start date').fill('2026-10-05');
    await dialog.getByRole('button', { name: 'Create job' }).click();
    await expect(page).toHaveURL(/\/app\/jobs\/80000000-0000-4000-8000-000000000009$/);
    const call = captured.rpc.find((c) => c.name === 'convert_quote_to_job');
    // 09:00–12:00 America/Chicago (CDT)
    expect(call?.body).toEqual({
      p_quote_id: quote().id,
      p_start: '2026-10-05T14:00:00.000Z',
      p_end: '2026-10-05T17:00:00.000Z',
    });
  });

  test('quote builder fits a 360px phone', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 740 });
    await setup(page, quote());
    await page.goto(`/app/quotes/${quote().id}`);
    await expect(page.getByRole('heading', { name: 'Quote #1001', level: 1 })).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - window.innerWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
