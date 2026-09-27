import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, SHOP, TECH } from './support/fixtures';
import { mockSupabase, SUPABASE_URL } from './support/mockSupabase';

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type Row = { [key: string]: Json };

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': '*',
  'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
};

const ownerMember = membershipRow(OWNER, 'owner');
const techMember = membershipRow(TECH, 'technician');

const TEAM: Json[] = [
  {
    member_id: ownerMember.id,
    user_id: OWNER.id,
    role: 'owner',
    display_name: OWNER.fullName,
    calendar_color: null,
    active: true,
    phone: null,
    email: null,
  },
  {
    member_id: techMember.id,
    user_id: TECH.id,
    role: 'technician',
    display_name: TECH.fullName,
    calendar_color: null,
    active: true,
    phone: null,
    email: null,
  },
];

const JOB_ID = '40000000-0000-4000-8000-000000000001';
const CUSTOMER_ID = '30000000-0000-4000-8000-000000000001';
const VEHICLE_ID = '31000000-0000-4000-8000-000000000001';
const SERVICE_ID = '32000000-0000-4000-8000-000000000001';
const CATEGORY_ID = '33000000-0000-4000-8000-000000000001';

const CUSTOMER: Row = {
  id: CUSTOMER_ID,
  first_name: 'Jane',
  last_name: 'Doe',
  company: null,
  email: 'jane@example.com',
  phone: '+12055550123',
  address_line1: '1 Main St',
  address_line2: null,
  city: 'Birmingham',
  region: 'AL',
  postal_code: '35203',
  sms_opted_out_at: null,
  email_opted_out_at: null,
};

const VEHICLE: Row = {
  id: VEHICLE_ID,
  year: 2021,
  make: 'Honda',
  model: 'Civic',
  trim: null,
  color: 'Blue',
  vin: null,
  license_plate: 'ABC123',
  category_id: CATEGORY_ID,
};

function jobRow(overrides: Row = {}): Row {
  return {
    id: JOB_ID,
    shop_id: SHOP.id,
    number: 1001,
    customer_id: CUSTOMER_ID,
    vehicle_id: VEHICLE_ID,
    status: 'scheduled',
    scheduled_start: '2026-09-28T14:00:00Z',
    scheduled_end: '2026-09-28T16:00:00Z',
    location_type: 'mobile',
    service_address_line1: '1 Main St',
    service_address_line2: null,
    service_city: 'Birmingham',
    service_region: 'AL',
    service_postal_code: '35203',
    resource_id: null,
    notes: null,
    internal_notes: null,
    source: 'staff',
    quote_id: null,
    coupon_id: null,
    discount_kind: 'none',
    discount_value: 0,
    subtotal_cents: 24000,
    discount_cents: 0,
    tax_rate_bps: 0,
    tax_cents: 0,
    total_cents: 24000,
    deposit_required_cents: 0,
    created_at: '2026-09-20T15:00:00Z',
    updated_at: '2026-09-20T15:00:00Z',
    confirmed_at: null,
    en_route_at: null,
    started_at: null,
    completed_at: null,
    cancelled_at: null,
    cancel_reason: null,
    reminder_sent_at: null,
    review_requested_at: null,
    customer: CUSTOMER,
    vehicle: VEHICLE,
    ...overrides,
  };
}

const EDGES: [string, string, 'forward' | 'backward', boolean][] = [
  ['scheduled', 'confirmed', 'forward', false],
  ['scheduled', 'en_route', 'forward', true],
  ['scheduled', 'in_progress', 'forward', true],
  ['scheduled', 'cancelled', 'forward', false],
  ['scheduled', 'no_show', 'forward', false],
  ['confirmed', 'en_route', 'forward', true],
  ['confirmed', 'scheduled', 'backward', false],
];
const TRANSITIONS: Json[] = EDGES.map(
  ([from_status, to_status, direction, technician_allowed]) => ({
    from_status,
    to_status,
    direction,
    technician_allowed,
  }),
);

const LINE: Row = {
  id: '41000000-0000-4000-8000-000000000001',
  service_id: SERVICE_ID,
  vehicle_id: VEHICLE_ID,
  name: 'Full detail',
  description: null,
  quantity: 1,
  unit_price_cents: 24000,
  discount_cents: 0,
  taxable: true,
  duration_minutes: 150,
  sort: 1,
  total_cents: 24000,
};

