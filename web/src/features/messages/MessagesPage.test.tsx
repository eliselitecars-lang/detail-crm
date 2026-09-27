import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import {
  builders,
  edgeHttpError,
  mockRpc,
  resetSupabaseMock,
  setTableResult,
  supabase,
  type RpcCall,
} from '@/test/supabaseMock';
import MessagesPage from './MessagesPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const invoke = () => supabase.functions.invoke;

const casey = {
  id: 'c1',
  first_name: 'Casey',
  last_name: 'Jones',
  company: null,
  phone: '+12055550101',
  email: null,
  sms_opt_in: true,
  email_opt_in: false,
  sms_opted_out_at: null,
  email_opted_out_at: null,
  archived_at: null,
};

function message(over: Record<string, unknown>) {
  return {
    id: 'm1',
    customer_id: 'c1',
    job_id: null,
    campaign_id: null,
    direction: 'inbound',
    channel: 'sms',
    to_address: '+12055550100',
    from_address: '+12055550101',
    subject: null,
    body: 'Is 9am still good?',
    status: 'received',
    error: null,
    template_key: null,
    read_at: null,
    send_after: '2026-03-10T14:00:00Z',
    sent_at: null,
    delivered_at: null,
    created_at: '2026-03-10T14:00:00Z',
    customer: casey,
    ...over,
  };
}

function threadRow(over: Record<string, unknown> = {}) {
  return {
    thread_key: 'c:c1',
    customer_id: 'c1',
    from_address: '+12055550101',
    customer_first_name: 'Casey',
    customer_last_name: 'Jones',
    customer_company: null,
    last_message_id: 'm1',
    last_direction: 'inbound',
    last_channel: 'sms',
    last_status: 'received',
    last_body: 'Is 9am still good?',
    last_created_at: '2026-03-10T14:00:00Z',
    unread_count: 1,
    ...over,
  };
}

/** inbox_threads pages (by p_before) + inbox_unread_count, plus any other RPCs. */
function mockInbox(
  pages: Record<string, unknown[]>,
  unread = 1,
  extra: Parameters<typeof mockRpc>[0] = {},
): RpcCall[] {
  return mockRpc({
    inbox_threads: (args) => ({
      data: pages[typeof args.p_before === 'string' ? args.p_before : 'first'] ?? [],
    }),
    inbox_unread_count: { data: unread },
    ...extra,
  });
}

beforeEach(() => {
  resetSupabaseMock();
  setTableResult('message_templates', { data: [] });
});

