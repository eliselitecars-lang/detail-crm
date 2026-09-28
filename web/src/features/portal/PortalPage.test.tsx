import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute, signedInAuth } from '@/test/render';
import {
  mockRpc,
  pgError,
  resetSupabaseMock,
  setFunctionResult,
  supabase,
} from '@/test/supabaseMock';
import { navigation } from '@/features/public-docs/shared/checkout';
import type { PortalOverview } from './api';
import PortalPage from './PortalPage';
import { MEMBERSHIP_REFRESH_MS } from './returnNotice';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const JOB_TOKEN = '11111111-2222-4333-8444-555555555555';

function overview(overrides: Partial<PortalOverview> = {}): PortalOverview {
  return {
    shops: [
      {
        slug: 'glacier',
        name: 'Glacier Detailing',
        logo_path: null,
        brand_color: null,
        phone: '+12055550100',
        email: null,
        website: null,
        city: 'Birmingham',
        region: 'AL',
        timezone: 'America/Chicago',
        currency: 'usd',
        booking_enabled: true,
      },
    ],
    customers: [],
    vehicles: [
      {
        id: 'v1',
        shop_slug: 'glacier',
        year: 2021,
        make: 'Toyota',
        model: 'Camry',
        trim: null,
        color: 'Blue',
        license_plate: 'ABC123',
        category_id: null,
        category_name: 'Sedan',
      },
    ],
    upcoming_jobs: [
      {
        token: JOB_TOKEN,
        shop_slug: 'glacier',
        number: 1042,
        status: 'scheduled',
        // 14:00Z = 9:00 AM in Chicago (CDT) — never the Honolulu test zone.
        scheduled_start: '2026-10-01T14:00:00Z',
        scheduled_end: '2026-10-01T15:30:00Z',
        completed_at: null,
        location_type: 'shop',
        vehicle: '2021 Toyota Camry',
        services: 'Full detail',
        total_cents: 15000,
        deposit_required_cents: 0,
      },
    ],
    past_jobs: [],
    quotes: [
      {
        token: 'q-token',
        shop_slug: 'glacier',
        number: 301,
        status: 'sent',
        total_cents: 54000,
        valid_until: '2026-12-31',
        sent_at: '2026-09-20T15:00:00Z',
        vehicle: null,
      },
    ],
    invoices: [
      {
        token: 'i-token',
        shop_slug: 'glacier',
        number: 2001,
        status: 'partially_paid',
        total_cents: 30000,
        amount_paid_cents: 10000,
        balance_cents: 20000,
        issued_at: '2026-09-20T15:00:00Z',
        due_at: null,
      },
    ],
    memberships: [],
    ...overrides,
  };
}

function render(path = '/portal') {
  return renderRoute(<PortalPage />, {
    path,
    routePath: '/portal',
    shop: null,
    auth: signedInAuth('ana@example.com', 'client-1'),
  });
}

beforeEach(() => {
  resetSupabaseMock();
});

