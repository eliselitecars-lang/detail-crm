import { screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import {
  builders,
  mockRpc,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import QuoteDetailPage from './QuoteDetailPage';
import { customerRow, quoteLineRow, quoteRow } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const invoke = supabase.functions.invoke;

function option(id: string, name: string, sort: number, total: number) {
  return {
    id,
    shop_id: 'shop-1',
    quote_id: 'quote-1',
    name,
    description: null,
    sort,
    subtotal_cents: total,
    discount_cents: 0,
    tax_cents: 0,
    total_cents: total,
    created_at: '2026-09-20T15:00:00Z',
    updated_at: '2026-09-20T15:00:00Z',
  };
}

function setup({
  quote = quoteRow(),
  lines = [quoteLineRow()],
  options = [] as ReturnType<typeof option>[],
}: {
  quote?: ReturnType<typeof quoteRow>;
  lines?: ReturnType<typeof quoteLineRow>[];
  options?: ReturnType<typeof option>[];
} = {}) {
  setTableResult('quotes', { data: quote });
  setTableResult('quote_line_items', { data: lines });
  setTableResult('quote_options', { data: options });
  setTableResult('customers', { data: customerRow() });
  setTableResult('vehicles', { data: [] });
  setTableResult('booking_settings', { data: { enabled: true, quote_self_schedule: true } });
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

afterEach(() => {
  vi.restoreAllMocks();
});

describe('QuoteDetailPage — proposal options', () => {
  const options = [option('opt-1', 'Basic', 1, 20000), option('opt-2', 'Premium', 2, 45000)];
  const lines = [
    quoteLineRow({ id: 'shared-1', name: 'Hand wash', option_id: null }),
    quoteLineRow({ id: 'basic-1', name: 'Spray sealant', option_id: 'opt-1' }),
    quoteLineRow({ id: 'premium-1', name: 'Ceramic coating', option_id: 'opt-2' }),
  ];

  it('shows shared lines, one tab per option and each option’s server total', async () => {
    const { user } = setup({ lines, options });
    expect(await screen.findByRole('list', { name: 'Shared line items' })).toHaveTextContent(
      'Hand wash',
    );
    const optionList = screen.getByRole('list', { name: 'Proposal options' });
    expect(within(optionList).getByText('$200.00')).toBeInTheDocument();
    expect(within(optionList).getByText('$450.00')).toBeInTheDocument();
    expect(screen.getByRole('list', { name: 'Basic line items' })).toHaveTextContent(
      'Spray sealant',
    );
    await user.click(screen.getByRole('tab', { name: /Premium/ }));
    expect(screen.getByRole('list', { name: 'Premium line items' })).toHaveTextContent(
      'Ceramic coating',
    );
    expect(screen.getByRole('heading', { name: 'Totals · Basic' })).toBeInTheDocument();
  });

  it('records an approval with the option the customer chose', async () => {
    const calls = mockRpc({
      staff_record_quote_response: { data: quoteRow({ status: 'approved' }) },
    });
    const { user } = setup({ quote: quoteRow({ status: 'sent' }), lines, options });
    await user.click(await screen.findByRole('button', { name: 'More quote actions' }));
    await user.click(screen.getByRole('menuitem', { name: 'Mark approved…' }));
    const dialog = await screen.findByRole('dialog', { name: 'Mark quote as approved' });
    await user.click(within(dialog).getByRole('button', { name: 'Mark approved' }));
    expect(
      await within(dialog).findByText('Choose the option the customer approved.'),
    ).toBeInTheDocument();
    await user.click(within(dialog).getByRole('radio', { name: /Premium/ }));
    await user.click(within(dialog).getByRole('button', { name: 'Mark approved' }));
    await waitFor(() =>
      expect(calls.find((c) => c.fn === 'staff_record_quote_response')?.args).toEqual({
        p_quote_id: 'quote-1',
        p_action: 'approve',
        p_selected_optional_line_ids: [],
        p_option_id: 'opt-2',
      }),
    );
  });

  it('starts two options on a draft', async () => {
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Offer options' }));
    await waitFor(() =>
      expect(builders.quote_options?.some((b) => b.insert.mock.calls.length > 0)).toBe(true),
    );
    const insert = builders.quote_options?.find((b) => b.insert.mock.calls.length > 0)?.insert;
    expect(insert).toHaveBeenCalledWith([
      { shop_id: 'shop-1', quote_id: 'quote-1', name: 'Option 1', description: null, sort: 1 },
      { shop_id: 'shop-1', quote_id: 'quote-1', name: 'Option 2', description: null, sort: 2 },
    ]);
  });
});

describe('QuoteDetailPage — fees, follow-ups, PDF, self-scheduling', () => {
  it('adds a preset fee through the server (it prices the line)', async () => {
    setTableResult('shop_fees', {
      data: [
        { id: 'fee-1', name: 'Travel', amount_cents: 2500, taxable: false, auto_apply: 'none' },
      ],
    });
    const calls = mockRpc({ add_fee_line: { data: 'line-9' } });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Add fee' }));
    await user.click(screen.getByRole('menuitem', { name: 'Travel · $25.00' }));
    await waitFor(() =>
      expect(calls.find((c) => c.fn === 'add_fee_line')?.args).toEqual({
        p_doc_kind: 'quote',
        p_doc_id: 'quote-1',
        p_fee_id: 'fee-1',
        p_request_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/) as unknown,
      }),
    );
    expect(await screen.findByText('Travel added')).toBeInTheDocument();
  });

  it('retries a fee with the same request nonce after a network failure, never twice', async () => {
    setTableResult('shop_fees', {
      data: [
        { id: 'fee-1', name: 'Travel', amount_cents: 2500, taxable: false, auto_apply: 'none' },
      ],
    });
    let attempt = 0;
    const calls = mockRpc({
      add_fee_line: () => {
        attempt += 1;
        return attempt === 1
          ? { data: null, error: new TypeError('Failed to fetch') }
          : { data: 'line-9' };
      },
    });
    const { user } = setup();
    const addFee = async () => {
      await user.click(await screen.findByRole('button', { name: 'Add fee' }));
      await user.click(screen.getByRole('menuitem', { name: 'Travel · $25.00' }));
    };
    await addFee();
    expect(await screen.findByText(/Can’t reach the server|Can't reach the server/)).toBeVisible();
    await addFee();
    expect(await screen.findByText('Travel added')).toBeInTheDocument();
    const nonces = calls
      .filter((c) => c.fn === 'add_fee_line')
      .map((c) => c.args.p_request_nonce as string);
    expect(nonces).toHaveLength(2);
    expect(nonces[1]).toBe(nonces[0]);
  });

  it('shows the next automatic reminder and pauses them', async () => {
    const status = {
      kind: 'quote',
      stage: 'quote',
      enabled: true,
      paused: false,
      attempts_sent: 1,
      max_attempts: 2,
      last_sent_at: '2026-09-22T15:00:00Z',
      next_at: '2026-09-29T15:00:00Z',
    };
    let current: Omit<typeof status, 'next_at'> & { next_at: string | null } = status;
    const calls = mockRpc({
      document_followup_status: () => ({ data: current }),
      set_document_followups_paused: (args) => {
        current = { ...status, paused: args.p_paused === true, next_at: null };
        return { data: current };
      },
    });
    const { user } = setup({ quote: quoteRow({ status: 'sent' }) });
    expect(
      await screen.findByText(/Next reminder Tue, Sep 29, 2026 · 10:00 AM/),
    ).toBeInTheDocument();
    expect(screen.getByText(/1 of 2 sent/)).toBeInTheDocument();
    await user.click(screen.getByRole('switch', { name: 'Remind the customer about this quote' }));
    await waitFor(() =>
      expect(calls.find((c) => c.fn === 'set_document_followups_paused')?.args).toEqual({
        p_kind: 'quote',
        p_id: 'quote-1',
        p_paused: true,
      }),
    );
    expect(await screen.findByText(/Paused for this quote/)).toBeInTheDocument();
  });

  it('downloads the staff PDF from the pdf function', async () => {
    const createObjectURL = vi.fn(() => 'blob:pdf');
    Object.assign(URL, { createObjectURL, revokeObjectURL: vi.fn() });
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
    invoke.mockResolvedValueOnce({
      data: new Blob(['%PDF'], { type: 'application/pdf' }),
      error: null,
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'More quote actions' }));
    await user.click(screen.getByRole('menuitem', { name: 'Download PDF' }));
    await waitFor(() =>
      expect(invoke).toHaveBeenCalledWith('pdf', {
        body: { action: 'staff_document', shop_id: 'shop-1', kind: 'quote', id: 'quote-1' },
      }),
    );
    await waitFor(() => expect(click).toHaveBeenCalled());
    expect(createObjectURL).toHaveBeenCalled();
  });

  it('says when the customer scheduled the quote themselves', async () => {
    setup({
      quote: quoteRow({
        status: 'converted',
        converted_job_id: 'job-7',
        self_scheduled_at: '2026-09-25T15:00:00Z',
      }),
    });
    expect(await screen.findByText(/Scheduled by the customer/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Open the job' })).toHaveAttribute(
      'href',
      '/app/jobs/job-7',
    );
  });

  it('turns customer self-scheduling off for one quote', async () => {
    const { user } = setup({ quote: quoteRow({ status: 'approved', self_schedule: true }) });
    await user.click(await screen.findByRole('switch', { name: 'Let the customer pick a time' }));
    await waitFor(() =>
      expect(
        builders.quotes?.some((b) =>
          b.update.mock.calls.some(
            ([patch]) => (patch as { self_schedule?: boolean }).self_schedule === false,
          ),
        ),
      ).toBe(true),
    );
  });
});
