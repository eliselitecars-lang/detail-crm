import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, SHOP, TECH, type MockUser, type Role } from './support/fixtures';
import {
  mockSupabase,
  reply,
  type Handler,
  type Json,
  type MockReply,
} from './support/mockSupabase';

/**
 * Shop subscription billing on the web (SPEC §4.10, docs/BILLING.md):
 * Settings > Billing, the app-shell banners, and PT402 / HTTP 402 refusals.
 * Every plan, price and date below is test data from the mocked server; the
 * app itself writes none.
 */

const MANAGER: MockUser = {
  id: '00000000-0000-4000-8000-000000000003',
  email: 'manager@glacier.test',
  fullName: 'Mia Manager',
};

const DAY = 86_400_000;
const PT402_MESSAGE =
  "This shop's subscription is inactive, so new records can't be created right now.";
const SEATS_MESSAGE = "This shop's plan allows 3 team members.";

const PLAN = {
  id: '30000000-0000-4000-8000-000000000001',
  name: 'Crew',
  description: 'For a growing team',
  amount_cents: 7900,
  currency: 'usd',
  interval: 'month',
  interval_count: 1,
  max_members: 3,
  features: ['online_booking', 'text_messages'],
};

function entitlement(overrides: Record<string, Json> = {}): Json {
  return {
    billing_enabled: true,
    state: 'trialing',
    reason: 'trial',
    plan_name: null,
    trial_ends_at: new Date(Date.now() + 30 * DAY).toISOString(),
    current_period_end: null,
    cancel_at_period_end: false,
    max_members: null,
    members_used: 2,
    can_write: true,
    is_owner: true,
    ...overrides,
  };
}

function billingRow(overrides: Record<string, Json> = {}): Json {
  return {
    plan_id: null,
    status: 'none',
    trial_ends_at: null,
    current_period_end: null,
    cancel_at_period_end: false,
    ...overrides,
  };
}

interface Setup {
  user?: MockUser;
  role?: Role;
  entitlement?: Json | Handler;
  shopBilling?: Json[] | Handler;
  plans?: Json[];
  billing?: Handler;
  tables?: Record<string, Json[] | Handler>;
  rpc?: Record<string, Json | Handler>;
  functions?: Record<string, Json | MockReply | Handler>;
}

async function setup(page: Page, options: Setup = {}) {
  const user = options.user ?? OWNER;
  await mockSupabase(page, {
    user,
    tables: {
      shop_members: [membershipRow(user, options.role ?? 'owner')],
      notifications: [],
      shop_billing: options.shopBilling ?? [billingRow()],
      ...options.tables,
    },
    rpc: {
      shop_entitlement: options.entitlement ?? entitlement(),
      public_billing_plans: options.plans ?? [PLAN],
      ...options.rpc,
    },
    functions: {
      ...(options.billing ? { billing: options.billing } : {}),
      ...options.functions,
    },
  });
}

const banner = (page: Page) => page.getByLabel('Subscription notice', { exact: true });

