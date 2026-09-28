import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue, signedInAuth } from '@/test/render';
import {
  edgeHttpError,
  mockRpc,
  resetSupabaseMock,
  setFunctionResult,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import { ALL_KINDS } from '../pushPrefs';
import { PushPrefsCard } from './PushPrefsCard';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

function renderAs(role: 'owner' | 'technician') {
  return renderRoute(<PushPrefsCard />, {
    path: '/app/notifications',
    shop: shopValue({ membership: membership({ role }) }),
    auth: signedInAuth('me@example.com', 'user-1'),
  });
}

beforeEach(() => {
  resetSupabaseMock();
  setTableResult('member_notification_prefs', { data: null });
  setTableResult('device_push_tokens', { data: null, count: 1 });
});

describe('PushPrefsCard', () => {
  it('shows only the kinds a technician can receive and keeps the others on save', async () => {
    setTableResult('member_notification_prefs', {
      data: { push_kinds: ['job_assigned', 'new_booking', 'general'], muted_until: null },
    });
    const calls = mockRpc({
      set_notification_prefs: {
        data: { push_kinds: ['new_booking', 'general'], muted_until: null },
      },
    });
    const { user } = renderAs('technician');
    const card = await screen.findByRole('region', { name: 'Push notifications (iPhone app)' });
    expect(await within(card).findByText('Notifications are on for 1 iPhone.')).toBeInTheDocument();
    expect(within(card).queryByRole('checkbox', { name: 'New booking' })).not.toBeInTheDocument();
    const assigned = await within(card).findByRole('checkbox', { name: 'Job assigned' });
    expect(assigned).toBeChecked();
    expect(within(card).getByRole('checkbox', { name: 'Task due' })).not.toBeChecked();
    await user.click(assigned);
    await user.click(within(card).getByRole('button', { name: 'Save push settings' }));
    await waitFor(() => expect(calls).toHaveLength(1));
    expect(calls[0]?.args).toEqual({
      p_shop_id: 'shop-1',
      // hidden manager kinds keep their saved state (new_booking stays on)
      p_push_kinds: ['new_booking', 'general'],
    });
  });

  it('treats a member without a saved row as "everything on" and saves a pause', async () => {
    const calls = mockRpc({
      set_notification_prefs: { data: { push_kinds: [...ALL_KINDS], muted_until: null } },
    });
    const { user } = renderAs('owner');
    const card = await screen.findByRole('region', { name: 'Push notifications (iPhone app)' });
    expect(await within(card).findByRole('checkbox', { name: 'Everything below' })).toBeChecked();
    expect(within(card).getByRole('checkbox', { name: 'Low stock' })).toBeChecked();
    await user.type(within(card).getByLabelText(/Pause pushes until/), '2099-01-02');
    await user.click(within(card).getByRole('button', { name: 'Save push settings' }));
    await waitFor(() => expect(calls).toHaveLength(1));
    expect(calls[0]?.args.p_push_kinds).toEqual([...ALL_KINDS]);
    // midnight shop time (America/Chicago test shop) on that date
    expect(calls[0]?.args.p_muted_until).toBe('2099-01-02T06:00:00.000Z');
  });

  it('sends a test push and explains a missing device', async () => {
    setFunctionResult('push', { data: { sent: 1, failed: 0, invalid_tokens: 0 } });
    const { user } = renderAs('technician');
    await user.click(await screen.findByRole('button', { name: 'Send a test' }));
    await waitFor(() =>
      expect(supabase.functions.invoke).toHaveBeenCalledWith('push', {
        body: { action: 'send_test', shop_id: 'shop-1' },
      }),
    );
    expect(await screen.findByText('Test notification sent')).toBeInTheDocument();

    supabase.functions.invoke.mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(422, {
        error: 'Turn on notifications in the iPhone app first, then try again.',
        code: 'unprocessable',
        details: { reason: 'no_devices' },
      }),
    });
    await user.click(screen.getByRole('button', { name: 'Send a test' }));
    expect(
      await screen.findByText('Turn on notifications in the iPhone app first, then try again.'),
    ).toBeInTheDocument();
  });

  it('disables the test without a registered iPhone', async () => {
    setTableResult('device_push_tokens', { data: null, count: 0 });
    renderAs('owner');
    expect(await screen.findByText(/No iPhone gets pushes yet/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Send a test' })).toBeDisabled();
  });
});
