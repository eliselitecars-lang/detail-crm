import { expect, test } from '@playwright/test';
import { mockSupabase, reply } from './support/mockSupabase';

/** Lead-capture form /lead/:token (P-9): questions, honeypot, rate limit, embed. */

const TOKEN = 'abababab-abab-4bab-8bab-abababababab';

const FORM = {
  shop: { name: 'Glacier Detailing', logo_path: null, brand_color: '#1F6FEB' },
  form: {
    name: 'Coating quote',
    headline: 'Get a ceramic coating quote',
    intro: 'Tell us about your car.',
    ask_vehicle: true,
    ask_message: true,
    success_message: 'Thanks! We will reply within a day.',
  },
  fields: [
    {
      key: 'budget',
      label: 'Budget',
      type: 'select',
      options: ['Under $1,000', '$1,000+'],
      help_text: null,
      required: true,
    },
  ],
};

test.describe('lead form', () => {
  test('a visitor sends a request with the shop’s questions answered', async ({ page }) => {
    const submissions: Record<string, unknown>[] = [];
    await mockSupabase(page, {
      rpc: {
        public_get_lead_form: FORM,
        public_submit_lead: ({ body }) => {
          submissions.push(body as Record<string, unknown>);
          return { ok: true, message: FORM.form.success_message };
        },
      },
    });
    await page.goto(`/lead/${TOKEN}`);
    await expect(page.getByRole('heading', { name: 'Get a ceramic coating quote' })).toBeVisible();
    await page.getByRole('button', { name: 'Send' }).click();
    await expect(page.getByText('Budget is required')).toBeVisible();
    expect(submissions).toHaveLength(0);

    await page.getByLabel(/^First name/).fill('Jane');
    await page.getByRole('textbox', { name: 'Phone' }).fill('(205) 555-0142');
    await page.getByLabel('Year').fill('2023');
    await page.getByLabel('Make').fill('Tesla');
    await page.getByLabel('Model').fill('Model Y');
    await page.getByLabel(/^Budget/).selectOption('$1,000+');
    await page.getByLabel('Message').fill('White, daily driver');
    await page.getByRole('button', { name: 'Send' }).click();
    await expect(page.getByRole('heading', { name: 'Thank you!' })).toBeVisible();
    await expect(page.getByText('Thanks! We will reply within a day.')).toBeVisible();

    expect(submissions[0]).toMatchObject({
      p_token: TOKEN,
      p_payload: {
        first_name: 'Jane',
        email: null,
        sms_opt_in: false,
        email_opt_in: false,
        vehicle: { year: 2023, make: 'Tesla', model: 'Model Y' },
        message: 'White, daily driver',
        answers: { budget: '$1,000+' },
      },
    });
    expect(submissions[0]?.p_payload).not.toHaveProperty('website');
  });

  test('explains a repeat request and a missing form', async ({ page }) => {
    await mockSupabase(page, {
      rpc: {
        public_get_lead_form: ({ body }) =>
          (body as { p_token: string }).p_token === TOKEN
            ? { ...FORM, fields: [] }
            : reply(404, { code: 'PT404', message: 'form not found' }),
        public_submit_lead: reply(429, {
          code: 'PT429',
          message:
            'we already received your request; please call the shop if you need anything else',
        }),
      },
    });
    await page.goto(`/lead/${TOKEN}`);
    await page.getByLabel(/^First name/).fill('Jane');
    await page.getByRole('textbox', { name: 'Email' }).fill('jane@example.com');
    await page.getByRole('button', { name: 'Send' }).click();
    await expect(page.getByText('We already have your request')).toBeVisible();

    await page.goto('/lead/12345678-1234-4234-8234-123456789012');
    await expect(page.getByText('This form isn’t available')).toBeVisible();
  });

  test('works at phone width in embed mode', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 740 });
    await mockSupabase(page, { rpc: { public_get_lead_form: FORM } });
    await page.goto(`/lead/${TOKEN}?embed=1`);
    await expect(page.getByRole('heading', { name: 'Get a ceramic coating quote' })).toBeVisible();
    await expect(page.getByRole('banner')).toHaveCount(0);
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