describe('PortalPage', () => {
  it('claims records, then lists appointments, invoices and quotes', async () => {
    const calls = mockRpc({
      portal_claim_customers: { data: 1 },
      portal_overview: { data: overview() },
    });
    render();
    const upcoming = await screen.findByRole('list', { name: 'Upcoming appointments' });
    expect(calls.map((c) => c.fn).slice(0, 2)).toEqual([
      'portal_claim_customers',
      'portal_overview',
    ]);
    const job = within(upcoming).getByRole('link');
    expect(job).toHaveAttribute('href', `/booking/${JOB_TOKEN}`);
    expect(job).toHaveTextContent('Thu, Oct 1, 2026 · 9:00 – 10:30 AM');
    expect(job).toHaveTextContent('Full detail');
    const invoice = within(screen.getByRole('list', { name: 'Invoices' })).getByRole('link');
    expect(invoice).toHaveAttribute('href', '/i/i-token');
    expect(invoice).toHaveTextContent('$200.00 due');
    expect(within(screen.getByRole('list', { name: 'Quotes' })).getByRole('link')).toHaveAttribute(
      'href',
      '/q/q-token',
    );
    expect(screen.getByText('2021 Toyota Camry')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Book with Glacier Detailing' })).toHaveAttribute(
      'href',
      '/book/glacier',
    );
  });

  it('explains how bookings appear when nothing is linked', async () => {
    mockRpc({
      portal_claim_customers: { data: 0 },
      portal_overview: {
        data: overview({ shops: [], vehicles: [], upcoming_jobs: [], quotes: [], invoices: [] }),
      },
    });
    render();
    expect(await screen.findByText('No bookings linked yet')).toBeInTheDocument();
    expect(screen.getByText(/same email as this account \(ana@example\.com\)/)).toBeInTheDocument();
  });

  it('asks an unconfirmed account to confirm its email and still loads', async () => {
    mockRpc({
      portal_claim_customers: pgError(
        '42501',
        'confirm your email address before linking your records',
      ),
      portal_overview: {
        data: overview({ shops: [], vehicles: [], upcoming_jobs: [], quotes: [], invoices: [] }),
      },
    });
    render();
    expect(await screen.findByText('Confirm your email to see your bookings')).toBeInTheDocument();
    expect(await screen.findByText('No bookings linked yet')).toBeInTheDocument();
  });

  it('shows a retryable error when the overview fails', async () => {
    mockRpc({
      portal_claim_customers: { data: 0 },
      portal_overview: pgError('42501', 'sign in to use the client portal'),
    });
    render();
    expect(await screen.findByText('Couldn’t load your account')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument();
  });

  it('confirms a saved card from the Stripe return URL and strips the parameter', async () => {
    mockRpc({ portal_claim_customers: { data: 1 }, portal_overview: { data: overview() } });
    const { router } = render('/portal?card=saved&tab=x');
    expect(
      await screen.findByText(
        'Your card was saved. Glacier Detailing can now charge it for future visits.',
      ),
    ).toBeInTheDocument();
    // only the return parameter is removed, with replace (no history entry)
    await waitFor(() => expect(router.state.location.search).toBe('?tab=x'));
    expect(router.state.historyAction).toBe('REPLACE');
    // the banner stays after the URL is cleaned
    expect(
      screen.getByText(
        'Your card was saved. Glacier Detailing can now charge it for future visits.',
      ),
    ).toBeInTheDocument();
  });

  it.each([
    ['card=canceled', 'No card was saved.'],
    ['membership=canceled', 'Membership sign-up was cancelled; nothing was charged.'],
  ])('shows an info banner for ?%s', async (query, text) => {
    mockRpc({ portal_claim_customers: { data: 1 }, portal_overview: { data: overview() } });
    const { router } = render(`/portal?${query}`);
    expect(await screen.findByText(text)).toBeInTheDocument();
    await waitFor(() => expect(router.state.location.search).toBe(''));
  });

  it('ignores unknown return values', async () => {
    mockRpc({ portal_claim_customers: { data: 1 }, portal_overview: { data: overview() } });
    render('/portal?card=bogus&membership=maybe');
    await screen.findByRole('list', { name: 'Upcoming appointments' });
    expect(
      screen.queryByText(/card was saved|No card was saved|membership/i),
    ).not.toBeInTheDocument();
  });

  it('re-reads the overview once, a few seconds after a membership sign-up', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      const calls = mockRpc({
        portal_claim_customers: { data: 1 },
        portal_overview: { data: overview() },
      });
      render('/portal?membership=active');
      expect(
        await screen.findByText(
          'Thanks! Your membership is being activated — it can take a minute to show as active.',
        ),
      ).toBeInTheDocument();
      const overviews = () => calls.filter((c) => c.fn === 'portal_overview').length;
      expect(overviews()).toBe(1);
      await vi.advanceTimersByTimeAsync(MEMBERSHIP_REFRESH_MS);
      await waitFor(() => expect(overviews()).toBe(2));
      await vi.advanceTimersByTimeAsync(MEMBERSHIP_REFRESH_MS * 2);
      expect(overviews()).toBe(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it('links to the account page from the footer', async () => {
    mockRpc({ portal_claim_customers: { data: 1 }, portal_overview: { data: overview() } });
    render();
    expect(await screen.findByRole('link', { name: 'Account settings' })).toHaveAttribute(
      'href',
      '/account',
    );
  });

  describe('self-service', () => {
    const MEMBERSHIP = '77777777-7777-4777-8777-777777777777';
    const membership = {
      id: MEMBERSHIP,
      shop_name: 'Glacier Detailing',
      shop_slug: 'glacier',
      plan_name: 'Monthly wash club',
      status: 'active',
      price_cents: 4900,
      interval: 'month',
      interval_count: 1,
      current_period_end: '2026-10-15T05:00:00Z',
      cancel_at_period_end: false,
      uses_per_period: 2,
      uses_this_period: 1,
      can_cancel: true,
    };

    it('cancels a membership at the end of the period', async () => {
      const calls = mockRpc({
        portal_claim_customers: { data: 1 },
        portal_overview: { data: overview() },
        portal_memberships: { data: [membership] },
      });
      setFunctionResult('payments', {
        data: {
          membership_id: MEMBERSHIP,
          status: 'active',
          cancel_at_period_end: true,
          current_period_end: '2026-10-15T05:00:00Z',
        },
      });
      const { user } = render();
      const list = await screen.findByRole('list', { name: 'Memberships' });
      expect(within(list).getByText(/1 of 2 visits used this period/)).toBeInTheDocument();
      expect(within(list).getByText(/Renews Oct 15, 2026/)).toBeInTheDocument();
      await user.click(within(list).getByRole('button', { name: 'Cancel membership' }));
      const dialog = await screen.findByRole('alertdialog', { name: /Cancel Monthly wash club/ });
      expect(dialog).toHaveTextContent('It stays active until Oct 15, 2026');
      await user.click(within(dialog).getByRole('button', { name: 'Cancel at period end' }));
      await waitFor(() =>
        expect(supabase.functions.invoke).toHaveBeenCalledWith('payments', {
          body: { action: 'portal_membership_cancel', membership_id: MEMBERSHIP },
        }),
      );
      await waitFor(() =>
        expect(calls.filter((c) => c.fn === 'portal_memberships').length).toBeGreaterThan(1),
      );
    });

    it('opens the billing portal for the card and receipts', async () => {
      mockRpc({
        portal_claim_customers: { data: 1 },
        portal_overview: { data: overview() },
        portal_memberships: { data: [membership] },
      });
      setFunctionResult('payments', { data: { url: 'https://billing.stripe.com/p/session/x' } });
      const assign = vi.spyOn(navigation, 'assign').mockImplementation(() => undefined);
      const { user } = render();
      await user.click(await screen.findByRole('button', { name: 'Card & billing history' }));
      await waitFor(() =>
        expect(assign).toHaveBeenCalledWith('https://billing.stripe.com/p/session/x'),
      );
      expect(supabase.functions.invoke).toHaveBeenCalledWith('payments', {
        body: { action: 'portal_billing_portal', membership_id: MEMBERSHIP },
      });
    });

    it('lists job reports, documents and the referral code', async () => {
      mockRpc({
        portal_claim_customers: { data: 1 },
        portal_overview: { data: overview() },
        portal_memberships: { data: [] },
        portal_job_reports: {
          data: [
            {
              shop_name: 'Glacier Detailing',
              job_number: 1040,
              completed_at: '2026-09-18T20:00:00Z',
              published_at: '2026-09-18T21:00:00Z',
              report_path: '/r/88888888-8888-4888-8888-888888888888',
            },
          ],
        },
        portal_documents: {
          data: [
            {
              id: 'doc-9',
              shop_name: 'Glacier Detailing',
              file_name: 'Warranty.pdf',
              content_type: 'application/pdf',
              size_bytes: 1024,
              job_number: 1040,
              created_at: '2026-09-18T21:00:00Z',
            },
          ],
        },
        portal_referrals: {
          data: [
            {
              shop_name: 'Glacier Detailing',
              code: 'ANA-4K7Q',
              share_url: 'https://app.example.com/book/glacier?coupon=ANA-4K7Q',
              credits_earned_cents: 2500,
              credit_balance_cents: 1000,
            },
          ],
        },
      });
      render();
      const reports = await screen.findByRole('list', { name: 'Job reports' });
      expect(within(reports).getByRole('link', { name: /Appointment #1040/ })).toHaveAttribute(
        'href',
        '/r/88888888-8888-4888-8888-888888888888',
      );
      const docs = await screen.findByRole('list', { name: 'Documents' });
      expect(within(docs).getByText('Warranty.pdf')).toBeInTheDocument();
      expect(await screen.findByLabelText('Your code')).toHaveTextContent('ANA-4K7Q');
      expect(screen.getByText(/Earned so far: \$25\.00/)).toBeInTheDocument();
    });
  });
});
