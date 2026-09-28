import { screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { mockRpc, pgError, resetSupabaseMock, supabase } from '@/test/supabaseMock';
import { navigation } from '@/features/public-docs/shared/checkout';
import JoinPage from './JoinPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const plans = {
  shop: { name: 'Glacier Detailing', logo_path: null, brand_color: null },
  plans: [
    {
      id: 'plan-1',
      name: 'Wash Club',
      description: 'Keep it clean.',
      price_cents: 2500,
      interval: 'week',
      interval_count: 2,
      included_services: ['Maintenance wash'],
      discount_bps: 1000,
      uses_per_period: 1,
      vehicle_scoped: false,
      terms: 'Cancel any time before your next billing date.',
    },
  ],
  currency: 'usd',
};

function render(path = '/join/glacier') {
  return renderRoute(<JoinPage />, { path, routePath: '/join/:slug', shop: null });
}

beforeEach(() => {
  resetSupabaseMock();
  supabase.functions.invoke.mockReset();
});

describe('JoinPage', () => {
  it('lists online plans and starts the subscription checkout', async () => {
    const assign = vi.spyOn(navigation, 'assign').mockImplementation(() => {});
    const calls = mockRpc({ public_membership_plans: { data: plans } });
    supabase.functions.invoke.mockResolvedValueOnce({
      data: {
        url: 'https://checkout.stripe.com/c/pay/cs_test_m',
        expires_at: 1790000000,
        amount_cents: 2500,
        interval: 'week',
        interval_count: 2,
        currency: 'usd',
      },
      error: null,
    });
    const { user } = render();
    expect(await screen.findByText('$25.00 every 2 weeks')).toBeInTheDocument();
    expect(calls[0]).toEqual({ fn: 'public_membership_plans', args: { p_slug: 'glacier' } });
    expect(screen.getByText(/1 visit per billing period/)).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Choose Wash Club' }));
    await user.type(screen.getByLabelText(/^First name/), 'Ana');
    await user.type(screen.getByRole('textbox', { name: 'Email' }), 'Ana@Example.com');
    await user.click(screen.getByRole('button', { name: 'Continue to payment' }));
    expect(screen.getByText('Accept the membership terms to continue.')).toBeInTheDocument();
    await user.click(screen.getByRole('checkbox', { name: 'I accept the membership terms' }));
    await user.click(screen.getByRole('button', { name: 'Continue to payment' }));
    await waitFor(() =>
      expect(supabase.functions.invoke).toHaveBeenCalledWith('payments', {
        body: {
          action: 'membership_join_checkout',
          slug: 'glacier',
          plan_id: 'plan-1',
          customer: {
            first_name: 'Ana',
            email: 'ana@example.com',
            sms_opt_in: false,
            email_opt_in: false,
          },
          request_nonce: expect.any(String),
        },
      }),
    );
    expect(assign).toHaveBeenCalledWith('https://checkout.stripe.com/c/pay/cs_test_m');
  });

  it('thanks the customer after checkout', async () => {
    mockRpc({ public_membership_plans: { data: plans } });
    render('/join/glacier?joined=1');
    expect(await screen.findByText('Welcome aboard!')).toBeInTheDocument();
  });

  it('shows a calm message for an unknown shop', async () => {
    mockRpc({ public_membership_plans: pgError('PT404', 'shop not found') });
    render('/join/nope');
    expect(await screen.findByText('We couldn’t find this page')).toBeInTheDocument();
  });
});