const SUMMARY: Row = {
  job_id: JOB_ID,
  invoice_id: null,
  invoice_number: null,
  invoice_status: null,
  total_cents: 24000,
  deposit_required_cents: 0,
  deposit_paid_cents: 0,
  deposit_due_cents: 0,
  paid_cents: 0,
  tip_cents: 0,
  refunded_cents: 0,
  pending_cents: 0,
  balance_cents: 24000,
};

/** Storage API double: records uploads, signs any path. */
async function mockStorage(page: Page, uploads: string[]) {
  await page.route(`${SUPABASE_URL}/storage/v1/**`, async (route) => {
    const request = route.request();
    if (request.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS });
    const url = new URL(request.url());
    if (url.pathname.includes('/object/sign/')) {
      const body = (request.postDataJSON() ?? {}) as { paths?: string[] };
      return route.fulfill({
        status: 200,
        headers: CORS,
        contentType: 'application/json',
        body: JSON.stringify(
          (body.paths ?? []).map((path) => ({
            path,
            signedURL: `/object/sign/job-photos/${path}?token=t`,
            error: null,
          })),
        ),
      });
    }
    const match = /\/storage\/v1\/object\/job-photos\/(.+)$/.exec(url.pathname);
    if (request.method() === 'POST' && match?.[1]) {
      uploads.push(decodeURIComponent(match[1]));
      return route.fulfill({
        status: 200,
        headers: CORS,
        contentType: 'application/json',
        body: JSON.stringify({ Key: `job-photos/${match[1]}`, Id: 'obj-1' }),
      });
    }
    return route.fulfill({
      status: 200,
      headers: CORS,
      contentType: 'application/json',
      body: '[]',
    });
  });
}

/** Table handlers for the job detail page. */
function detailTables(job: Row, patches: Row[], photos: Row[]) {
  return {
    notifications: [],
    jobs: ({ method, body }: { method: string; body: unknown }) => {
      if (method === 'PATCH') {
        patches.push(body as Row);
        Object.assign(job, body as Row);
        return [{ id: JOB_ID }];
      }
      return [job];
    },
    job_status_transitions: TRANSITIONS,
    job_line_items: [LINE],
    job_assignments: [{ id: 'a-1', member_id: techMember.id }],
    job_checklist_items: [],
    job_photos: ({ method, body }: { method: string; body: unknown }) => {
      if (method === 'POST') {
        const row = body as Row;
        photos.push({
          id: `p-${photos.length + 1}`,
          storage_path: row.storage_path ?? '',
          kind: row.kind ?? 'other',
          caption: null,
          uploaded_by: OWNER.id,
          created_at: '2026-09-28T15:00:00Z',
        });
        return [];
      }
      return photos;
    },
    inspections: [],
    form_submissions: [],
    time_entries: [],
    messages: [],
    resources: [],
  };
}

