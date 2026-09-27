import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { navigation } from '@/features/public-docs/shared/checkout';
import {
  edge,
  mockRpc,
  pgError,
  resetPublicMocks,
  type RpcCall,
} from '@/features/public-docs/shared/testing';
import BookingPage from './BookingPage';
import {
  catalogFixture,
  profileFixture,
  SEDAN,
  slotsFixture,
  TOKEN,
  WASH,
  WAX,
} from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/features/public-docs/shared/testSupabase'));

type User = ReturnType<typeof renderRoute>['user'];

const preview = {
  valid: false,
  message: 'this coupon code is not valid',
  code: '',
  kind: null,
  value: null,
  description: null,
  subtotal_cents: 19000,
  discount_cents: 0,
  tax_cents: 0,
  total_cents: 19000,
};

function setup(overrides: Record<string, unknown> = {}): { calls: RpcCall[]; user: User } {
  const calls = mockRpc({
    public_shop_profile: { data: profileFixture() },
    public_booking_catalog: { data: catalogFixture() },
    get_available_slots: { data: slotsFixture() },
    public_validate_coupon: (args) =>
      args.p_code === 'SPRING10'
        ? {
            data: {
              ...preview,
              valid: true,
              message: null,
              code: 'SPRING10',
              kind: 'percent',
              value: 1000,
              discount_cents: 1900,
              total_cents: 17100,
            },
          }
        : { data: preview },
    create_online_booking: {
      data: {
        job_token: TOKEN,
        job_number: 1042,
        status: 'requested',
        total_cents: 17100,
        deposit_required_cents: 3420,
      },
    },
    ...overrides,
  });
  const { user } = renderRoute(<BookingPage />, {
    path: '/book/glacier',
    routePath: '/book/:slug',
    shop: null,
  });
  return { calls, user };
}

async function completeVehicleAndServices(user: User) {
  await screen.findByRole('heading', { name: 'Tell us about your vehicle' });
  await user.click(screen.getByRole('radio', { name: 'Sedan' }));
  await user.type(screen.getByLabelText('Year'), '2021');
  await user.type(screen.getByLabelText(/^Make/), 'Toyota');
  await user.type(screen.getByLabelText(/^Model/), 'Camry');
  await user.click(screen.getByRole('button', { name: 'Continue' }));

  await screen.findByRole('heading', { name: 'Choose your services' });
  await user.click(screen.getByRole('checkbox', { name: /Full detail/ }));
  await user.click(screen.getByRole('checkbox', { name: /Hand wax/ }));
  await user.click(screen.getByRole('button', { name: 'Continue' }));
}

async function pickFirstTime(user: User) {
  await screen.findByRole('heading', { name: 'Pick a date and time' });
  const times = await screen.findAllByRole('button', { pressed: false, name: /AM|PM/ });
  await user.click(times[0]!);
  await user.click(screen.getByRole('button', { name: 'Continue' }));
}

async function fillDetails(user: User) {
  await screen.findByRole('heading', { name: 'Your details' });
  await user.type(screen.getByLabelText(/^First name/), 'Ana');
  await user.type(screen.getByRole('textbox', { name: /^Email/ }), 'ana@example.com');
}

beforeEach(() => {
  resetPublicMocks();
});

