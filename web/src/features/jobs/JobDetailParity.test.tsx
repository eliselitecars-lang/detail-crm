/**
 * Job detail parity features: repeating visits (P-1), completion gates
 * (P-11), photo visibility + videos (P-8 / P-30), the customer report (P-8),
 * files (P-25), preset fees (P-21), job fields (P-9), deposit follow-ups
 * (P-3) and sold-by (P-12).
 */
import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue, signedInAuth } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import JobDetailPage from './JobDetailPage';
import { jobDetailRow, TEAM, TRANSITIONS } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const SUMMARY = {
  job_id: 'job-1',
  invoice_id: null,
  invoice_number: null,
  invoice_status: null,
  invoice_job_count: 0,
  total_cents: 27188,
  deposit_required_cents: 5000,
  deposit_paid_cents: 0,
  deposit_due_cents: 5000,
  paid_cents: 0,
  tip_cents: 0,
  refunded_cents: 0,
  pending_cents: 0,
  balance_cents: 27188,
};

const SERIES = {
  id: 'series-1',
  freq: 'week',
  interval: 2,
  by_weekday: [2, 4],
  month_mode: null,
  month_day: null,
  month_nth: null,
  month_weekday: null,
  start_date: '2026-09-14',
  local_start: '09:00:00',
  duration_minutes: 120,
  until_date: null,
  max_occurrences: 12,
  active: true,
  ended_at: null,
};

const PHOTO = {
  id: 'p-1',
  storage_path: 'shop-1/job-1/a.jpg',
  kind: 'before',
  caption: null,
  uploaded_by: 'user-1',
  created_at: '2026-09-28T15:00:00Z',
  customer_visible: false,
  media_type: 'image',
  bucket: 'job-photos',
  duration_seconds: null,
  poster_path: null,
};

const VIDEO = {
  ...PHOTO,
  id: 'p-2',
  storage_path: 'shop-1/job-1/v-walk.mp4',
  kind: 'after',
  customer_visible: true,
  media_type: 'video',
  bucket: 'job-media',
  duration_seconds: 65,
  poster_path: 'shop-1/job-1/poster.jpg',
};

interface Options {
  role?: 'owner' | 'technician';
  job?: ReturnType<typeof jobDetailRow>;
  rpc?: Record<string, unknown>;
  techsCanShareReports?: boolean;
}

function setup(options: Options = {}) {
  const role = options.role ?? 'owner';
  const tech = role === 'technician';
  const rpc: Record<string, unknown> = {
    shop_team: TEAM,
    job_payment_summary: [SUMMARY],
    document_followup_status: {
      kind: 'deposit',
      stage: 'deposit',
      enabled: true,
      paused: false,
      attempts_sent: 1,
      max_attempts: 3,
      last_sent_at: '2026-09-27T15:00:00Z',
      next_at: '2026-10-06T15:00:00Z',
    },
    ...options.rpc,
  };
  supabase.rpc.mockImplementation((...args: unknown[]) =>
    createBuilder({ data: rpc[String(args[0])] ?? null }),
  );
  setTableResult('jobs', { data: options.job ?? jobDetailRow() });
  setTableResult('job_status_transitions', { data: TRANSITIONS });
  setTableResult('job_line_items', { data: [] });
  setTableResult('job_assignments', { data: [{ id: 'a-1', member_id: 'member-2' }] });
  setTableResult('job_checklist_items', { data: [] });
  const base = membership({ role, memberId: tech ? 'member-2' : 'member-1' });
  return renderRoute(<JobDetailPage />, {
    path: '/app/jobs/job-1',
    routePath: '/app/jobs/:jobId',
    auth: signedInAuth(tech ? 'tech@example.com' : 'owner@example.com', tech ? 'user-2' : 'user-1'),
    shop: shopValue({
      membership: {
        ...base,
        shop: { ...base.shop, techs_can_share_reports: options.techsCanShareReports ?? false },
      },
    }),
    routes: [{ path: '/app/jobs/:jobId', element: <p>Other job</p> }],
  });
}