test.describe('jobs', () => {
  test.use({ timezoneId: 'Pacific/Honolulu' });

  test('owner creates a job from a calendar slot with catalog pricing', async ({ page }) => {
    const inserted: Record<string, unknown[]> = {
      jobs: [],
      job_line_items: [],
      job_assignments: [],
    };
    const job = jobRow({ location_type: 'shop' });
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        ...detailTables(job, [], []),
        shop_members: [ownerMember],
        customers: [CUSTOMER],
        vehicles: [VEHICLE],
        vehicle_categories: [{ id: CATEGORY_ID, name: 'Car', sort: 1 }],
        services: [
          {
            id: SERVICE_ID,
            name: 'Full detail',
            kind: 'service',
            duration_minutes: 150,
            category_id: null,
            description: null,
            sort: 1,
          },
        ],
        service_categories: [],
        jobs: ({ method, body }) => {
          if (method === 'POST') {
            inserted.jobs?.push(body);
            return [{ id: JOB_ID }];
          }
          return [job];
        },
        job_line_items: ({ method, body }) => {
          if (method === 'POST') inserted.job_line_items?.push(body);
          return [LINE];
        },
        job_assignments: ({ method, body }) => {
          if (method === 'POST') inserted.job_assignments?.push(body);
          return [{ id: 'a-1', member_id: techMember.id }];
        },
      },
      rpc: {
        shop_team: TEAM,
        job_payment_summary: [SUMMARY],
        price_services: {
          vehicle_category_id: CATEGORY_ID,
          tax_rate_bps: 0,
          duration_minutes: 150,
          priced: true,
          lines: [
            {
              service_id: SERVICE_ID,
              name: 'Full detail',
              kind: 'service',
              taxable: true,
              duration_minutes: 150,
              catalog_price_cents: 24000,
              unit_price_cents: 24000,
              membership_included: false,
              note: null,
            },
          ],
          memberships: [],
          suggested_discount_kind: 'none',
          suggested_discount_value: 0,
          totals: { subtotal_cents: 24000, discount_cents: 0, tax_cents: 0, total_cents: 24000 },
        },
      },
    });
    await mockStorage(page, []);

    await page.goto('/app/jobs/new?start=2026-09-28T14:00:00.000Z');
    // 14:00Z is 09:00 in the shop's zone (America/Chicago), not Honolulu's 04:00
    await expect(page.getByLabel('Start time')).toHaveValue('09:00');

    await page.getByRole('combobox', { name: 'Customer' }).fill('Jane');
    await page.getByRole('option', { name: /Jane Doe/ }).click();
    await page.getByText('2021 Honda Civic (Blue)').click();
    await expect(page.getByRole('radio', { name: /2021 Honda Civic/ })).toBeChecked();
    await page.getByRole('checkbox', { name: /Full detail/ }).check();
    await expect(page.getByText('$240.00').first()).toBeVisible();
    // end = start + summed service durations (2 h 30 min)
    await expect(page.getByLabel('End time')).toHaveValue('11:30');
    await page.getByRole('checkbox', { name: TECH.fullName }).check();
    await page.getByRole('button', { name: 'Create job' }).click();

    await expect(page).toHaveURL(new RegExp(`/app/jobs/${JOB_ID}$`));
    await expect(page.getByRole('heading', { name: 'Job #1001', level: 1 })).toBeVisible();
    expect(inserted.jobs?.[0]).toMatchObject({
      customer_id: CUSTOMER_ID,
      vehicle_id: VEHICLE_ID,
      status: 'scheduled',
      scheduled_start: '2026-09-28T14:00:00.000Z',
      scheduled_end: '2026-09-28T16:30:00.000Z',
    });
    expect(inserted.jobs?.[0]).not.toHaveProperty('total_cents');
    expect(inserted.job_line_items?.[0]).toEqual([
      expect.objectContaining({ job_id: JOB_ID, service_id: SERVICE_ID, unit_price_cents: 24000 }),
    ]);
    expect(inserted.job_assignments?.[0]).toEqual([
      { shop_id: SHOP.id, job_id: JOB_ID, member_id: techMember.id },
    ]);
  });

  test('owner filters the jobs list and opens a job', async ({ page }) => {
    const queries: string[] = [];
    const job = jobRow();
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        ...detailTables(job, [], []),
        shop_members: [ownerMember],
        jobs: ({ url }) => {
          if (url.searchParams.get('select')?.includes('line_items')) {
            queries.push(url.search);
            return [
              {
                id: JOB_ID,
                number: 1001,
                status: 'scheduled',
                scheduled_start: '2026-09-28T14:00:00Z',
                scheduled_end: '2026-09-28T16:00:00Z',
                total_cents: 24000,
                location_type: 'mobile',
                customer: { id: CUSTOMER_ID, first_name: 'Jane', last_name: 'Doe', company: null },
                vehicle: { id: VEHICLE_ID, year: 2021, make: 'Honda', model: 'Civic' },
                line_items: [{ name: 'Full detail', sort: 1 }],
                assignments: [{ member_id: techMember.id }],
              },
            ];
          }
          return [job];
        },
      },
      rpc: { shop_team: TEAM, job_payment_summary: [SUMMARY] },
    });
    await mockStorage(page, []);

    await page.goto('/app/jobs');
    const table = page.getByRole('table', { name: 'Jobs' });
    await expect(table).toContainText('Jane Doe');
    await expect(table).toContainText('9:00'); // shop time, not Honolulu
    await expect(table).toContainText(TECH.fullName);
    // back-to-back changes: the second must not drop the first
    await page.getByRole('button', { name: 'Scheduled', exact: true }).click();
    await page.getByLabel('Assigned to').selectOption(techMember.id);
    await expect(page).toHaveURL(/status=scheduled&assignee=/);
    await expect
      .poll(() =>
        queries.some(
          (q) => q.includes('status=in.%28scheduled%29') || q.includes('status=in.(scheduled)'),
        ),
      )
      .toBe(true);
    await expect
      .poll(() => queries.some((q) => q.includes(`assignee_filter.member_id=eq.${techMember.id}`)))
      .toBe(true);

    await table.getByRole('link', { name: /#1001/ }).first().click();
    await expect(page).toHaveURL(new RegExp(`/app/jobs/${JOB_ID}$`));
  });

  test('owner moves the status, edits notes and uploads a before photo', async ({ page }) => {
    const patches: Row[] = [];
    const photos: Row[] = [];
    const uploads: string[] = [];
    const job = jobRow();
    await mockSupabase(page, {
      user: OWNER,
      tables: { ...detailTables(job, patches, photos), shop_members: [ownerMember] },
      rpc: { shop_team: TEAM, job_payment_summary: [SUMMARY] },
    });
    await mockStorage(page, uploads);

    await page.goto(`/app/jobs/${JOB_ID}`);
    await expect(page.getByRole('heading', { name: 'Job #1001', level: 1 })).toBeVisible();
    await expect(page.getByRole('link', { name: /1 Main St, Birmingham/ })).toHaveAttribute(
      'href',
      /google\.com\/maps/,
    );

    await page.getByRole('button', { name: 'Mark as Confirmed' }).click();
    await expect.poll(() => patches).toContainEqual({ status: 'confirmed' });
    await expect(page.getByRole('button', { name: 'Move back to Scheduled' })).toBeVisible();

    await page.getByLabel('Internal notes').fill('Bring the extractor');
    await page.getByRole('button', { name: 'Save notes' }).click();
    await expect
      .poll(() => patches.find((p) => 'internal_notes' in p))
      .toMatchObject({ internal_notes: 'Bring the extractor' });

    await page.getByLabel('Photo type').selectOption('before');
    await page
      .locator('input[type="file"]')
      .first()
      .setInputFiles({
        name: 'front.jpg',
        mimeType: 'image/jpeg',
        buffer: Buffer.from([0xff, 0xd8, 0xff, 0xd9]),
      });
    await expect(page.getByText('Photo uploaded')).toBeVisible();
    expect(uploads[0]).toMatch(new RegExp(`^${SHOP.id}/${JOB_ID}/[0-9a-f-]{36}\\.jpg$`));
    await expect(page.getByRole('region', { name: 'Before photos' })).toBeVisible();
  });

  test('assigned technician records a pre-inspection with a damage mark and customer signature', async ({
    page,
  }) => {
    const job = jobRow();
    const uploads: string[] = [];
    const inspections: Row[] = [];
    const inspectionPatches: Row[] = [];
    const markInserts: Row[] = [];
    await mockSupabase(page, {
      user: TECH,
      tables: {
        ...detailTables(job, [], []),
        shop_members: [techMember],
        inspections: ({ method, body }) => {
          if (method === 'POST') {
            const row = body as Row;
            inspections.push({
              id: '50000000-0000-4000-8000-000000000001',
              job_id: JOB_ID,
              vehicle_id: row.vehicle_id ?? null,
              kind: row.kind ?? 'pre',
              mileage: null,
              fuel_level: null,
              notes: null,
              customer_signature_path: null,
              signed_by_name: null,
              signed_at: null,
              created_at: '2026-09-28T14:05:00Z',
              marks: [],
            });
            return [];
          }
          if (method === 'PATCH') {
            const patch = body as Row;
            inspectionPatches.push(patch);
            const target = inspections[0];
            if (target) {
              Object.assign(target, patch);
              if (patch.customer_signature_path) target.signed_at = '2026-09-28T14:10:00Z';
            }
            return [{ id: target?.id ?? null }];
          }
          return inspections;
        },
        inspection_marks: ({ method, body }) => {
          if (method === 'POST') {
            const mark = body as Row;
            markInserts.push(mark);
            const marks = inspections[0]?.marks;
            if (Array.isArray(marks)) {
              marks.push({
                id: `m-${marks.length + 1}`,
                view: mark.view ?? 'front',
                x: mark.x ?? 0,
                y: mark.y ?? 0,
                damage: mark.damage ?? 'other',
                note: mark.note ?? null,
                photo_path: null,
                created_at: '2026-09-28T14:06:00Z',
              });
            }
          }
          return [];
        },
      },
      rpc: { shop_team: TEAM },
    });
    await page.route(`${SUPABASE_URL}/storage/v1/**`, async (route) => {
      const request = route.request();
      if (request.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS });
      const url = new URL(request.url());
      if (request.method() === 'POST' && url.pathname.includes('/object/signatures/')) {
        uploads.push(decodeURIComponent(url.pathname.split('/object/signatures/')[1] ?? ''));
      }
      const body = url.pathname.includes('/object/sign/')
        ? (((request.postDataJSON() ?? {}) as { paths?: string[] }).paths?.map((path) => ({
            path,
            signedURL: `/object/sign/signatures/${path}?token=t`,
            error: null,
          })) ?? [])
        : { Key: 'ok', Id: 'obj' };
      return route.fulfill({
        status: 200,
        headers: CORS,
        contentType: 'application/json',
        body: JSON.stringify(body),
      });
    });

    await page.goto(`/app/jobs/${JOB_ID}`);
    await page.getByRole('button', { name: 'Start pre' }).click();
    await expect(page.getByRole('heading', { name: /Pre-service inspection/ })).toBeVisible();

    await page.getByRole('tab', { name: /Driver side/ }).click();
    const diagram = page.getByRole('button', { name: /Driver side view, 0 damage marks/ });
    const box = await diagram.boundingBox();
    if (!box) throw new Error('diagram not rendered');
    await page.mouse.click(box.x + box.width * 0.25, box.y + box.height * 0.5);
    const markDialog = page.getByRole('dialog', { name: 'Add damage — Driver side' });
    await markDialog.getByLabel('Damage').selectOption('dent');
    await markDialog.getByLabel('Note').fill('Door ding');
    await markDialog.getByRole('button', { name: 'Add mark' }).click();
    await expect(markDialog).toBeHidden();
    await expect(page.getByRole('listitem').filter({ hasText: 'Door ding' })).toBeVisible();
    expect(markInserts[0]).toMatchObject({ view: 'left', damage: 'dent', note: 'Door ding' });
    expect(Number(markInserts[0]?.x)).toBeGreaterThan(0.1);
    expect(Number(markInserts[0]?.x)).toBeLessThan(0.4);

    // Unsaved details are part of what the customer signs — no separate save.
    await page.getByLabel('Mileage').fill('45210');
    await page.getByLabel('Fuel level (%)').fill('50');
    await page.getByRole('button', { name: 'Collect customer signature' }).click();
    const signDialog = page.getByRole('dialog', { name: /Sign the pre-service inspection/ });
    await expect(signDialog.getByLabel(/Signer’s full name/)).toHaveValue('Jane Doe');
    await expect(signDialog).toContainText('Mileage: 45,210 mi');
    await expect(signDialog).toContainText('Fuel level: 50%');
    const pad = await signDialog.getByRole('img', { name: /Customer signature/ }).boundingBox();
    if (!pad) throw new Error('signature pad not rendered');
    await page.mouse.move(pad.x + 20, pad.y + pad.height / 2);
    await page.mouse.down();
    await page.mouse.move(pad.x + pad.width / 2, pad.y + 20, { steps: 8 });
    await page.mouse.move(pad.x + pad.width - 20, pad.y + pad.height - 20, { steps: 8 });
    await page.mouse.up();
    await signDialog.getByRole('button', { name: 'Sign', exact: true }).click();
    await expect(page.getByText('Inspection signed')).toBeVisible();

    expect(uploads[0]).toMatch(
      new RegExp(
        `^${SHOP.id}/inspections/50000000-0000-4000-8000-000000000001/[0-9a-f-]{36}\\.png$`,
      ),
    );
    // one update: the details the customer saw + the signature
    expect(inspectionPatches).toEqual([
      {
        mileage: 45210,
        fuel_level: 50,
        notes: null,
        customer_signature_path: uploads[0] ?? '',
        signed_by_name: 'Jane Doe',
      },
    ]);
    expect(inspections[0]).toMatchObject({ mileage: 45210, fuel_level: 50 });
    await expect(page.getByLabel('Mileage')).toHaveValue('45210');
    await expect(page.getByLabel('Mileage')).toBeDisabled();
    // locked once signed: no more marking or signing
    await expect(page.getByText('Signed', { exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Collect customer signature' })).toHaveCount(0);
    await expect(
      page.getByRole('img', { name: /Driver side view with 1 damage marks/ }),
    ).toBeVisible();
  });

  test('owner moves a service up when every line has the default sort', async ({ page }) => {
    const lines: Row[] = [
      { ...LINE, sort: 0 },
      { ...LINE, id: '41000000-0000-4000-8000-000000000002', name: 'Ceramic coating', sort: 0 },
    ];
    const sortPatches: { id: string; sort: Json }[] = [];
    const job = jobRow();
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        ...detailTables(job, [], []),
        shop_members: [ownerMember],
        job_line_items: ({ method, body, url }) => {
          if (method === 'PATCH') {
            const id = (url.searchParams.get('id') ?? '').replace(/^eq\./, '');
            const patch = body as Row;
            sortPatches.push({ id, sort: patch.sort ?? null });
            const target = lines.find((l) => l.id === id);
            if (target) Object.assign(target, patch);
            return [];
          }
          // ordered like the real query: sort, then created_at (array order)
          return lines
            .map((l, i) => ({ l, i }))
            .sort((a, b) => Number(a.l.sort) - Number(b.l.sort) || a.i - b.i)
            .map(({ l }) => l);
        },
      },
      rpc: { shop_team: TEAM, job_payment_summary: [SUMMARY] },
    });
    await mockStorage(page, []);

    await page.goto(`/app/jobs/${JOB_ID}`);
    const services = page.getByRole('region', { name: 'Services' });
    await page.getByRole('button', { name: 'Move Ceramic coating up' }).click();
    await expect.poll(() => sortPatches.length).toBe(2);
    expect(sortPatches).toEqual([
      { id: '41000000-0000-4000-8000-000000000002', sort: 1 },
      { id: LINE.id as string, sort: 2 },
    ]);
    await expect(page.getByRole('button', { name: 'Move Ceramic coating up' })).toBeDisabled();
    await expect(services.getByText(/Ceramic coating|Full detail/).first()).toHaveText(
      /Ceramic coating/,
    );
  });

  test('assigned technician on a phone: forward steps only, sends "on my way", no money', async ({
    page,
  }) => {
    const sent: unknown[] = [];
    const patches: Row[] = [];
    const job = jobRow();
    await mockSupabase(page, {
      user: TECH,
      tables: { ...detailTables(job, patches, []), shop_members: [techMember] },
      rpc: { shop_team: TEAM },
    });
    await mockStorage(page, []);
    await page.route(`${SUPABASE_URL}/functions/v1/messaging`, async (route) => {
      if (route.request().method() === 'OPTIONS')
        return route.fulfill({ status: 204, headers: CORS });
      sent.push(route.request().postDataJSON());
      return route.fulfill({
        status: 200,
        headers: CORS,
        contentType: 'application/json',
        body: JSON.stringify({ message_id: 'msg-1', channel: 'sms', status: 'sent', error: null }),
      });
    });

    await page.setViewportSize({ width: 360, height: 800 });
    await page.goto(`/app/jobs/${JOB_ID}`);
    await expect(page.getByRole('heading', { name: 'Job #1001', level: 1 })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Mark as On the way' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Mark as Confirmed' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Cancel job' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Add service' })).toHaveCount(0);
    await expect(page.getByText('$240.00')).toHaveCount(0);

    await page.getByRole('button', { name: 'On my way' }).click();
    await expect(page.getByText('“On my way” sent')).toBeVisible();
    expect(sent[0]).toEqual({
      action: 'send',
      shop_id: SHOP.id,
      job_id: JOB_ID,
      channel: 'sms',
      template_key: 'on_the_way',
    });

    await page.getByRole('button', { name: 'Mark as On the way' }).click();
    await expect.poll(() => patches).toContainEqual({ status: 'en_route' });

    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
