import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import {
  builders,
  createBuilder,
  mockRpc,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import CampaignDetailPage from './CampaignDetailPage';
import CampaignNewPage from './CampaignNewPage';
import CampaignsPage from './CampaignsPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const draft = {
  id: 'camp-1',
  name: 'Spring special',
  channel: 'sms',
  subject: null,
  body: 'Hi {{customer_first_name}}, spring slots are open.',
  audience: { tags: ['vip'] },
  status: 'draft',
  scheduled_at: null,
  launched_at: null,
  cancelled_at: null,
  recipient_count: 0,
  created_at: '2026-03-01T15:00:00Z',
  updated_at: '2026-03-02T15:00:00Z',
};

function rpcResults(results: Record<string, unknown>) {
  supabase.rpc.mockImplementation(((fn: string) =>
    createBuilder({ data: results[fn] ?? null })) as never);
}

beforeEach(() => {
  resetSupabaseMock();
  setTableResult('customers', { data: [{ tags: ['VIP', 'fleet'] }] });
});

describe('CampaignsPage', () => {
  it('lists campaigns with status and recipients', async () => {
    setTableResult('campaigns', {
      data: [
        draft,
        {
          ...draft,
          id: 'camp-2',
          name: 'Winter wash',
          status: 'launched',
          launched_at: '2026-01-10T15:00:00Z',
          recipient_count: 128,
        },
      ],
    });
    renderRoute(<CampaignsPage />, { path: '/app/campaigns', routePath: '/app/campaigns' });
    const table = await screen.findByRole('table', { name: 'Campaigns' });
    const winter = within(table).getByRole('row', { name: /Winter wash/ });
    expect(winter).toHaveTextContent('Launched');
    expect(winter).toHaveTextContent('128');
    expect(winter).toHaveTextContent('Launched Jan 10, 2026');
    expect(within(table).getByRole('link', { name: 'Spring special' })).toHaveAttribute(
      'href',
      '/app/campaigns/camp-1',
    );
    await screen.findByRole('tab', { name: /Drafts/ });
  });

  it('shows the empty state', async () => {
    setTableResult('campaigns', { data: [] });
    renderRoute(<CampaignsPage />, { path: '/app/campaigns', routePath: '/app/campaigns' });
    expect(await screen.findByText('No campaigns yet')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'New campaign' })).toHaveAttribute(
      'href',
      '/app/campaigns/new',
    );
  });

  it('shows an error with retry', async () => {
    setTableResult('campaigns', {
      error: { code: '42501', message: 'permission denied for table campaigns' },
    });
    renderRoute(<CampaignsPage />, { path: '/app/campaigns', routePath: '/app/campaigns' });
    expect(await screen.findByText('Couldn’t load campaigns')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /try again|retry/i })).toBeInTheDocument();
  });
});

describe('CampaignNewPage', () => {
  it('previews the audience and saves a draft', async () => {
    rpcResults({ preview_campaign_audience: 42 });
    setTableResult('campaigns', { data: { id: 'camp-new' } });
    const { user, router } = renderRoute(<CampaignNewPage />, {
      path: '/app/campaigns/new',
      routePath: '/app/campaigns/new',
      routes: [{ path: '/app/campaigns/:campaignId', element: <p>detail page</p> }],
    });

    expect(await screen.findByText('42')).toBeInTheDocument();
    expect(supabase.rpc).toHaveBeenCalledWith('preview_campaign_audience', {
      p_shop_id: 'shop-1',
      p_channel: 'sms',
      p_audience: {},
    });

    await user.type(screen.getByRole('textbox', { name: /Campaign name/ }), 'Spring special');
    await user.type(screen.getByRole('textbox', { name: /^Message/ }), 'Book your spring detail');
    await user.type(screen.getByRole('combobox', { name: /Tags/ }), 'vip{Enter}');
    expect(screen.getByRole('list', { name: 'Selected tags' })).toHaveTextContent('vip');
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('preview_campaign_audience', {
        p_shop_id: 'shop-1',
        p_channel: 'sms',
        p_audience: { tags: ['vip'] },
      }),
    );

    await user.click(screen.getByRole('button', { name: 'Save draft' }));
    await waitFor(() => expect(router.state.location.pathname).toBe('/app/campaigns/camp-new'));
    const insert = builders.campaigns?.find((b) => b.insert.mock.calls.length > 0)?.insert;
    expect(insert).toHaveBeenCalledWith({
      shop_id: 'shop-1',
      name: 'Spring special',
      channel: 'sms',
      subject: null,
      body: 'Book your spring detail',
      audience: { tags: ['vip'] },
      scheduled_at: null,
    });
  });

  it('previews the rendered text, its length and the limit from the server', async () => {
    const calls = mockRpc({
      preview_campaign_audience: { data: 3 },
      preview_campaign_message: (args) => ({
        data: {
          subject: null,
          body: `${String(args.p_body).replace('{{shop_name}}', 'Glacier Detailing')}\nReply STOP to opt out.`,
          body_length: 1590,
          max_body_length: 1577,
          footer_added: true,
          truncated: true,
        },
      }),
    });
    const { user } = renderRoute(<CampaignNewPage />);
    await user.type(
      await screen.findByRole('textbox', { name: /^Message/ }),
      'Deals at {{{{shop_name}}',
    );
    const preview = await screen.findByRole('region', { name: 'Message preview' });
    expect(preview).toHaveTextContent('Deals at Glacier Detailing');
    expect(preview).toHaveTextContent('Reply STOP to opt out.');
    expect(within(preview).getByRole('alert')).toHaveTextContent(
      '13 characters over the limit and will be cut off',
    );
    expect(
      screen.getByText(/1,590\/1,577 characters · “Reply STOP to opt out.” is added/),
    ).toBeInTheDocument();
    // Debounced: one request for the finished text, not one per keystroke.
    const previews = calls.filter((c) => c.fn === 'preview_campaign_message');
    expect(previews.length).toBeLessThanOrEqual(2);
    expect(previews.at(-1)?.args).toEqual({
      p_shop_id: 'shop-1',
      p_channel: 'sms',
      p_body: 'Deals at {{shop_name}}',
    });
  });

  it('validates required fields', async () => {
    rpcResults({ preview_campaign_audience: 0 });
    const { user } = renderRoute(<CampaignNewPage />);
    await user.click(await screen.findByRole('button', { name: 'Save draft' }));
    expect(await screen.findByText('Name is required.')).toBeInTheDocument();
    expect(screen.getByText('Write the message.')).toBeInTheDocument();
    expect(supabase.from).not.toHaveBeenCalledWith('campaigns');
  });
});

