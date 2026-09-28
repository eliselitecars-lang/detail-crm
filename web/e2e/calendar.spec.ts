import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, SHOP, TECH } from './support/fixtures';
import { mockSupabase, reply, type Handler, type MockReply } from './support/mockSupabase';

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type Row = { [key: string]: Json };

const TZ = SHOP.timezone; // America/Chicago
const ownerMember = membershipRow(OWNER, 'owner');
const techMember = membershipRow(TECH, 'technician');
const JOB_ID = '40000000-0000-4000-8000-000000000001';

const TEAM: Json[] = [ownerMember, techMember].map((m) => ({
  member_id: m.id,
  user_id: null,
  role: m.role,
  display_name: m.display_name,
  calendar_color: null,
  active: true,
  phone: null,
  email: null,
}));

/** Today's date (yyyy-MM-dd) on the shop's wall clock. */
function shopToday(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(new Date());
}

/** Shop wall-clock date + time → UTC ISO (for fixtures and assertions). */
function shopTimeToUtc(date: string, time: string): string {
  const guess = new Date(`${date}T${time}:00Z`);
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: TZ,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).formatToParts(guess);
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value);
  const wall = Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'));
  return new Date(guess.getTime() - (wall - guess.getTime())).toISOString();
}

function jobEvent(date: string, overrides: Row = {}): Row {
  return {
    event_type: 'job',
    id: JOB_ID,
    job_number: 1001,
    status: 'confirmed',
    starts_at: shopTimeToUtc(date, '10:00'),
    ends_at: shopTimeToUtc(date, '12:00'),
    is_busy_block: false,
    customer_id: '30000000-0000-4000-8000-000000000001',
    customer_name: 'Jane Doe',
    vehicle_id: null,
    vehicle_label: '2021 Honda Civic',
    location_type: 'shop',
    service_address: null,
    resource_id: null,
    assigned_member_ids: [techMember.id],
    member_id: null,
    title: 'Jane Doe',
    ...overrides,
  };
}

function busyBlock(date: string): Row {
  return {
    ...jobEvent(date),
    id: '40000000-0000-4000-8000-000000000002',
    job_number: null,
    status: null,
    starts_at: shopTimeToUtc(date, '13:00'),
    ends_at: shopTimeToUtc(date, '14:00'),
    is_busy_block: true,
    customer_id: null,
    customer_name: null,
    vehicle_label: null,
    location_type: null,
    assigned_member_ids: null,
    title: null,
  };
}

interface Setup {
  user?: typeof OWNER;
  events?: Row[];
  resources?: Row[];
  patches?: Row[];
  rangeCalls?: Json[];
  /** Answer every reschedule (PATCH) with this PostgREST error. */
  rejectPatch?: MockReply;
  /** Extra table / RPC handlers (calendar events, day map). */
  tables?: Record<string, Json[] | Handler>;
  rpc?: Record<string, Json | Handler>;
}

async function setup(page: Page, options: Setup = {}) {
  const user = options.user ?? OWNER;
  const today = shopToday();
  await mockSupabase(page, {
    user,
    tables: {
      shop_members: [user === OWNER ? ownerMember : techMember],
      notifications: [],
      business_hours: [0, 1, 2, 3, 4, 5, 6].map((weekday) => ({
        weekday,
        opens_at: '08:00:00',
        closes_at: '18:00:00',
      })),
      resources: options.resources ?? [],
      jobs: ({ method, body }) => {
        if (method === 'PATCH' && options.rejectPatch) {
          options.patches?.push(body as Row);
          return options.rejectPatch;
        }
        if (method === 'PATCH') {
          options.patches?.push(body as Row);
          // the server now holds the moved job
          const event = options.events?.find((e) => e.id === JOB_ID);
          if (event) {
            const patch = body as Row;
            if ('scheduled_start' in patch) event.starts_at = patch.scheduled_start ?? null;
            if ('scheduled_end' in patch) event.ends_at = patch.scheduled_end ?? null;
            if ('resource_id' in patch) event.resource_id = patch.resource_id ?? null;
          }
        }
        return [{ id: JOB_ID }];
      },
      ...options.tables,
    },
    rpc: {
      shop_team: TEAM,
      calendar_events: ({ body }) => {
        options.rangeCalls?.push(body as Json);
        return options.events ?? [jobEvent(today)];
      },
      ...options.rpc,
    },
  });
  return today;
}

/** Page y of a time-grid slot row, e.g. "10:00:00". */
async function slotY(page: Page, time: string): Promise<number> {
  const box = await page.locator(`td.fc-timegrid-slot-lane[data-time="${time}"]`).boundingBox();
  if (!box) throw new Error(`slot ${time} not found`);
  return box.y;
}