test.describe('shop billing', () => {
  test('billing off: nothing to buy, no Billing section, no banner', async ({ page }) => {
    await setup(page, {
      entitlement: entitlement({ billing_enabled: false, state: 'active', reason: 'billing_off' }),
      plans: [],
    });
    await page.goto('/app/settings/billing');
    await expect(page.getByRole('heading', { name: 'Billing', level: 2 })).toBeVisible();
    await expect(page.getByText('Billing isn’t enabled')).toBeVisible();
    await expect(page.getByRole('button', { name: /Choose|Manage billing/ })).toHaveCount(0);
    const nav = page.getByRole('navigation', { name: 'Settings' });
    await expect(nav.getByRole('link', { name: 'Business profile' })).toBeVisible();
    await expect(nav.getByRole('link', { name: 'Billing' })).toHaveCount(0);

    await page.goto('/app/notifications');
    await expect(page.getByRole('heading', { name: 'Notifications', level: 1 })).toBeVisible();
    await expect(banner(page)).toHaveCount(0);
  });

  test('trial: the owner is reminded, sees the server’s plans and checks out on Stripe', async ({
    page,
  }) => {
    const calls: unknown[] = [];
    await setup(page, {
      entitlement: entitlement({ trial_ends_at: new Date(Date.now() + 3 * DAY).toISOString() }),
      billing: ({ body }) => {
        calls.push(body);
        return { url: 'https://checkout.stripe.com/c/pay/cs_test_e2e' };
      },
    });
    await page.route('https://checkout.stripe.com/**', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'text/html',
        body: '<!doctype html><title>Stripe Checkout</title><h1>Stripe Checkout (test)</h1>',
      }),
    );

    await page.goto('/app/notifications');
    await expect(banner(page)).toContainText(/This shop’s trial ends in (2|3) days/);
    await banner(page).getByRole('link', { name: 'Go to Billing' }).click();
    await expect(page).toHaveURL(/\/app\/settings\/billing$/);
    // The billing page shows the same standing in full: no banner there.
    await expect(banner(page)).toHaveCount(0);
    await expect(page.getByText('Trial', { exact: true })).toBeVisible();
    await expect(
      page.getByRole('navigation', { name: 'Settings' }).getByRole('link', { name: 'Billing' }),
    ).toBeVisible();

    const card = page.getByRole('article', { name: 'Crew' });
    await expect(card).toContainText('$79');
    await expect(card).toContainText('per month');
    await expect(card).toContainText('Up to 3 team members');
    await expect(card).toContainText('Online booking');
    await card.getByRole('button', { name: /^Choose Crew/ }).click();
    await expect(page).toHaveURL('https://checkout.stripe.com/c/pay/cs_test_e2e');
    await expect(page.getByRole('heading', { name: 'Stripe Checkout (test)' })).toBeVisible();
    expect(calls).toEqual([
      {
        action: 'checkout',
        shop_id: SHOP.id,
        plan_id: PLAN.id,
        request_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/) as unknown,
      },
    ]);
  });

  test('the trial reminder can be dismissed for the session', async ({ page }) => {
    await setup(page, {
      entitlement: entitlement({ trial_ends_at: new Date(Date.now() + 2 * DAY).toISOString() }),
    });
    await page.goto('/app/notifications');
    await expect(banner(page)).toBeVisible();
    await banner(page).getByRole('button', { name: 'Dismiss for now' }).click();
    await expect(banner(page)).toHaveCount(0);
    await page.reload();
    await expect(page.getByRole('heading', { name: 'Notifications', level: 1 })).toBeVisible();
    await expect(banner(page)).toHaveCount(0);
  });

  test('back from Checkout: waits for Stripe’s webhook, then confirms', async ({ page }) => {
    let reads = 0;
    await setup(page, {
      shopBilling: () => {
        reads += 1;
        // the webhook lands after a couple of polls
        return [reads < 3 ? billingRow() : billingRow({ status: 'active', plan_id: PLAN.id })];
      },
      entitlement: () =>
        reads < 3
          ? entitlement()
          : entitlement({
              state: 'active',
              reason: 'subscribed',
              plan_name: 'Crew',
              trial_ends_at: null,
              current_period_end: new Date(Date.now() + 30 * DAY).toISOString(),
            }),
    });
    await page.goto('/app/settings/billing?checkout=success');
    await expect(page.getByText('Confirming your subscription with Stripe…')).toBeVisible();
    await expect(page).toHaveURL(/\/app\/settings\/billing$/);
    await expect(page.getByText('Thanks! Stripe confirmed your subscription.')).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.getByText('Active', { exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Manage billing' })).toBeVisible();
    await expect(page.getByRole('button', { name: /^Choose/ })).toHaveCount(0);
  });

  test('back from a cancelled Checkout', async ({ page }) => {
    await setup(page);
    await page.goto('/app/settings/billing?checkout=cancelled');
    await expect(
      page.getByText('Checkout was cancelled. No subscription was started.'),
    ).toBeVisible();
    await expect(page).toHaveURL(/\/app\/settings\/billing$/);
  });

  test('lapsed: the owner gets Go to Billing on every page, not dismissible', async ({ page }) => {
    await setup(page, {
      entitlement: entitlement({
        state: 'lapsed',
        reason: 'trial_ended',
        can_write: false,
        trial_ends_at: new Date(Date.now() - 2 * DAY).toISOString(),
      }),
    });
    await page.goto('/app/notifications');
    const alert = banner(page);
    await expect(alert).toHaveAttribute('role', 'alert');
    await expect(alert).toContainText(
      'This shop’s subscription is inactive, so new records can’t be created right now. You can still view everything.',
    );
    await expect(alert.getByRole('button', { name: 'Dismiss for now' })).toHaveCount(0);
    await alert.getByRole('link', { name: 'Go to Billing' }).click();
    await expect(page.getByText('Inactive', { exact: true })).toBeVisible();
    await expect(page.getByText(/Creating new customers, jobs, quotes, invoices/)).toBeVisible();
    await expect(page.getByRole('button', { name: /^Choose Crew/ })).toBeVisible();
  });

  test('lapsed: a technician is told to ask the owner and cannot open Billing', async ({
    page,
  }) => {
    await setup(page, {
      user: TECH,
      role: 'technician',
      entitlement: entitlement({
        state: 'lapsed',
        reason: 'trial_ended',
        can_write: false,
        is_owner: false,
        trial_ends_at: null,
        members_used: null,
      }),
    });
    await page.goto('/app/notifications');
    await expect(banner(page)).toContainText('Ask the shop owner to renew it.');
    await expect(banner(page).getByRole('link')).toHaveCount(0);
    await page.goto('/app/settings/billing');
    await expect(page.getByText('You don’t have access to this page')).toBeVisible();
    await expect(page.getByRole('button', { name: /Choose|Manage billing/ })).toHaveCount(0);
  });

  test('a manager sees the standing read-only', async ({ page }) => {
    await setup(page, {
      user: MANAGER,
      role: 'manager',
      entitlement: entitlement({ state: 'past_due', reason: 'past_due', is_owner: false }),
      shopBilling: [billingRow({ status: 'past_due', plan_id: PLAN.id })],
    });
    await page.goto('/app/settings/billing');
    await expect(page.getByText('Payment problem', { exact: true })).toBeVisible();
    await expect(
      page.getByText('Only the shop owner can choose a plan or change the subscription.'),
    ).toBeVisible();
    await expect(page.getByRole('button', { name: /Choose|Manage billing/ })).toHaveCount(0);
    // payment problems are the owner's to fix: no banner for a manager
    await expect(banner(page)).toHaveCount(0);
  });
});