describe('BookingPage', () => {
  it('walks through the wizard and books with the server’s totals', async () => {
    const { calls, user } = setup();
    const assign = vi.spyOn(navigation, 'assign').mockImplementation(() => undefined);
    edge.invoke.mockResolvedValue({
      data: {
        url: 'https://checkout.stripe.com/c/pay/cs_test',
        expires_at: 1,
        amount_cents: 3420,
        tip_cents: 0,
        currency: 'usd',
      },
      error: null,
    });
    await completeVehicleAndServices(user);

    // prices for the chosen category (server catalog), shop time zone note
    await pickFirstTime(user);
    const slotCall = calls.find((c) => c.fn === 'get_available_slots');
    expect(slotCall?.args).toMatchObject({
      p_shop_slug: 'glacier',
      p_service_ids: [WASH, WAX],
      p_vehicle_category_id: SEDAN,
    });

    await fillDetails(user);
    await user.type(screen.getByLabelText('Coupon code'), 'SPRING10');
    await user.click(screen.getByRole('button', { name: 'Apply' }));
    expect(await screen.findByText(/SPRING10/)).toBeInTheDocument();
    expect(screen.getByText(/\$19\.00 off/)).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Continue' }));

    await screen.findByRole('heading', { name: 'Review and book' });
    expect(await screen.findByText('$171.00')).toBeInTheDocument();
    expect(screen.getByText(/deposit of 20% of the total/i)).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Request appointment' }));

    expect(await screen.findByRole('heading', { name: 'Request received' })).toBeInTheDocument();
    const create = calls.find((c) => c.fn === 'create_online_booking');
    expect(create?.args.p_slug).toBe('glacier');
    const payload = create?.args.p_payload as Record<string, unknown>;
    expect(payload).toMatchObject({
      service_ids: [WASH],
      addon_ids: [WAX],
      starts_at: slotsFixture()[0]?.starts_at,
      coupon_code: 'SPRING10',
      vehicle: { make: 'Toyota', model: 'Camry', year: 2021, category_id: SEDAN },
      customer: { first_name: 'Ana', email: 'ana@example.com' },
    });
    expect(JSON.stringify(payload)).not.toMatch(/price|total/);
    expect(screen.getByText('#1042')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'View or manage booking' })).toHaveAttribute(
      'href',
      `/booking/${TOKEN}`,
    );

    await user.click(screen.getByRole('button', { name: 'Pay $34.20 deposit' }));
    await waitFor(() =>
      expect(assign).toHaveBeenCalledWith('https://checkout.stripe.com/c/pay/cs_test'),
    );
    expect(edge.invoke).toHaveBeenCalledWith('payments', {
      body: expect.objectContaining({ action: 'booking_deposit_checkout', token: TOKEN }),
    });
  }, 20_000);

  it('sends the visitor back to pick another time when the slot was just taken', async () => {
    const { user } = setup({
      create_online_booking: pgError(
        '23P01',
        'that time is no longer available; please choose another time',
      ),
    });
    await completeVehicleAndServices(user);
    await pickFirstTime(user);
    await fillDetails(user);
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await screen.findByRole('heading', { name: 'Review and book' });
    await screen.findAllByText('$190.00');
    await user.click(screen.getByRole('button', { name: 'Request appointment' }));

    expect(
      await screen.findByRole('heading', { name: 'Pick a date and time' }),
    ).toBeInTheDocument();
    expect(screen.getByText(/that time was just booked by someone else/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Continue' })).toBeDisabled();
  });

  it('shows a server validation error on the step that can fix it', async () => {
    const { user } = setup({
      create_online_booking: pgError('22023', 'this address is outside our service area'),
    });
    await completeVehicleAndServices(user);
    await pickFirstTime(user);
    await fillDetails(user);
    await user.click(screen.getByRole('radio', { name: /At my location/ }));
    await user.type(screen.getByLabelText(/^Street address/), '1 Elm St');
    await user.type(screen.getByLabelText(/^City/), 'Far Away');
    await user.type(screen.getByLabelText(/^ZIP/), '99999');
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await screen.findAllByText('$190.00');
    await user.click(screen.getByRole('button', { name: 'Request appointment' }));
    expect(await screen.findByRole('heading', { name: 'Your details' })).toBeInTheDocument();
    expect(screen.getByText('This address is outside our service area.')).toBeInTheDocument();
  });

  it('validates required vehicle fields before continuing', async () => {
    const { user } = setup();
    await screen.findByRole('heading', { name: 'Tell us about your vehicle' });
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    expect(screen.getByText('Choose your vehicle type.')).toBeInTheDocument();
    expect(screen.getByText('Make is required.')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Tell us about your vehicle' })).toBeInTheDocument();
  });

  it('shows a friendly closed state when online booking is off', async () => {
    setup({
      public_shop_profile: {
        data: profileFixture({ booking: { ...profileFixture().booking, enabled: false } }),
      },
    });
    expect(await screen.findByText('Online booking is closed right now')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Call \(205\) 555-0100/ })).toHaveAttribute(
      'href',
      'tel:+12055550100',
    );
  });

  it('explains an unknown booking link', async () => {
    setup({ public_shop_profile: pgError('P0002', 'shop not found') });
    expect(await screen.findByText('We couldn’t find this booking page')).toBeInTheDocument();
  });

  it('lists services for the chosen vehicle type with server prices', async () => {
    const { user } = setup();
    await screen.findByRole('heading', { name: 'Tell us about your vehicle' });
    await user.click(screen.getByRole('radio', { name: 'Truck' }));
    await user.type(screen.getByLabelText(/^Make/), 'Ford');
    await user.type(screen.getByLabelText(/^Model/), 'F-150');
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await screen.findByRole('heading', { name: 'Choose your services' });
    const detail = screen.getByRole('checkbox', { name: /Full detail/ });
    expect(detail.closest('label')).toHaveTextContent('$200.00');
    const coating = screen.getByRole('checkbox', { name: /Ceramic coating/ });
    expect(coating).toBeDisabled();
    expect(
      within(coating.closest('label')!).getByText('Not available for Truck'),
    ).toBeInTheDocument();
  });
});
