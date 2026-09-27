import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import {
  builders,
  createBuilder,
  edgeHttpError,
  mockRpc,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import QuoteDetailPage from './QuoteDetailPage';
import { customerRow, quoteLineRow, quoteRow } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const invoke = supabase.functions.invoke;

function rpcByName(results: Record<string, unknown>) {
  supabase.rpc.mockImplementation((...args: unknown[]) => {
    const name = String(args[0]);
    return createBuilder({ data: name in results ? results[name] : null });
  });
}

function setup(quote = quoteRow(), lines = [quoteLineRow()]) {
  setTableResult('quotes', { data: quote });
  setTableResult('quote_line_items', { data: lines });
  setTableResult('customers', { data: customerRow() });
  setTableResult('vehicles', { data: [] });
  setTableResult('shops', {
    data: {
      quote_terms: null,
      invoice_terms: null,
      invoice_due_days: 14,
      tax_rate_bps: 800,
      name: 'Glacier Detailing',
      phone: null,
    },
  });
  return renderRoute(<QuoteDetailPage />, {
    path: `/app/quotes/${quote.id}`,
    routePath: '/app/quotes/:quoteId',
    routes: [{ path: '/app/jobs/:jobId', element: <p>Job page</p> }],
  });
}

beforeEach(() => {
  resetSupabaseMock();
  invoke.mockReset();
});

describe('QuoteDetailPage', () => {
  it('shows lines and server totals for a draft, editable', async () => {
    setup();
    expect(
      await screen.findByRole('heading', { name: 'Quote #1001', level: 1 }),
    ).toBeInTheDocument();
    const lines = screen.getByRole('list', { name: 'Line items' });
    expect(within(lines).getByText('Full detail')).toBeInTheDocument();
    expect(screen.getByText('$270.00')).toBeInTheDocument(); // total from the server
    expect(screen.getByRole('button', { name: 'Edit Full detail' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Send quote' })).toBeEnabled();
    // Draft: no client link yet
    expect(screen.queryByRole('button', { name: 'Copy client link' })).not.toBeInTheDocument();
  });

  it('sends a draft: marks it sent, then asks the server to send quote_sent', async () => {
    const calls = mockRpc({
      preview_document_message: {
        data: [
          {
            enabled: true,
            to_address: '+12055550123',
            subject: null,
            body: 'Hi Jane, your quote is ready: https://app/q/tok',
          },
        ],
      },
      mark_quote_sent: { data: quoteRow({ status: 'sent' }) },
    });
    invoke.mockResolvedValue({
      data: { message_id: 'm-1', channel: 'sms', status: 'sent', error: null },
      error: null,
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Send quote' }));
    const dialog = await screen.findByRole('dialog', { name: /Send quote #1001/ });
    const preview = await within(dialog).findByRole('region', { name: 'Message preview' });
    expect(preview).toHaveTextContent('Hi Jane, your quote is ready: https://app/q/tok');
    expect(calls).toContainEqual({
      fn: 'preview_document_message',
      args: { p_quote_id: 'quote-1', p_channel: 'sms' },
    });
    await user.click(within(dialog).getByRole('button', { name: 'Send text' }));
    await waitFor(() => expect(invoke).toHaveBeenCalled());
    // mark_quote_sent happens first, so the link in the message works.
    const order = calls.map((c) => c.fn);
    expect(order).toContain('mark_quote_sent');
    expect(invoke).toHaveBeenCalledWith('messaging', {
      body: {
        action: 'send',
        shop_id: 'shop-1',
        channel: 'sms',
        template_key: 'quote_sent',
        quote_id: 'quote-1',
        request_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/),
      },
    });
    expect(calls.some((c) => c.fn === 'render_template')).toBe(false);
    expect(await screen.findByText('Quote #1001 sent by text')).toBeInTheDocument();
  });

  it('shows the server’s preview as-is (no empty “Call us at” line for a shop without a phone)', async () => {
    mockRpc({
      preview_document_message: {
        data: [
          {
            enabled: true,
            to_address: 'jane@example.com',
            subject: 'Your quote from Glacier Detailing',
            body: 'Hi Jane,\nYour quote is ready: https://app/q/tok\nThanks!',
          },
        ],
      },
      mark_quote_sent: { data: quoteRow({ status: 'sent' }) },
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Send quote' }));
    const dialog = await screen.findByRole('dialog', { name: /Send quote #1001/ });
    await user.click(within(dialog).getByRole('radio', { name: /Email/ }));
    const preview = await within(dialog).findByRole('region', { name: 'Message preview' });
    expect(preview).toHaveTextContent('Subject: Your quote from Glacier Detailing');
    expect(preview).toHaveTextContent('Your quote is ready: https://app/q/tok');
    expect(preview).not.toHaveTextContent('Call us at');
  });

  it('keeps the draft open with the server’s reason and a retry that reuses the nonce', async () => {
    const calls = mockRpc({
      preview_document_message: {
        data: [{ enabled: true, to_address: '+12055550123', subject: null, body: 'Hi Jane' }],
      },
      mark_quote_sent: { data: quoteRow({ status: 'sent' }) },
    });
    invoke
      .mockResolvedValueOnce({
        data: null,
        error: edgeHttpError(422, {
          error: 'Text messaging is not set up for this shop.',
          code: 'unprocessable',
          details: { reason: 'sms_not_configured' },
        }),
      })
      .mockResolvedValueOnce({
        data: { message_id: 'm-1', channel: 'sms', status: 'sent', error: null },
        error: null,
      });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Send quote' }));
    const dialog = await screen.findByRole('dialog', { name: /Send quote #1001/ });
    await within(dialog).findByRole('region', { name: 'Message preview' });
    await user.click(within(dialog).getByRole('button', { name: 'Send text' }));
    const alert = await within(dialog).findByRole('alert');
    expect(alert).toHaveTextContent('Quote #1001 is marked as sent, but the message wasn’t sent.');
    expect(alert).toHaveTextContent('Text messaging is not set up for this shop.');
    await user.click(within(dialog).getByRole('button', { name: 'Try again' }));
    await waitFor(() => expect(invoke).toHaveBeenCalledTimes(2));
    const nonces = invoke.mock.calls.map(
      ([, options]) => (options.body as { request_nonce: string }).request_nonce,
    );
    expect(nonces[0]).toBe(nonces[1]);
    // mark_quote_sent is not repeated on the retry
    expect(calls.filter((c) => c.fn === 'mark_quote_sent')).toHaveLength(1);
  });

  it('offers the link instead when the template is turned off', async () => {
    mockRpc({
      preview_document_message: {
        data: [{ enabled: false, to_address: '+12055550123', subject: null, body: '' }],
      },
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Send quote' }));
    const dialog = await screen.findByRole('dialog', { name: /Send quote #1001/ });
    expect(await within(dialog).findByText(/turned off for texts/)).toBeInTheDocument();
    expect(within(dialog).getByRole('button', { name: 'Copy link' })).toBeInTheDocument();
    expect(within(dialog).getByRole('button', { name: 'Send text' })).toBeDisabled();
  });

  it('shows the copy-link fallback when the send is refused as template_disabled', async () => {
    mockRpc({
      preview_document_message: {
        data: [{ enabled: true, to_address: '+12055550123', subject: null, body: 'Hi Jane' }],
      },
      mark_quote_sent: { data: quoteRow({ status: 'sent' }) },
    });
    invoke.mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(422, {
        error: 'This message template is turned off for this channel.',
        code: 'unprocessable',
        details: { reason: 'template_disabled' },
      }),
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Send quote' }));
    const dialog = await screen.findByRole('dialog', { name: /Send quote #1001/ });
    await within(dialog).findByRole('region', { name: 'Message preview' });
    await user.click(within(dialog).getByRole('button', { name: 'Send text' }));
    expect(await within(dialog).findByRole('alert')).toHaveTextContent(
      'This message template is turned off for this channel.',
    );
    expect(within(dialog).getByRole('button', { name: 'Copy link' })).toBeInTheDocument();
  });

  it('can just mark a quote sent without messaging', async () => {
    mockRpc({ mark_quote_sent: { data: quoteRow({ status: 'sent' }) } });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Send quote' }));
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('radio', { name: /just mark as sent/ }));
    await user.click(within(dialog).getByRole('button', { name: 'Mark as sent' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('mark_quote_sent', { p_quote_id: 'quote-1' }),
    );
    expect(invoke).not.toHaveBeenCalled();
  });

  it('locks editing on an approved quote and converts it to a job', async () => {
    rpcByName({ convert_quote_to_job: { id: 'job-9', number: 77 } });
    const { user } = setup(quoteRow({ status: 'approved', approved_at: '2026-09-21T10:00:00Z' }));
    await screen.findByRole('heading', { name: 'Quote #1001', level: 1 });
    expect(screen.queryByRole('button', { name: 'Edit Full detail' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Copy client link' })).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Convert to job' }));
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('radio', { name: /Schedule later/ }));
    await user.click(within(dialog).getByRole('button', { name: 'Create job' }));
    expect(await screen.findByText('Job page')).toBeInTheDocument();
    expect(supabase.rpc).toHaveBeenCalledWith('convert_quote_to_job', { p_quote_id: 'quote-1' });
  });

  it('converts with a schedule in the shop time zone', async () => {
    rpcByName({ convert_quote_to_job: { id: 'job-9', number: 77 } });
    const { user } = setup(quoteRow({ status: 'approved' }));
    await user.click(await screen.findByRole('button', { name: 'Convert to job' }));
    const dialog = await screen.findByRole('dialog');
    const startDate = within(dialog).getByLabelText(/Start date/);
    await user.clear(startDate);
    await user.type(startDate, '2026-10-05');
    await user.click(within(dialog).getByRole('button', { name: 'Create job' }));
    await screen.findByText('Job page');
    // America/Chicago (CDT, UTC-5): 09:00 local → 14:00Z; 3 h of work → 12:00 local
    expect(supabase.rpc).toHaveBeenCalledWith('convert_quote_to_job', {
      p_quote_id: 'quote-1',
      p_start: '2026-10-05T14:00:00.000Z',
      p_end: '2026-10-05T17:00:00.000Z',
    });
  });

  it('records which optional items the customer chose when staff mark it approved', async () => {
    const { user } = setup(quoteRow({ status: 'sent', sent_at: '2026-09-21T10:00:00Z' }), [
      quoteLineRow(),
      quoteLineRow({
        id: 'qli-2',
        name: 'Ceramic top-up',
        optional: true,
        selected: false,
        unit_price_cents: 5000,
        total_cents: 5000,
        sort: 2,
      }),
      quoteLineRow({
        id: 'qli-3',
        name: 'Headlight restore',
        optional: true,
        selected: false,
        unit_price_cents: 3000,
        total_cents: 3000,
        sort: 3,
      }),
    ]);
    await user.click(await screen.findByRole('button', { name: 'More quote actions' }));
    await user.click(screen.getByRole('menuitem', { name: /Mark approved/ }));
    const dialog = await screen.findByRole('dialog', { name: 'Mark quote as approved' });
    const topUp = within(dialog).getByRole('checkbox', { name: 'Ceramic top-up' });
    expect(topUp).not.toBeChecked();
    expect(within(dialog).getByRole('checkbox', { name: 'Headlight restore' })).not.toBeChecked();
    await user.click(topUp);
    await user.type(within(dialog).getByLabelText(/Approved by/), ' Jane Doe ');
    await user.click(within(dialog).getByRole('button', { name: 'Mark approved' }));

    // One atomic RPC: the full list of chosen optional lines, the name and the status.
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('staff_record_quote_response', {
        p_quote_id: 'quote-1',
        p_action: 'approve',
        p_selected_optional_line_ids: ['qli-2'],
        p_approved_by_name: 'Jane Doe',
      }),
    );
    expect(builders.quote_line_items?.some((b) => b.update.mock.calls.length > 0)).toBe(false);
    expect(builders.quotes?.some((b) => b.update.mock.calls.length > 0)).toBe(false);
  });

  it('records a decline with the reason and shows the server’s refusal', async () => {
    rpcByName({});
    supabase.rpc.mockReturnValueOnce(
      createBuilder({
        error: { code: '22023', message: 'this quote has expired', details: null, hint: null },
      }),
    );
    const { user } = setup(quoteRow({ status: 'viewed', sent_at: '2026-09-21T10:00:00Z' }));
    await user.click(await screen.findByRole('button', { name: 'More quote actions' }));
    await user.click(screen.getByRole('menuitem', { name: /Mark declined/ }));
    const dialog = await screen.findByRole('dialog', { name: 'Mark quote as declined' });
    await user.type(within(dialog).getByLabelText(/Reason/), 'Went with another shop');
    await user.click(within(dialog).getByRole('button', { name: 'Mark declined' }));
    expect(await screen.findByText('This quote has expired.')).toBeInTheDocument();
    expect(supabase.rpc).toHaveBeenCalledWith('staff_record_quote_response', {
      p_quote_id: 'quote-1',
      p_action: 'decline',
      p_declined_reason: 'Went with another shop',
    });
  });

  it('duplicates with the shop’s current tax rate', async () => {
    const { user } = setup(quoteRow({ tax_rate_bps: 500 }));
    setTableResult('shops', { data: { tax_rate_bps: 925 } });
    await user.click(await screen.findByRole('button', { name: 'More quote actions' }));
    await user.click(screen.getByRole('menuitem', { name: 'Duplicate' }));
    await waitFor(() =>
      expect(
        builders.quotes?.find((b) => b.insert.mock.calls.length > 0)?.insert,
      ).toHaveBeenCalledWith(
        expect.objectContaining({ tax_rate_bps: 925, customer_id: quoteRow().customer_id }),
      ),
    );
    expect(await screen.findByText('Duplicated as quote #1001')).toBeInTheDocument();
  });

  it('removes the new draft when its lines fail to copy', async () => {
    const { user } = setup();
    await screen.findByRole('list', { name: 'Line items' });
    setTableResult('quote_line_items', {
      data: null,
      error: { message: "the vehicle does not belong to this quote's customer", code: '23514' },
    });
    await user.click(await screen.findByRole('button', { name: 'More quote actions' }));
    await user.click(screen.getByRole('menuitem', { name: 'Duplicate' }));
    await waitFor(() =>
      expect(builders.quotes?.some((b) => b.delete.mock.calls.length > 0)).toBe(true),
    );
    const cleanup = builders.quotes?.find((b) => b.delete.mock.calls.length > 0);
    expect(cleanup?.eq).toHaveBeenCalledWith('id', 'quote-1');
    expect(
      (await screen.findAllByText("The vehicle does not belong to this quote's customer.")).length,
    ).toBeGreaterThan(0);
  });

  it('shows an error state with retry', async () => {
    setTableResult('quotes', { data: null, error: { message: 'boom', code: 'XX000' } });
    setTableResult('quote_line_items', { data: [] });
    renderRoute(<QuoteDetailPage />, { path: '/app/quotes/q', routePath: '/app/quotes/:quoteId' });
    expect(await screen.findByRole('button', { name: 'Try again' })).toBeInTheDocument();
  });
});
