import { screen, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute, signedInAuth } from '@/test/render';
import { mockRpc, pgError, resetPublicMocks } from '@/features/public-docs/shared/testing';
import type { PortalOverview } from './api';
import PortalPage from './PortalPage';

vi.mock('@/lib/supabase', () => import('@/features/public-docs/shared/testSupabase'));

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

function render() {
  return renderRoute(<PortalPage />, {
    path: '/portal',
    routePath: '/portal',
    shop: null,
    auth: signedInAuth('ana@example.com', 'client-1'),
  });
}

beforeEach(() => {
  resetPublicMocks();
});

describe('PortalPage', () => {
  it('claims records, then lists appointments, invoices and quotes', async () => {
    const calls = mockRpc({
      portal_claim_customers: { data: 1 },
      portal_overview: { data: overview() },
    });
    render();
    const upcoming = await screen.findByRole('list', { name: 'Upcoming appointments' });
    expect(calls.map((c) => c.fn)).toEqual(['portal_claim_customers', 'portal_overview']);
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
});
