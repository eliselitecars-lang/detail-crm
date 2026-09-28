import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue, signedInAuth } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  setFunctionResult,
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
  setTableResult('job_status_transitions', { data: TRANSITIONS });
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
