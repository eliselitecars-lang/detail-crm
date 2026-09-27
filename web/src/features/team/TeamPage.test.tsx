import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi, type Mock } from 'vitest';
import { membership, renderRoute, shopValue, signedInAuth } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import TeamPage from './TeamPage';

vi.mock('@/lib/supabase', async () => {
  const mod = await import('@/test/supabaseMock');
  Object.assign(mod.supabase, { functions: { invoke: vi.fn() } });
  return mod;
});

const invoke = () => (supabase as unknown as { functions: { invoke: Mock } }).functions.invoke;

const team = [
  {
    member_id: 'm-owner',
    user_id: 'user-1',
    role: 'owner',
    display_name: 'Olivia Owner',
    calendar_color: null,
    active: true,
    phone: null,
    email: 'owner@example.com',
  },
  {
    member_id: 'm-tech',
    user_id: 'user-2',
    role: 'technician',
    display_name: 'Theo Tech',
    calendar_color: '#1F9D55',
    active: true,
    phone: '+12055550123',
    email: 'theo@example.com',
  },
];

function inviteResult(email: string, emailSent: boolean) {
  return {
    invite: {
      id: 'inv-9',
      shop_id: 'shop-1',
      email,
      role: 'manager',
      expires_at: '2099-01-01T00:00:00Z',
    },
    invite_url: 'https://app.test/invite/tok-9',
    email_sent: emailSent,
  };
}

function rpcResults(results: Record<string, unknown>) {
  supabase.rpc.mockImplementation(((fn: string) =>
    createBuilder({ data: results[fn] ?? null })) as never);
}

function renderAs(role: 'owner' | 'admin' | 'manager', refetch = vi.fn(() => Promise.resolve())) {
  return renderRoute(<TeamPage />, {
    // user-1 is the owner row; other roles sign in as a user not in the list
    auth:
      role === 'owner'
        ? signedInAuth('owner@example.com', 'user-1')
        : signedInAuth('a@example.com', 'user-9'),
    shop: shopValue({ membership: membership({ role }), refetch }),
  });
}

beforeEach(() => {
  resetSupabaseMock();
  invoke().mockReset();
  rpcResults({ shop_team: team });
  setTableResult('member_compensation', {
    data: [{ member_id: 'm-tech', hourly_rate_cents: 2250, commission_bps: 1000 }],
  });
  setTableResult('shop_invites', {
    data: [
      {
        id: 'inv-1',
        email: 'new@example.com',
        role: 'manager',
        token: 'tok-1',
        expires_at: '2099-01-01T00:00:00Z',
        created_at: '2026-03-01T00:00:00Z',
      },
    ],
  });
});