beforeEach(() => resetSupabaseMock());

describe('repeating visits', () => {
  it('shows the rule and changes this and the following visits', async () => {
    setTableResult('job_series', { data: SERIES });
    const { user } = setup({
      job: jobDetailRow({ series_id: 'series-1', series_seq: 3 }),
      rpc: { update_job_series: { updated: true, deleted: 0, created: 0, changed: 8, kept: 1 } },
    });
    expect(await screen.findByText(/Repeats every 2 weeks on Tue, Thu/)).toBeInTheDocument();
    expect(screen.getByText(/Visit 3 of 12/)).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Edit' }));
    const dialog = await screen.findByRole('dialog', { name: 'Edit schedule & location' });
    await user.click(within(dialog).getByRole('radio', { name: 'This and following visits' }));
    const start = within(dialog).getByLabelText('Start time');
    await user.clear(start);
    await user.type(start, '10:00');
    const end = within(dialog).getByLabelText('End time');
    await user.clear(end);
    await user.type(end, '12:00');
    await user.click(within(dialog).getByRole('button', { name: 'Save' }));

    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('update_job_series', {
        p_series_id: 'series-1',
        p_patch: { local_start: '10:00' },
        p_from_job_id: 'job-1',
      }),
    );
    // this visit was kept by the series (not eligible): it still gets the change
    await waitFor(() =>
      expect((builders.jobs ?? []).flatMap((b) => b.update.mock.calls)).toContainEqual([
        expect.objectContaining({
          scheduled_start: '2026-09-28T15:00:00.000Z',
          scheduled_end: '2026-09-28T17:00:00.000Z',
        }),
      ]),
    );
    // the in-place count is reported, not only removed visits
    expect(
      await screen.findByText(
        '8 upcoming visits updated; 1 kept as it was (already confirmed, paid or worked on).',
      ),
    ).toBeInTheDocument();
  });

  it('keeps a monthly rule as it is when only the end changes on a clamped visit', async () => {
    // "day 31" series: its September visit falls on the 30th
    setTableResult('job_series', {
      data: {
        ...SERIES,
        freq: 'month',
        interval: 1,
        by_weekday: [],
        month_mode: 'day_of_month',
        month_day: 31,
        start_date: '2026-08-31',
        max_occurrences: null,
      },
    });
    const { user } = setup({
      job: jobDetailRow({
        series_id: 'series-1',
        series_seq: 2,
        scheduled_start: '2026-09-30T14:00:00Z',
        scheduled_end: '2026-09-30T16:00:00Z',
      }),
      rpc: { update_job_series: { updated: true, deleted: 2, created: 0, changed: 0, kept: 0 } },
    });
    expect(await screen.findByText(/Repeats every month on day 31/)).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Edit repeat' }));
    const dialog = await screen.findByRole('dialog', { name: 'Edit repeat' });
    expect(within(dialog).getByRole('radio', { name: 'On day 31 (as now)' })).toBeChecked();
    expect(within(dialog).getByRole('radio', { name: 'On day 30' })).not.toBeChecked();
    await user.click(within(dialog).getByRole('radio', { name: 'After a number of visits' }));
    const count = within(dialog).getByLabelText('Number of visits');
    await user.clear(count);
    await user.type(count, '3');
    await user.click(within(dialog).getByRole('button', { name: 'Save repeat' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('update_job_series', {
        p_series_id: 'series-1',
        p_patch: {
          freq: 'month',
          interval: 1,
          month_mode: 'day_of_month',
          month_day: 31,
          until_date: null,
          max_occurrences: 3,
        },
        p_from_job_id: 'job-1',
      }),
    );
    expect(await screen.findByText('2 upcoming visits removed.')).toBeInTheDocument();
  });

  it('keeps a new date to this visit only', async () => {
    setTableResult('job_series', { data: SERIES });
    const { user } = setup({ job: jobDetailRow({ series_id: 'series-1', series_seq: 3 }) });
    await screen.findByText(/Repeats every/);
    await user.click(screen.getByRole('button', { name: 'Edit' }));
    const dialog = await screen.findByRole('dialog', { name: 'Edit schedule & location' });
    await user.click(within(dialog).getByRole('radio', { name: 'This and following visits' }));
    const date = within(dialog).getByLabelText('Start date');
    await user.clear(date);
    await user.type(date, '2026-09-29');
    const endDate = within(dialog).getByLabelText('End date');
    await user.clear(endDate);
    await user.type(endDate, '2026-09-29');
    await user.click(within(dialog).getByRole('button', { name: 'Save' }));
    expect(await within(dialog).findByRole('alert')).toHaveTextContent(/this visit only/);
    expect(supabase.rpc).not.toHaveBeenCalledWith('update_job_series', expect.anything());
  });

  it('ends the repeat after a date', async () => {
    setTableResult('job_series', { data: SERIES });
    const { user } = setup({
      job: jobDetailRow({ series_id: 'series-1', series_seq: 3 }),
      rpc: { end_job_series: { deleted: 4, kept: 0 } },
    });
    await user.click(await screen.findByRole('button', { name: 'End repeat' }));
    const dialog = await screen.findByRole('dialog', { name: 'End this repeating job?' });
    expect(within(dialog).getByLabelText('Last visit date')).toHaveValue('2026-09-28');
    await user.click(within(dialog).getByRole('button', { name: 'End repeat' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('end_job_series', {
        p_series_id: 'series-1',
        p_after_date: '2026-09-28',
      }),
    );
  });

  it('tells technicians it repeats without reading the series', async () => {
    setup({ role: 'technician', job: jobDetailRow({ series_id: 'series-1', series_seq: 3 }) });
    expect(await screen.findByText(/Part of a repeating job/)).toBeInTheDocument();
    expect(builders.job_series).toBeUndefined();
    expect(screen.queryByRole('button', { name: 'End repeat' })).not.toBeInTheDocument();
  });
});

describe('completion gates', () => {
  const GATES = {
    open_required_items: [{ id: 'i1', label: 'Vacuum interior' }],
    before_photos: { required: 0, have: 0 },
    after_photos: { required: 2, have: 1 },
  };

  it('shows what is missing and lets a manager complete anyway with a reason', async () => {
    const { user } = setup({
      job: jobDetailRow({ status: 'in_progress', started_at: '2026-09-28T14:05:00Z' }),
      rpc: { job_completion_blockers: GATES },
    });
    await user.click(await screen.findByRole('button', { name: 'Mark as Completed' }));
    const dialog = await screen.findByRole('dialog', { name: 'This job can’t be completed yet' });
    expect(dialog).toHaveTextContent('Required checklist item not done: Vacuum interior');
    expect(dialog).toHaveTextContent('2 “after” photos needed (1 so far)');
    expect(supabase.rpc).not.toHaveBeenCalledWith('set_job_status', expect.anything());

    await user.type(within(dialog).getByLabelText(/Reason for the override/), 'Customer waived');
    await user.click(within(dialog).getByRole('button', { name: 'Complete anyway' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('set_job_status', {
        p_job_id: 'job-1',
        p_status: 'completed',
        p_force: true,
        p_reason: 'Customer waived',
      }),
    );
  });

  it('shows who completed the job past its requirements, when and why', async () => {
    setTableResult('job_gate_overrides', {
      data: [
        {
          id: 'o-1',
          to_status: 'completed',
          reason: 'Customer waived the after photos',
          blockers: {
            open_required_items: [{ id: 'i1', label: 'Vacuum interior' }],
            after_photos: { required: 2, have: 1 },
          },
          overridden_by: 'user-1',
          created_at: '2026-09-28T18:00:00Z',
        },
      ],
    });
    setup({ job: jobDetailRow({ status: 'completed', completed_at: '2026-09-28T18:00:00Z' }) });
    const notice = await screen.findByRole('region', { name: 'Requirement overrides' });
    expect(notice).toHaveTextContent('Moved to Completed without meeting its requirements');
    expect(notice).toHaveTextContent('Customer waived the after photos');
    await waitFor(() => expect(notice).toHaveTextContent('by Olivia Owner'));
    const waived = within(notice).getByRole('list', { name: 'Requirements that were not met' });
    expect(waived).toHaveTextContent('Required checklist item not done: Vacuum interior');
    expect(waived).toHaveTextContent('2 “after” photos needed (1 so far)');
    expect(builders.job_gate_overrides?.[0]?.eq).toHaveBeenCalledWith('job_id', 'job-1');
  });

  it('shows no override notice for a job that met its requirements', async () => {
    setTableResult('job_gate_overrides', { data: [] });
    setup({ job: jobDetailRow({ status: 'completed' }) });
    await screen.findByRole('heading', { name: /Job #/ });
    await waitFor(() => expect(builders.job_gate_overrides?.length).toBeGreaterThan(0));
    expect(screen.queryByRole('region', { name: 'Requirement overrides' })).toBeNull();
  });

  it('never offers technicians the override', async () => {
    const { user } = setup({
      role: 'technician',
      job: jobDetailRow({ status: 'in_progress' }),
      rpc: { job_completion_blockers: GATES },
    });
    await user.click(await screen.findByRole('button', { name: 'Mark as Completed' }));
    const dialog = await screen.findByRole('dialog', { name: 'This job can’t be completed yet' });
    expect(within(dialog).queryByRole('button', { name: 'Complete anyway' })).toBeNull();
    expect(dialog).toHaveTextContent(/ask a manager/);
  });

  it('completes straight away when nothing blocks', async () => {
    const { user } = setup({
      job: jobDetailRow({ status: 'in_progress' }),
      rpc: {
        job_completion_blockers: {
          open_required_items: [],
          before_photos: { required: 0, have: 0 },
          after_photos: { required: 0, have: 0 },
        },
      },
    });
    await user.click(await screen.findByRole('button', { name: 'Mark as Completed' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('set_job_status', {
        p_job_id: 'job-1',
        p_status: 'completed',
      }),
    );
  });
});

describe('photos, videos and the customer report', () => {
  it('toggles what the customer sees and plays videos', async () => {
    setTableResult('job_photos', { data: [PHOTO, VIDEO] });
    const { user } = setup({ rpc: { set_job_photo_visibility: 1 } });
    const show = await screen.findByRole('button', {
      name: /Show Before photo from .* to the customer/,
    });
    await user.click(show);
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('set_job_photo_visibility', {
        p_photo_ids: ['p-1'],
        p_visible: true,
      }),
    );
    const video = screen.getByLabelText(/^After video from/);
    expect(video.tagName).toBe('VIDEO');
    expect(video).toHaveAttribute('src', 'https://signed.test/job-media/shop-1/job-1/v-walk.mp4');
    expect(video).toHaveAttribute(
      'poster',
      'https://signed.test/job-photos/shop-1/job-1/poster.jpg',
    );
    expect(screen.getByText('Video · 1:05')).toBeInTheDocument();
  });

  it('publishes the report and sends the link', async () => {
    setTableResult('job_reports', { data: null });
    setTableResult('job_photos', { data: [VIDEO] });
    const { user } = setup({
      rpc: {
        publish_job_report: {
          report_id: 'r-1',
          token: '70000000-0000-4000-8000-000000000001',
          url: 'https://app.example.com/r/70000000-0000-4000-8000-000000000001',
          queued: true,
        },
      },
    });
    const card = (await screen.findByRole('heading', { name: 'Customer report' })).closest(
      'section',
    );
    await user.click(within(card as HTMLElement).getByRole('button', { name: 'Share' }));
    const dialog = await screen.findByRole('dialog', { name: 'Share a job report' });
    expect(dialog).toHaveTextContent('1 photo or video of these kinds is marked “Customer sees”.');
    await user.click(within(dialog).getByRole('button', { name: 'Publish and send' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('publish_job_report', {
        p_job_id: 'job-1',
        p_include_inspections: true,
        p_photo_kinds: ['before', 'after'],
        p_send: true,
      }),
    );
    expect(await screen.findByText('Report published and sent')).toBeInTheDocument();
  });

  it('hides the report from technicians unless the shop lets them share', async () => {
    setup({ role: 'technician' });
    await screen.findByRole('heading', { name: 'Job #1001', level: 1 });
    expect(screen.queryByRole('heading', { name: 'Customer report' })).not.toBeInTheDocument();
    expect(builders.job_reports).toBeUndefined();
  });
});

describe('files, fees, job fields, follow-ups and sold by', () => {
  it('uploads a file into the job’s documents folder', async () => {
    setTableResult('documents', { data: [] });
    const { user } = setup();
    const button = await screen.findByRole('button', { name: 'Add files' });
    const input = button.parentElement?.querySelector('input[type="file"]');
    if (!(input instanceof HTMLInputElement)) throw new Error('file input missing');
    await user.upload(input, new File(['%PDF'], 'Quote v2.pdf', { type: 'application/pdf' }));
    const upload = supabase.storage.from('documents').upload;
    await waitFor(() => expect(upload).toHaveBeenCalled());
    const [path] = upload.mock.calls[0] ?? [];
    expect(path).toMatch(/^shop-1\/jobs\/job-1\/[0-9a-f-]{36}-Quote-v2\.pdf$/);
    await waitFor(() =>
      expect(builders.documents?.some((b) => b.insert.mock.calls.length > 0)).toBe(true),
    );
    const insert = builders.documents?.find((b) => b.insert.mock.calls.length > 0)?.insert;
    expect(insert).toHaveBeenCalledWith({
      shop_id: 'shop-1',
      job_id: 'job-1',
      storage_path: path,
      file_name: 'Quote v2.pdf',
      content_type: 'application/pdf',
      size_bytes: 4,
    });
  });

  it('adds a preset fee through add_fee_line', async () => {
    setTableResult('shop_fees', {
      data: [
        {
          id: 'fee-1',
          name: 'Travel fee',
          amount_cents: 2500,
          taxable: false,
          auto_apply: 'none',
          active: true,
          sort: 1,
        },
      ],
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Add fee' }));
    await user.click(await screen.findByRole('menuitem', { name: 'Travel fee · $25.00' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('add_fee_line', {
        p_doc_kind: 'job',
        p_doc_id: 'job-1',
        p_fee_id: 'fee-1',
        p_request_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/) as unknown,
      }),
    );
  });

  it('shows and edits the job’s custom fields', async () => {
    setTableResult('custom_fields', {
      data: [
        {
          id: 'cf-1',
          entity: 'job',
          key: 'gate_code',
          label: 'Gate code',
          type: 'text',
          options: [],
          help_text: null,
          required: false,
          show_in_booking: true,
          show_in_lead_form: false,
          location_scope: 'any',
          sort: 1,
          archived_at: null,
        },
      ],
    });
    const { user } = setup({ job: jobDetailRow({ custom_data: { gate_code: '1234' } }) });
    const card = (await screen.findByRole('heading', { name: 'Job details' })).closest('section');
    expect(await within(card as HTMLElement).findByText('1234')).toBeInTheDocument();
    await user.click(within(card as HTMLElement).getByRole('button', { name: 'Edit' }));
    const input = within(card as HTMLElement).getByLabelText('Gate code');
    await user.clear(input);
    await user.type(input, '5678');
    await user.click(within(card as HTMLElement).getByRole('button', { name: 'Save details' }));
    await waitFor(() =>
      expect((builders.jobs ?? []).flatMap((b) => b.update.mock.calls)).toContainEqual([
        { custom_data: { gate_code: '5678' } },
      ]),
    );
  });

  it('shows the deposit reminders and pauses them', async () => {
    const { user } = setup({
      rpc: {
        set_document_followups_paused: {
          kind: 'deposit',
          enabled: true,
          paused: true,
          attempts_sent: 1,
          max_attempts: 3,
          last_sent_at: null,
          next_at: null,
        },
      },
    });
    expect(
      await screen.findByText('Next reminder Tue, Oct 6, 2026 · 10:00 AM · 1 of 3 sent.'),
    ).toBeInTheDocument();
    await user.click(screen.getByRole('switch', { name: 'Pause reminders for this job' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('set_document_followups_paused', {
        p_kind: 'deposit',
        p_id: 'job-1',
        p_paused: true,
      }),
    );
  });

  it('credits the sale to another member', async () => {
    const { user } = setup({ job: jobDetailRow({ sold_by_member_id: 'member-1' }) });
    const select = await screen.findByLabelText('Sold by');
    expect(select).toHaveValue('member-1');
    await user.selectOptions(select, 'member-2');
    await waitFor(() =>
      expect((builders.jobs ?? []).flatMap((b) => b.update.mock.calls)).toContainEqual([
        { sold_by_member_id: 'member-2' },
      ]),
    );
  });

  it('puts a line on another of the customer’s vehicles', async () => {
    setTableResult('vehicles', {
      data: [
        {
          id: 'veh-1',
          year: 2021,
          make: 'Honda',
          model: 'Civic',
          trim: null,
          color: 'Blue',
          vin: null,
          license_plate: 'ABC123',
          category_id: 'cat-1',
        },
        {
          id: 'veh-2',
          year: 2019,
          make: 'Ford',
          model: 'F-150',
          trim: null,
          color: null,
          vin: null,
          license_plate: null,
          category_id: 'cat-2',
        },
      ],
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Custom item' }));
    const dialog = await screen.findByRole('dialog', { name: 'Add custom item' });
    const picker = within(dialog).getByLabelText('Vehicle');
    expect(picker).toHaveValue('veh-1'); // defaults to the job's vehicle
    await within(dialog).findByRole('option', { name: /2019 Ford F-150/ });
    await user.selectOptions(picker, 'veh-2');
    await user.type(within(dialog).getByLabelText(/Name/), 'Bed liner wash');
    await user.type(within(dialog).getByLabelText(/Unit price/), '40');
    await user.click(within(dialog).getByRole('button', { name: 'Add item' }));
    await waitFor(() =>
      expect(builders.job_line_items?.some((b) => b.insert.mock.calls.length > 0)).toBe(true),
    );
    const insert = builders.job_line_items?.find((b) => b.insert.mock.calls.length > 0)?.insert;
    expect(insert).toHaveBeenCalledWith([
      expect.objectContaining({ name: 'Bed liner wash', vehicle_id: 'veh-2', service_id: null }),
    ]);
  });

  it('marks required checklist items and lets managers require new ones', async () => {
    const { user } = setup();
    setTableResult('job_checklist_items', {
      data: [
        {
          id: 'chk-1',
          label: 'Vacuum interior',
          sort: 1,
          done_at: null,
          done_by: null,
          template_id: null,
          required: true,
        },
      ],
    });
    // the badge is part of the item's label
    expect(
      await screen.findByRole('checkbox', { name: /Vacuum interior\s*Required/ }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole('button', { name: 'Required to complete: Vacuum interior' }),
    ).toHaveAttribute('aria-pressed', 'true');
    await user.type(screen.getByLabelText('New checklist item'), 'Photo of odometer');
    await user.click(screen.getByRole('checkbox', { name: 'Required' }));
    await user.type(screen.getByLabelText('New checklist item'), '{Enter}');
    await waitFor(() =>
      expect(builders.job_checklist_items?.some((b) => b.insert.mock.calls.length > 0)).toBe(true),
    );
    const insert = builders.job_checklist_items?.find(
      (b) => b.insert.mock.calls.length > 0,
    )?.insert;
    expect(insert).toHaveBeenCalledWith(
      expect.objectContaining({ label: 'Photo of odometer', required: true }),
    );
  });
});
