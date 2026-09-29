import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, type Role } from './support/fixtures';
import { mockSupabase, reply, type Json, type MockReply } from './support/mockSupabase';

/**
 * A customer's deletion request goes through payments → erase_customer
 * (owner / admin): the dialog first shows the server's dry run (delete, or
 * anonymise when records reference the customer, and what is in the way),
 * then confirms. The web never deletes the customers row itself.
 */
const SHOP_ID = '10000000-0000-4000-8000-000000000001';
const CUSTOMER = {
  id: '30000000-0000-4000-8000-000000000011',
  shop_id: SHOP_ID,
  first_name: 'Jane',
  last_name: 'Doe',
  company: null,
  email: 'jane.doe@example.com',
  phone: '+12055550123',
  address_line1: '1 Main St',
  address_line2: null,
  city: 'Birmingham',
  region: 'AL',
  postal_code: '35203',
  country: 'US',
  lat: null,
  lng: null,
  notes: null,
  tags: [],
  lifecycle: 'customer',
  source: 'staff',
  sms_opt_in: false,
  email_opt_in: false,
  portal_user_id: null,
  stripe_customer_id: null,
  archived_at: null,
  erased_at: null,
  merged_into_id: null,
  created_at: '2026-01-05T15:00:00Z',
  updated_at: '2026-01-05T15:00:00Z',
  search_text: 'jane doe',
  sms_opted_out_at: null,
  email_opted_out_at: null,
};

const PREVIEW = {
  dry_run: true,
  mode: 'deleted',
  erased: false,
  membership_active: false,
  payments_in_progress: 0,
  open_checkouts: 0,
  saved_cards: 0,
};

interface Recorded {
  /** Bodies sent to the payments function, in order. */
  calls: Record<string, unknown>[];
  /** Direct DELETEs on customers (there must be none: the server erases). */
  tableDeletes: string[];
}

async function setup(
  page: Page,
  role: Role,
  {
    preview = {},
    confirm,
  }: {
    preview?: Record<string, Json>;
    /** What the confirmed call answers (default: erased in the preview's mode). */
    confirm?: Json | MockReply;
  } = {},
): Promise<Recorded> {
  const recorded: Recorded = { calls: [], tableDeletes: [] };
  const dryRun = { ...PREVIEW, ...preview };
  await mockSupabase(page, {
    user: OWNER,
    tables: {
      shop_members: [membershipRow(OWNER, role)],
      notifications: [],
      vehicles: [],
      customers: ({ method, url }) => {
        if (method === 'DELETE') recorded.tableDeletes.push(url.search);
        const id = url.searchParams.get('id');
        return id === `eq.${CUSTOMER.id}` || id === null ? [CUSTOMER] : [];
      },
    },
    functions: {
      payments: ({ body }) => {
        const call = body as Record<string, unknown>;
        recorded.calls.push(call);
        if (call.action !== 'erase_customer') return reply(400, { error: 'unexpected action' });
        if (call.confirm !== true) return dryRun;
        return (
          confirm ?? {
            erased: true,
            mode: dryRun.mode,
            payments_cancelled: dryRun.payments_in_progress,
            sessions_expired: dryRun.open_checkouts,
            cards_removed: dryRun.saved_cards,
            stripe_customers_deleted: 0,
          }
        );
      },
    },
  });
  return recorded;
}

const detailPath = `/app/customers/${CUSTOMER.id}`;
const previewCall = { action: 'erase_customer', shop_id: SHOP_ID, customer_id: CUSTOMER.id };
const confirmCall = { ...previewCall, confirm: true };

