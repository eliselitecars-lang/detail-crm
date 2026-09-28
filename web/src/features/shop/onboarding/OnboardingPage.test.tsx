import { screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute, shopValue, signedInAuth } from '@/test/render';
import {
  builders,
  mockRpc,
  pgError,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import OnboardingPage from './OnboardingPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

function setup() {
  const switchShop = vi.fn();
  const utils = renderRoute(<OnboardingPage />, {
    routePath: '/app/onboarding',
    path: '/app/onboarding',
    auth: signedInAuth('owner@example.com', 'user-1'),
    shop: shopValue({ membership: null, switchShop }),
    routes: [{ path: '/app', element: <p>Dashboard home</p> }],
  });
  return { ...utils, switchShop };
}

describe('OnboardingPage', () => {
  it('validates each step before moving on', async () => {
    const { user } = setup();
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    expect(await screen.findByText('Shop name is required.')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Your business' })).toBeInTheDocument();
  });

  it('suggests a booking link from the name and blocks reserved links', async () => {
    const { user } = setup();
    await user.type(screen.getByLabelText(/Shop name/), 'App');
    expect(screen.getByLabelText(/Booking link/)).toHaveValue('app');
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    expect(await screen.findByText('That link is reserved. Try another.')).toBeInTheDocument();
  });

  it('creates the shop, saves details and hours, then opens the dashboard', async () => {
    const calls = mockRpc({
      create_shop: { data: { id: 'shop-new', name: 'Glacier Detailing' } },
      replace_business_hours: { data: [] },
    });
    const { user, switchShop } = setup();

    await user.type(screen.getByLabelText(/Shop name/), 'Glacier Detailing');
    expect(screen.getByLabelText(/Booking link/)).toHaveValue('glacier-detailing');
    await user.click(screen.getByRole('radio', { name: /Mobile/ }));
    await user.click(screen.getByRole('button', { name: 'Continue' }));

    expect(await screen.findByRole('heading', { name: 'Contact & location' })).toBeInTheDocument();
    await user.selectOptions(screen.getByLabelText(/Time zone/), 'America/Chicago');
    await user.type(screen.getByLabelText(/Business phone/), '2055550123');
    expect(screen.getByLabelText(/Business phone/)).toHaveValue('(205) 555-0123');
    await user.type(screen.getByLabelText(/City/), 'Birmingham');
    await user.click(screen.getByRole('button', { name: 'Continue' }));

    expect(await screen.findByRole('heading', { name: 'Taxes & hours' })).toBeInTheDocument();
    const tax = screen.getByLabelText(/Sales tax rate/);
    await user.clear(tax);
    await user.type(tax, '8.25');
    await user.click(screen.getByRole('switch', { name: 'Open on Saturday' }));
    await user.click(screen.getByRole('button', { name: 'Create shop' }));

    expect(await screen.findByText('Dashboard home')).toBeInTheDocument();
    expect(supabase.rpc).toHaveBeenCalledWith('create_shop', {
      p_name: 'Glacier Detailing',
      p_slug: 'glacier-detailing',
      p_timezone: 'America/Chicago',
      p_business_type: 'mobile',
      p_email: 'owner@example.com',
      p_phone: '+12055550123',
    });
    const shopUpdate = builders.shops?.[0];
    expect(shopUpdate?.update).toHaveBeenCalledWith(
      expect.objectContaining({ city: 'Birmingham', tax_rate_bps: 825, address_line1: null }),
    );
    expect(shopUpdate?.eq).toHaveBeenCalledWith('id', 'shop-new');
    // Hours are replaced atomically by the RPC (no direct table writes).
    expect(builders.business_hours).toBeUndefined();
    const hours = calls.find((c) => c.fn === 'replace_business_hours');
    expect(hours?.args.p_shop_id).toBe('shop-new');
    expect(hours?.args.p_rows).toEqual(
      expect.arrayContaining([
        { weekday: 1, opens_at: '08:00', closes_at: '17:00' },
        { weekday: 6, opens_at: '08:00', closes_at: '17:00' },
      ]),
    );
    expect(hours?.args.p_rows).toHaveLength(6);
    expect(switchShop).toHaveBeenCalledWith('shop-new');
  });

  it('links the pricing page and tells the owner how long their trial runs when billing is on', async () => {
    const trialEnd = new Date(Date.now() + 14 * 24 * 3600 * 1000).toISOString();
    const calls = mockRpc({
      public_billing_plans: {
        data: [
          {
            id: 'plan-1',
            name: 'Solo',
            description: null,
            amount_cents: 4900,
            currency: 'usd',
            interval: 'month',
            interval_count: 1,
            max_members: 1,
            features: [],
          },
        ],
      },
      create_shop: { data: { id: 'shop-new', name: 'Glacier Detailing' } },
      replace_business_hours: { data: [] },
      shop_entitlement: {
        data: {
          billing_enabled: true,
          state: 'trialing',
          reason: 'trial',
          plan_name: null,
          trial_ends_at: trialEnd,
          current_period_end: null,
          cancel_at_period_end: false,
          max_members: null,
          members_used: 1,
          can_write: true,
          is_owner: true,
        },
      },
    });
    const { user } = setup();
    expect(await screen.findByRole('link', { name: 'pricing page' })).toHaveAttribute(
      'href',
      '/pricing',
    );
    await user.type(screen.getByLabelText(/Shop name/), 'Glacier Detailing');
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await screen.findByRole('heading', { name: 'Contact & location' });
    await user.selectOptions(screen.getByLabelText(/Time zone/), 'America/Chicago');
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await screen.findByRole('heading', { name: 'Taxes & hours' });
    await user.click(screen.getByRole('button', { name: 'Create shop' }));
    expect(await screen.findByText('Dashboard home')).toBeInTheDocument();
    expect(calls).toContainEqual({ fn: 'shop_entitlement', args: { p_shop_id: 'shop-new' } });
    expect(
      await screen.findByText(/Your free trial runs until .* \(14 days\)\./),
    ).toBeInTheDocument();
  });

  it('shows no pricing link or trial while billing is off', async () => {
    mockRpc({ public_billing_plans: { data: [] } });
    setup();
    await screen.findByRole('heading', { name: 'Your business' });
    await waitFor(() =>
      expect(
        (supabase.rpc.mock.calls as unknown[][]).some((call) => call[0] === 'public_billing_plans'),
      ).toBe(true),
    );
    expect(screen.queryByRole('link', { name: 'pricing page' })).toBeNull();
  });

  it('sends the user back to step 1 when the booking link is taken', async () => {
    mockRpc({ create_shop: pgError('23505', 'slug "glacier" is already taken') });
    const { user } = setup();
    await user.type(screen.getByLabelText(/Shop name/), 'Glacier');
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await user.click(await screen.findByRole('button', { name: 'Continue' }));
    await user.click(await screen.findByRole('button', { name: 'Create shop' }));
    await waitFor(() =>
      expect(screen.getByText('That booking link is taken. Try another.')).toBeInTheDocument(),
    );
    expect(screen.getByRole('heading', { name: 'Your business' })).toBeInTheDocument();
  });

  async function failAfterCreate() {
    let hoursFail = true;
    const calls = mockRpc({
      create_shop: { data: { id: 'shop-new' } },
      replace_business_hours: () =>
        hoursFail
          ? pgError('42501', 'only owners and admins can change business hours')
          : { data: [] },
    });
    const utils = setup();
    const { user } = utils;
    await user.type(screen.getByLabelText(/Shop name/), 'Glacier Detailing');
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await user.selectOptions(await screen.findByLabelText(/Time zone/), 'America/Chicago');
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await user.click(await screen.findByRole('button', { name: 'Create shop' }));
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Your shop was created, but some settings didn’t save',
    );
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument();
    hoursFail = false;
    const created = () => calls.filter((c) => c.fn === 'create_shop').length;
    return { ...utils, created };
  }

  it('saves edits made after a partial failure when retrying', async () => {
    const { user, switchShop, created } = await failAfterCreate();

    await user.click(screen.getByRole('button', { name: 'Back' }));
    await user.selectOptions(await screen.findByLabelText(/Time zone/), 'America/Denver');
    await user.click(screen.getByRole('button', { name: 'Back' }));
    const name = await screen.findByLabelText(/Shop name/);
    await user.clear(name);
    await user.type(name, 'Glacier Mobile');
    await user.click(screen.getByRole('radio', { name: /Both/ }));
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await user.click(await screen.findByRole('button', { name: 'Continue' }));
    await user.click(await screen.findByRole('button', { name: 'Try again' }));

    expect(await screen.findByText('Dashboard home')).toBeInTheDocument();
    expect(created()).toBe(1); // the shop is not created twice
    const retryUpdate = builders.shops?.at(-1);
    expect(retryUpdate?.update).toHaveBeenCalledWith(
      expect.objectContaining({
        name: 'Glacier Mobile',
        slug: 'glacier-mobile', // still auto-derived from the (edited) name
        timezone: 'America/Denver',
        business_type: 'both',
      }),
    );
    expect(retryUpdate?.eq).toHaveBeenCalledWith('id', 'shop-new');
    expect(switchShop).toHaveBeenCalledWith('shop-new');
  });

  it('shows a taken booking link on step 1 when a retry changes it', async () => {
    const { user, created } = await failAfterCreate();
    setTableResult('shops', {
      error: {
        code: '23505',
        message: 'duplicate key value violates unique constraint "shops_slug_key"',
        details: 'Key (slug)=(apex) already exists.',
        hint: null,
      },
    });
    await user.click(screen.getByRole('button', { name: 'Back' }));
    await user.click(await screen.findByRole('button', { name: 'Back' }));
    const slug = await screen.findByLabelText(/Booking link/);
    await user.clear(slug);
    await user.type(slug, 'apex');
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await user.click(await screen.findByRole('button', { name: 'Continue' }));
    await user.click(await screen.findByRole('button', { name: 'Try again' }));

    expect(await screen.findByText('That booking link is taken. Try another.')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Your business' })).toBeInTheDocument();
    expect(created()).toBe(1);
  });
});
