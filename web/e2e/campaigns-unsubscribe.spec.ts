import { expect, test, type Page } from '@playwright/test';
import { mockSupabase, reply, type Json, type MockReply } from './support/mockSupabase';

const TOKEN = '40000000-0000-4000-8000-0000000000aa';
const STILL_SENT = 'booking confirmations, appointment reminders, quotes, invoices and receipts';

interface Info {
  shop_name: string;
  shop_logo_path: string | null;
  unsubscribed: boolean;
  scope: 'marketing' | 'all' | null;
  can_resubscribe: boolean;
}

const INFO: Info = {
  shop_name: 'Glacier Detailing',
  shop_logo_path: null,
  unsubscribed: false,
  scope: null,
  can_resubscribe: true,
};

/**
 * A mocked server with the 0126 rules (public_unsubscribe: marketing only,
 * public_unsubscribe_all: everything, public_resubscribe: lifts any scope
 * while a current customer has the address). Records every call in order.
 */
async function serve(
  page: Page,
  initial: Partial<Info> = {},
  overrides: Record<string, MockReply> = {},
) {
  const state: Info = { ...INFO, ...initial };
  const calls: { fn: string; body: unknown }[] = [];
  const handler =
    (fn: string, change: () => Json) =>
    ({ body }: { body: unknown }): Json | MockReply => {
      calls.push({ fn, body });
      return overrides[fn] ?? change();
    };
  await mockSupabase(page, {
    rpc: {
      public_unsubscribe_info: handler('public_unsubscribe_info', () => ({ ...state })),
      public_unsubscribe: handler('public_unsubscribe', () => {
        if (state.scope !== 'all') Object.assign(state, { unsubscribed: true, scope: 'marketing' });
        return true;
      }),
      public_unsubscribe_all: handler('public_unsubscribe_all', () => {
        Object.assign(state, { unsubscribed: true, scope: 'all' });
        return true;
      }),
      public_resubscribe: handler('public_resubscribe', () => {
        if (!state.can_resubscribe) return false;
        Object.assign(state, { unsubscribed: false, scope: null });
        return true;
      }),
    },
  });
  return { state, fns: () => calls.map((c) => c.fn), calls };
}