describe('CampaignDetailPage', () => {
  it('saves and launches a draft after confirmation', async () => {
    setTableResult('campaigns', { data: draft });
    rpcResults({
      preview_campaign_audience: 7,
      launch_campaign: { ...draft, status: 'launched', recipient_count: 7 },
    });
    const { user } = renderRoute(<CampaignDetailPage />, {
      path: '/app/campaigns/camp-1',
      routePath: '/app/campaigns/:campaignId',
    });
    expect(
      await screen.findByRole('heading', { name: 'Spring special', level: 1 }),
    ).toBeInTheDocument();
    expect(screen.getByRole('list', { name: 'Selected tags' })).toHaveTextContent('vip');

    await user.click(screen.getByRole('button', { name: 'Review & launch' }));
    const dialog = await screen.findByRole('dialog', { name: 'Launch this campaign?' });
    expect(within(dialog).getByText('7')).toBeInTheDocument();
    const update = builders.campaigns?.find((b) => b.update.mock.calls.length > 0);
    expect(update?.eq).toHaveBeenCalledWith('id', 'camp-1');

    await user.click(within(dialog).getByRole('button', { name: 'Launch campaign' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('launch_campaign', { p_campaign_id: 'camp-1' }),
    );
    expect(await screen.findByText('Campaign launched to 7 recipients')).toBeInTheDocument();
  });

  it('shows delivery stats and cancels unsent messages', async () => {
    setTableResult('campaigns', {
      data: {
        ...draft,
        status: 'launched',
        launched_at: '2026-03-05T15:00:00Z',
        recipient_count: 12,
      },
    });
    setTableResult('messages', { data: null, count: 3 });
    rpcResults({ cancel_campaign: { ...draft, status: 'cancelled' } });
    const { user } = renderRoute(<CampaignDetailPage />, {
      path: '/app/campaigns/camp-1',
      routePath: '/app/campaigns/:campaignId',
    });
    const recipients = await screen.findByText('Recipients');
    expect(recipients.nextElementSibling).toHaveTextContent('12');
    expect(screen.getByText('Delivered').nextElementSibling).toHaveTextContent('3');
    expect(screen.getByText(/whose|tagged “vip”/)).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Cancel unsent messages' }));
    const dialog = await screen.findByRole('alertdialog', { name: 'Cancel unsent messages?' });
    await user.click(within(dialog).getByRole('button', { name: 'Cancel campaign' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('cancel_campaign', { p_campaign_id: 'camp-1' }),
    );
  });

  it('still lets the owner cancel a launched campaign when the delivery stats fail', async () => {
    setTableResult('campaigns', {
      data: {
        ...draft,
        status: 'launched',
        launched_at: '2026-03-05T15:00:00Z',
        scheduled_at: '2026-03-20T15:00:00Z',
        recipient_count: 40,
      },
    });
    setTableResult('messages', { data: null, error: { message: 'boom', code: '500' } });
    rpcResults({ cancel_campaign: { ...draft, status: 'cancelled' } });
    const { user } = renderRoute(<CampaignDetailPage />, {
      path: '/app/campaigns/camp-1',
      routePath: '/app/campaigns/:campaignId',
    });
    expect(await screen.findByText(/Couldn.t load/)).toBeInTheDocument();
    const button = screen.getByRole('button', { name: 'Cancel unsent messages' });
    expect(button).toBeEnabled();
    expect(button).not.toHaveAttribute('title', 'Every message has already been sent.');
    await user.click(button);
    const dialog = await screen.findByRole('alertdialog', { name: 'Cancel unsent messages?' });
    expect(
      within(dialog).getByText(/Every message that hasn’t been sent yet is withdrawn/),
    ).toBeInTheDocument();
    await user.click(within(dialog).getByRole('button', { name: 'Cancel campaign' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('cancel_campaign', { p_campaign_id: 'camp-1' }),
    );
  });

  it('disables cancelling once no message is left queued', async () => {
    setTableResult('campaigns', {
      data: {
        ...draft,
        status: 'launched',
        launched_at: '2026-03-05T15:00:00Z',
        recipient_count: 3,
      },
    });
    setTableResult('messages', { data: null, count: 0 });
    renderRoute(<CampaignDetailPage />, {
      path: '/app/campaigns/camp-1',
      routePath: '/app/campaigns/:campaignId',
    });
    await screen.findByText('Recipients');
    const button = screen.getByRole('button', { name: 'Cancel unsent messages' });
    await waitFor(() => expect(button).toBeDisabled());
    expect(button).toHaveAttribute('title', 'Every message has already been sent.');
  });
});