describe('TeamPage', () => {
  it('owner sees members, pay, pending invites and ownership transfer', async () => {
    renderAs('owner');
    const table = await screen.findByRole('table', { name: 'Team members' });
    const theo = within(table).getByRole('row', { name: /Theo Tech/ });
    expect(within(table).getByRole('columnheader', { name: 'Pay' })).toBeInTheDocument();
    expect(theo).toHaveTextContent('Technician');
    expect(theo).toHaveTextContent('$22.50/hr · 10% commission');
    expect(theo).toHaveTextContent('(205) 555-0123');
    expect(await screen.findByText('new@example.com')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Transfer ownership…' })).toBeInTheDocument();
    // the owner row has no actions for the owner themself except editing their details
    expect(
      screen.getAllByRole('button', { name: 'Actions for Olivia Owner' }).length,
    ).toBeGreaterThan(0);
  });

  it('manager gets a read-only directory', async () => {
    renderAs('manager');
    await screen.findByRole('table', { name: 'Team members' });
    expect(screen.queryByRole('button', { name: 'Invite member' })).not.toBeInTheDocument();
    expect(screen.queryAllByRole('button', { name: /Actions for/ })).toHaveLength(0);
    expect(screen.queryByRole('columnheader', { name: 'Pay' })).not.toBeInTheDocument();
    expect(screen.queryByText('Pending invites')).not.toBeInTheDocument();
    expect(supabase.from).not.toHaveBeenCalledWith('member_compensation');
    expect(supabase.from).not.toHaveBeenCalledWith('shop_invites');
  });

  it('changes a role with only the allowed choices', async () => {
    const { user } = renderAs('admin');
    await user.click((await screen.findAllByRole('button', { name: 'Actions for Theo Tech' }))[0]!);
    await user.click(screen.getByRole('menuitem', { name: 'Change role…' }));
    const dialog = await screen.findByRole('dialog', { name: /Change role/ });
    expect(within(dialog).queryByRole('radio', { name: /Owner/ })).not.toBeInTheDocument();
    await user.click(within(dialog).getByRole('radio', { name: /Manager/ }));
    await user.click(within(dialog).getByRole('button', { name: 'Save role' }));
    await waitFor(() =>
      expect(builders.shop_members?.[0]?.update).toHaveBeenCalledWith({ role: 'manager' }),
    );
    expect(builders.shop_members?.[0]?.eq).toHaveBeenCalledWith('id', 'm-tech');
  });

  it('admins cannot act on the owner', async () => {
    renderAs('admin');
    await screen.findByRole('table', { name: 'Team members' });
    expect(screen.queryAllByRole('button', { name: 'Actions for Olivia Owner' })).toHaveLength(0);
  });

  it('sends an invite through the invites function', async () => {
    invoke().mockResolvedValue({ data: inviteResult('sam@example.com', true), error: null });
    const { user } = renderAs('owner');
    await user.click(await screen.findByRole('button', { name: 'Invite member' }));
    const dialog = await screen.findByRole('dialog', { name: 'Invite a team member' });
    expect(within(dialog).queryByRole('radio', { name: /Owner/ })).toBeNull();
    await user.type(within(dialog).getByRole('textbox', { name: /Email/ }), 'Sam@Example.com');
    await user.click(within(dialog).getByRole('radio', { name: /Manager/ }));
    await user.click(within(dialog).getByRole('button', { name: 'Send invite' }));
    await waitFor(() =>
      expect(invoke()).toHaveBeenCalledWith('invites', {
        body: {
          action: 'send_invite',
          shop_id: 'shop-1',
          email: 'sam@example.com',
          role: 'manager',
        },
      }),
    );
    expect(await screen.findByText('Invite sent')).toBeInTheDocument();
  });

  it('resends and revokes pending invites', async () => {
    invoke().mockResolvedValue({ data: inviteResult('new@example.com', false), error: null });
    const { user } = renderAs('owner');
    await user.click(
      await screen.findByRole('button', { name: 'Resend invite to new@example.com' }),
    );
    await waitFor(() =>
      expect(invoke()).toHaveBeenCalledWith('invites', {
        body: { action: 'resend_invite', invite_id: 'inv-1' },
      }),
    );
    // the email failed but the invite exists: offer the link
    expect(await screen.findByText(/the email didn’t go out/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Copy link' })).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Revoke invite for new@example.com' }));
    const dialog = await screen.findByRole('alertdialog', { name: 'Revoke this invite?' });
    await user.click(within(dialog).getByRole('button', { name: 'Revoke invite' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('revoke_invite', { p_invite_id: 'inv-1' }),
    );
  });

  it('transfers ownership only after typing the shop name', async () => {
    const refetch = vi.fn(() => Promise.resolve());
    const { user } = renderAs('owner', refetch);
    await user.click(await screen.findByRole('button', { name: 'Transfer ownership…' }));
    const dialog = await screen.findByRole('alertdialog', { name: 'Transfer ownership' });
    const confirm = within(dialog).getByRole('button', { name: 'Transfer ownership' });
    await user.selectOptions(within(dialog).getByRole('combobox', { name: /New owner/ }), 'm-tech');
    expect(confirm).toBeDisabled();
    await user.type(
      within(dialog).getByRole('textbox', { name: /Type the shop name/ }),
      'Glacier Detailing',
    );
    expect(confirm).toBeEnabled();
    await user.click(confirm);
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('transfer_ownership', {
        p_shop_id: 'shop-1',
        p_member_id: 'm-tech',
      }),
    );
    await waitFor(() => expect(refetch).toHaveBeenCalled());
  });
});
