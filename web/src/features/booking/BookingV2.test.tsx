import { screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { QueryClient } from '@tanstack/react-query';
import { useLayoutEffect, type ReactNode } from 'react';
import { useLocation } from 'react-router';
import { createTestQueryClient, renderRoute } from '@/test/render';
import { mockRpc, pgError, resetSupabaseMock, type RpcCall } from '@/test/supabaseMock';
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
import { bookingKeys, shopProfileSchema } from './api';
import { EMBED_SCROLL_TOP_MESSAGE } from './embed';
import { resetTrackingForTests } from './tracking';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

type User = ReturnType<typeof renderRoute>['user'];

const LINK = '99999999-9999-4999-8999-999999999999';

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

const created = {
  data: {
    job_token: TOKEN,
    job_number: 1042,
    status: 'requested',
    total_cents: 19000,
    deposit_required_cents: 3800,
  },
};

function setup(
  path: string,
  overrides: Record<string, unknown> = {},
  queryClient: QueryClient = createTestQueryClient(),
  extra: ReactNode = null,
) {
  const calls: RpcCall[] = mockRpc({
    public_shop_profile: { data: profileFixture() },
    public_booking_catalog: { data: catalogFixture() },
    public_booking_questions: { data: [] },
    public_booking_slots: { data: slotsFixture() },
    public_validate_coupon: (args) =>
      args.p_code === 'FRIEND-7K2'
        ? {
            data: {
              ...preview,
              valid: true,
              message: null,
              code: 'FRIEND-7K2',
              kind: 'fixed',
              value: 2000,
              discount_cents: 2000,
              total_cents: 17000,
            },
          }
        : { data: preview },
    create_online_booking: created,
    ...overrides,
  });
  const { user, router } = renderRoute(
    <>
      <BookingPage />
      {extra}
    </>,
    {
      path,
      routePath: '/book/:slug',
      shop: null,
      queryClient,
    },
  );
  return { calls, user, router };
}

/**
 * Clicks a link and tells whether the browser would load a new document
 * (the router did not take the click). jsdom cannot load it, so the default
 * action is prevented after the router had its turn.
 */
async function clickLeavesDocument(link: HTMLElement): Promise<boolean> {
  let prevented: boolean | null = null;
  const record = (event: Event) => {
    prevented = event.defaultPrevented;
    event.preventDefault();
  };
  window.addEventListener('click', record);
  try {
    link.click();
    await Promise.resolve();
  } finally {
    window.removeEventListener('click', record);
  }
  return prevented === false;
}

async function vehicle(user: User, pickSize = true) {
  await screen.findByRole('heading', { name: 'Tell us about your vehicle' });
  if (pickSize) await user.click(screen.getByRole('radio', { name: 'Sedan' }));
  await user.type(screen.getByLabelText(/^Make/), 'Toyota');
  await user.type(screen.getByLabelText(/^Model/), 'Camry');
  await user.click(screen.getByRole('button', { name: 'Continue' }));
}

async function pickTime(user: User) {
  await screen.findByRole('heading', { name: 'Pick a date and time' });
  const times = await screen.findAllByRole('button', { pressed: false, name: /AM|PM/ });
  await user.click(times[0]!);
  await user.click(screen.getByRole('button', { name: 'Continue' }));
}

async function details(user: User) {
  await screen.findByRole('heading', { name: 'Your details' });
  await user.type(screen.getByLabelText(/^First name/), 'Ana');
  await user.type(screen.getByRole('textbox', { name: /^Email/ }), 'ana@example.com');
}

beforeEach(() => {
  resetSupabaseMock();
  resetTrackingForTests();
});

afterEach(() => {
  document.head.querySelectorAll('script[src^="https://"]').forEach((s) => s.remove());
  const w = window as Window & { fbq?: unknown; gtag?: unknown; dataLayer?: unknown };
  delete w.fbq;
  delete w.gtag;
  delete w.dataLayer;
});

describe('booking links into the wizard', () => {
  it('preselects the size and services, applies the referral code and cleans the URL', async () => {
    const { user, calls, router } = setup(
      `/book/glacier?services=${WASH},${WAX},not-a-uuid&category=${SEDAN}&coupon=FRIEND-7K2`,
    );
    await screen.findByRole('heading', { name: 'Tell us about your vehicle' });
    await waitFor(() => expect(router.state.location.search).toBe(''));
    expect(screen.getByRole('radio', { name: 'Sedan' })).toBeChecked();
    await vehicle(user, false);
    await screen.findByRole('heading', { name: 'Choose your services' });
    expect(screen.getByRole('checkbox', { name: /Full detail/ })).toBeChecked();
    expect(screen.getByRole('checkbox', { name: /Hand wax/ })).toBeChecked();
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await pickTime(user);
    await details(user);
    expect(await screen.findByText(/Code/)).toHaveTextContent('FRIEND-7K2');
    expect(screen.getByText(/\$20\.00 off/)).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await screen.findByRole('heading', { name: 'Review and book' });
    await user.click(await screen.findByRole('button', { name: 'Request appointment' }));
    await screen.findByRole('heading', { name: 'Request received' });
    const payload = calls.find((c) => c.fn === 'create_online_booking')?.args.p_payload;
    expect(payload).toMatchObject({ coupon_code: 'FRIEND-7K2', service_ids: [WASH] });
    // Without tags, the manage link stays in the app.
    await user.click(screen.getByRole('link', { name: 'View or manage booking' }));
    expect(router.state.location.pathname).toBe(`/booking/${TOKEN}`);
  }, 20_000);

  it('keeps a referral code from the link in the input when it can’t be checked', async () => {
    let attempts = 0;
    const { user } = setup(`/book/glacier?services=${WASH}&category=${SEDAN}&coupon=FRIEND-7K2`, {
      public_validate_coupon: (args: Record<string, unknown>) => {
        attempts += 1;
        if (attempts === 1) return pgError('PT429', 'too many coupon checks; try again shortly');
        return args.p_code === 'FRIEND-7K2'
          ? {
              data: {
                ...preview,
                valid: true,
                message: null,
                code: 'FRIEND-7K2',
                kind: 'fixed',
                value: 2000,
                discount_cents: 2000,
                total_cents: 17000,
              },
            }
          : { data: preview };
      },
    });
    await vehicle(user, false);
    await screen.findByRole('heading', { name: 'Choose your services' });
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await pickTime(user);
    await screen.findByRole('heading', { name: 'Your details' });
    expect(
      await screen.findByText(/We couldn’t check code FRIEND-7K2: .*Tap Apply to try again\./),
    ).toBeInTheDocument();
    const input = screen.getByRole('textbox', { name: 'Coupon code' });
    expect(input).toHaveValue('FRIEND-7K2');
    expect(input).toBeEnabled();
    await user.click(screen.getByRole('button', { name: 'Apply' }));
    expect(await screen.findByText(/\$20\.00 off/)).toBeInTheDocument();
    expect(attempts).toBeGreaterThanOrEqual(2);
  }, 20_000);

  it('shows a rejected referral code in the input with the reason', async () => {
    const { user } = setup(`/book/glacier?services=${WASH}&category=${SEDAN}&coupon=OLD-CODE`);
    await vehicle(user, false);
    await screen.findByRole('heading', { name: 'Choose your services' });
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await pickTime(user);
    await screen.findByRole('heading', { name: 'Your details' });
    expect(
      await screen.findByText('Code OLD-CODE can’t be used: This coupon code is not valid.'),
    ).toBeInTheDocument();
    expect(screen.getByRole('textbox', { name: 'Coupon code' })).toHaveValue('OLD-CODE');
  }, 20_000);

  it('books through a private link: its catalog, its token on slots and the booking', async () => {
    const { user, calls } = setup(`/book/glacier?link=${LINK}`, {
      public_booking_link: {
        data: {
          slug: 'glacier',
          name: 'Fleet wash for Acme',
          note: 'Book any weekday.',
          expires_at: null,
          catalog: catalogFixture(),
        },
      },
    });
    expect(await screen.findByRole('heading', { name: 'Fleet wash for Acme' })).toBeInTheDocument();
    expect(screen.getByText('Book any weekday.')).toBeInTheDocument();
    expect(calls.some((c) => c.fn === 'public_booking_catalog')).toBe(false);
    await vehicle(user);
    await screen.findByRole('heading', { name: 'Choose your services' });
    await user.click(screen.getByRole('checkbox', { name: /Full detail/ }));
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await pickTime(user);
    expect(calls.find((c) => c.fn === 'public_booking_slots')?.args).toMatchObject({
      p_link_token: LINK,
    });
    await details(user);
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await screen.findByRole('heading', { name: 'Review and book' });
    await user.click(await screen.findByRole('button', { name: 'Request appointment' }));
    await screen.findByRole('heading', { name: 'Request received' });
    expect(calls.find((c) => c.fn === 'create_online_booking')?.args.p_payload).toMatchObject({
      link_token: LINK,
    });
    expect(calls.find((c) => c.fn === 'public_validate_coupon')?.args).toMatchObject({
      p_link_token: LINK,
      p_location_type: 'shop',
    });
  }, 20_000);

  it('explains a private link that no longer works', async () => {
    setup(`/book/glacier?link=${LINK}`, {
      public_booking_link: pgError('PT404', 'booking link not found'),
    });
    expect(await screen.findByText('This booking link is no longer available')).toBeInTheDocument();
    const all = screen.getByRole('link', { name: 'See all services' });
    expect(all).toHaveAttribute('href', '/book/glacier');
    // A new document without a referrer: the booking page's tags never see ?link=.
    expect(all).toHaveAttribute('rel', 'noreferrer');
    expect(await clickLeavesDocument(all)).toBe(true);
  });
});

describe('booking questions and availability', () => {
  it('asks the questions for the chosen location and sends valid answers', async () => {
    const { user, calls } = setup('/book/glacier', {
      public_booking_questions: {
        data: [
          {
            key: 'gate_code',
            label: 'Gate code',
            type: 'text',
            options: [],
            help_text: null,
            required: true,
            location_scope: 'mobile',
          },
          {
            key: 'pets',
            label: 'Pets in the car?',
            type: 'select',
            options: ['None', 'Dog', 'Cat'],
            help_text: null,
            required: false,
            location_scope: null,
          },
        ],
      },
    });
    await vehicle(user);
    await screen.findByRole('heading', { name: 'Choose your services' });
    await user.click(screen.getByRole('checkbox', { name: /Full detail/ }));
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await screen.findByRole('heading', { name: 'Pick a date and time' });
    await user.click(screen.getByRole('radio', { name: /At my location/ }));
    await waitFor(() =>
      expect(
        calls.some((c) => c.fn === 'public_booking_slots' && c.args.p_location_type === 'mobile'),
      ).toBe(true),
    );
    await pickTime(user);
    await details(user);
    await user.type(screen.getByLabelText(/^Street address/), '1 Elm St');
    await user.type(screen.getByLabelText(/^City/), 'Birmingham');
    await user.type(screen.getByLabelText(/^ZIP/), '35203');
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    expect(await screen.findByText('Gate code is required')).toBeInTheDocument();
    await user.type(screen.getByLabelText(/^Gate code/), '#4521');
    await user.selectOptions(screen.getByLabelText(/Pets in the car/), 'Dog');
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await screen.findByRole('heading', { name: 'Review and book' });
    await user.click(await screen.findByRole('button', { name: 'Request appointment' }));
    await screen.findByRole('heading', { name: 'Request received' });
    expect(calls.find((c) => c.fn === 'create_online_booking')?.args.p_payload).toMatchObject({
      answers: { gate_code: '#4521', pets: 'Dog' },
      location: { type: 'mobile' },
    });
  }, 20_000);

  it('says which days a category can be booked online', async () => {
    const catalog = catalogFixture();
    catalog.service_categories = [{ id: 'sc-1', name: 'Detailing', bookable_weekdays: [1, 3] }];
    const { user } = setup('/book/glacier', { public_booking_catalog: { data: catalog } });
    await vehicle(user);
    await screen.findByRole('heading', { name: 'Choose your services' });
    await user.click(screen.getByRole('checkbox', { name: /Full detail/ }));
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    expect(
      await screen.findByText('Detailing can be booked online on Mondays and Wednesdays.'),
    ).toBeInTheDocument();
  });
});

describe('embed mode and tracking', () => {
  it('renders without the page chrome and leaves the frame for the booking page', async () => {
    const { user } = setup('/book/glacier?embed=1');
    await vehicle(user);
    await screen.findByRole('heading', { name: 'Choose your services' });
    // No PublicLayout header / banner.
    expect(screen.queryByRole('banner')).not.toBeInTheDocument();
    await user.click(screen.getByRole('checkbox', { name: /Full detail/ }));
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await pickTime(user);
    await details(user);
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await screen.findByRole('heading', { name: 'Review and book' });
    await user.click(await screen.findByRole('button', { name: 'Request appointment' }));
    await screen.findByRole('heading', { name: 'Request received' });
    const pay = screen.getByRole('link', { name: /Pay \$38\.00 deposit/ });
    expect(pay).toHaveAttribute('href', `/booking/${TOKEN}`);
    expect(pay).toHaveAttribute('target', '_top');
    expect(screen.queryByRole('button', { name: /deposit/ })).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Privacy Policy' })).toHaveAttribute(
      'target',
      '_blank',
    );
  }, 20_000);

  it('loads the shop’s tags only when they are set, never on private links', async () => {
    setup('/book/glacier', {
      public_shop_profile: {
        data: profileFixture({
          tracking: { meta_pixel_id: '1234567890', ga4_measurement_id: 'G-ABC123' },
        }),
      },
    });
    await screen.findByRole('heading', { name: 'Tell us about your vehicle' });
    await waitFor(() =>
      expect(
        document.head.querySelector('script[src="https://connect.facebook.net/en_US/fbevents.js"]'),
      ).not.toBeNull(),
    );
    expect(
      document.head.querySelector('script[src^="https://www.googletagmanager.com/gtag/js"]'),
    ).not.toBeNull();
    const w = window as Window & { fbq?: { queue?: unknown[] }; dataLayer?: unknown[] };
    expect(w.fbq?.queue).toContainEqual(['track', 'PageView']);
    const events = (w.dataLayer ?? []).map((a) => Array.from(a as ArrayLike<unknown>));
    const config = events.find((e) => e[0] === 'config');
    expect(config?.[2]).toMatchObject({ send_page_view: false });
    expect(JSON.stringify(events)).not.toMatch(/\?/);
  });

  it('stops the tags when the booking page is left inside the document', async () => {
    const { router } = setup('/book/glacier', {
      public_shop_profile: {
        data: profileFixture({
          tracking: { meta_pixel_id: '1234567890', ga4_measurement_id: 'G-ABC123' },
        }),
      },
    });
    await screen.findByRole('heading', { name: 'Tell us about your vehicle' });
    // While a tag is on, the footer's legal links are full page loads too.
    expect(await clickLeavesDocument(screen.getByRole('link', { name: 'Privacy Policy' }))).toBe(
      true,
    );
    const w = window as unknown as { fbq?: { queue?: unknown[] } } & Record<string, unknown>;
    expect(w['ga-disable-G-ABC123']).toBeUndefined();
    await router.navigate('/somewhere-else');
    await waitFor(() => expect(w['ga-disable-G-ABC123']).toBe(true));
    expect(w.fbq?.queue).toContainEqual(['consent', 'revoke']);
  });

  it('loads the tags only after the coupon code has left the address bar', async () => {
    // The address bar as the router sees it, updated before any page effect runs.
    let search = 'unset';
    function AddressBar() {
      const location = useLocation();
      useLayoutEffect(() => {
        search = location.search;
      }, [location.search]);
      return null;
    }
    const seen: { args: unknown[]; search: string }[] = [];
    // A preloaded fbq (as fbevents.js leaves it) records the URL at each call.
    (window as unknown as { fbq: unknown }).fbq = (...args: unknown[]) =>
      seen.push({ args, search });
    // The shop profile is already cached, so the wizard mounts in the first
    // render, before the page has taken the coupon off the URL.
    const profile = profileFixture({
      tracking: { meta_pixel_id: '1234567890', ga4_measurement_id: null },
    });
    const queryClient = createTestQueryClient();
    queryClient.setQueryData(bookingKeys.profile('glacier'), shopProfileSchema.parse(profile));
    setup(
      '/book/glacier?coupon=FRIEND-7K2',
      { public_shop_profile: { data: profile } },
      queryClient,
      <AddressBar />,
    );
    await screen.findByRole('heading', { name: 'Tell us about your vehicle' });
    await waitFor(() => expect(seen.some((c) => c.args[0] === 'init')).toBe(true));
    for (const call of seen) expect(call.search).toBe('');
    expect(seen).toContainEqual({ args: ['track', 'PageView'], search: '' });
  });

  it('keeps the legal links in the app when no tag is loaded', async () => {
    setup('/book/glacier');
    await screen.findByRole('heading', { name: 'Tell us about your vehicle' });
    expect(await clickLeavesDocument(screen.getByRole('link', { name: 'Privacy Policy' }))).toBe(
      false,
    );
  });

  it('does not load tags without ids', async () => {
    setup('/book/glacier');
    await screen.findByRole('heading', { name: 'Tell us about your vehicle' });
    expect(document.head.querySelector('script[src^="https://"]')).toBeNull();
    expect(within(document.body).queryByText(/pixel/i)).not.toBeInTheDocument();
  });

  it('leaves the document for the booking link while the tags are loaded', async () => {
    const { user, router } = setup('/book/glacier', {
      public_shop_profile: {
        data: profileFixture({
          tracking: { meta_pixel_id: '1234567890', ga4_measurement_id: 'G-ABC123' },
        }),
      },
    });
    await vehicle(user);
    await screen.findByRole('heading', { name: 'Choose your services' });
    await user.click(screen.getByRole('checkbox', { name: /Full detail/ }));
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await pickTime(user);
    await details(user);
    await user.click(screen.getByRole('button', { name: 'Continue' }));
    await screen.findByRole('heading', { name: 'Review and book' });
    await user.click(await screen.findByRole('button', { name: 'Request appointment' }));
    await screen.findByRole('heading', { name: 'Request received' });
    const manage = screen.getByRole('link', { name: 'View or manage booking' });
    expect(manage).toHaveAttribute('href', `/booking/${TOKEN}`);
    // A plain link: the router never pushes the token URL into this document
    // (where the tags' history listeners would report it).
    let prevented: boolean | null = null;
    const record = (event: Event) => {
      prevented = event.defaultPrevented;
      event.preventDefault(); // jsdom cannot load another document
    };
    window.addEventListener('click', record);
    try {
      await user.click(manage);
    } finally {
      window.removeEventListener('click', record);
    }
    expect(prevented).toBe(false);
    expect(router.state.location.pathname).toBe('/book/glacier');
  }, 20_000);

  it('asks the embedding page to show the frame’s top on each step change', async () => {
    vi.spyOn(window, 'top', 'get').mockReturnValue({} as Window);
    const post = vi.spyOn(window.parent, 'postMessage');
    try {
      const { user } = setup('/book/glacier?embed=1');
      await vehicle(user);
      await screen.findByRole('heading', { name: 'Choose your services' });
      expect(post).toHaveBeenCalledWith({ type: EMBED_SCROLL_TOP_MESSAGE }, '*');
    } finally {
      vi.restoreAllMocks();
    }
  });
});
