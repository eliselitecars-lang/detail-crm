import { readFile } from 'node:fs/promises';
import { expect, test } from '@playwright/test';
import { membershipRow, OWNER, TECH } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

const CUSTOMER = '40000000-0000-4000-8000-000000000001';
const INVOICE = '41000000-0000-4000-8000-000000000001';
const SERVICE = '42000000-0000-4000-8000-000000000001';

const revenue = [
  {
    bucket_start: '2026-03-01',
    gross_cents: 50000,
    refunds_cents: 5000,
    net_cents: 45000,
    tips_cents: 2000,
    payments_count: 3,
  },
  {
    bucket_start: '2026-03-02',
    gross_cents: 12500,
    refunds_cents: 0,
    net_cents: 12500,
    tips_cents: 0,
    payments_count: 1,
  },
];

/**
 * report_revenue as the server shapes it: one row per day from p_from through
 * p_to (the client rejects a response that stops early), with the sample
 * payments on the first two days.
 */
function dailyRevenue({ body }: { body: unknown }) {
  const { p_from, p_to } = body as { p_from: string; p_to: string };
  const rows: Record<string, unknown>[] = [];
  for (let d = new Date(`${p_from}T00:00:00Z`); d <= new Date(`${p_to}T00:00:00Z`);) {
    const i = rows.length;
    const sample = revenue[i];
    rows.push({
      ...(sample ?? {
        gross_cents: 0,
        refunds_cents: 0,
        net_cents: 0,
        tips_cents: 0,
        payments_count: 0,
      }),
      bucket_start: d.toISOString().slice(0, 10),
    });
    d = new Date(d.getTime() + 86_400_000);
  }
  return rows as never;
}

const methods = ['card', 'card_present', 'cash', 'check', 'bank_transfer', 'other'].map((m) => ({
  method: m,
  payments_count: m === 'card' ? 3 : m === 'cash' ? 1 : 0,
  gross_cents: m === 'card' ? 50000 : m === 'cash' ? 12500 : 0,
  refunds_cents: m === 'card' ? 5000 : 0,
  net_cents: m === 'card' ? 45000 : m === 'cash' ? 12500 : 0,
  tips_cents: m === 'card' ? 2000 : 0,
  tip_refunds_cents: 0,
  collected_cents: m === 'card' ? 47000 : m === 'cash' ? 12500 : 0,
  deposits_cents: m === 'card' ? 10000 : 0,
  memberships_cents: 0,
}));

const team = (withPay: boolean) => [
  {
    member_id: membershipRow(TECH, 'technician').id,
    display_name: TECH.fullName,
    role: 'technician',
    active: true,
    worked_seconds: 27000,
    hours: 7.5,
    jobs_completed: 2,
    revenue_cents: 60000,
    pre_tax_revenue_cents: 55000,
    hourly_rate_cents: withPay ? 2000 : null,
    commission_bps: withPay ? 1000 : null,
    commission_cents: withPay ? 5500 : null,
    labor_cost_cents: withPay ? 15000 : null,
  },
];