test.describe('PT402 / HTTP 402 refusals', () => {
  const lapsed = entitlement({ state: 'lapsed', reason: 'trial_ended', can_write: false });

  async function createCustomer(page: Page) {
    await page.goto('/app/customers');
    await page.getByRole('button', { name: 'New customer' }).click();
    const dialog = page.getByRole('dialog', { name: 'New customer' });
    await dialog.getByLabel('First name').fill('Jane');
    await dialog.getByRole('button', { name: 'Add customer' }).click();
    return dialog;
  }

  const refuseInsert: Handler = ({ method }) =>
    method === 'POST'
      ? reply(402, { code: 'PT402', message: PT402_MESSAGE, details: null, hint: null })
      : [];

  test('owner: the server’s message verbatim plus Go to Billing', async ({ page }) => {
    await setup(page, { entitlement: lapsed, tables: { customers: refuseInsert } });
    const dialog = await createCustomer(page);
    const alert = dialog.getByRole('alert');
    await expect(alert).toContainText(PT402_MESSAGE);
    await alert.getByRole('link', { name: 'Go to Billing' }).click();
    await expect(page).toHaveURL(/\/app\/settings\/billing$/);
    await expect(page.getByText('Inactive', { exact: true })).toBeVisible();
  });

  test('manager: the same message, no billing link', async ({ page }) => {
    await setup(page, {
      user: MANAGER,
      role: 'manager',
      entitlement: lapsed,
      tables: { customers: refuseInsert },
    });
    const dialog = await createCustomer(page);
    const alert = dialog.getByRole('alert');
    await expect(alert).toContainText(PT402_MESSAGE);
    await expect(alert.getByRole('link')).toHaveCount(0);
  });

  test('seat limit on an invite (edge 402) shows the plan’s member limit', async ({ page }) => {
    await setup(page, {
      entitlement: entitlement({
        state: 'active',
        reason: 'subscribed',
        plan_name: 'Crew',
        max_members: 3,
        members_used: 3,
      }),
      tables: { shop_invites: [] },
      rpc: { shop_team: [] },
      functions: {
        invites: reply(402, {
          error: SEATS_MESSAGE,
          code: 'payment_required',
          details: { reason: 'seat_limit' },
        }),
      },
    });
    await page.goto('/app/team');
    await page.getByRole('button', { name: 'Invite member' }).click();
    const dialog = page.getByRole('dialog', { name: 'Invite a team member' });
    await dialog.getByRole('textbox', { name: /Email/ }).fill('sam@example.com');
    await dialog.getByRole('button', { name: 'Send invite' }).click();
    const alert = dialog.getByRole('alert');
    await expect(alert).toContainText(SEATS_MESSAGE);
    await expect(alert.getByRole('link', { name: 'Go to Billing' })).toBeVisible();
  });

  test('a refusal shown as a toast carries the owner’s Go to Billing action', async ({ page }) => {
    const inactive = membershipRow(TECH, 'technician');
    await setup(page, {
      entitlement: entitlement({ state: 'active', reason: 'subscribed', max_members: 3 }),
      tables: {
        shop_members: ({ method }) =>
          method === 'PATCH'
            ? reply(402, { code: 'PT402', message: SEATS_MESSAGE, details: null, hint: null })
            : [membershipRow(OWNER, 'owner')],
        shop_invites: [],
      },
      rpc: {
        shop_team: [
          {
            member_id: membershipRow(OWNER, 'owner').id,
            user_id: OWNER.id,
            role: 'owner',
            display_name: OWNER.fullName,
            calendar_color: null,
            active: true,
            phone: null,
            email: OWNER.email,
          },
          {
            member_id: inactive.id,
            user_id: TECH.id,
            role: 'technician',
            display_name: TECH.fullName,
            calendar_color: null,
            active: false,
            phone: null,
            email: TECH.email,
          },
        ],
      },
    });
    await page.goto('/app/team');
    await page.getByRole('button', { name: `Actions for ${TECH.fullName}` }).click();
    await page.getByRole('menuitem', { name: 'Reactivate' }).click();
    await page
      .getByRole('dialog', { name: `Reactivate ${TECH.fullName}?` })
      .getByRole('button', { name: 'Reactivate' })
      .click();
    const toast = page.getByRole('alert').filter({ hasText: SEATS_MESSAGE });
    await expect(toast).toBeVisible();
    await toast.getByRole('button', { name: 'Go to Billing' }).click();
    await expect(page).toHaveURL(/\/app\/settings\/billing$/);
  });
});