test.describe('campaign email unsubscribe page', () => {
  test('an anonymous visitor is told marketing stops (not receipts), confirms and is unsubscribed', async ({
    page,
  }) => {
    const server = await serve(page);
    await page.goto(`/u/${TOKEN}`);
    await expect(
      page.getByRole('heading', { name: 'Unsubscribe from Glacier Detailing marketing emails' }),
    ).toBeVisible();
    // 0126: the link ends marketing only; say so before the click.
    await expect(page.getByText(/campaigns, promotions and service follow-ups/)).toBeVisible();
    await expect(
      page.getByText(`You’ll still get ${STILL_SENT} from Glacier Detailing.`),
    ).toBeVisible();
    // Opening the link (scanners, prefetchers) never changes anything.
    expect(server.fns()).toEqual(['public_unsubscribe_info']);

    await page.getByRole('button', { name: 'Unsubscribe' }).click();
    await expect(page.getByRole('heading', { name: 'You’re unsubscribed' })).toBeFocused();
    await expect(
      page.getByText(/Glacier Detailing won’t send marketing emails .* to this address any more/),
    ).toBeVisible();
    await expect(
      page.getByText(`You’ll still get ${STILL_SENT} from them.`, { exact: false }),
    ).toBeVisible();
    expect(server.calls[1]).toEqual({ fn: 'public_unsubscribe', body: { p_token: TOKEN } });
    // The page shows the server's state, read again after the change.
    expect(server.fns()).toEqual([
      'public_unsubscribe_info',
      'public_unsubscribe',
      'public_unsubscribe_info',
    ]);
    await expect(
      page.getByRole('button', { name: 'Resubscribe to marketing emails' }),
    ).toBeVisible();
  });

  test('the visitor resubscribes to marketing emails', async ({ page }) => {
    const server = await serve(page, { unsubscribed: true, scope: 'marketing' });
    await page.goto(`/u/${TOKEN}`);
    await page.getByRole('button', { name: 'Resubscribe to marketing emails' }).click();
    await expect(page.getByRole('heading', { name: 'You’re subscribed again' })).toBeFocused();
    await expect(
      page.getByText('Glacier Detailing can send marketing emails to this address again', {
        exact: false,
      }),
    ).toBeVisible();
    await expect(page.getByRole('button', { name: 'Unsubscribe' })).toBeVisible();
    expect(server.calls).toContainEqual({ fn: 'public_resubscribe', body: { p_token: TOKEN } });
    expect(server.state.scope).toBeNull();
  });

  test('stopping all emails needs a confirmation that says what else stops', async ({ page }) => {
    const server = await serve(page, { unsubscribed: true, scope: 'marketing' });
    await page.goto(`/u/${TOKEN}`);
    await page.getByRole('button', { name: 'Stop all emails from Glacier Detailing' }).click();
    const dialog = page.getByRole('alertdialog', {
      name: 'Stop all emails from Glacier Detailing?',
    });
    await expect(dialog).toContainText(
      `You’ll also stop getting ${STILL_SENT} from Glacier Detailing at this address, not just marketing emails.`,
    );
    await dialog.getByRole('button', { name: 'Cancel' }).click();
    await expect(dialog).toBeHidden();
    expect(server.fns()).toEqual(['public_unsubscribe_info']);

    await page.getByRole('button', { name: 'Stop all emails from Glacier Detailing' }).click();
    await dialog.getByRole('button', { name: 'Stop all emails' }).click();
    await expect(dialog).toBeHidden();
    await expect(
      page.getByRole('heading', { name: 'You’re unsubscribed from all emails' }),
    ).toBeFocused();
    await expect(
      page.getByText(
        `This address is opted out of all emails from Glacier Detailing, including ${STILL_SENT}.`,
      ),
    ).toBeVisible();
    expect(server.calls).toContainEqual({ fn: 'public_unsubscribe_all', body: { p_token: TOKEN } });
    // From there, the server allows lifting everything again.
    await page.getByRole('button', { name: 'Resubscribe to all Glacier Detailing emails' }).click();
    await expect(page.getByRole('heading', { name: 'You’re subscribed again' })).toBeVisible();
  });

  test('a rate-limited answer is shown plainly and changes nothing', async ({ page }) => {
    const server = await serve(
      page,
      { unsubscribed: true, scope: 'marketing' },
      {
        public_unsubscribe_all: reply(429, {
          code: 'PT429',
          message: 'too many requests',
          details: null,
          hint: null,
        }),
      },
    );
    await page.goto(`/u/${TOKEN}`);
    await page.getByRole('button', { name: 'Stop all emails from Glacier Detailing' }).click();
    const dialog = page.getByRole('alertdialog', {
      name: 'Stop all emails from Glacier Detailing?',
    });
    await dialog.getByRole('button', { name: 'Stop all emails' }).click();
    await expect(dialog.getByRole('alert')).toHaveText(
      'Too many requests from your connection. Wait a minute, then try again.',
    );
    expect(server.state.scope).toBe('marketing');
  });

  test('an address nobody can resubscribe keeps the different-address advice', async ({ page }) => {
    await serve(page, { unsubscribed: true, scope: 'all', can_resubscribe: false });
    await page.goto(`/u/${TOKEN}`);
    await expect(
      page.getByRole('heading', { name: 'You’re unsubscribed from all emails' }),
    ).toBeVisible();
    await expect(page.getByText(/give them a different email address/)).toBeVisible();
    // Only the page's own content: the dev server's query devtools add a button
    // outside <main> once they have loaded.
    await expect(page.getByRole('main').getByRole('button')).toHaveCount(0);
  });

  test('an unknown link (PT404) says so, and fits a 360px screen', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 740 });
    await mockSupabase(page, {
      rpc: {
        public_unsubscribe_info: reply(404, {
          code: 'PT404',
          message: 'unsubscribe link not found',
          details: null,
          hint: null,
        }),
      },
    });
    await page.goto(`/u/${TOKEN}`);
    await expect(
      page.getByRole('heading', { name: 'This unsubscribe link isn’t valid' }),
    ).toBeVisible();
    await expect(page.getByRole('button', { name: 'Unsubscribe' })).toHaveCount(0);
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
