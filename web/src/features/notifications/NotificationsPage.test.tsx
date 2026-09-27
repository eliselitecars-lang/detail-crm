import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute, shopValue, signedInAuth } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  supabase,
  type Builder,
} from '@/test/supabaseMock';
import { UNREAD_PAGE_SIZE } from './api';
import NotificationsPage from './NotificationsPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const unreadRow = {
  id: 'n-1',
  kind: 'new_booking',
  title: 'New booking request from Jane Doe',
  body: 'Full Detail · Oct 1 at 9:00 AM',
  job_id: 'job-1',
  read_at: null,
  created_at: '2026-09-27T14:00:00Z',
};
const readRow = {
  id: 'n-2',
  kind: 'inbound_message',
  title: 'New text from Sam Lee',
  body: null,
  job_id: null,
  read_at: '2026-09-26T10:00:00Z',
  created_at: '2026-09-26T09:00:00Z',
};

/** Unread and read queries share a table; answer by the filter each one uses. */
type FakeRow = Omit<typeof unreadRow, 'body' | 'job_id' | 'read_at'> & {
  body: string | null;
  job_id: string | null;
  read_at: string | null;
};

function serve({
  unread = [unreadRow],
  read = [readRow],
  failWrites = false,
}: { unread?: FakeRow[]; read?: FakeRow[]; failWrites?: boolean } = {}) {
  const state: { unread: FakeRow[]; read: FakeRow[] } = { unread: [...unread], read: [...read] };
  supabase.from.mockImplementation((table: string) => {
    const builder: Builder = createBuilder({ data: [] });
    let wantsRead = false;
    let writing = false;
    let head = false;
    let range: [number, number] = [0, 999];
    builder.select.mockImplementation((_cols: string, opts?: { head?: boolean }) => {
      head = opts?.head === true;
      return builder;
    });
    builder.range.mockImplementation((from: number, to: number) => {
      range = [from, to];
      return builder;
    });
    // A write "moves" everything to read on the fake server (unless it fails).
    builder.update.mockImplementation(() => {
      writing = true;
      if (failWrites) return builder;
      state.read = [
        ...state.unread.map((r) => ({ ...r, read_at: '2026-09-27T15:00:00Z' })),
        ...state.read,
      ];
      state.unread = [];
      return builder;
    });
    builder.not.mockImplementation(() => {
      wantsRead = true;
      return builder;
    });
    (builder as { then: PromiseLike<unknown>['then'] }).then = (ok, fail) => {
      const rows = wantsRead ? state.read : state.unread;
      const result =
        writing && failWrites
          ? { data: null, error: { code: '08006', message: 'connection failure' }, count: null }
          : head
            ? { data: null, error: null, count: rows.length }
            : { data: rows.slice(range[0], range[1] + 1), error: null, count: null };
      return Promise.resolve(result).then(ok, fail);
    };
    (builders[table] ??= []).push(builder);
    return builder;
  });
}

beforeEach(() => {
  resetSupabaseMock();
});

function setup() {
  return renderRoute(<NotificationsPage />, {
    path: '/app/notifications',
    routePath: '/app/notifications',
    auth: signedInAuth('owner@example.com', 'user-1'),
    shop: shopValue(),
    routes: [{ path: '/app/jobs/:id', element: <p>Job page</p> }],
  });
}

