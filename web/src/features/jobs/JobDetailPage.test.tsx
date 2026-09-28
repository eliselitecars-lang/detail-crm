import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue, signedInAuth } from '@/test/render';
import {
  builders,
  createBuilder,
  pgError,
  resetSupabaseMock,
  setFunctionResult,
  setTableResult,
  supabase,
  type MockResult,
} from '@/test/supabaseMock';
import JobDetailPage from './JobDetailPage';
import { jobDetailRow, TEAM, TRANSITIONS } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const SUMMARY = {
  job_id: 'job-1',
  invoice_id: null,
  invoice_number: null,
  invoice_status: null,
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

function setup(
  options: {
    role?: 'owner' | 'manager' | 'technician';
    job?: ReturnType<typeof jobDetailRow>;
    rpc?: Record<string, unknown>;
    /** Keep job_line_items as the test set them. */
    keepLines?: boolean;
    /** What the job_status_transitions read answers (default: TRANSITIONS). */
    transitions?: MockResult;
  } = {},
) {
  const job = options.job ?? jobDetailRow();
  const role = options.role ?? 'owner';
  const rpc: Record<string, unknown> = {
    shop_team: TEAM,
    job_payment_summary: [SUMMARY],
    ...options.rpc,
  };
  supabase.rpc.mockImplementation((...args: unknown[]) =>
    createBuilder({ data: rpc[String(args[0])] ?? null }),
  );
  setTableResult('jobs', { data: job });
  setTableResult('job_status_transitions', options.transitions ?? { data: TRANSITIONS });
  if (!options.keepLines) setTableResult('job_line_items', { data: [LINE] });
  setTableResult('job_assignments', { data: [{ id: 'a-1', member_id: 'member-2' }] });
  setTableResult('job_checklist_items', {
    data: [
      {
        id: 'chk-1',
        label: 'Vacuum interior',
        sort: 1,
        done_at: null,
        done_by: null,
        template_id: null,
      },
    ],
  });
  const tech = role === 'technician';
  return renderRoute(<JobDetailPage />, {
    path: '/app/jobs/job-1',
    routePath: '/app/jobs/:jobId',
    auth: signedInAuth(tech ? 'tech@example.com' : 'owner@example.com', tech ? 'user-2' : 'user-1'),
    shop: shopValue({
      membership: membership({ role, memberId: tech ? 'member-2' : 'member-1' }),
    }),
    routes: [{ path: '/app/invoices/:invoiceId', element: <p>Invoice page</p> }],
  });
}

const LINE = {
  id: 'line-1',
  service_id: 'svc-1',
  vehicle_id: 'veh-1',
  name: 'Full detail',
  description: null,
  quantity: 1,
  unit_price_cents: 25000,
  discount_cents: 0,
  taxable: true,
  duration_minutes: 120,
  sort: 1,
  total_cents: 25000,
};

/** A cancel_open_payments answer for job-1 (nothing released unless overridden). */
function released(counts: Partial<Record<'cancelled' | 'succeeded' | 'in_progress', number>> = {}) {
  return {
    invoice_id: null,
    job_id: 'job-1',
    cancelled: 0,
    succeeded: 0,
    in_progress: 0,
    sessions_expired: 0,
    ...counts,
  };
}

beforeEach(() => resetSupabaseMock());

describe('JobDetailPage', () => {
  it('shows the job header, people, schedule in the shop timezone and server totals', async () => {
    setup();
    expect(await screen.findByRole('heading', { name: 'Job #1001', level: 1 })).toBeInTheDocument();
    // 14:00Z is 9:00 AM in America/Chicago (the test browser runs in Honolulu)
    expect(screen.getAllByText(/9:00/).length).toBeGreaterThan(0);
    expect(screen.getByRole('link', { name: 'Call Jane Doe' })).toHaveAttribute(
      'href',
      'tel:+12055550123',
    );
    expect(screen.getByRole('link', { name: /1 Main St, Birmingham, AL 35203/ })).toHaveAttribute(
      'href',
      expect.stringContaining('google.com/maps'),
    );
    expect(await screen.findByText('Full detail')).toBeInTheDocument();
    expect(screen.getAllByText('$271.88').length).toBeGreaterThan(0); // job total from the server
    expect(await screen.findByText('Vacuum interior')).toBeInTheDocument();
  });

  it('lets a manager move the status forward and cancel with a reason', async () => {
    setFunctionResult('payments', { data: released() });
    const { user } = setup();
    const next = await screen.findByRole('button', { name: 'Mark as Confirmed' });
    await user.click(next);
    // one RPC with the same transition rules as a direct update (0073)
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('set_job_status', {
        p_job_id: 'job-1',
        p_status: 'confirmed',
      }),
    );

    await user.click(screen.getByRole('button', { name: 'Cancel job' }));
    const dialog = await screen.findByRole('dialog', { name: 'Cancel this job?' });
    await user.type(within(dialog).getByLabelText(/Reason/), 'Customer rescheduled');
    await user.click(within(dialog).getByRole('button', { name: 'Cancel job' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('set_job_status', {
        p_job_id: 'job-1',
        p_status: 'cancelled',
        p_reason: 'Customer rescheduled',
      }),
    );
    // Open card payments / pay links are released first.
    expect(supabase.functions.invoke).toHaveBeenCalledWith('payments', {
      body: { action: 'cancel_open_payments', shop_id: 'shop-1', job_id: 'job-1' },
    });
  });

  it('refuses to cancel while a card payment on the job is processing', async () => {
    setFunctionResult('payments', { data: released({ in_progress: 1 }) });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Cancel job' }));
    const dialog = await screen.findByRole('dialog', { name: 'Cancel this job?' });
    await user.click(within(dialog).getByRole('button', { name: 'Cancel job' }));
    expect(
      await within(dialog).findByText('A card payment is in progress — wait for it to finish.'),
    ).toBeInTheDocument();
    expect(supabase.rpc).not.toHaveBeenCalledWith('set_job_status', expect.anything());
  });

  it('says so when money was recorded, then marks the no-show', async () => {
    setFunctionResult('payments', { data: released({ succeeded: 1 }) });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'No-show' }));
    const confirm = await screen.findByRole('alertdialog', { name: 'Mark as no-show?' });
    await user.click(within(confirm).getByRole('button', { name: 'Mark no-show' }));
    expect(await screen.findByText('A card payment was recorded')).toBeInTheDocument();
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('set_job_status', {
        p_job_id: 'job-1',
        p_status: 'no_show',
      }),
    );
  });

  it('moves a line with one reorder_job_line_items call', async () => {
    setTableResult('job_line_items', {
      data: [
        { ...LINE, id: 'line-1', name: 'Full detail', sort: 0 },
        { ...LINE, id: 'line-2', name: 'Hand wax', sort: 0 },
      ],
    });
    const { user } = setup({ keepLines: true });
    await user.click(await screen.findByRole('button', { name: 'Move Hand wax up' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('reorder_job_line_items', {
        p_job_id: 'job-1',
        p_ids: ['line-2', 'line-1'],
      }),
    );
    expect((builders.job_line_items ?? []).some((b) => b.update.mock.calls.length > 0)).toBe(false);
  });

  it('gives technicians only their forward steps and no money or editing', async () => {
    setup({ role: 'technician' });
    await screen.findByRole('heading', { name: 'Job #1001', level: 1 });
    expect(await screen.findByRole('button', { name: 'Mark as On the way' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Mark as In progress' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Mark as Confirmed' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Cancel job' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Add service' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Create invoice' })).not.toBeInTheDocument();
    expect(screen.queryByText('$271.88')).not.toBeInTheDocument();
    // assigned technicians can clock in on the job
    expect(await screen.findByRole('button', { name: 'Clock in on this job' })).toBeInTheDocument();
  });

  it('creates an invoice from the job and opens it', async () => {
    const { user, router } = setup({
      rpc: { create_invoice_from_job: { id: 'inv-9', number: 2001 } },
    });
    const button = await screen.findByRole('button', { name: 'Create invoice' });
    expect(await screen.findByText('Deposit due')).toBeInTheDocument();
    await user.click(button);
    await waitFor(() => expect(router.state.location.pathname).toBe('/app/invoices/inv-9'));
    expect(supabase.rpc).toHaveBeenCalledWith('create_invoice_from_job', { p_job_id: 'job-1' });
  });

  it('links to the existing invoice instead of creating another', async () => {
    setup({
      rpc: {
        job_payment_summary: [
          { ...SUMMARY, invoice_id: 'inv-1', invoice_number: 2001, invoice_status: 'open' },
        ],
      },
    });
    expect(await screen.findByRole('link', { name: 'Open invoice' })).toHaveAttribute(
      'href',
      '/app/invoices/inv-1',
    );
    expect(screen.queryByRole('button', { name: 'Create invoice' })).not.toBeInTheDocument();
  });

  it('locks the services and discount of a billed job (0097) and says why', async () => {
    setup({
      rpc: {
        job_payment_summary: [
          { ...SUMMARY, invoice_id: 'inv-1', invoice_number: 2001, invoice_status: 'paid' },
        ],
      },
    });
    const note = await screen.findByText(/its services, prices and discount can’t change/);
    expect(within(note).getByRole('link', { name: 'invoice #2001' })).toHaveAttribute(
      'href',
      '/app/invoices/inv-1',
    );
    expect(screen.queryByRole('button', { name: 'Add service' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Custom item' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Edit Full detail' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Delete Full detail' })).toBeDisabled();
    const card = screen.getByRole('heading', { name: 'Services & items' }).closest('section');
    expect(card).not.toBeNull();
    expect(within(card!).queryByRole('button', { name: /^(Add|Change)$/ })).toBeNull();
  });

  it('keeps a job editable once its invoice is void', async () => {
    setup({
      rpc: {
        job_payment_summary: [
          { ...SUMMARY, invoice_id: 'inv-1', invoice_number: 2001, invoice_status: 'void' },
        ],
      },
    });
    expect(await screen.findByRole('button', { name: 'Add service' })).toBeInTheDocument();
    expect(screen.queryByText(/its services, prices and discount can’t change/)).toBeNull();
    const card = screen.getByRole('heading', { name: 'Services & items' }).closest('section');
    expect(within(card!).getByRole('button', { name: /^(Add|Change)$/ })).toBeEnabled();
  });

  it('shares a form link only with managers, fetched from form_link_token', async () => {
    const FORM = {
      id: 'form-1',
      title: 'Liability waiver',
      body_snapshot: 'I accept the risks.',
      requires_signature: true,
      signer_name: null,
      signed_at: null,
      created_at: '2026-09-20T15:00:00Z',
      form_template_id: 'tpl-1',
    };
    setTableResult('form_submissions', { data: [FORM] });
    const { user } = setup({
      role: 'manager',
      rpc: { form_link_token: '60000000-0000-4000-8000-000000000001' },
    });
    await user.click(await screen.findByRole('button', { name: 'Copy link' }));
    expect(supabase.rpc).toHaveBeenCalledWith('form_link_token', { p_submission_id: 'form-1' });
    expect(await screen.findByText('Form link copied')).toBeInTheDocument();
    expect(builders.form_submissions?.[0]?.select).toHaveBeenCalledWith(
      expect.not.stringContaining('public_token'),
    );
  });

  it('shows the form link in a dialog that stays when the browser refuses to copy it (Safari)', async () => {
    setTableResult('form_submissions', {
      data: [
        {
          id: 'form-1',
          title: 'Liability waiver',
          body_snapshot: 'I accept the risks.',
          requires_signature: true,
          signer_name: null,
          signed_at: null,
          created_at: '2026-09-20T15:00:00Z',
          form_template_id: 'tpl-1',
        },
      ],
    });
    const { user } = setup({
      role: 'manager',
      rpc: { form_link_token: '60000000-0000-4000-8000-000000000001' },
    });
    const copy = await screen.findByRole('button', { name: 'Copy link' });
    const write = vi
      .spyOn(navigator.clipboard, 'writeText')
      .mockRejectedValue(new DOMException('no user activation', 'NotAllowedError'));
    Object.defineProperty(document, 'execCommand', { value: () => false, configurable: true });
    try {
      await user.click(copy);
      const dialog = await screen.findByRole('dialog', { name: 'Copy this link' });
      expect(within(dialog).getByRole('status', { name: 'Form link' })).toHaveTextContent(
        `${window.location.origin}/f/60000000-0000-4000-8000-000000000001`,
      );
      expect(screen.queryByText('Form link copied')).not.toBeInTheDocument();
    } finally {
      write.mockRestore();
      Reflect.deleteProperty(document, 'execCommand');
    }
  });

  it('lets technicians sign forms on their device but never share the customer’s link', async () => {
    setTableResult('form_submissions', {
      data: [
        {
          id: 'form-1',
          title: 'Liability waiver',
          body_snapshot: 'I accept the risks.',
          requires_signature: true,
          signer_name: null,
          signed_at: null,
          created_at: '2026-09-20T15:00:00Z',
          form_template_id: 'tpl-1',
        },
      ],
    });
    setup({ role: 'technician' });
    expect(await screen.findByRole('button', { name: 'Sign here' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Copy link' })).not.toBeInTheDocument();
    expect(supabase.rpc).not.toHaveBeenCalledWith('form_link_token', expect.anything());
  });

  it('confirms before removing a checklist item or a damage mark (and its photo)', async () => {
    setTableResult('inspections', {
      data: [
        {
          id: 'insp-1',
          job_id: 'job-1',
          vehicle_id: 'veh-1',
          kind: 'pre',
          mileage: null,
          fuel_level: null,
          notes: null,
          customer_signature_path: null,
          signed_by_name: null,
          signed_at: null,
          signed_remotely: false,
          created_at: '2026-01-01T00:00:00Z',
          marks: [
            {
              id: 'mark-1',
              view: 'front',
              x: 0.4,
              y: 0.5,
              damage: 'dent',
              note: null,
              photo_path: 'shop-1/job-1/mark-1.jpg',
              created_at: '2026-01-01T00:00:00Z',
            },
          ],
        },
      ],
    });
    const { user } = setup();
    const deletes = (table: string) =>
      (builders[table] ?? []).filter((b) => b.delete.mock.calls.length > 0);

    // Checklist item: a mis-tap only opens the confirmation.
    await user.click(await screen.findByRole('button', { name: 'Remove Vacuum interior' }));
    let confirm = await screen.findByRole('alertdialog', { name: 'Remove this item?' });
    expect(confirm).toHaveTextContent('Vacuum interior');
    await user.click(within(confirm).getByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(screen.queryByRole('alertdialog')).toBeNull());
    expect(deletes('job_checklist_items')).toHaveLength(0);

    await user.click(screen.getByRole('button', { name: 'Remove Vacuum interior' }));
    confirm = await screen.findByRole('alertdialog', { name: 'Remove this item?' });
    await user.click(within(confirm).getByRole('button', { name: 'Remove' }));
    await waitFor(() => expect(deletes('job_checklist_items')).toHaveLength(1));
    expect(deletes('job_checklist_items')[0]?.eq).toHaveBeenCalledWith('id', 'chk-1');

    // Damage mark: its photo is evidence, so nothing is deleted until confirmed.
    const photos = supabase.storage.from('job-photos');
    await user.click(await screen.findByRole('button', { name: 'Remove mark 1' }));
    confirm = await screen.findByRole('alertdialog', { name: 'Remove mark 1?' });
    expect(confirm).toHaveTextContent('its photo is deleted too');
    await user.click(within(confirm).getByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(screen.queryByRole('alertdialog')).toBeNull());
    expect(deletes('inspection_marks')).toHaveLength(0);
    expect(photos.remove).not.toHaveBeenCalled();

    await user.click(screen.getByRole('button', { name: 'Remove mark 1' }));
    confirm = await screen.findByRole('alertdialog', { name: 'Remove mark 1?' });
    await user.click(within(confirm).getByRole('button', { name: 'Remove' }));
    await waitFor(() => expect(photos.remove).toHaveBeenCalledWith(['shop-1/job-1/mark-1.jpg']));
    expect(deletes('inspection_marks')[0]?.eq).toHaveBeenCalledWith('id', 'mark-1');
  });

  it('says why the status can’t change when its steps fail to load, and retries', async () => {
    const { user } = setup({ transitions: pgError('XX000', 'upstream timeout') });
    const message = await screen.findByText(/Couldn’t load the status steps/);
    const alert = message.closest<HTMLElement>('[role="alert"]');
    expect(alert).not.toBeNull();
    expect(screen.queryByRole('button', { name: 'Cancel job' })).toBeNull();

    setTableResult('job_status_transitions', { data: TRANSITIONS });
    await user.click(within(alert!).getByRole('button', { name: 'Try again' }));
    expect(await screen.findByRole('button', { name: 'Cancel job' })).toBeInTheDocument();
    expect(screen.queryByText(/Couldn’t load the status steps/)).toBeNull();
  });

  it('explains in visible text that an unscheduled job must be scheduled first', async () => {
    setup({
      job: jobDetailRow({ status: 'requested', scheduled_start: null, scheduled_end: null }),
    });
    const hint = await screen.findByText(
      'Schedule the job first: it needs a date and time before it can be marked Scheduled.',
    );
    expect(screen.queryByRole('button', { name: 'Mark as Scheduled' })).toBeNull();
    const step = within(screen.getByRole('navigation', { name: 'Job status' })).getByText(
      'Scheduled',
    );
    expect(step.closest('span')?.getAttribute('aria-describedby')).toBe(hint.id);
  });

  it('shows a not-found error without a retry loop', async () => {
    setTableResult('jobs', { data: null });
    renderRoute(<JobDetailPage />, {
      path: '/app/jobs/missing',
      routePath: '/app/jobs/:jobId',
      shop: shopValue(),
    });
    expect(await screen.findByText('Couldn’t load this job')).toBeInTheDocument();
  });
});
