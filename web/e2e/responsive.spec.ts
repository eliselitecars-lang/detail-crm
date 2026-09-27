import { expect, test, type Page } from '@playwright/test';
import { OWNER } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

/** Phone-width regressions: no screen may scroll sideways at 360px. */

const PHONE = { width: 360, height: 740 };

async function horizontalOverflow(page: Page): Promise<number> {
  return page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
}

/** Every matching element's box must sit inside `container`'s box. */
async function expectInside(page: Page, selector: string, container: string) {
  const outside = await page.evaluate(
    ({ selector, container }) => {
      const box = document.querySelector(container)?.getBoundingClientRect();
      if (!box) return ['<container missing>'];
      return Array.from(document.querySelectorAll(selector))
        .filter((el) => {
          const r = el.getBoundingClientRect();
          return r.left < box.left - 0.5 || r.right > box.right + 0.5;
        })
        .map((el) => el.getAttribute('aria-label') ?? el.textContent ?? el.tagName);
    },
    { selector, container },
  );
  expect(outside).toEqual([]);
}

test.describe('360px layouts', () => {
  test.use({ viewport: PHONE });

  test('onboarding business hours fit inside the card', async ({ page }) => {
    await mockSupabase(page, { user: OWNER, tables: { shop_members: [] } });
    await page.goto('/app/onboarding');
    await page.getByLabel(/Shop name/).fill('Glacier Detailing');
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.getByRole('heading', { name: 'Contact & location' })).toBeVisible();
    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.getByRole('heading', { name: 'Taxes & hours' })).toBeVisible();

    // Worst case: two ranges on a day (remove + add buttons on the same day).
    await page.getByRole('button', { name: 'Add time range for Monday' }).click();
    await expect(page.getByLabel('Monday opens at')).toHaveCount(2);

    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    await expectInside(page, 'form [role="switch"], form button, form input', 'form');
    // Native time inputs clip "08:00 AM" silently (no overflow), so assert a
    // usable width: the pair shares the row instead of being squeezed.
    const widths = await page
      .locator('input[type="time"]')
      .evaluateAll((inputs) => inputs.map((input) => input.getBoundingClientRect().width));
    expect(widths.length).toBeGreaterThan(0);
    for (const width of widths) expect(width).toBeGreaterThanOrEqual(112);
  });

  const token = '6f1c2f7e-4c9b-4f55-9d7a-0b3e2a1c9d10';
  const longEmail = 'christopher.washington-montgomery@detailprofessionals.example.com';
  const invite = {
    shop_name: 'Glacier Detailing',
    shop_slug: 'glacier-detailing',
    role: 'technician',
    email: longEmail,
    expires_at: '2030-01-01T00:00:00Z',
    status: 'pending',
  };

  test('invite page wraps long email addresses (signed out)', async ({ page }) => {
    await mockSupabase(page, { rpc: { public_get_invite: [invite] } });
    await page.goto(`/invite/${token}`);
    await expect(page.getByRole('heading', { name: 'Join Glacier Detailing' })).toBeVisible();
    await expect(page.getByText(longEmail).first()).toBeVisible();
    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    await expectInside(page, 'dt, dd, p', 'main');
  });

  test('invite email-mismatch alert wraps long addresses (signed in)', async ({ page }) => {
    await mockSupabase(page, { user: OWNER, rpc: { public_get_invite: [invite] } });
    await page.goto(`/invite/${token}`);
    await expect(page.getByRole('alert')).toContainText('signed in as');
    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    await expectInside(page, '[role="alert"], dd', 'main');
  });
});
