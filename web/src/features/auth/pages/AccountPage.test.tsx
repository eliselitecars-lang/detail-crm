import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute, signedInAuth } from '@/test/render';
import { edgeHttpError, resetSupabaseMock, supabase } from '@/test/supabaseMock';
import { routes } from '../routes';
import { reloadTo } from '../leave';
import AccountPage from './AccountPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));
vi.mock('../leave', () => ({
  ACCOUNT_DELETED_LOGIN: '/login?account=deleted',
  reloadTo: vi.fn(),
}));

const invoke = supabase.functions.invoke;

function setup() {
  const auth = signedInAuth('ana@example.com', 'user-9');
  const signOut = vi.fn(() => Promise.resolve());
  const utils = renderRoute(<AccountPage />, {
    path: '/account',
    routePath: '/account',
    shop: null,
    auth: { ...auth, signOut },
    routes: [
      { path: '/login', element: <p>Login page</p> },
      { path: '/app/team', element: <p>Team page</p> },
    ],
  });
  return { ...utils, signOut };
}

async function confirmDelete(user: ReturnType<typeof setup>['user']) {
  await user.click(screen.getByRole('button', { name: /Delete account/ }));
  const dialog = await screen.findByRole('alertdialog', { name: 'Delete your account?' });
  const confirm = within(dialog).getByRole('button', { name: 'Delete account permanently' });
  expect(confirm).toBeDisabled();
  await user.type(within(dialog).getByLabelText('Type DELETE to confirm'), 'delete');
  expect(confirm).toBeEnabled();
  await user.click(confirm);
  return dialog;
}

beforeEach(() => resetSupabaseMock());

describe('AccountPage', () => {
  it('is a signed-in /account route', () => {
    expect(routes.public?.map((r) => r.path)).toContain('/account');
  });

  it('deletes the account after a typed confirmation, then signs out', async () => {
    invoke.mockResolvedValueOnce({ data: { deleted: true }, error: null });
    const { user, signOut } = setup();
    expect(screen.getByText('Signed in as ana@example.com')).toBeInTheDocument();
    await confirmDelete(user);
    await waitFor(() => expect(reloadTo).toHaveBeenCalledWith('/login?account=deleted'));
    expect(invoke).toHaveBeenCalledWith('account', { body: { action: 'delete_account' } });
    expect(signOut).toHaveBeenCalled();
  });

  it('lists owned shops with ways to transfer or delete them (409 owns_shops)', async () => {
    invoke.mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(409, {
        error: 'Transfer ownership or delete these shops first.',
        code: 'conflict',
        details: {
          reason: 'owns_shops',
          shops: [
            { shop_id: 'shop-a', name: 'Apex Detail' },
            { shop_id: 'shop-b', name: 'Bayside Tint' },
          ],
        },
      }),
    });
    const { user, signOut, router } = setup();
    const dialog = await confirmDelete(user);
    const shops = await within(dialog).findByRole('list', { name: 'Shops you own' });
    expect(within(shops).getByText('Apex Detail')).toBeInTheDocument();
    expect(within(shops).getByRole('link', { name: 'Delete Bayside Tint' })).toHaveAttribute(
      'href',
      '/app/settings/delete-shop',
    );
    expect(signOut).not.toHaveBeenCalled();
    expect(reloadTo).not.toHaveBeenCalled();

    // Opening a shop's page makes it the current shop first.
    await user.click(
      within(shops).getByRole('link', { name: 'Transfer ownership of Bayside Tint' }),
    );
    expect(window.localStorage.getItem('detailcrm:lastShop:user-9')).toBe('shop-b');
    expect(router.state.location.pathname).toBe('/app/team');
  });

  it('shows other failures and keeps the account', async () => {
    invoke.mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(401, { code: 401, message: 'Invalid JWT' }),
    });
    const { user, signOut } = setup();
    const dialog = await confirmDelete(user);
    expect(await within(dialog).findByRole('alert')).toHaveTextContent(
      'Your session has expired. Sign in again.',
    );
    expect(signOut).not.toHaveBeenCalled();
  });
});
