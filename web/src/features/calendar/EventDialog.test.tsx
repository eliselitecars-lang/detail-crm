import { screen, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { createBuilder, resetSupabaseMock, supabase } from '@/test/supabaseMock';
import { TEAM } from '@/features/jobs/testFixtures';
import { EventDialog } from './EventDialog';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

describe('EventDialog time off', () => {
  it('says the team list failed, offers a retry and then lists the members', async () => {
    let teamFails = true;
    supabase.rpc.mockImplementation((...args: unknown[]) =>
      String(args[0]) === 'shop_team' && teamFails
        ? createBuilder({ error: { message: 'offline', code: 'XX000' } })
        : createBuilder({ data: String(args[0]) === 'shop_team' ? TEAM : null }),
    );
    const { user } = renderRoute(
      <EventDialog
        target={{ mode: 'new', start: { date: '2026-09-29', time: '09:00' } }}
        onClose={() => undefined}
      />,
    );
    const dialog = await screen.findByRole('dialog');
    await user.selectOptions(within(dialog).getByLabelText(/^Kind/), 'time_off');
    expect(await within(dialog).findByText('Couldn’t load the team list.')).toBeInTheDocument();

    // saving explains why no one can be chosen
    await user.click(within(dialog).getByRole('button', { name: 'Add event' }));
    expect(
      await within(dialog).findByText(/The team list didn’t load, so no one can be chosen yet/),
    ).toBeInTheDocument();

    teamFails = false;
    await user.click(within(dialog).getByRole('button', { name: 'Try again' }));
    const member = within(dialog).getByLabelText(/^Team member/);
    expect(
      await within(member).findByRole('option', { name: TEAM[0]!.display_name }),
    ).toBeInTheDocument();
    expect(within(dialog).queryByText('Couldn’t load the team list.')).toBeNull();
  });
});
