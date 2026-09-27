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

vi.mock('@/lib/supabase', async () => {
  const mod = await import('@/test/supabaseMock');
  const bucket = {
    createSignedUrls: vi.fn((paths: string[]) =>
      Promise.resolve({
        data: paths.map((path) => ({
          path,
          signedUrl: `https://signed.test/${path}`,
          error: null,
        })),
        error: null,
      }),
    ),
    upload: vi.fn(() => Promise.resolve({ data: { path: 'x' }, error: null })),
    remove: vi.fn(() => Promise.resolve({ data: [], error: null })),
  };
  return {
    ...mod,
    supabase: Object.assign(mod.supabase, {
      functions: { invoke: vi.fn() },
      storage: { from: vi.fn(() => bucket) },
    }),
  };
});

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
  setTableResult('job_line_items', {
    data: [
      {
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
      },
    ],
  });
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
    const { user } = setup();
    const next = await screen.findByRole('button', { name: 'Mark as Confirmed' });
    await user.click(next);
    await waitFor(() =>
      expect(builders.jobs?.some((b) => b.update.mock.calls.length > 0)).toBe(true),
    );
    const statusUpdate = builders.jobs?.find((b) => b.update.mock.calls.length > 0);
    expect(statusUpdate?.update).toHaveBeenCalledWith({ status: 'confirmed' });

    await user.click(screen.getByRole('button', { name: 'Cancel job' }));
    const dialog = await screen.findByRole('dialog', { name: 'Cancel this job?' });
    await user.type(within(dialog).getByLabelText(/Reason/), 'Customer rescheduled');
    await user.click(within(dialog).getByRole('button', { name: 'Cancel job' }));
    await waitFor(() => {
      const calls = (builders.jobs ?? []).flatMap((b) => b.update.mock.calls);
      expect(calls).toContainEqual([
        { status: 'cancelled', cancel_reason: 'Customer rescheduled' },
      ]);
    });
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
