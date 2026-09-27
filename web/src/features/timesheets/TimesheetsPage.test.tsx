import { fireEvent, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import TimesheetsPage from './TimesheetsPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const members = [
  {
    member_id: 'member-1',
    display_name: 'Olivia Owner',
    role: 'manager',
    active: true,
    calendar_color: null,
  },
  {
    member_id: 'm-tech',
    display_name: 'Theo Tech',
    role: 'technician',
    active: true,
    calendar_color: null,
  },
];

const entries = [
  {
    id: 'e1',
    member_id: 'm-tech',
    job_id: null,
    kind: 'shift',
    clock_in: '2026-03-10T13:00:00Z', // 8:00 AM Chicago
    clock_out: '2026-03-10T21:30:00Z', // 4:30 PM
    source: 'app',
    notes: 'Mobile route',
    job: null,
  },
  {
    id: 'e2',
    member_id: 'm-tech',
    job_id: 'j1',
    kind: 'job',
    clock_in: '2026-03-10T14:00:00Z',
    clock_out: '2026-03-10T16:00:00Z',
    source: 'app',
    notes: null,
    job: { id: 'j1', number: 1042 },
  },
];

function rpcResults(results: Record<string, unknown>) {
  supabase.rpc.mockImplementation(((fn: string) =>
    createBuilder({ data: results[fn] ?? null })) as never);
}

function renderAs(role: 'manager' | 'technician') {
  return renderRoute(<TimesheetsPage />, {
    shop: shopValue({ membership: membership({ role }) }),
  });
}

async function setRange(from: string, to: string) {
  fireEvent.change(await screen.findByLabelText('From'), { target: { value: from } });
  fireEvent.change(screen.getByLabelText('To'), { target: { value: to } });
}

beforeEach(() => {
  resetSupabaseMock();
  rpcResults({ shop_team: members });
});

describe('TimesheetsPage', () => {
  it('manager sees entries with totals per member and day', async () => {
    setTableResult('time_entries', { data: entries });
    renderAs('manager');
    await setRange('2026-03-09', '2026-03-15');

    const totals = await screen.findByRole('table', { name: 'Totals per team member' });
    const row = within(totals).getByRole('row', { name: /Theo Tech/ });
    expect(row).toHaveTextContent('8h 30m');
    expect(row).toHaveTextContent('2h 00m');

    const byDay = screen.getByRole('table', { name: 'Hours per team member per day' });
    expect(within(byDay).getByRole('row', { name: /Tue, Mar 10/ })).toHaveTextContent('8h 30m');

    const list = screen.getByRole('table', { name: 'Time entries' });
    expect(within(list).getByRole('row', { name: /Job #1042/ })).toHaveTextContent(
      'Tue, Mar 10, 2026 · 9:00 AM',
    );
    expect(screen.getAllByRole('button', { name: /Edit entry/ }).length).toBeGreaterThan(0);
    const listQuery = builders.time_entries?.filter((b) => b.or.mock.calls.length > 0).at(-1);
    expect(listQuery?.lt).toHaveBeenCalledWith('clock_in', '2026-03-16T05:00:00.000Z');
    expect(listQuery?.or).toHaveBeenCalledWith(
      'clock_out.is.null,clock_out.gte.2026-03-09T05:00:00.000Z',
    );
  });

  it('highlights running entries', async () => {
    setTableResult('time_entries', { data: [{ ...entries[0], clock_out: null }] });
    renderAs('manager');
    expect(await screen.findByText(/1 entry is still running/)).toBeInTheDocument();
    expect(screen.getAllByText('Running').length).toBeGreaterThan(0);
  });

  it('adds a manual entry and shows the server overlap error', async () => {
    setTableResult('time_entries', { data: [] });
    const { user } = renderAs('manager');
    await user.click((await screen.findAllByRole('button', { name: 'Add entry' }))[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'Add time entry' });
    await user.selectOptions(
      within(dialog).getByRole('combobox', { name: /Team member/ }),
      'm-tech',
    );
    fireEvent.change(within(dialog).getAllByLabelText(/Date/)[0]!, {
      target: { value: '2026-03-10' },
    });
    fireEvent.change(within(dialog).getAllByLabelText(/Time/)[0]!, { target: { value: '08:00' } });
    fireEvent.change(within(dialog).getAllByLabelText(/Date/)[1]!, {
      target: { value: '2026-03-10' },
    });
    fireEvent.change(within(dialog).getAllByLabelText(/Time/)[1]!, { target: { value: '12:00' } });

    setTableResult('time_entries', {
      error: {
        code: '23P01',
        message: 'conflicting key value violates exclusion constraint "time_entries_no_overlap"',
      },
    });
    await user.click(within(dialog).getByRole('button', { name: 'Add entry' }));
    expect(await within(dialog).findByRole('alert')).toHaveTextContent(
      'That overlaps with an existing entry.',
    );
    const insert = builders.time_entries?.find((b) => b.insert.mock.calls.length > 0)?.insert;
    expect(insert).toHaveBeenCalledWith({
      member_id: 'm-tech',
      kind: 'shift',
      job_id: null,
      clock_in: '2026-03-10T13:00:00.000Z',
      clock_out: '2026-03-10T17:00:00.000Z',
      notes: null,
      shop_id: 'shop-1',
      source: 'manual',
    });
  });

  it('technician sees only their own time and can clock in', async () => {
    setTableResult('time_entries', { data: [] });
    rpcResults({
      shop_team: members,
      clock_in: { ...entries[0], member_id: 'member-1', clock_out: null },
    });
    const { user } = renderAs('technician');
    expect(await screen.findByText('You’re clocked out')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Add entry' })).not.toBeInTheDocument();
    expect(screen.queryByRole('combobox', { name: 'Team member' })).not.toBeInTheDocument();
    expect(await screen.findByText('No time entries in this range')).toBeInTheDocument();
    const list = builders.time_entries?.find((b) => b.or.mock.calls.length > 0);
    expect(list?.eq).toHaveBeenCalledWith('member_id', 'member-1');

    await user.click(screen.getByRole('button', { name: 'Clock in' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('clock_in', {
        p_shop_id: 'shop-1',
        p_source: 'web',
      }),
    );
  });

  it('shows the running shift timer and clocks out', async () => {
    const start = new Date(Date.now() - 65 * 60_000).toISOString();
    setTableResult('time_entries', {
      data: [{ ...entries[0], member_id: 'member-1', clock_in: start, clock_out: null }],
    });
    rpcResults({ shop_team: members, clock_out: { ...entries[0], member_id: 'member-1' } });
    const { user } = renderAs('technician');
    expect(await screen.findByRole('timer', { name: 'Time on the clock' })).toHaveTextContent(
      /^1:0[45]:/,
    );
    await user.click(screen.getByRole('button', { name: 'Clock out' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('clock_out', {
        p_shop_id: 'shop-1',
        p_kind: 'shift',
      }),
    );
  });
});
