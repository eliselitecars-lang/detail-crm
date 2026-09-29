import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import {
  mockRpc,
  pgError,
  resetSupabaseMock,
  supabase,
  type MockResult,
  type RpcHandler,
} from '@/test/supabaseMock';
import { routes } from './routes';
import UnsubscribePage from './UnsubscribePage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const TOKEN = '40000000-0000-4000-8000-0000000000aa';
const STILL_SENT = 'booking confirmations, appointment reminders, quotes, invoices and receipts';

interface Info {
  shop_name: string;
  shop_logo_path: string | null;
  unsubscribed: boolean;
  scope: 'marketing' | 'all' | null;
  can_resubscribe: boolean;
}

const INFO: Info = {
  shop_name: 'Glacier Detailing',
  shop_logo_path: null,
  unsubscribed: false,
  scope: null,
  can_resubscribe: true,
};

function renderAt(path: string) {
  // No shop: anonymous visitors reach this page from an email.
  return renderRoute(<UnsubscribePage />, { path, routePath: '/u/:token', shop: null });
}

/**
 * A fake server with the 0126 rules: public_unsubscribe is marketing-only
 * (an 'all' opt-out stays 'all'), public_unsubscribe_all is 'all', and
 * public_resubscribe lifts any scope while a current customer has the
 * address. `overrides` replace a function's answer.
 */
function server(
  initial: Partial<Info> = {},
  overrides: Record<string, MockResult | RpcHandler> = {},
) {
  const state: Info = { ...INFO, ...initial };
  const calls = mockRpc({
    public_unsubscribe_info: () => ({ data: { ...state } }),
    public_unsubscribe: () => {
      if (state.scope !== 'all') Object.assign(state, { unsubscribed: true, scope: 'marketing' });
      return { data: true };
    },
    public_unsubscribe_all: () => {
      Object.assign(state, { unsubscribed: true, scope: 'all' });
      return { data: true };
    },
    public_resubscribe: () => {
      if (!state.can_resubscribe) return { data: false };
      Object.assign(state, { unsubscribed: false, scope: null });
      return { data: true };
    },
    ...overrides,
  });
  return { state, calls, fns: () => calls.map((c) => c.fn) };
}

beforeEach(() => {
  resetSupabaseMock();
});