async function dragBy(page: Page, source: { x: number; y: number }, dy: number) {
  await page.mouse.move(source.x, source.y);
  await page.mouse.down();
  await page.mouse.move(source.x, source.y + dy / 2, { steps: 5 });
  await page.mouse.move(source.x, source.y + dy, { steps: 5 });
  await page.mouse.up();
}

test.describe('calendar', () => {
  test.use({ timezoneId: 'Pacific/Honolulu' });

  test('renders the shop-time week, fetches the visible range and opens a job', async ({
    page,
  }) => {
    const rangeCalls: Json[] = [];
    const today = await setup(page, { rangeCalls });
    await page.goto('/app/calendar');
    const event = page.locator('.fc-event', { hasText: '#1001 · Jane Doe' });
    await expect(event).toBeVisible();
    // 10:00 on the shop clock even though the browser is in Honolulu
    await expect(event).toContainText('10:00');
    expect(rangeCalls[0]).toMatchObject({ p_shop_id: SHOP.id, p_include_cancelled: false });
    const range = rangeCalls[0] as { p_from: string; p_to: string };
    const todayStart = shopTimeToUtc(today, '00:00');
    expect(Date.parse(range.p_from)).toBeLessThanOrEqual(Date.parse(todayStart));
    expect(Date.parse(range.p_to)).toBeGreaterThan(Date.parse(todayStart));
    // the range starts at a shop-local midnight
    expect(
      new Intl.DateTimeFormat('en-US', { timeZone: TZ, hour: 'numeric', hourCycle: 'h23' }).format(
        new Date(range.p_from),
      ),
    ).toBe('00');

    await event.click();
    await expect(page).toHaveURL(new RegExp(`/app/jobs/${JOB_ID}$`));
  });

  test('manager drags a job to a new time, confirms, and the server is updated', async ({
    page,
  }) => {
    const patches: Row[] = [];
    const today = await setup(page, { patches });
    await page.goto('/app/calendar');
    const event = page.locator('.fc-timegrid-event', { hasText: '#1001' });
    await expect(event).toBeVisible();
    const box = await event.boundingBox();
    if (!box) throw new Error('event not rendered');
    const hour = (await slotY(page, '11:00:00')) - (await slotY(page, '10:00:00'));
    await dragBy(page, { x: box.x + box.width / 2, y: box.y + box.height / 2 }, hour);

    const dialog = page.getByRole('dialog', { name: 'Reschedule Job #1001?' });
    await expect(dialog).toContainText('11:00');
    await dialog.getByRole('button', { name: 'Reschedule' }).click();
    await expect(page.getByText('Job #1001 rescheduled')).toBeVisible();
    expect(patches).toContainEqual({
      scheduled_start: shopTimeToUtc(today, '11:00'),
      scheduled_end: shopTimeToUtc(today, '13:00'),
    });
  });

  test('a rejected reschedule reverts the event; cancelling the dialog does too', async ({
    page,
  }) => {
    const patches: Row[] = [];
    await setup(page, {
      patches,
      rejectPatch: reply(400, {
        code: '23514',
        message: 'the new time overlaps a blocked time',
        details: null,
        hint: null,
      }),
    });
    await page.goto('/app/calendar');
    const event = page.locator('.fc-timegrid-event', { hasText: '#1001' });
    await expect(event).toContainText('10:00');
    const hour = (await slotY(page, '11:00:00')) - (await slotY(page, '10:00:00'));

    let box = await event.boundingBox();
    if (!box) throw new Error('event not rendered');
    await dragBy(page, { x: box.x + box.width / 2, y: box.y + box.height / 2 }, hour);
    await page.getByRole('dialog').getByRole('button', { name: 'Reschedule' }).click();
    await expect(page.getByText('the new time overlaps a blocked time')).toBeVisible();
    await expect(event).toContainText('10:00');
    expect(patches).toHaveLength(1);

    box = await event.boundingBox();
    if (!box) throw new Error('event not rendered');
    await dragBy(page, { x: box.x + box.width / 2, y: box.y + box.height / 2 }, hour);
    await page.getByRole('dialog').getByRole('button', { name: 'Cancel' }).click();
    await expect(page.getByRole('dialog')).toHaveCount(0);
    await expect(event).toContainText('10:00');
    expect(patches).toHaveLength(1);
  });

  test('selecting a free range starts a new job for that slot', async ({ page }) => {
    const today = await setup(page, { events: [] });
    await page.goto('/app/calendar');
    await expect(page.getByText('No jobs in this range.', { exact: false })).toBeVisible();
    await page.locator('td.fc-timegrid-slot-lane[data-time="15:30:00"]').scrollIntoViewIfNeeded();
    const column = await page.locator(`td.fc-timegrid-col[data-date="${today}"]`).boundingBox();
    if (!column) throw new Error('today column not rendered');
    const x = column.x + column.width / 2;
    const top = await slotY(page, '14:00:00');
    const bottom = await slotY(page, '15:00:00');
    await page.mouse.move(x, top + 3);
    await page.mouse.down();
    await page.mouse.move(x, bottom - 6, { steps: 6 });
    await page.mouse.up();
    await expect(page).toHaveURL(/\/app\/jobs\/new\?/);
    const url = new URL(page.url());
    expect(url.searchParams.get('start')).toBe(shopTimeToUtc(today, '14:00'));
    expect(url.searchParams.get('end')).toBe(shopTimeToUtc(today, '15:00'));
  });

  test('technician on a phone sees a list with anonymized busy blocks and cannot create', async ({
    page,
  }) => {
    const today = shopToday();
    await setup(page, { user: TECH, events: [jobEvent(today), busyBlock(today)] });
    await page.setViewportSize({ width: 360, height: 800 });
    await page.goto('/app/calendar');
    await expect(page.getByRole('button', { name: 'List' })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
    await expect(page.getByText('#1001 · Jane Doe')).toBeVisible();
    await expect(page.getByText('Busy', { exact: true })).toBeVisible();
    await expect(page.getByRole('link', { name: /New job/ })).toHaveCount(0);
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });

  test('bay / van view: drag a job into another bay, confirm, and it moves there', async ({
    page,
  }) => {
    const BAY_ID = '60000000-0000-4000-8000-000000000001';
    const today = shopToday();
    const patches: Row[] = [];
    const events = [jobEvent(today)];
    await setup(page, {
      patches,
      events,
      resources: [{ id: BAY_ID, name: 'Bay 1', kind: 'bay', active: true, archived_at: null }],
    });
    await page.goto('/app/calendar');
    await page.getByRole('button', { name: 'Bays' }).click();

    const bay = page.getByRole('region', { name: 'Bay 1' });
    const none = page.getByRole('region', { name: 'No bay / van' });
    const event = none.locator('.fc-timegrid-event', { hasText: '#1001' });
    await expect(event).toContainText('10:00');
    await expect(bay.locator('.fc-timegrid-event')).toHaveCount(0);

    const dragToBay = async () => {
      const from = await event.boundingBox();
      const lane = await bay.locator('td.fc-timegrid-col[data-date]').boundingBox();
      if (!from || !lane) throw new Error('calendar not rendered');
      const start = { x: from.x + from.width / 2, y: from.y + 8 };
      await page.mouse.move(start.x, start.y);
      await page.mouse.down();
      await page.mouse.move(start.x - 20, start.y, { steps: 5 });
      await page.mouse.move(lane.x + lane.width / 2, start.y, { steps: 10 });
      await page.mouse.up();
    };

    // cancelling puts it back where it was, with no write
    await dragToBay();
    let dialog = page.getByRole('dialog', { name: 'Reschedule Job #1001?' });
    await expect(dialog).toContainText('Bay / van: Bay 1 (was No bay / van)');
    await dialog.getByRole('button', { name: 'Cancel' }).click();
    await expect(dialog).toHaveCount(0);
    await expect(none.locator('.fc-timegrid-event', { hasText: '#1001' })).toHaveCount(1);
    await expect(bay.locator('.fc-timegrid-event')).toHaveCount(0);
    expect(patches).toHaveLength(0);

    await dragToBay();
    dialog = page.getByRole('dialog', { name: 'Reschedule Job #1001?' });
    await expect(dialog).toContainText('10:00');
    await dialog.getByRole('button', { name: 'Reschedule' }).click();
    await expect(page.getByText('Job #1001 moved to Bay 1')).toBeVisible();
    expect(patches).toEqual([
      {
        scheduled_start: shopTimeToUtc(today, '10:00'),
        scheduled_end: shopTimeToUtc(today, '12:00'),
        resource_id: BAY_ID,
      },
    ]);
    // exactly one copy, in the new bay
    await expect(bay.locator('.fc-timegrid-event', { hasText: '#1001' })).toHaveCount(1);
    await expect(none.locator('.fc-timegrid-event')).toHaveCount(0);
    await expect(bay).toContainText('1 job');
  });

  test('manager adds a weekly meeting; it shows with its kind on the calendar', async ({
    page,
  }) => {
    const today = shopToday();
    const inserts: Row[] = [];
    const events = [jobEvent(today)];
    await setup(page, {
      events,
      tables: {
        blocked_times: ({ method, body }) => {
          if (method === 'POST') {
            const row = body as Row;
            inserts.push(row);
            events.push({
              ...busyBlock(today),
              event_type: 'blocked_time',
              id: '70000000-0000-4000-8000-000000000001',
              is_busy_block: true,
              starts_at: row.starts_at ?? null,
              ends_at: row.ends_at ?? null,
              assigned_member_ids: [],
              title: row.title ?? null,
              event_kind: 'meeting',
            });
            return [{ id: '70000000-0000-4000-8000-000000000001' }];
          }
          return [];
        },
      },
    });
    await page.goto('/app/calendar');
    await page.getByRole('button', { name: 'Day', exact: true }).click();
    await page.getByRole('button', { name: 'New event' }).click();
    const dialog = page.getByRole('dialog', { name: 'New event' });
    await dialog.getByLabel('Title').fill('Team huddle');
    await dialog.getByLabel('Start date').fill(today);
    await dialog.getByLabel('Start time').fill('13:00');
    await dialog.getByLabel('End time').fill('13:30');
    await dialog.getByLabel('Repeat').selectOption('week');
    await dialog.getByRole('button', { name: 'Add event' }).click();
    await expect(page.getByText('Event added')).toBeVisible();
    expect(inserts[0]).toMatchObject({
      shop_id: SHOP.id,
      kind: 'meeting',
      title: 'Team huddle',
      member_id: null,
      starts_at: shopTimeToUtc(today, '13:00'),
      ends_at: shopTimeToUtc(today, '13:30'),
      affects_capacity: false,
      recurrence: { freq: 'week', interval: 1 },
    });
    const meeting = page.locator('.fc-event', { hasText: 'Team huddle' });
    await expect(meeting).toBeVisible();
    await expect(meeting).toContainText('Meeting:');
  });

  test('day map: stops on OpenStreetMap, reorder saves the route, Google Maps hand-off', async ({
    page,
  }) => {
    const today = shopToday();
    const orders: Json[] = [];
    // OpenStreetMap tiles are the only third-party requests; serve a blank tile
    await page.route('https://tile.openstreetmap.org/**', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'image/png',
        body: Buffer.from(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==',
          'base64',
        ),
      }),
    );
    await setup(page, {
      events: [
        jobEvent(today, {
          location_type: 'mobile',
          service_address: '1 Main St, Birmingham',
          service_lat: 33.52,
          service_lng: -86.81,
        }),
        jobEvent(today, {
          id: '40000000-0000-4000-8000-000000000009',
          job_number: 1009,
          title: 'Sam Lee',
          starts_at: shopTimeToUtc(today, '14:00'),
          ends_at: shopTimeToUtc(today, '15:00'),
          location_type: 'mobile',
          service_address: '5 Oak Ave, Homewood',
          service_lat: null,
          service_lng: null,
        }),
      ],
      tables: {
        shops: [
          {
            lat: 33.5,
            lng: -86.8,
            address_line1: null,
            city: null,
            region: null,
            postal_code: null,
          },
        ],
      },
      rpc: {
        set_route_order: ({ body }) => {
          orders.push(body as Json);
          return 2;
        },
      },
    });
    await page.goto('/app/calendar');
    await page.getByRole('button', { name: 'Map' }).click();
    const map = page.getByRole('region', { name: 'Map of the day’s stops' });
    await expect(map).toBeVisible();
    await expect(map.locator('.dc-route-marker')).toHaveCount(2); // the shop + the located stop
    await expect(map).toContainText('OpenStreetMap');
    const stops = page.getByRole('region', { name: 'Stops in route order' });
    await expect(
      stops.getByText('Not located yet — open the job in the iPhone app.'),
    ).toBeVisible();
    const link = stops.getByRole('link', { name: /Open route in Google Maps/ });
    const href = new URL((await link.getAttribute('href')) ?? '');
    expect(href.searchParams.get('origin')).toBe('33.5,-86.8');
    expect(href.searchParams.get('waypoints')).toBe('33.52,-86.81');
    expect(href.searchParams.get('destination')).toBe('5 Oak Ave, Homewood');

    await stops.getByRole('button', { name: 'Move Sam Lee earlier' }).click();
    await expect
      .poll(() => orders)
      .toEqual([
        { p_shop_id: SHOP.id, p_job_ids: ['40000000-0000-4000-8000-000000000009', JOB_ID] },
      ]);
  });
});
