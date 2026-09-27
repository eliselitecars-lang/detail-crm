import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi, type Mock } from 'vitest';
import { renderRoute } from '@/test/render';
import { builders, resetSupabaseMock, setTableResult, supabase } from '@/test/supabaseMock';
import MessagesPage from './MessagesPage';

vi.mock('@/lib/supabase', async () => {
  const mod = await import('@/test/supabaseMock');
  // The shared mock has no edge functions; add `functions.invoke` for this file.
  Object.assign(mod.supabase, { functions: { invoke: vi.fn() } });
  return mod;
});

const invoke = () => (supabase as unknown as { functions: { invoke: Mock } }).functions.invoke;

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

beforeEach(() => {
  resetSupabaseMock();
  invoke().mockReset();
  setTableResult('message_templates', { data: [] });
});

describe('MessagesPage', () => {
  it('lists threads with preview and unread count', async () => {
    setTableResult('messages', { data: [message({})] });
    renderRoute(<MessagesPage />, { path: '/app/messages', routePath: '/app/messages' });
    const nav = await screen.findByRole('navigation', { name: 'Conversations' });
    const link = within(nav).getByRole('link', { name: /Casey Jones/ });
    expect(link).toHaveTextContent('Is 9am still good?');
    expect(link).toHaveTextContent('1 unread');
    expect(link).toHaveAttribute('href', '/app/messages?customer=c1');
    expect(screen.getByRole('heading', { name: 'Messages', level: 1 })).toBeInTheDocument();
  });

  it('shows the empty state with a way to start a conversation', async () => {
    setTableResult('messages', { data: [] });
    renderRoute(<MessagesPage />, { path: '/app/messages', routePath: '/app/messages' });
    expect(await screen.findByText('No conversations yet')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Start a conversation' })).toBeInTheDocument();
  });

  it('opens a deep-linked thread, marks it read and sends a text', async () => {
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
      },
    });
    expect(await screen.findByText('Message sent')).toBeInTheDocument();
  });

  it('shows opt-out badges and blocks the opted-out channel', async () => {
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

  it('shows a server error from the send action', async () => {
    setTableResult('messages', { data: [message({ read_at: '2026-03-10T15:00:00Z' })] });
    setTableResult('customers', { data: casey });
    const response = new Response(JSON.stringify({ error: 'Text messaging is not set up.' }), {
      status: 422,
    });
    invoke().mockResolvedValue({
      data: null,
      error: Object.assign(new Error('fail'), { name: 'FunctionsHttpError', context: response }),
    });
    const { user } = renderRoute(<MessagesPage />, {
      path: '/app/messages?customer=c1',
      routePath: '/app/messages',
    });
    const box = await screen.findByRole('textbox', { name: 'Message' });
    await user.type(box, 'Hi');
    await user.click(screen.getByRole('button', { name: 'Send text' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Text messaging is not set up.');
  });
});
