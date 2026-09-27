import { screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { createBuilder, resetSupabaseMock, supabase } from '@/test/supabaseMock';
import { routes } from './routes';
import UnsubscribePage from './UnsubscribePage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const TOKEN = '40000000-0000-4000-8000-0000000000aa';

function renderAt(path: string) {
  // No shop: anonymous visitors reach this page from an email.
  return renderRoute(<UnsubscribePage />, { path, routePath: '/u/:token', shop: null });
}

beforeEach(() => {
  resetSupabaseMock();
});

describe('UnsubscribePage', () => {
  it('is registered as a public /u/:token route', () => {
    expect(routes.public?.map((r) => r.path)).toContain('/u/:token');
  });

  it('asks first, then unsubscribes through public_unsubscribe', async () => {
    supabase.rpc.mockReturnValueOnce(createBuilder({ data: true }));
    const { user } = renderAt(`/u/${TOKEN}`);
    expect(
      screen.getByRole('heading', { name: 'Unsubscribe from emails', level: 1 }),
    ).toBeInTheDocument();
    // Opening the link alone never unsubscribes (link scanners follow GETs).
    expect(supabase.rpc).not.toHaveBeenCalled();

    await user.click(screen.getByRole('button', { name: 'Unsubscribe' }));
    const done = await screen.findByRole('heading', { name: 'You’re unsubscribed' });
    expect(done).toHaveFocus();
    expect(supabase.rpc).toHaveBeenCalledWith('public_unsubscribe', { p_token: TOKEN });
  });

  it('says the link is invalid when the server does not know it', async () => {
    supabase.rpc.mockReturnValueOnce(createBuilder({ data: false }));
    const { user } = renderAt(`/u/${TOKEN}`);
    await user.click(screen.getByRole('button', { name: 'Unsubscribe' }));
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
    supabase.rpc
      .mockReturnValueOnce(
        createBuilder({ error: { message: 'Failed to fetch', code: '', details: '', hint: '' } }),
      )
      .mockReturnValueOnce(createBuilder({ data: true }));
    const { user } = renderAt(`/u/${TOKEN}`);
    await user.click(screen.getByRole('button', { name: 'Unsubscribe' }));
    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent('We couldn’t unsubscribe you');
    await user.click(screen.getByRole('button', { name: 'Try again' }));
    expect(await screen.findByRole('heading', { name: 'You’re unsubscribed' })).toBeInTheDocument();
    expect(supabase.rpc).toHaveBeenCalledTimes(2);
  });
});
