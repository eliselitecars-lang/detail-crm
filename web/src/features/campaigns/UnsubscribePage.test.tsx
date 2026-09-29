import { screen } from '@testing-library/react';
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

const INFO = {
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

function serve(handlers: Record<string, MockResult | RpcHandler>) {
  return mockRpc({ public_unsubscribe_info: { data: INFO }, ...handlers });
}

beforeEach(() => {
  resetSupabaseMock();
});

describe('UnsubscribePage', () => {
  it('is registered as a public /u/:token route', () => {
    expect(routes.public?.map((r) => r.path)).toContain('/u/:token');
  });

  it('names the shop, asks first, then unsubscribes from marketing email only', async () => {
    const calls = serve({ public_unsubscribe: { data: true } });
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
      screen.getByText(
        'You’ll still get booking confirmations, appointment reminders, quotes, invoices and receipts from Glacier Detailing.',
      ),
    ).toBeInTheDocument();
    expect(screen.queryByText(/all of their emails|can’t be undone/)).not.toBeInTheDocument();
    // Opening the link alone never unsubscribes (link scanners follow GETs).
    expect(calls.map((c) => c.fn)).toEqual(['public_unsubscribe_info']);
    expect(calls[0]?.args).toEqual({ p_token: TOKEN });

    await user.click(screen.getByRole('button', { name: 'Unsubscribe' }));
    const done = await screen.findByRole('heading', { name: 'You’re unsubscribed' });
    expect(done).toHaveFocus();
    expect(
      screen.getByText(
        'Glacier Detailing won’t send marketing emails — campaigns, promotions and service follow-ups — to this address any more. You’ll still get booking confirmations, appointment reminders, quotes, invoices and receipts from them.',
      ),
    ).toBeInTheDocument();
    // No promise of a way back the page doesn't offer (the shop cannot opt the
    // address back in: customers_comms_guard, 0126).
    expect(screen.queryByText(/resubscribe|opt back in|ask to be added back/i)).toBeNull();
    expect(screen.queryByRole('button')).toBeNull();
    expect(supabase.rpc).toHaveBeenCalledWith('public_unsubscribe', { p_token: TOKEN });
  });

  it('shows the shop logo when it has one', async () => {
    serve({ public_unsubscribe_info: { data: { ...INFO, shop_logo_path: 'shop-1/logo.png' } } });
    renderAt(`/u/${TOKEN}`);
    expect(await screen.findByRole('img', { name: 'Glacier Detailing logo' })).toHaveAttribute(
      'src',
      'https://cdn.test/shop-1/logo.png',
    );
  });

  it('shows the done state straight away when the address already unsubscribed from marketing', async () => {
    const calls = serve({
      public_unsubscribe_info: { data: { ...INFO, unsubscribed: true, scope: 'marketing' } },
    });
    renderAt(`/u/${TOKEN}`);
    expect(await screen.findByRole('heading', { name: 'You’re unsubscribed' })).toBeInTheDocument();
    expect(screen.getByText(/won’t send marketing emails/)).toBeInTheDocument();
    expect(screen.getByText(/You’ll still get booking confirmations/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Unsubscribe' })).not.toBeInTheDocument();
    expect(calls.map((c) => c.fn)).toEqual(['public_unsubscribe_info']);
  });

  it('tells an address opted out of every email that nothing is sent to it', async () => {
    serve({ public_unsubscribe_info: { data: { ...INFO, unsubscribed: true, scope: 'all' } } });
    renderAt(`/u/${TOKEN}`);
    expect(await screen.findByRole('heading', { name: 'You’re unsubscribed' })).toBeInTheDocument();
    expect(
      screen.getByText(
        /opted out of all emails from Glacier Detailing, including booking confirmations, appointment reminders, quotes, invoices and receipts/,
      ),
    ).toBeInTheDocument();
    expect(screen.queryByText(/You’ll still get/)).toBeNull();
  });

  it('never claims email still arrives when the scope is unknown', async () => {
    // An older server without `scope`: assume the full opt-out.
    serve({
      public_unsubscribe_info: {
        data: { shop_name: 'Glacier Detailing', shop_logo_path: null, unsubscribed: true },
      },
    });
    renderAt(`/u/${TOKEN}`);
    expect(await screen.findByText(/opted out of all emails/)).toBeInTheDocument();
  });

  it('says the link is invalid when the server does not know it (PT404)', async () => {
    const calls = serve({
      public_unsubscribe_info: pgError('PT404', 'unsubscribe link not found'),
    });
    renderAt(`/u/${TOKEN}`);
    expect(
      await screen.findByRole('heading', { name: 'This unsubscribe link isn’t valid' }),
    ).toBeInTheDocument();
    expect(calls).toHaveLength(1); // not found is never retried
  });

  it('says the link is invalid when public_unsubscribe no longer knows it', async () => {
    serve({ public_unsubscribe: { data: false } });
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
    serve({
      public_unsubscribe: () =>
        fail
          ? { error: { message: 'Failed to fetch', code: '', details: '', hint: '' } }
          : { data: true },
    });
    const { user } = renderAt(`/u/${TOKEN}`);
    await user.click(await screen.findByRole('button', { name: 'Unsubscribe' }));
    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent('We couldn’t unsubscribe you');
    fail = false;
    await user.click(screen.getByRole('button', { name: 'Try again' }));
    expect(await screen.findByRole('heading', { name: 'You’re unsubscribed' })).toBeInTheDocument();
  });
});