describe('NotificationsPage', () => {
  it('lists unread first, then earlier ones', async () => {
    serve();
    setup();
    const unread = await screen.findByRole('list', { name: 'Unread notifications' });
    expect(within(unread).getByText('New booking request from Jane Doe')).toBeInTheDocument();
    const earlier = await screen.findByRole('list', { name: 'Earlier notifications' });
    expect(within(earlier).getByText('New text from Sam Lee')).toBeInTheDocument();
    expect(within(earlier).getByRole('link', { name: 'Open messages' })).toHaveAttribute(
      'href',
      '/app/messages',
    );
    const queries = builders.notifications ?? [];
    expect(
      queries.some((b) => b.is.mock.calls.some(([c, v]) => c === 'read_at' && v === null)),
    ).toBe(true);
    expect(
      queries.every((b) => b.eq.mock.calls.some(([c, v]) => c === 'user_id' && v === 'user-1')),
    ).toBe(true);
  });

  it('marks one read (optimistically) and opens the job', async () => {
    serve();
    const { user } = setup();
    const unread = await screen.findByRole('list', { name: 'Unread notifications' });
    await user.click(within(unread).getByRole('button', { name: 'Mark read' }));
    await waitFor(() =>
      expect(within(unread).queryByRole('button', { name: 'Mark read' })).not.toBeInTheDocument(),
    );
    const update = builders.notifications?.find((b) => b.update.mock.calls.length > 0);
    expect(update?.eq).toHaveBeenCalledWith('id', 'n-1');
    expect(update?.update).toHaveBeenCalledWith({ read_at: expect.any(String) });
  });

  it('opens the deep link', async () => {
    serve();
    const { user } = setup();
    const unread = await screen.findByRole('list', { name: 'Unread notifications' });
    await user.click(within(unread).getByRole('link', { name: 'Open job' }));
    expect(await screen.findByText('Job page')).toBeInTheDocument();
  });

  it('marks all read with the RPC and dismisses', async () => {
    serve();
    supabase.rpc.mockReturnValueOnce(createBuilder({ data: 1 }));
    const { user } = setup();
    await screen.findByRole('list', { name: 'Unread notifications' });
    await user.click(screen.getByRole('button', { name: 'Mark all read' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('mark_all_notifications_read', {
        p_shop_id: 'shop-1',
      }),
    );
    expect(await screen.findByText('1 notification marked read')).toBeInTheDocument();

    await user.click(
      screen.getByRole('button', { name: 'Dismiss notification: New text from Sam Lee' }),
    );
    await waitFor(() =>
      expect(builders.notifications?.some((b) => b.delete.mock.calls.length > 0)).toBe(true),
    );
  });

  it('pages through unread past the first page, with the exact unread count', async () => {
    const many = Array.from({ length: UNREAD_PAGE_SIZE + 5 }, (_, i) => ({
      ...unreadRow,
      id: `u-${i}`,
      title: `Unread number ${i + 1}`,
      created_at: new Date(Date.UTC(2026, 8, 27, 14, 0) - i * 60_000).toISOString(),
    }));
    serve({ unread: many, read: [] });
    const { user } = setup();
    const unread = await screen.findByRole('list', { name: 'Unread notifications' });
    expect(within(unread).getAllByRole('listitem')).toHaveLength(UNREAD_PAGE_SIZE);
    expect(await screen.findByText(`${UNREAD_PAGE_SIZE + 5} new`)).toBeInTheDocument();
    await user.click(await screen.findByRole('button', { name: 'Show more unread (5 more)' }));
    expect(await within(unread).findByText(`Unread number ${UNREAD_PAGE_SIZE + 5}`)).toBeVisible();
    expect(within(unread).getAllByRole('listitem')).toHaveLength(UNREAD_PAGE_SIZE + 5);
    expect(screen.queryByRole('button', { name: /Show more unread/ })).not.toBeInTheDocument();
  });

  it('rolls back and announces a failed mark-read', async () => {
    serve({ failWrites: true });
    const { user } = setup();
    const unread = await screen.findByRole('list', { name: 'Unread notifications' });
    await user.click(within(unread).getByRole('button', { name: 'Mark read' }));
    expect(await screen.findByText('Couldn’t mark the notification read')).toBeInTheDocument();
    expect(await within(unread).findByRole('button', { name: 'Mark read' })).toBeInTheDocument();
    expect(within(unread).getByText('(unread)')).toBeInTheDocument();
  });

  it('shows empty states', async () => {
    serve({ unread: [], read: [] });
    setup();
    expect(await screen.findByText('You’re all caught up')).toBeInTheDocument();
    expect(await screen.findByText('No earlier notifications')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Mark all read' })).toBeDisabled();
  });
});
