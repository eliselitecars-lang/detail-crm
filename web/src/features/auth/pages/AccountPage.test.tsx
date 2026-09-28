import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute, signedInAuth } from '@/test/render';
import {
  edgeHttpError,
  mockRpc,
  pgError,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
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

function memberRow(id: string, shopId: string, name: string, role: string) {
  return {
    id,
    shop_id: shopId,
    role,
    display_name: 'Ana',
    calendar_color: null,
    shop: {
      id: shopId,
      name,
      slug: name.toLowerCase().replace(/\s+/g, '-'),
      timezone: 'America/Chicago',
      currency: 'usd',
      logo_path: null,
      brand_color: null,
      business_type: 'fixed',
      techs_can_collect_payments: false,
      techs_can_share_reports: false,
      tax_rate_bps: 0,
    },
  };
}

describe('AccountPage', () => {
  it('is a signed-in /account route', () => {
    expect(routes.public?.map((r) => r.path)).toContain('/account');
  });

  it('lets a member leave a shop, but not one they own', async () => {
    setTableResult('shop_members', {
      data: [
        memberRow('m-1', 'shop-a', 'Apex Detail', 'owner'),
        memberRow('m-2', 'shop-b', 'Bayside Tint', 'technician'),
      ],
    });
    const calls = mockRpc({ leave_shop: { data: null } });
    window.localStorage.setItem('detailcrm:lastShop:user-9', 'shop-b');
    const { user } = setup();
    const shops = await screen.findByRole('list', { name: 'Your shops' });
    expect(within(shops).getByText('Apex Detail')).toBeInTheDocument();
    expect(within(shops).getByText('Transfer ownership to leave')).toBeInTheDocument();
    expect(within(shops).queryByRole('button', { name: 'Leave Apex Detail' })).toBeNull();

    await user.click(within(shops).getByRole('button', { name: 'Leave Bayside Tint' }));
    const dialog = await screen.findByRole('alertdialog', { name: 'Leave Bayside Tint?' });
    await user.click(within(dialog).getByRole('button', { name: 'Leave shop' }));
    await waitFor(() =>
      expect(calls).toContainEqual({ fn: 'leave_shop', args: { p_shop_id: 'shop-b' } }),
    );
    expect(await screen.findByText('You left Bayside Tint')).toBeInTheDocument();
    // The app no longer tries to reopen the shop that was left.
    expect(window.localStorage.getItem('detailcrm:lastShop:user-9')).toBeNull();
  });

  it('keeps the dialog open with the reason when leaving fails', async () => {
    setTableResult('shop_members', {
      data: [memberRow('m-2', 'shop-b', 'Bayside Tint', 'manager')],
    });
    mockRpc({ leave_shop: pgError('P0002', 'you are not a member of this shop') });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Leave Bayside Tint' }));
    const dialog = await screen.findByRole('alertdialog', { name: 'Leave Bayside Tint?' });
    await user.click(within(dialog).getByRole('button', { name: 'Leave shop' }));
    expect(await within(dialog).findByRole('alert')).toBeInTheDocument();
  });

  it('shows no shop list for a portal client on no team', async () => {
    setTableResult('shop_members', { data: [] });
    setup();
    expect(await screen.findByRole('heading', { name: 'Delete account' })).toBeInTheDocument();
    await waitFor(() => expect(screen.queryByText('Loading your shops…')).toBeNull());
    expect(screen.queryByRole('list', { name: 'Your shops' })).toBeNull();
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

  it('links the Privacy Policy and Terms of Service for every role', () => {
    setup();
    const card = screen.getByRole('region', { name: 'Privacy and terms' });
    expect(within(card).getByRole('link', { name: 'Privacy Policy' })).toHaveAttribute(
      'href',
      '/privacy',
    );
    expect(within(card).getByRole('link', { name: 'Terms of Service' })).toHaveAttribute(
      'href',
      '/terms',
    );
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