test.describe('customers — deletion request', () => {
  test('owner deletes a customer without records after the preview', async ({ page }) => {
    const recorded = await setup(page, 'owner');
    await page.goto(detailPath);
    await expect(page.getByRole('heading', { name: 'Jane Doe', level: 1 })).toBeVisible();

    await page.getByRole('button', { name: 'Delete', exact: true }).click();
    const dialog = page.getByRole('alertdialog', { name: 'Delete Jane Doe?' });
    await expect(dialog.getByText(/deleted for good/)).toBeVisible();
    await expect(
      dialog.getByText(/vehicles, quotes, messages, files and form answers/),
    ).toBeVisible();
    await dialog.getByRole('button', { name: 'Delete customer' }).click();

    await expect(page.getByText('Jane Doe deleted')).toBeVisible();
    await expect(page).toHaveURL(/\/app\/customers$/);
    expect(recorded.calls).toEqual([previewCall, confirmCall]);
    expect(recorded.tableDeletes).toEqual([]);
  });

  test('admin anonymises a customer with records; saved cards and open pages are cleared first', async ({
    page,
  }) => {
    const recorded = await setup(page, 'admin', {
      preview: { mode: 'anonymised', saved_cards: 1, open_checkouts: 2 },
    });
    await page.goto(detailPath);
    await page.getByRole('button', { name: 'Delete', exact: true }).click();

    const dialog = page.getByRole('alertdialog', { name: 'Anonymise Jane Doe?' });
    await expect(
      dialog.getByText(/kept for your books without their personal details/),
    ).toBeVisible();
    await expect(
      dialog.getByText('1 saved card is removed from your Stripe account.'),
    ).toBeVisible();
    await expect(
      dialog.getByText(/2 payment pages \(pay or deposit links\) are still open/),
    ).toBeVisible();
    await expect(dialog.getByRole('button', { name: 'Delete customer' })).toHaveCount(0);
    await dialog.getByRole('button', { name: 'Anonymise customer' }).click();

    await expect(page.getByText('Jane Doe anonymised')).toBeVisible();
    await expect(
      page.getByText(
        'Their invoices, payments and job history are kept without their personal details.',
      ),
    ).toBeVisible();
    await expect(page).toHaveURL(/\/app\/customers$/);
    expect(recorded.calls).toEqual([previewCall, confirmCall]);
    expect(recorded.tableDeletes).toEqual([]);
  });

  test('a refusal is explained and nothing is left half done on the page', async ({ page }) => {
    const recorded = await setup(page, 'owner', {
      confirm: reply(409, {
        error: 'A card payment page for this customer was opened meanwhile. Try again in a moment.',
        code: 'conflict',
        details: { reason: 'checkout_open' },
      }),
    });
    await page.goto(detailPath);
    await page.getByRole('button', { name: 'Delete', exact: true }).click();
    const dialog = page.getByRole('alertdialog', { name: 'Delete Jane Doe?' });
    await dialog.getByRole('button', { name: 'Delete customer' }).click();

    const alert = dialog.getByRole('alert');
    await expect(alert).toContainText(
      'A payment page for this customer was opened while deleting.',
    );
    await expect(alert).toContainText('The customer’s record wasn’t changed.');
    await expect(page).toHaveURL(new RegExp(`${detailPath}$`));
    // the dialog asks for a fresh preview after a refusal
    await expect.poll(() => recorded.calls.length).toBe(3);
    expect(recorded.calls).toEqual([previewCall, confirmCall, previewCall]);
    expect(recorded.tableDeletes).toEqual([]);
  });

  test('an active membership blocks the request until it is cancelled', async ({ page }) => {
    const recorded = await setup(page, 'owner', {
      preview: { mode: 'anonymised', membership_active: true },
    });
    await page.goto(detailPath);
    await page.getByRole('button', { name: 'Delete', exact: true }).click();
    const dialog = page.getByRole('alertdialog', { name: 'Anonymise Jane Doe?' });
    await expect(dialog.getByRole('alert')).toContainText('Cancel it on the Memberships tab first');
    await expect(dialog.getByRole('button', { name: 'Anonymise customer' })).toBeDisabled();
    await dialog.getByRole('button', { name: 'Cancel' }).click();
    await expect(dialog).toBeHidden();
    expect(recorded.calls).toEqual([previewCall]);
  });

  test('managers do not see Delete', async ({ page }) => {
    const recorded = await setup(page, 'manager');
    await page.goto(detailPath);
    await expect(page.getByRole('heading', { name: 'Jane Doe', level: 1 })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Edit' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Delete', exact: true })).toHaveCount(0);
    expect(recorded.calls).toEqual([]);
  });
});