test.describe('reports', () => {
  test('owner reviews revenue, sales, customers and receivables and exports CSV', async ({
    page,
  }) => {
    const calls: { fn: string; body: unknown }[] = [];
    const log =
      (fn: string, result: unknown) =>
      ({ body }: { body: unknown }) => {
        calls.push({ fn, body });
        return result as never;
      };
    await mockSupabase(page, {
      user: OWNER,
      tables: { shop_members: [membershipRow(OWNER, 'owner')], notifications: [] },
      rpc: {
        report_revenue: log('report_revenue', revenue),
        report_payments: log('report_payments', methods),
        report_sales_by_service: log('report_sales_by_service', [
          {
            service_id: SERVICE,
            service_name: 'Full Detail',
            service_kind: 'service',
            category_id: null,
            category_name: 'Exterior',
            quantity: 2,
            jobs_count: 2,
            gross_cents: 50000,
            discount_cents: 2500,
            net_cents: 47500,
          },
          {
            service_id: null,
            service_name: 'Headlight restore',
            service_kind: null,
            category_id: null,
            category_name: null,
            quantity: 1,
            jobs_count: 1,
            gross_cents: 8000,
            discount_cents: 0,
            net_cents: 8000,
          },
        ]),
        report_team: log('report_team', team(true)),
        report_customers: log('report_customers', {
          from: '2026-03-01',
          to: '2026-03-02',
          timezone: 'America/Chicago',
          customers_served: 4,
          new_customers: 3,
          returning_customers: 1,
          customers_created: 5,
          completed_jobs: 4,
          average_ticket_cents: 15625,
          top_customers: [
            {
              customer_id: CUSTOMER,
              name: 'Dana Driver',
              lifetime_net_cents: 125000,
              completed_jobs: 6,
              last_completed_at: '2026-03-02T20:00:00Z',
            },
          ],
        }),
        report_outstanding: log('report_outstanding', {
          as_of: '2026-03-03T18:00:00Z',
          timezone: 'America/Chicago',
          count: 1,
          balance_cents: 20000,
          overdue_count: 1,
          overdue_balance_cents: 20000,
          buckets: [
            { bucket: '0-30', count: 0, balance_cents: 0 },
            { bucket: '31-60', count: 1, balance_cents: 20000 },
            { bucket: '61-90', count: 0, balance_cents: 0 },
            { bucket: '90+', count: 0, balance_cents: 0 },
          ],
          invoices: [
            {
              invoice_id: INVOICE,
              number: 1042,
              status: 'partially_paid',
              customer_id: CUSTOMER,
              customer_name: 'Dana Driver',
              job_id: null,
              issued_at: '2026-01-10T15:00:00Z',
              due_at: '2026-01-24T15:00:00Z',
              total_cents: 30000,
              amount_paid_cents: 10000,
              balance_cents: 20000,
              days_past_due: 38,
              overdue: true,
              bucket: '31-60',
            },
          ],
        }),
      },
    });

    await page.goto('/app/reports?range=custom&from=2026-03-01&to=2026-03-02');
    const tiles = page.getByLabel('Revenue totals');
    await expect(tiles).toContainText('$575.00');
    await expect(tiles).toContainText('$625.00');
    // The chart renders real bars.
    await expect(page.locator('.recharts-bar-rectangle').first()).toBeVisible();
    expect(calls[0]).toEqual({
      fn: 'report_revenue',
      body: {
        p_shop_id: expect.any(String),
        p_from: '2026-03-01',
        p_to: '2026-03-02',
        p_bucket: 'day',
      },
    });

    const downloadPromise = page.waitForEvent('download');
    await page.getByRole('button', { name: 'Export CSV' }).click();
    const download = await downloadPromise;
    expect(download.suggestedFilename()).toBe('revenue_2026-03-01_to_2026-03-02.csv');
    const text = await readFile((await download.path()) ?? '', 'utf8');
    expect(text).toContain('Period start,Payments,Gross,Refunds,Net,Tips');
    expect(text).toContain('2026-03-01,3,500.00,50.00,450.00,20.00');

    await page.getByRole('tab', { name: 'Payments' }).click();
    const payments = page.getByRole('table', { name: 'Payments by method' });
    await expect(payments.getByRole('row', { name: /Card \(online\)/ })).toContainText('$470.00');
    await expect(payments.getByRole('row')).toHaveCount(3); // header + card + cash

    await page.getByRole('tab', { name: 'Sales by service' }).click();
    const sales = page.getByRole('table', { name: 'Sales by service' });
    await expect(sales.getByRole('link', { name: 'Full Detail' })).toHaveAttribute(
      'href',
      `/app/catalog/services/${SERVICE}`,
    );
    await expect(sales).toContainText('Headlight restore');

    await page.getByRole('tab', { name: 'Team' }).click();
    const teamTable = page.getByRole('table', { name: 'Team performance' });
    await expect(
      teamTable.getByRole('columnheader', { name: 'Commission', exact: true }),
    ).toBeVisible();
    await expect(teamTable.getByRole('row', { name: /Theo Tech/ })).toContainText('$55.00');

    await page.getByRole('tab', { name: 'Customers' }).click();
    await expect(page.getByLabel('Customer totals')).toContainText('$156.25');
    await expect(
      page.getByRole('table', { name: 'Top customers' }).getByRole('link', { name: 'Dana Driver' }),
    ).toHaveAttribute('href', `/app/customers/${CUSTOMER}`);

    await page.getByRole('tab', { name: 'Outstanding' }).click();
    const open = page.getByRole('table', { name: 'Open invoices' });
    await expect(open.getByRole('link', { name: '#1042' })).toHaveAttribute(
      'href',
      `/app/invoices/${INVOICE}`,
    );
    await expect(page.getByText('no date range needed', { exact: false })).toBeVisible();
    expect(calls.find((c) => c.fn === 'report_outstanding')?.body).toEqual({
      p_shop_id: expect.any(String),
    });
  });

  test('technician sees only their own numbers', async ({ page }) => {
    const called: string[] = [];
    await mockSupabase(page, {
      user: TECH,
      tables: { shop_members: [membershipRow(TECH, 'technician')], notifications: [] },
      rpc: {
        report_team: () => {
          called.push('report_team');
          return team(true);
        },
        report_revenue: () => {
          called.push('report_revenue');
          return [];
        },
      },
    });
    await page.setViewportSize({ width: 360, height: 780 });
    await page.goto('/app/reports');
    await expect(page.getByRole('heading', { name: 'My numbers' })).toBeVisible();
    await expect(page.getByRole('tablist')).toHaveCount(0);
    await expect(page.getByRole('list', { name: 'Team performance' })).toContainText('7.5 h');
    expect(called).toEqual(['report_team']);
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });

  test('owner reports fit a 360px screen', async ({ page }) => {
    await mockSupabase(page, {
      user: OWNER,
      tables: { shop_members: [membershipRow(OWNER, 'owner')], notifications: [] },
      rpc: { report_revenue: dailyRevenue, report_payments: methods },
    });
    await page.setViewportSize({ width: 360, height: 780 });
    const overflow = () =>
      page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      );
    await page.goto('/app/reports');
    await expect(page.getByRole('img', { name: /Revenue chart/ })).toBeVisible();
    expect(await overflow()).toBeLessThanOrEqual(0);
    await page.getByRole('tab', { name: 'Payments' }).click();
    await expect(page.getByRole('heading', { name: 'Payments by method' })).toBeVisible();
    expect(await overflow()).toBeLessThanOrEqual(0);
  });

  test('custom range errors block the query', async ({ page }) => {
    let queried = false;
    await mockSupabase(page, {
      user: OWNER,
      tables: { shop_members: [membershipRow(OWNER, 'owner')], notifications: [] },
      rpc: {
        report_revenue: () => {
          queried = true;
          return [];
        },
      },
    });
    await page.goto('/app/reports');
    await page.getByRole('combobox', { name: 'Date range' }).selectOption('custom');
    await page.getByLabel('From', { exact: true }).fill('2026-03-10');
    await page.getByLabel('To', { exact: true }).fill('2026-03-01');
    await expect(page.getByText('The end date must be on or after the start date.')).toBeVisible();
    await expect(page.getByText('Choose a valid date range')).toBeVisible();
    queried = false;
    await page.getByLabel('To', { exact: true }).fill('2026-03-20');
    await expect(page.getByText('No payments in this period')).toBeVisible();
    expect(queried).toBe(true);
  });

  test('long ranges cannot be grouped by day (server rows are capped)', async ({ page }) => {
    const buckets: unknown[] = [];
    await mockSupabase(page, {
      user: OWNER,
      tables: { shop_members: [membershipRow(OWNER, 'owner')], notifications: [] },
      rpc: {
        report_revenue: ({ body }: { body: unknown }) => {
          buckets.push((body as { p_bucket: string }).p_bucket);
          return [] as never;
        },
      },
    });
    await page.goto('/app/reports?range=custom&from=2023-01-01&to=2026-09-27&bucket=day');
    await expect(page.getByText('No payments in this period')).toBeVisible();
    expect(buckets).toEqual(['month']);
    const groupBy = page.getByRole('combobox', { name: 'Group by' });
    await expect(groupBy).toHaveValue('month');
    await expect(groupBy.getByRole('option', { name: 'Daily (range too long)' })).toBeDisabled();
    await groupBy.selectOption('week');
    await expect.poll(() => buckets.at(-1)).toBe('week');
  });
});
