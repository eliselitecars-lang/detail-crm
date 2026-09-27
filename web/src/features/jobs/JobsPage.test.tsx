import { screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import JobsPage from './JobsPage';
import { jobListRow, TEAM } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

function setup(options: { role?: 'owner' | 'technician'; path?: string } = {}) {
  const rpc: Record<string, unknown> = {
    shop_team: TEAM,
    search_shop: [
      { kind: 'customer', id: 'cust-1', customer_id: 'cust-1' },
      { kind: 'job', id: 'job-7', customer_id: 'cust-1' },
    ],
  };
  supabase.rpc.mockImplementation((...args: unknown[]) =>
    createBuilder({ data: rpc[String(args[0])] ?? null }),
  );
  return renderRoute(<JobsPage />, {
    path: options.path ?? '/app/jobs',
    routePath: '/app/jobs',
    shop: shopValue({ membership: membership({ role: options.role ?? 'owner' }) }),
  });
}

beforeEach(() => resetSupabaseMock());

describe('JobsPage', () => {
  it('lists jobs with shop-time schedule, services, assignees and server totals', async () => {
    setTableResult('jobs', { data: [jobListRow()], count: 1 });
    setup();
    expect((await screen.findAllByText('#1001')).length).toBeGreaterThan(0);
    expect(screen.getAllByText('Jane Doe').length).toBeGreaterThan(0);
    expect(screen.getAllByText('2021 Honda Civic').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Full detail, Wax').length).toBeGreaterThan(0);
    expect((await screen.findAllByText('Theo Tech')).length).toBeGreaterThan(0);
    expect(screen.getAllByText('$271.88').length).toBeGreaterThan(0);
    expect(screen.getAllByText(/9:00/).length).toBeGreaterThan(0); // America/Chicago, not the browser zone
    expect(screen.getByRole('link', { name: /New job/ })).toHaveAttribute('href', '/app/jobs/new');
  });

  it('filters by status and searches by customer / job number via search_shop', async () => {
    setTableResult('jobs', { data: [jobListRow()], count: 1 });
    const { user, router } = setup();
    await screen.findAllByText('#1001');
    await user.click(screen.getByRole('button', { name: 'Confirmed' }));
    await waitFor(() => expect(router.state.location.search).toBe('?status=confirmed'));
    await waitFor(() =>
      expect(builders.jobs?.some((b) => b.in.mock.calls.some((c) => c[0] === 'status'))).toBe(true),
    );

    await user.type(screen.getByRole('searchbox', { name: 'Search jobs' }), 'jane');
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('search_shop', {
        p_shop_id: 'shop-1',
        p_query: 'jane',
        p_limit: 50,
      }),
    );
    await waitFor(() => expect(builders.jobs?.some((b) => b.or.mock.calls.length > 0)).toBe(true));
    const orCall = builders.jobs?.find((b) => b.or.mock.calls.length > 0)?.or.mock.calls[0];
    expect(orCall?.[0]).toBe('id.in.(job-7),customer_id.in.(cust-1)');
  });

  it('shows an empty state and a filtered empty state', async () => {
    setTableResult('jobs', { data: [], count: 0 });
    setup();
    expect(await screen.findByText('No jobs yet')).toBeInTheDocument();
  });

  it('shows an error with retry', async () => {
    setTableResult('jobs', { error: { message: 'boom', code: 'XX000' } });
    setup();
    expect(await screen.findByRole('button', { name: /Try again|Retry/ })).toBeInTheDocument();
  });

  it('hides money, the assignee filter and job creation from technicians', async () => {
    setTableResult('jobs', { data: [jobListRow()], count: 1 });
    setup({ role: 'technician' });
    expect((await screen.findAllByText('#1001')).length).toBeGreaterThan(0);
    expect(screen.getAllByText('Jobs assigned to you.').length).toBeGreaterThan(0);
    expect(screen.queryAllByText('$271.88')).toHaveLength(0);
    expect(screen.queryByLabelText('Assigned to')).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: /New job/ })).not.toBeInTheDocument();
  });
});