describe('UnsubscribePage', () => {
  it('is registered as a public /u/:token route', () => {
    expect(routes.public?.map((r) => r.path)).toContain('/u/:token');
  });

  it('names the shop, asks first, then unsubscribes from marketing email only', async () => {
    const { fns, calls } = server();
    const { user } = renderAt(`/u/${TOKEN}`);
    expect(
      await screen.findByRole('heading', {
        name: 'Unsubscribe from Glacier Detailing marketing emails',
        level: 1,
      }),
    ).toBeInTheDocument();
    // Before the click (0126): marketing stops, transactional email keeps coming.
    expect(
      screen.getByText(/Stop marketing emails from Glacier Detailing — campaigns, promotions/),
    ).toBeInTheDocument();
    expect(
      screen.getByText(`You’ll still get ${STILL_SENT} from Glacier Detailing.`),
    ).toBeInTheDocument();
    // Opening the link alone never changes anything (link scanners follow GETs).
    expect(fns()).toEqual(['public_unsubscribe_info']);
    expect(calls[0]?.args).toEqual({ p_token: TOKEN });

    await user.click(screen.getByRole('button', { name: 'Unsubscribe' }));
    const done = await screen.findByRole('heading', { name: 'You’re unsubscribed' });
    await waitFor(() => expect(done).toHaveFocus());
    expect(
      screen.getByText(
        `Glacier Detailing won’t send marketing emails — campaigns, promotions and service follow-ups — to this address any more. You’ll still get ${STILL_SENT} from them.`,
      ),
    ).toBeInTheDocument();
    // The state shown is the server's, read again after the change.
    expect(fns()).toEqual([
      'public_unsubscribe_info',
      'public_unsubscribe',
      'public_unsubscribe_info',
    ]);
    expect(supabase.rpc).toHaveBeenCalledWith('public_unsubscribe', { p_token: TOKEN });
    // Now the other choices.
    expect(screen.getByRole('button', { name: 'Resubscribe to marketing emails' })).toBeEnabled();
    expect(
      screen.getByRole('button', { name: 'Stop all emails from Glacier Detailing' }),
    ).toBeEnabled();
  });

  it('resubscribes to marketing email from the done state', async () => {
    const { fns, state } = server({ unsubscribed: true, scope: 'marketing' });
    const { user } = renderAt(`/u/${TOKEN}`);
    await user.click(
      await screen.findByRole('button', { name: 'Resubscribe to marketing emails' }),
    );
    const notice = await screen.findByRole('heading', { name: 'You’re subscribed again' });
    await waitFor(() => expect(notice).toHaveFocus());
    expect(
      screen.getByText(
        `Glacier Detailing can send marketing emails to this address again, as well as ${STILL_SENT}.`,
      ),
    ).toBeInTheDocument();
    // …and the marketing unsubscribe is offered again.
    expect(screen.getByRole('button', { name: 'Unsubscribe' })).toBeInTheDocument();
    expect(fns()).toEqual([
      'public_unsubscribe_info',
      'public_resubscribe',
      'public_unsubscribe_info',
    ]);
    expect(supabase.rpc).toHaveBeenCalledWith('public_resubscribe', { p_token: TOKEN });
    expect(state.scope).toBeNull();
  });

  it('stops all emails only after a confirmation that says what else stops', async () => {
    const { fns } = server({ unsubscribed: true, scope: 'marketing' });
    const { user } = renderAt(`/u/${TOKEN}`);
    await user.click(
      await screen.findByRole('button', { name: 'Stop all emails from Glacier Detailing' }),
    );
    let dialog = await screen.findByRole('alertdialog', {
      name: 'Stop all emails from Glacier Detailing?',
    });
    expect(dialog).toHaveTextContent(
      `You’ll also stop getting ${STILL_SENT} from Glacier Detailing at this address, not just marketing emails. You can turn them back on from this page.`,
    );
    // Cancel changes nothing.
    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }));
    expect(fns()).toEqual(['public_unsubscribe_info']);

    await user.click(
      screen.getByRole('button', { name: 'Stop all emails from Glacier Detailing' }),
    );
    dialog = await screen.findByRole('alertdialog', {
      name: 'Stop all emails from Glacier Detailing?',
    });
    await user.click(within(dialog).getByRole('button', { name: 'Stop all emails' }));
    const done = await screen.findByRole('heading', {
      name: 'You’re unsubscribed from all emails',
    });
    await waitFor(() => expect(done).toHaveFocus());
    expect(screen.queryByRole('alertdialog')).toBeNull();
    expect(
      screen.getByText(
        `This address is opted out of all emails from Glacier Detailing, including ${STILL_SENT}.`,
      ),
    ).toBeInTheDocument();
    expect(fns()).toEqual([
      'public_unsubscribe_info',
      'public_unsubscribe_all',
      'public_unsubscribe_info',
    ]);
    // From 'all', resubscribing turns everything back on, and says so.
    expect(
      screen.getByRole('button', { name: 'Resubscribe to all Glacier Detailing emails' }),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/Turns booking confirmations.*marketing emails too/),
    ).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Stop all emails/ })).toBeNull();
  });

  it('lifts an opt-out of every email when the server allows it', async () => {
    const { fns } = server({ unsubscribed: true, scope: 'all' });
    const { user } = renderAt(`/u/${TOKEN}`);
    await user.click(
      await screen.findByRole('button', { name: 'Resubscribe to all Glacier Detailing emails' }),
    );
    expect(
      await screen.findByRole('heading', { name: 'You’re subscribed again' }),
    ).toBeInTheDocument();
    expect(fns()).toContain('public_resubscribe');
  });

  it('keeps the different-address advice when nobody can resubscribe the address', async () => {
    server({ unsubscribed: true, scope: 'all', can_resubscribe: false });
    renderAt(`/u/${TOKEN}`);
    expect(
      await screen.findByRole('heading', { name: 'You’re unsubscribed from all emails' }),
    ).toBeInTheDocument();
    expect(
      screen.getByText(
        `This address is opted out of all emails from Glacier Detailing, including ${STILL_SENT}. If you want emails from Glacier Detailing again, give them a different email address.`,
      ),
    ).toBeInTheDocument();
    expect(screen.queryByRole('button')).toBeNull();
  });

  it('explains a refused resubscribe and shows the server’s state again', async () => {
    const holder: { state?: Info } = {};
    const { state } = server(
      { unsubscribed: true, scope: 'marketing' },
      {
        public_resubscribe: () => {
          // The customer record was archived meanwhile: nobody to opt in.
          if (holder.state) holder.state.can_resubscribe = false;
          return { data: false };
        },
      },
    );
    holder.state = state;
    const { user } = renderAt(`/u/${TOKEN}`);
    await user.click(
      await screen.findByRole('button', { name: 'Resubscribe to marketing emails' }),
    );
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'We couldn’t resubscribe this address: Glacier Detailing no longer has a customer record with it.',
    );
    expect(screen.getByRole('heading', { name: 'You’re unsubscribed' })).toBeInTheDocument();
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: 'Resubscribe to marketing emails' })).toBeNull(),
    );
  });

  it('shows a rate limit plainly and changes nothing', async () => {
    const { state } = server(
      { unsubscribed: true, scope: 'marketing' },
      { public_unsubscribe_all: pgError('PT429', 'too many requests') },
    );
    const { user } = renderAt(`/u/${TOKEN}`);
    await user.click(
      await screen.findByRole('button', { name: 'Stop all emails from Glacier Detailing' }),
    );
    const dialog = await screen.findByRole('alertdialog', {
      name: 'Stop all emails from Glacier Detailing?',
    });
    await user.click(within(dialog).getByRole('button', { name: 'Stop all emails' }));
    expect(await within(dialog).findByRole('alert')).toHaveTextContent(
      'Too many requests from your connection. Wait a minute, then try again.',
    );
    expect(state.scope).toBe('marketing');
  });

  it('shows a failed resubscribe plainly', async () => {
    server(
      { unsubscribed: true, scope: 'marketing' },
      {
        public_resubscribe: {
          error: { message: 'Failed to fetch', code: '', details: '', hint: '' },
        },
      },
    );
    const { user } = renderAt(`/u/${TOKEN}`);
    await user.click(
      await screen.findByRole('button', { name: 'Resubscribe to marketing emails' }),
    );
    expect(await screen.findByRole('alert')).toHaveTextContent(/Can.t reach the server/);
    expect(screen.getByRole('heading', { name: 'You’re unsubscribed' })).toBeInTheDocument();
  });

  it('shows the shop logo when it has one', async () => {
    server({ shop_logo_path: 'shop-1/logo.png' });
    renderAt(`/u/${TOKEN}`);
    expect(await screen.findByRole('img', { name: 'Glacier Detailing logo' })).toHaveAttribute(
      'src',
      'https://cdn.test/shop-1/logo.png',
    );
  });

  it('never claims email still arrives when the scope is unknown', async () => {
    // An older server without `scope` / `can_resubscribe`: assume the full opt-out.
    mockRpc({
      public_unsubscribe_info: {
        data: { shop_name: 'Glacier Detailing', shop_logo_path: null, unsubscribed: true },
      },
    });
    renderAt(`/u/${TOKEN}`);
    expect(await screen.findByText(/opted out of all emails/)).toBeInTheDocument();
    expect(screen.queryByText(/You’ll still get/)).toBeNull();
    expect(screen.queryByRole('button')).toBeNull();
  });

  it('says the link is invalid when the server does not know it (PT404)', async () => {
    const calls = mockRpc({
      public_unsubscribe_info: pgError('PT404', 'unsubscribe link not found'),
    });
    renderAt(`/u/${TOKEN}`);
    expect(
      await screen.findByRole('heading', { name: 'This unsubscribe link isn’t valid' }),
    ).toBeInTheDocument();
    expect(calls).toHaveLength(1); // not found is never retried
  });

  it('says the link is invalid when public_unsubscribe no longer knows it', async () => {
    server({}, { public_unsubscribe: { data: false } });
    const { user } = renderAt(`/u/${TOKEN}`);
    await user.click(await screen.findByRole('button', { name: 'Unsubscribe' }));
    expect(
      await screen.findByRole('heading', { name: 'This unsubscribe link isn’t valid' }),
    ).toBeInTheDocument();
  });

  it('rejects a malformed token without calling the server', () => {
    renderAt('/u/not-a-token');
    expect(
      screen.getByRole('heading', { name: 'This unsubscribe link isn’t valid' }),
    ).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Unsubscribe' })).not.toBeInTheDocument();
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it('shows an error with retry when the request fails', async () => {
    let fail = true;
    const holder: { state?: Info } = {};
    const { state } = server(
      {},
      {
        public_unsubscribe: () => {
          if (fail) {
            return { error: { message: 'Failed to fetch', code: '', details: '', hint: '' } };
          }
          if (holder.state) Object.assign(holder.state, { unsubscribed: true, scope: 'marketing' });
          return { data: true };
        },
      },
    );
    holder.state = state;
    const { user } = renderAt(`/u/${TOKEN}`);
    await user.click(await screen.findByRole('button', { name: 'Unsubscribe' }));
    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent('We couldn’t unsubscribe you');
    expect(alert).toHaveTextContent(/Can.t reach the server/);
    fail = false;
    await user.click(screen.getByRole('button', { name: 'Try again' }));
    expect(await screen.findByRole('heading', { name: 'You’re unsubscribed' })).toBeInTheDocument();
  });
});
