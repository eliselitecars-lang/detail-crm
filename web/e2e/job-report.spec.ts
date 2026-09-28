import { expect, test } from '@playwright/test';
import { mockSupabase, reply, SUPABASE_URL, type Json } from './support/mockSupabase';

/** Customer job report /r/:token (P-8, P-25, P-30): media, documents, remote sign-off. */

const TOKEN = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const SHOP = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const PRE = '12121212-1212-4121-8121-121212121212';

// 1×1 transparent PNG so <img> elements load without a real server.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  'base64',
);
const signed = (name: string) =>
  `${SUPABASE_URL}/storage/v1/object/sign/job-photos/${name}?token=t`;

function report(signedBy: string | null) {
  return {
    shop: {
      name: 'Glacier Detailing',
      logo_path: null,
      brand_color: '#1F6FEB',
      phone: '+12055550100',
      email: null,
      review_url: null,
    },
    job: {
      number: 1042,
      status: 'completed',
      completed_at: '2026-09-20T20:00:00Z',
      local_date: '2026-09-20',
    },
    vehicle: { year: 2021, make: 'Toyota', model: 'Camry', color: 'Blue' },
    services: ['Full detail'],
    message: null,
    published_at: '2026-09-20T21:00:00Z',
    photos: [
      {
        id: 'p1',
        kind: 'before',
        caption: 'Hood before',
        media_type: 'image',
        duration_seconds: null,
        has_poster: false,
        created_at: '2026-09-20T15:00:00Z',
      },
      {
        id: 'p2',
        kind: 'after',
        caption: 'Hood after',
        media_type: 'image',
        duration_seconds: null,
        has_poster: false,
        created_at: '2026-09-20T19:00:00Z',
      },
    ],
    inspections: [
      {
        id: PRE,
        kind: 'pre',
        mileage: 45210,
        fuel_level: 50,
        marks: [
          {
            id: 'm1',
            view: 'left',
            x: 0.4,
            y: 0.5,
            damage: 'scratch',
            note: 'Door scratch',
            has_photo: false,
          },
        ],
        signed_at: signedBy ? '2026-09-21T10:00:00Z' : null,
        signed_by_name: signedBy,
        signed_remotely: signedBy !== null,
        can_acknowledge: signedBy === null,
      },
    ],
    documents: [],
    signature_upload_prefix: signedBy ? null : `${SHOP}/reports/${TOKEN}/`,
  };
}

test('a customer reviews the report and signs the inspection remotely', async ({ page }) => {
  const acks: Record<string, unknown>[] = [];
  const uploads: string[] = [];
  await mockSupabase(page, {
    rpc: {
      public_get_job_report: report(null),
      public_ack_inspection: ({ body }) => {
        acks.push(body as Record<string, unknown>);
        return report('Jane Doe');
      },
    },
    functions: {
      'public-media': ({ body }) =>
        (body as { token: string }).token === TOKEN
          ? {
              expires_in: 600,
              items: [
                { ref_id: 'p1', kind: 'photo', url: signed('p1.png') },
                { ref_id: 'p2', kind: 'photo', url: signed('p2.png') },
              ],
            }
          : reply(404, { error: 'This report link is no longer available.', code: 'not_found' }),
    },
    storage: ({ url, method }): Json => {
      if (method === 'POST' && url.pathname.includes('/object/signatures/')) {
        uploads.push(url.pathname);
        return { Key: url.pathname };
      }
      return {};
    },
  });
  await page.route(`${SUPABASE_URL}/storage/v1/object/sign/**`, (route) =>
    route.fulfill({ status: 200, contentType: 'image/png', body: PNG }),
  );
  await page.goto(`/r/${TOKEN}`);
  await expect(page.getByRole('heading', { name: 'Your job report', level: 1 })).toBeVisible();
  await expect(page.getByRole('img', { name: 'Hood after' })).toHaveAttribute(
    'src',
    signed('p2.png'),
  );
  await expect(page.getByText('Door scratch')).toBeVisible();

  const form = page.getByRole('form', { name: 'Review and sign' });
  await form.getByRole('textbox', { name: /Your full name/ }).fill('Jane Doe');
  const pad = form.getByRole('img', { name: /Your signature/ });
  await pad.scrollIntoViewIfNeeded();
  const box = await pad.boundingBox();
  if (!box) throw new Error('signature pad not visible');
  await page.mouse.move(box.x + 20, box.y + 20);
  await page.mouse.down();
  await page.mouse.move(box.x + 120, box.y + 60, { steps: 8 });
  await page.mouse.move(box.x + 200, box.y + 30, { steps: 8 });
  await page.mouse.up();
  await form.getByRole('button', { name: 'Sign inspection' }).click();

  await expect(page.getByText('Signed by Jane Doe')).toBeVisible();
  await expect(page.getByRole('form', { name: 'Review and sign' })).toHaveCount(0);
  expect(uploads[0]).toMatch(new RegExp(`/object/signatures/${SHOP}/reports/${TOKEN}/signature-`));
  expect(acks[0]).toMatchObject({
    p_token: TOKEN,
    p_inspection_id: PRE,
    p_signer_name: 'Jane Doe',
  });
  expect(String(acks[0]?.p_signature_path)).toMatch(
    new RegExp(`^${SHOP}/reports/${TOKEN}/signature-[0-9a-f-]+\\.png$`),
  );
});

test('a revoked report link explains itself', async ({ page }) => {
  await mockSupabase(page, {
    rpc: { public_get_job_report: reply(404, { code: 'PT404', message: 'job report not found' }) },
  });
  await page.goto(`/r/${TOKEN}`);
  await expect(page.getByText('We couldn’t find this job report')).toBeVisible();
});
