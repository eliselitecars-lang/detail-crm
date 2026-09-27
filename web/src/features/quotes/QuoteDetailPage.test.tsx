import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { supabase as appSupabase } from '@/lib/supabase';
import { renderRoute } from '@/test/render';
import { createBuilder, resetSupabaseMock, setTableResult, supabase } from '@/test/supabaseMock';
import QuoteDetailPage from './QuoteDetailPage';
import { customerRow, quoteLineRow, quoteRow } from './testFixtures';

vi.mock('@/lib/supabase', async () => {
  const mod = await import('@/test/supabaseMock');
  return { ...mod, supabase: Object.assign(mod.supabase, { functions: { invoke: vi.fn() } }) };
});

const invoke = vi.mocked(appSupabase.functions.invoke);

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
  setTableResult('message_templates', {
    data: { subject: null, body: 'Hi {{customer_first_name}}: {{quote_link}}', enabled: true },
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

  it('sends a draft: marks it sent, then texts the rendered template', async () => {
    rpcByName({
      render_template: 'Hi Jane: https://app/q/tok',
      mark_quote_sent: quoteRow({ status: 'sent' }),
    });
    invoke.mockResolvedValue({
      data: { message_id: 'm-1', channel: 'sms', status: 'sent', error: null },
      error: null,
      response: undefined,
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Send quote' }));
    const dialog = await screen.findByRole('dialog', { name: /Send quote #1001/ });
    const message = await within(dialog).findByRole('textbox', { name: 'Message' });
    expect(message).toHaveValue('Hi Jane: https://app/q/tok');
    await user.click(within(dialog).getByRole('button', { name: 'Send text' }));
    await waitFor(() => expect(invoke).toHaveBeenCalled());
    expect(supabase.rpc).toHaveBeenCalledWith('mark_quote_sent', { p_quote_id: 'quote-1' });
    expect(invoke).toHaveBeenCalledWith('messaging', {
      body: {
        action: 'send',
        shop_id: 'shop-1',
        customer_id: customerRow().id,
        channel: 'sms',
        body: 'Hi Jane: https://app/q/tok',
      },
    });
  });

  it('can just mark a quote sent without messaging', async () => {
    rpcByName({ render_template: 'Hi', mark_quote_sent: quoteRow({ status: 'sent' }) });
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

  it('shows an error state with retry', async () => {
    setTableResult('quotes', { data: null, error: { message: 'boom', code: 'XX000' } });
    setTableResult('quote_line_items', { data: [] });
    renderRoute(<QuoteDetailPage />, { path: '/app/quotes/q', routePath: '/app/quotes/:quoteId' });
    expect(await screen.findByRole('button', { name: 'Try again' })).toBeInTheDocument();
  });
});
