/**
 * A lapsed shop (0102 / 0103): staff pages must not keep advertising what the
 * server turned off (lead forms, online gift card and membership sales,
 * automations), and the banner / billing page must say so.
 */
import { screen, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import { mockRpc, resetSupabaseMock, setTableResult } from '@/test/supabaseMock';
import { planRow } from '@/features/quotes/testFixtures';
import GiftCardsPage from '@/features/gift-cards/GiftCardsPage';
import MembershipsPage from '@/features/memberships/MembershipsPage';
import { renderSettings } from '@/features/settings/testing/renderSettings';
import { BillingBanner } from './BillingBanner';
import type { Entitlement } from './model';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

function entitlement(state: Entitlement['state']): Entitlement {
  return {
    billing_enabled: true,
    state,
    reason: state === 'lapsed' ? 'trial_ended' : 'subscribed',
    plan_name: null,
    trial_ends_at: null,
    current_period_end: null,
    cancel_at_period_end: false,
    max_members: null,
    members_used: null,
    can_write: state !== 'lapsed',
    is_owner: true,
  };
}

const standing = (state: Entitlement['state']) =>
  mockRpc({ shop_entitlement: { data: entitlement(state) } });

const owner = () => shopValue({ membership: membership({ role: 'owner' }) });

describe('lapsed shop: staff pages', () => {
  it('gift cards: online sales read as paused, no shop link, issuing is off', async () => {
    standing('lapsed');
    setTableResult('gift_cards', { data: [], count: 0 });
    setTableResult('gift_card_settings', {
      data: { online_enabled: true, offers: [], allow_custom_amount: true, expires_months: null },
    });
    renderRoute(<GiftCardsPage />, {
      path: '/app/gift-cards',
      routePath: '/app/gift-cards',
      shop: owner(),
    });
    expect(await screen.findByText('Online sales paused')).toBeInTheDocument();
    expect(screen.queryByText('Selling online')).toBeNull();
    expect(screen.queryByRole('link', { name: /Online shop/ })).toBeNull();
    for (const button of screen.getAllByRole('button', { name: 'Issue gift card' })) {
      expect(button).toBeDisabled();
    }
    const notice = screen.getByRole('status', {
      name: 'Paused while the subscription is inactive',
    });
    expect(within(notice).getByRole('link', { name: 'Go to Billing' })).toBeInTheDocument();
  });

  it('gift cards: an active shop still shows "Selling online"', async () => {
    standing('active');
    setTableResult('gift_cards', { data: [], count: 0 });
    setTableResult('gift_card_settings', {
      data: { online_enabled: true, offers: [], allow_custom_amount: true, expires_months: null },
    });
    renderRoute(<GiftCardsPage />, {
      path: '/app/gift-cards',
      routePath: '/app/gift-cards',
      shop: owner(),
    });
    expect(await screen.findByText('Selling online')).toBeInTheDocument();
    expect(screen.queryByText('Online sales paused')).toBeNull();
  });

  it('memberships: online plans read as paused and the join page card is hidden', async () => {
    standing('lapsed');
    setTableResult('membership_plans', { data: [planRow({ online_joinable: true })] });
    renderRoute(<MembershipsPage />, {
      path: '/app/memberships?tab=plans',
      routePath: '/app/memberships',
      shop: owner(),
    });
    expect((await screen.findAllByText('Online paused')).length).toBeGreaterThan(0);
    expect(screen.queryByText('Online join page')).toBeNull();
    expect(screen.getByText(/the online join page lists no plans/)).toBeInTheDocument();
  });

  it('lead forms: an active form reads "Paused", not "Live"', async () => {
    standing('lapsed');
    setTableResult('lead_forms', {
      data: [
        {
          id: 'f1',
          token: 'tok-f1',
          name: 'Website',
          headline: null,
          intro: null,
          default_source: 'other',
          field_ids: [],
          ask_vehicle: true,
          ask_message: true,
          success_message: null,
          notify_staff: true,
          auto_reply: false,
          active: true,
          archived_at: null,
          created_at: '2026-01-01T00:00:00Z',
        },
      ],
    });
    setTableResult('lead_submissions', { data: null, count: 0 });
    setTableResult('custom_fields', { data: [] });
    renderSettings('/app/settings/lead-forms');
    expect(await screen.findByText('Paused')).toBeInTheDocument();
    expect(screen.queryByText('Live')).toBeNull();
    expect(
      screen.getByText(/Lead forms are off while this shop’s subscription is inactive/),
    ).toBeInTheDocument();
  });

  it('templates: says scheduled automatic messages have stopped', async () => {
    standing('lapsed');
    setTableResult('message_templates', { data: [] });
    renderSettings('/app/settings/templates');
    expect(
      await screen.findByText(/appointment reminders, review requests and follow-ups aren’t sent/),
    ).toBeInTheDocument();
  });
});

describe('lapsed shop: banner', () => {
  it('names what stopped, including lead forms, online sales and reminders', async () => {
    standing('lapsed');
    renderRoute(<BillingBanner />, { shop: owner() });
    const banner = await screen.findByRole('alert', { name: 'Subscription notice' });
    expect(banner).toHaveTextContent(/lead forms/);
    expect(banner).toHaveTextContent(/online gift card and membership sales/);
    expect(banner).toHaveTextContent(/automatic reminders and follow-ups are paused/);
  });
});