describe('MessagesPage', () => {
  it('lists threads from inbox_threads with preview and unread count', async () => {
    const calls = mockInbox({ first: [threadRow()] }, 3);
    renderRoute(<MessagesPage />, { path: '/app/messages', routePath: '/app/messages' });
    const nav = await screen.findByRole('navigation', { name: 'Conversations' });
    const link = within(nav).getByRole('link', { name: /Casey Jones/ });
    expect(link).toHaveTextContent('Is 9am still good?');
    expect(link).toHaveTextContent('1 unread');
    expect(link).toHaveAttribute('href', '/app/messages?customer=c1');
    expect(screen.getByRole('heading', { name: 'Messages', level: 1 })).toBeInTheDocument();
    // The header counts every unread message of the shop (inbox_unread_count).
    expect(await screen.findByText('3 unread messages')).toBeInTheDocument();
    expect(calls).toContainEqual({
      fn: 'inbox_threads',
      args: { p_shop_id: 'shop-1', p_limit: 50 },
    });
    expect(calls).toContainEqual({ fn: 'inbox_unread_count', args: { p_shop_id: 'shop-1' } });
    // No client-side grouping of raw messages any more.
    expect(builders.messages).toBeUndefined();
  });

  it('lists senders that match no customer by their number', async () => {
    mockInbox({
      first: [
        threadRow({
          thread_key: 'a:+12055550199',
          customer_id: null,
          from_address: '+12055550199',
          customer_first_name: null,
          customer_last_name: null,
        }),
      ],
    });
    renderRoute(<MessagesPage />, { path: '/app/messages', routePath: '/app/messages' });
    const nav = await screen.findByRole('navigation', { name: 'Conversations' });
    const link = within(nav).getByRole('link', { name: /\(205\) 555-0199/ });
    expect(link).toHaveTextContent('Not matched to a customer');
    expect(link).toHaveAttribute('href', '/app/messages?from=%2B12055550199');
  });

  it('loads older conversations with p_before = the last row’s time', async () => {
    const first = Array.from({ length: 50 }, (_, i) =>
      threadRow({
        thread_key: `c:x${i}`,
        customer_id: `x${i}`,
        customer_first_name: `Recipient ${i}`,
        last_direction: 'outbound',
        last_status: 'sent',
        last_body: 'Spring special',
        last_created_at: `2026-03-12T10:${String(59 - i).padStart(2, '0')}:00Z`,
        unread_count: 0,
      }),
    );
    const before = first.at(-1)?.last_created_at ?? '';
    const calls = mockInbox({ first, [before]: [threadRow()] });
    const { user } = renderRoute(<MessagesPage />, {
      path: '/app/messages',
      routePath: '/app/messages',
    });
    const nav = await screen.findByRole('navigation', { name: 'Conversations' });
    expect(within(nav).getAllByRole('link')).toHaveLength(50);
    await user.click(within(nav).getByRole('button', { name: 'Load older conversations' }));
    expect(await within(nav).findByRole('link', { name: /Casey Jones/ })).toBeInTheDocument();
    expect(calls).toContainEqual({
      fn: 'inbox_threads',
      args: { p_shop_id: 'shop-1', p_limit: 50, p_before: before },
    });
    expect(
      within(nav).queryByRole('button', { name: 'Load older conversations' }),
    ).not.toBeInTheDocument();

    await user.click(within(nav).getByRole('tab', { name: /Unread/ }));
    expect(within(nav).getAllByRole('link')).toHaveLength(1);
  });

  it('shows the empty state with a way to start a conversation', async () => {
    mockInbox({ first: [] }, 0);
    renderRoute(<MessagesPage />, { path: '/app/messages', routePath: '/app/messages' });
    expect(await screen.findByText('No conversations yet')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Start a conversation' })).toBeInTheDocument();
  });

  it('opens a deep-linked thread, marks it read and sends a text', async () => {
    mockInbox({ first: [threadRow()] });
    setTableResult('messages', { data: [message({})] });
    setTableResult('customers', { data: casey });
    invoke().mockResolvedValue({
      data: { message_id: 'm2', channel: 'sms', status: 'sent', error: null },
      error: null,
    });
    const { user } = renderRoute(<MessagesPage />, {
      path: '/app/messages?customer=c1',
      routePath: '/app/messages',
    });

    const thread = await screen.findByRole('region', { name: 'Conversation with Casey Jones' });
    expect(await within(thread).findByRole('article', { name: /Received text/ })).toHaveTextContent(
      'Is 9am still good?',
    );

    // opening the thread marks inbound messages read
    await waitFor(() =>
      expect(builders.messages?.some((b) => b.update.mock.calls.length > 0)).toBe(true),
    );
    const updater = builders.messages?.find((b) => b.update.mock.calls.length > 0);
    expect(updater?.update).toHaveBeenCalledWith({ read_at: expect.any(String) });
    expect(updater?.eq).toHaveBeenCalledWith('customer_id', 'c1');
    expect(updater?.is).toHaveBeenCalledWith('read_at', null);

    await user.type(within(thread).getByRole('textbox', { name: 'Message' }), 'Yes, see you then');
    await user.click(within(thread).getByRole('button', { name: 'Send text' }));
    await waitFor(() => expect(invoke()).toHaveBeenCalledTimes(1));
    expect(invoke()).toHaveBeenCalledWith('messaging', {
      body: {
        action: 'send',
        shop_id: 'shop-1',
        customer_id: 'c1',
        channel: 'sms',
        body: 'Yes, see you then',
        request_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/),
      },
    });
    expect(await screen.findByText('Message sent')).toBeInTheDocument();
  });

  it('shows opt-out badges and blocks the opted-out channel', async () => {
    mockInbox({ first: [] });
    const optedOut = { ...casey, sms_opted_out_at: '2026-03-01T12:00:00Z' };
    setTableResult('messages', { data: [message({ read_at: '2026-03-10T15:00:00Z' })] });
    setTableResult('customers', { data: optedOut });
    renderRoute(<MessagesPage />, {
      path: '/app/messages?customer=c1',
      routePath: '/app/messages',
    });
    expect(await screen.findByText(/Texts opted out Mar 1, 2026/)).toBeInTheDocument();
    expect(screen.getByRole('radio', { name: 'Text' })).toBeDisabled();
    expect(screen.getByRole('status')).toHaveTextContent(/Opted out of texts/);
  });

  it('reports a delivery failure returned by the immediate send attempt', async () => {
    mockInbox({ first: [] });
    setTableResult('messages', { data: [message({ read_at: '2026-03-10T15:00:00Z' })] });
    setTableResult('customers', { data: casey });
    invoke().mockResolvedValue({
      data: { message_id: 'm3', channel: 'sms', status: 'failed', error: 'Unreachable number' },
      error: null,
    });
    const { user } = renderRoute(<MessagesPage />, {
      path: '/app/messages?customer=c1',
      routePath: '/app/messages',
    });
    await user.type(await screen.findByRole('textbox', { name: 'Message' }), 'Hi');
    await user.click(screen.getByRole('button', { name: 'Send text' }));
    expect(await screen.findByText('Message not delivered')).toBeInTheDocument();
    expect(screen.getByText('Unreachable number')).toBeInTheDocument();
  });

  it('shows a server refusal inline, keeps the draft and retries with a fresh nonce', async () => {
    mockInbox({ first: [] });
    setTableResult('messages', { data: [message({ read_at: '2026-03-10T15:00:00Z' })] });
    setTableResult('customers', { data: casey });
    invoke()
      .mockResolvedValueOnce({
        data: null,
        error: edgeHttpError(422, {
          error: 'This customer has opted out of text messages.',
          code: 'unprocessable',
          details: { reason: 'opted_out' },
        }),
      })
      .mockResolvedValueOnce({
        data: null,
        error: edgeHttpError(502, { message: 'upstream error' }),
      });
    const { user } = renderRoute(<MessagesPage />, {
      path: '/app/messages?customer=c1',
      routePath: '/app/messages',
    });
    const box = await screen.findByRole('textbox', { name: 'Message' });
    await user.type(box, 'Hi');
    await user.click(screen.getByRole('button', { name: 'Send text' }));
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'This customer has opted out of text messages.',
    );
    expect(box).toHaveValue('Hi'); // the draft is kept
    await user.click(screen.getByRole('button', { name: 'Send text' }));
    await waitFor(() => expect(invoke()).toHaveBeenCalledTimes(2));
    await user.click(screen.getByRole('button', { name: 'Send text' }));
    await waitFor(() => expect(invoke()).toHaveBeenCalledTimes(3));
    const nonces = invoke().mock.calls.map(
      ([, options]) => (options.body as { request_nonce: string }).request_nonce,
    );
    // a definitive refusal renews the nonce; a server error keeps it for the retry
    expect(nonces[1]).not.toBe(nonces[0]);
    expect(nonces[2]).toBe(nonces[1]);
  });

  it('asks for the job when the wording needs one (job_required)', async () => {
    mockInbox({ first: [] });
    setTableResult('messages', { data: [message({ read_at: '2026-03-10T15:00:00Z' })] });
    setTableResult('customers', { data: casey });
    setTableResult('message_templates', {
      data: [
        {
          id: 't1',
          key: 'follow_up',
          channel: 'sms',
          subject: null,
          body: 'How is your {{vehicle}}?',
          enabled: true,
        },
      ],
    });
    setTableResult('jobs', {
      data: [{ id: 'j1', number: 1001, status: 'completed', scheduled_start: null }],
    });
    invoke().mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(422, {
        error: 'This message is about a job: choose the job to send it for.',
        code: 'unprocessable',
        details: { reason: 'job_required', variables: ['vehicle'] },
      }),
    });
    const { user } = renderRoute(<MessagesPage />, {
      path: '/app/messages?customer=c1',
      routePath: '/app/messages',
    });
    await user.selectOptions(
      await screen.findByRole('combobox', { name: 'Template' }),
      'follow_up',
    );
    await user.click(screen.getByRole('button', { name: 'Send template' }));
    const job = await screen.findByRole('combobox', { name: /Job for this message/ });
    expect(
      await screen.findByText('This wording uses {{vehicle}}; pick the job it is about.'),
    ).toBeInTheDocument();
    await waitFor(() => expect(job).toHaveFocus());
  });

  it('requires a job for job-only templates before sending', async () => {
    mockInbox({ first: [] });
    setTableResult('messages', { data: [message({ read_at: '2026-03-10T15:00:00Z' })] });
    setTableResult('customers', { data: casey });
    setTableResult('message_templates', {
      data: [
        {
          id: 't2',
          key: 'on_the_way',
          channel: 'sms',
          subject: null,
          body: 'On our way',
          enabled: true,
        },
      ],
    });
    setTableResult('jobs', {
      data: [{ id: 'j1', number: 1001, status: 'scheduled', scheduled_start: null }],
    });
    const { user } = renderRoute(<MessagesPage />, {
      path: '/app/messages?customer=c1',
      routePath: '/app/messages',
    });
    await user.selectOptions(
      await screen.findByRole('combobox', { name: 'Template' }),
      'on_the_way',
    );
    expect(screen.getByRole('button', { name: 'Send template' })).toBeDisabled();
    await user.selectOptions(screen.getByRole('combobox', { name: /Job for this message/ }), 'j1');
    expect(screen.getByRole('button', { name: 'Send template' })).toBeEnabled();
  });

  it('links to the business settings when the review link is missing', async () => {
    mockInbox({ first: [] });
    setTableResult('messages', { data: [message({ read_at: '2026-03-10T15:00:00Z' })] });
    setTableResult('customers', { data: casey });
    setTableResult('message_templates', {
      data: [
        {
          id: 't3',
          key: 'review_request',
          channel: 'sms',
          subject: null,
          body: 'Review us: {{review_link}}',
          enabled: true,
        },
      ],
    });
    invoke().mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(422, {
        error: "Add the shop's review link in settings before sending this message.",
        code: 'unprocessable',
        details: { reason: 'missing_link', variables: ['review_link'] },
      }),
    });
    const { user } = renderRoute(<MessagesPage />, {
      path: '/app/messages?customer=c1',
      routePath: '/app/messages',
    });
    await user.selectOptions(
      await screen.findByRole('combobox', { name: 'Template' }),
      'review_request',
    );
    await user.click(screen.getByRole('button', { name: 'Send template' }));
    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent("Add the shop's review link in settings");
    expect(within(alert).getByRole('link', { name: 'Add your review link' })).toHaveAttribute(
      'href',
      '/app/settings/business',
    );
  });

  it('keeps the draft and shows why an appointment message was refused', async () => {
    mockInbox({ first: [] });
    setTableResult('messages', { data: [message({ read_at: '2026-03-10T15:00:00Z' })] });
    setTableResult('customers', { data: casey });
    setTableResult('message_templates', {
      data: [
        {
          id: 't2',
          key: 'on_the_way',
          channel: 'sms',
          subject: null,
          body: 'On our way',
          enabled: true,
        },
      ],
    });
    setTableResult('jobs', {
      data: [{ id: 'j1', number: 1001, status: 'cancelled', scheduled_start: null }],
    });
    invoke().mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(422, {
        error:
          'This appointment is cancelled or was a no-show; its appointment messages can no longer be sent.',
        code: 'unprocessable',
        details: { reason: 'appointment_closed' },
      }),
    });
    const { user } = renderRoute(<MessagesPage />, {
      path: '/app/messages?customer=c1',
      routePath: '/app/messages',
    });
    await user.selectOptions(
      await screen.findByRole('combobox', { name: 'Template' }),
      'on_the_way',
    );
    await user.selectOptions(screen.getByRole('combobox', { name: /Job for this message/ }), 'j1');
    await user.click(screen.getByRole('button', { name: 'Send template' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('This appointment is cancelled');
    expect(screen.getByRole('combobox', { name: 'Template' })).toHaveValue('on_the_way');
  });

  it('shows no_marketing_consent refusals inline', async () => {
    mockInbox({ first: [] });
    setTableResult('messages', { data: [message({ read_at: '2026-03-10T15:00:00Z' })] });
    setTableResult('customers', { data: casey });
    setTableResult('message_templates', {
      data: [
        {
          id: 't1',
          key: 'follow_up',
          channel: 'sms',
          subject: null,
          body: 'Thanks!',
          enabled: true,
        },
      ],
    });
    invoke().mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(422, {
        error: 'This customer has not agreed to receive marketing text messages.',
        code: 'unprocessable',
        details: { reason: 'no_marketing_consent' },
      }),
    });
    const { user } = renderRoute(<MessagesPage />, {
      path: '/app/messages?customer=c1',
      routePath: '/app/messages',
    });
    await user.selectOptions(
      await screen.findByRole('combobox', { name: 'Template' }),
      'follow_up',
    );
    await user.click(screen.getByRole('button', { name: 'Send template' }));
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'This customer has not agreed to receive marketing text messages.',
    );
  });
});
