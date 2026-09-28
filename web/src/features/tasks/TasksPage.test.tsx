import { fireEvent, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue, signedInAuth } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import { dueAtFrom, dueState, isMine, sortOpenTasks, taskWrite, validateTask } from './model';
import TasksPage from './TasksPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

function task(id: string, extra: Record<string, unknown> = {}) {
  return {
    id,
    title: `Task ${id}`,
    notes: null,
    assignee_member_id: 'member-1',
    due_at: null,
    customer_id: null,
    job_id: null,
    done_at: null,
    created_by: 'user-1',
    created_at: '2026-09-20T15:00:00Z',
    customer: null,
    job: null,
    ...extra,
  };
}

function renderAs(role: 'owner' | 'technician', path = '/app/tasks') {
  return renderRoute(<TasksPage />, {
    path,
    routePath: '/app/tasks',
    shop: shopValue({ membership: membership({ role }) }),
    auth: signedInAuth('me@example.com', 'user-1'),
  });
}

beforeEach(() => {
  resetSupabaseMock();
  supabase.rpc.mockImplementation(((fn: string) =>
    createBuilder({
      data:
        fn === 'shop_team'
          ? [
              { member_id: 'member-1', display_name: 'Olivia Owner', active: true },
              { member_id: 'm-tech', display_name: 'Theo Tech', active: true },
            ]
          : [],
    })) as never);
});

describe('TasksPage', () => {
  it('lists my open tasks, overdue first, with links', async () => {
    setTableResult('tasks', {
      data: [
        task('t1', { title: 'Order coating', due_at: '2099-01-01T15:00:00Z' }),
        task('t2', {
          title: 'Call back Dana',
          due_at: '2020-01-01T15:00:00Z',
          job_id: 'job-1',
          job: { id: 'job-1', number: 1042 },
        }),
        task('t3', { title: 'Theo’s errand', assignee_member_id: 'm-tech', created_by: 'user-9' }),
      ],
    });
    renderAs('owner');
    const list = await screen.findByRole('list', { name: 'My tasks' });
    const items = within(list).getAllByRole('listitem');
    expect(items.map((i) => i.textContent)).toEqual([
      expect.stringContaining('Call back Dana'),
      expect.stringContaining('Order coating'),
    ]);
    expect(within(items[0]!).getByText('Overdue')).toBeInTheDocument();
    expect(within(items[0]!).getByRole('link', { name: 'Job #1042' })).toHaveAttribute(
      'href',
      '/app/jobs/job-1',
    );
    expect(screen.getByRole('tab', { name: 'All open' })).toBeInTheDocument();
  });

  it('ticks a task done optimistically', async () => {
    setTableResult('tasks', { data: [task('t1', { title: 'Order coating' })] });
    const { user } = renderAs('owner');
    const box = await screen.findByRole('checkbox', { name: 'Mark “Order coating” done' });
    await user.click(box);
    await waitFor(() => {
      const update = builders.tasks?.find((b) => b.update.mock.calls.length > 0);
      expect(update?.update).toHaveBeenCalledWith({ done_at: expect.any(String) });
      expect(update?.eq).toHaveBeenCalledWith('id', 't1');
    });
  });

  it('shows the tick at once, while the update is on its way', async () => {
    setTableResult('tasks', { data: [task('t1', { title: 'Order coating' })] });
    renderAs('owner');
    const box = await screen.findByRole('checkbox', { name: 'Mark “Order coating” done' });
    // Synchronous click: the checkbox must not snap back before the async
    // optimistic update (onMutate) has run.
    fireEvent.click(box);
    expect(box).toBeChecked();
    await waitFor(() =>
      expect(builders.tasks?.some((b) => b.update.mock.calls.length > 0)).toBe(true),
    );
  });

  it('creates a task assigned to a teammate with a due time', async () => {
    setTableResult('tasks', { data: [] });
    const { user } = renderAs('owner');
    await user.click(await screen.findByRole('button', { name: 'New task' }));
    const dialog = await screen.findByRole('dialog', { name: 'New task' });
    await user.type(within(dialog).getByRole('textbox', { name: /Title/ }), 'Restock pads');
    await user.type(within(dialog).getByLabelText('Due date'), '2026-10-02');
    await user.type(within(dialog).getByLabelText('Due time'), '14:30');
    await user.selectOptions(
      within(dialog).getByRole('combobox', { name: /Assigned to/ }),
      'm-tech',
    );
    await user.click(within(dialog).getByRole('button', { name: 'Add task' }));
    await waitFor(() => {
      const insert = builders.tasks?.find((b) => b.insert.mock.calls.length > 0);
      expect(insert?.insert).toHaveBeenCalledWith({
        shop_id: 'shop-1',
        title: 'Restock pads',
        notes: null,
        due_at: '2026-10-02T19:30:00.000Z',
        assignee_member_id: 'm-tech',
        customer_id: null,
        job_id: null,
      });
    });
  });

  it('technicians assign only themselves and have no "All open" list', async () => {
    setTableResult('tasks', { data: [] });
    const { user } = renderAs('technician', '/app/tasks?view=all');
    expect(await screen.findByText('Nothing on your list')).toBeInTheDocument();
    expect(screen.queryByRole('tab', { name: 'All open' })).not.toBeInTheDocument();
    await user.click(screen.getAllByRole('button', { name: 'New task' })[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'New task' });
    const assignee = within(dialog).getByRole('combobox', { name: /Assigned to/ });
    expect(
      within(assignee)
        .getAllByRole('option')
        .map((o) => o.textContent),
    ).toEqual(['Me', 'Nobody']);
    expect(within(dialog).queryByText('Customer')).not.toBeInTheDocument();
  });
});

describe('task rules', () => {
  const TZ = 'America/Chicago';
  it('validates, computes the due instant and orders open tasks', () => {
    expect(
      validateTask({
        title: ' ',
        notes: '',
        dueDate: '',
        dueTime: '10:00',
        assigneeId: '',
        customerId: null,
        jobId: null,
      }),
    ).toEqual({
      title: 'Give the task a title.',
      due: 'Choose a date for the due time.',
    });
    expect(dueAtFrom({ dueDate: '2026-10-02', dueTime: '' }, TZ)).toBe('2026-10-02T14:00:00.000Z');
    const a = task('a', { due_at: '2026-10-03T00:00:00Z' });
    const b = task('b', { due_at: '2026-10-01T00:00:00Z' });
    const c = task('c');
    expect(sortOpenTasks([c, a, b]).map((t) => t.id)).toEqual(['b', 'a', 'c']);
    expect(dueState(b, TZ, new Date('2026-10-02T00:00:00Z'))).toBe('overdue');
    expect(isMine(task('x', { assignee_member_id: null, created_by: 'u' }), 'm', 'u')).toBe(true);
    expect(isMine(task('x', { assignee_member_id: 'other', created_by: 'u' }), 'm', 'u')).toBe(
      false,
    );
  });

  it('never sends assignee, customer or job changes for a technician’s edit', () => {
    const draft = {
      title: 'T',
      notes: '',
      dueDate: '',
      dueTime: '',
      assigneeId: 'm',
      customerId: 'c',
      jobId: 'j',
    };
    expect(taskWrite(draft, TZ, { manager: false, isNew: false })).toEqual({
      title: 'T',
      notes: null,
      due_at: null,
    });
    expect(taskWrite(draft, TZ, { manager: false, isNew: true })).toEqual({
      title: 'T',
      notes: null,
      due_at: null,
      assignee_member_id: 'm',
      job_id: 'j',
    });
  });
});
