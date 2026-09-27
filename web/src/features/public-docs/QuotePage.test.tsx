import { screen, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import QuotePage from './QuotePage';
import { mockRpc, pgError, resetSupabaseMock } from '@/test/supabaseMock';
import { DOC_TOKEN, OPT_A, quoteFixture } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

function render(path = `/q/${DOC_TOKEN}`) {
  return renderRoute(<QuotePage />, { path, routePath: '/q/:token', shop: null });
}

beforeEach(() => {
  resetSupabaseMock();
});

describe('QuotePage', () => {
  it('shows lines, optional add-ons and the server totals', async () => {
    const calls = mockRpc({ public_get_quote: { data: quoteFixture() } });
    render();
    expect(
      await screen.findByRole('heading', { name: 'Quote #301', level: 1 }),
    ).toBeInTheDocument();
    expect(calls[0]).toEqual({ fn: 'public_get_quote', args: { p_token: DOC_TOKEN } });
    expect(screen.getByText(/Prepared for Ana Diaz/)).toBeInTheDocument();
    expect(screen.getByRole('checkbox', { name: 'Wheel coating' })).not.toBeChecked();
    expect(screen.getByRole('checkbox', { name: 'Glass coating' })).toBeChecked();
    expect(screen.getByText('$540.00')).toBeInTheDocument();
    expect(screen.getByText('Tax (8%)')).toBeInTheDocument();
  });

  it('approves with the typed name and exactly the chosen optional items', async () => {
    const approved = quoteFixture({
      status: 'approved',
      can_respond: false,
      approved_by_name: 'Ana Diaz',
      approved_at: '2026-09-27T15:00:00Z',
      total_cents: 70200,
    });
    const calls = mockRpc({
      public_get_quote: { data: quoteFixture() },
      public_respond_quote: { data: approved },
    });
    const { user } = render();
    await user.click(await screen.findByRole('checkbox', { name: 'Wheel coating' }));
    await user.click(screen.getByRole('checkbox', { name: 'Glass coating' }));
    await user.click(screen.getByRole('button', { name: 'Approve quote' }));
    expect(screen.getByText('Type your full name to approve.')).toBeInTheDocument();
    await user.type(screen.getByLabelText(/^Your full name/), 'Ana Diaz');
    await user.click(screen.getByRole('button', { name: 'Approve quote' }));
    expect(await screen.findByText('Quote approved')).toBeInTheDocument();
    expect(calls.find((c) => c.fn === 'public_respond_quote')?.args).toEqual({
      p_token: DOC_TOKEN,
      p_action: 'approve',
      p_signer_name: 'Ana Diaz',
      p_selected_optional_line_ids: [OPT_A],
    });
    expect(screen.getByText('$702.00')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Approve quote' })).not.toBeInTheDocument();
  });

  it('declines with a reason', async () => {
    const calls = mockRpc({
      public_get_quote: { data: quoteFixture() },
      public_respond_quote: {
        data: quoteFixture({ status: 'declined', can_respond: false, declined_reason: 'Too much' }),
      },
    });
    const { user } = render();
    await user.click(await screen.findByRole('button', { name: 'Decline' }));
    const dialog = screen.getByRole('dialog');
    await user.type(within(dialog).getByLabelText('Reason'), 'Too much');
    await user.click(within(dialog).getByRole('button', { name: 'Decline quote' }));
    expect(await screen.findByText('Quote declined')).toBeInTheDocument();
    expect(calls.find((c) => c.fn === 'public_respond_quote')?.args).toEqual({
      p_token: DOC_TOKEN,
      p_action: 'decline',
      p_declined_reason: 'Too much',
    });
  });

  it('shows the expired state without response controls', async () => {
    mockRpc({
      public_get_quote: { data: quoteFixture({ status: 'expired', can_respond: false }) },
    });
    render();
    expect(await screen.findByText('This quote has expired')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Approve quote' })).not.toBeInTheDocument();
    expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
  });

  it('shows the converted state', async () => {
    mockRpc({
      public_get_quote: { data: quoteFixture({ status: 'converted', can_respond: false }) },
    });
    render();
    expect(await screen.findByText('Quote accepted and scheduled')).toBeInTheDocument();
  });

  it('surfaces a server refusal (e.g. expired meanwhile)', async () => {
    mockRpc({
      public_get_quote: { data: quoteFixture() },
      public_respond_quote: pgError('22023', 'this quote has expired'),
    });
    const { user } = render();
    await user.type(await screen.findByLabelText(/^Your full name/), 'Ana');
    await user.click(screen.getByRole('button', { name: 'Approve quote' }));
    expect(await screen.findByText('This quote has expired.')).toBeInTheDocument();
  });

  it('shows not found for an unknown quote', async () => {
    mockRpc({ public_get_quote: pgError('PT404', 'quote not found') });
    render();
    expect(await screen.findByText('We couldn’t find this quote')).toBeInTheDocument();
  });

  it('shows a retryable error on network failure', async () => {
    let fail = true;
    mockRpc({
      public_get_quote: () => (fail ? pgError('XX000', 'boom') : { data: quoteFixture() }),
    });
    const { user } = render();
    expect(
      await screen.findByText('Couldn’t load this quote', {}, { timeout: 8000 }),
    ).toBeInTheDocument();
    fail = false;
    await user.click(screen.getByRole('button', { name: 'Try again' }));
    expect(
      await screen.findByRole('heading', { name: 'Quote #301', level: 1 }),
    ).toBeInTheDocument();
  });
});
