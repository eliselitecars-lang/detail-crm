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

const INFO = { shop_name: 'Glacier Detailing', shop_logo_path: null, unsubscribed: false };

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

  it('names the shop, asks first, then unsubscribes through public_unsubscribe', async () => {
    const calls = serve({ public_unsubscribe: { data: true } });
    const { user } = renderAt(`/u/${TOKEN}`);
    expect(
      await screen.findByRole('heading', {
        name: 'Unsubscribe from Glacier Detailing emails',
        level: 1,
      }),
    ).toBeInTheDocument();
    // Before the click: it stops every email, receipts included, for good.
    expect(
      screen.getByText(/stops all of their emails, including receipts, invoices/),
    ).toBeInTheDocument();
    // Opening the link alone never unsubscribes (link scanners follow GETs).
    expect(calls.map((c) => c.fn)).toEqual(['public_unsubscribe_info']);
    expect(calls[0]?.args).toEqual({ p_token: TOKEN });

    await user.click(screen.getByRole('button', { name: 'Unsubscribe' }));
    const done = await screen.findByRole('heading', { name: 'You’re unsubscribed' });
    expect(done).toHaveFocus();
    expect(screen.getByText(/any more emails from Glacier Detailing/)).toBeInTheDocument();
    // No promise of a remedy nobody can perform (the shop cannot clear an
    // email opt-out: customers_comms_guard, 0033).
    expect(screen.queryByText(/ask to be added back/)).not.toBeInTheDocument();
    expect(screen.getByText(/receipts, invoices and appointment reminders/)).toBeInTheDocument();
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

  it('shows the done state straight away when the address is already unsubscribed', async () => {
    const calls = serve({ public_unsubscribe_info: { data: { ...INFO, unsubscribed: true } } });
    renderAt(`/u/${TOKEN}`);
    expect(await screen.findByRole('heading', { name: 'You’re unsubscribed' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Unsubscribe' })).not.toBeInTheDocument();
    expect(calls.map((c) => c.fn)).toEqual(['public_unsubscribe_info']);
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
