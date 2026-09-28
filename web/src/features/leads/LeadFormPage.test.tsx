import { screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { mockRpc, pgError, resetSupabaseMock, supabase } from '@/test/supabaseMock';
import LeadFormPage from './LeadFormPage';
import { buildLeadPayload, EMPTY_LEAD, leadSubmitErrorBanner, validateLead } from './model';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const TOKEN = 'abababab-abab-4bab-8bab-abababababab';

const form = {
  shop: { name: 'Glacier Detailing', logo_path: null, brand_color: '#1F6FEB' },
  form: {
    name: 'Coating quote request',
    headline: 'Get a ceramic coating quote',
    intro: 'Tell us about your car and we’ll be in touch.',
    ask_vehicle: true,
    ask_message: true,
    success_message: null,
  },
  fields: [
    {
      key: 'budget',
      label: 'Budget',
      type: 'select',
      options: ['Under $1,000', '$1,000+'],
      help_text: null,
      required: true,
    },
  ],
};

function render(path = `/lead/${TOKEN}`) {
  return renderRoute(<LeadFormPage />, { path, routePath: '/lead/:token', shop: null });
}

beforeEach(() => {
  resetSupabaseMock();
});

describe('LeadFormPage', () => {
  it('validates, then sends only what was asked and shows the thank-you', async () => {
    const calls = mockRpc({
      public_get_lead_form: { data: form },
      public_submit_lead: { data: { ok: true, message: 'Thanks! We will call you today.' } },
    });
    const { user } = render();
    expect(
      await screen.findByRole('heading', { name: 'Get a ceramic coating quote', level: 1 }),
    ).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Send' }));
    expect(screen.getByText('First name is required.')).toBeInTheDocument();
    expect(screen.getByText('Enter an email address or a phone number.')).toBeInTheDocument();
    expect(screen.getByText('Budget is required')).toBeInTheDocument();
    expect(calls.some((c) => c.fn === 'public_submit_lead')).toBe(false);

    await user.type(screen.getByLabelText(/^First name/), 'Ana');
    await user.type(screen.getByRole('textbox', { name: /^Email/ }), 'ANA@Example.com');
    await user.type(screen.getByLabelText('Make'), 'Tesla');
    await user.selectOptions(screen.getByLabelText(/^Budget/), '$1,000+');
    await user.type(screen.getByLabelText('Message'), 'Model 3, white');
    await user.click(screen.getByRole('checkbox', { name: 'Email me news and offers' }));
    await user.click(screen.getByRole('button', { name: 'Send' }));

    expect(await screen.findByRole('heading', { name: 'Thank you!' })).toBeInTheDocument();
    expect(screen.getByText('Thanks! We will call you today.')).toBeInTheDocument();
    const call = calls.find((c) => c.fn === 'public_submit_lead');
    expect(call?.args).toEqual({
      p_token: TOKEN,
      p_payload: {
        first_name: 'Ana',
        last_name: null,
        email: 'ana@example.com',
        phone: null,
        sms_opt_in: false,
        email_opt_in: true,
        vehicle: { year: null, make: 'Tesla', model: null },
        message: 'Model 3, white',
        answers: { budget: '$1,000+' },
      },
    });
  });

  it('shows the rate limit message from the server', async () => {
    mockRpc({
      public_get_lead_form: { data: { ...form, fields: [] } },
      public_submit_lead: pgError(
        'PT429',
        'we already received your request; please call the shop if you need anything else',
      ),
    });
    const { user } = render();
    await user.type(await screen.findByLabelText(/^First name/), 'Ana');
    await user.type(screen.getByRole('textbox', { name: /^Email/ }), 'ana@example.com');
    await user.click(screen.getByRole('button', { name: 'Send' }));
    expect(await screen.findByText('We already have your request')).toBeInTheDocument();
  });

  it('never says the request was received when the form-wide limit refused it', async () => {
    mockRpc({
      public_get_lead_form: { data: { ...form, fields: [] } },
      public_submit_lead: pgError(
        'PT429',
        'this form is receiving too many requests; please try again later or call the shop',
      ),
    });
    const { user } = render();
    await user.type(await screen.findByLabelText(/^First name/), 'Ana');
    await user.type(screen.getByRole('textbox', { name: /^Email/ }), 'ana@example.com');
    await user.click(screen.getByRole('button', { name: 'Send' }));
    expect(await screen.findByText('Your request wasn’t sent')).toBeInTheDocument();
    expect(screen.getByText(/This form is receiving too many requests/)).toBeInTheDocument();
    expect(screen.queryByText('We already have your request')).not.toBeInTheDocument();
  });

  it('explains a form that is gone, and never asks with a bad token', async () => {
    mockRpc({ public_get_lead_form: pgError('PT404', 'form not found') });
    render();
    expect(await screen.findByText('This form isn’t available')).toBeInTheDocument();
    resetSupabaseMock();
    mockRpc({});
    render('/lead/nope');
    await waitFor(() =>
      expect(screen.getAllByText('This form isn’t available').length).toBeGreaterThan(0),
    );
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it('renders the compact embed layout', async () => {
    mockRpc({ public_get_lead_form: { data: form } });
    render(`/lead/${TOKEN}?embed=1`);
    await screen.findByRole('heading', { name: 'Get a ceramic coating quote', level: 1 });
    expect(screen.queryByRole('banner')).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Terms of Service' })).toHaveAttribute(
      'target',
      '_blank',
    );
  });
});

describe('lead model', () => {
  it('needs an email or a phone and caps lengths', () => {
    const opts = { askVehicle: true, askMessage: false };
    expect(validateLead({ ...EMPTY_LEAD, firstName: 'A', phone: '205 555 0100' }, opts)).toEqual(
      {},
    );
    expect(validateLead({ ...EMPTY_LEAD, firstName: 'A', email: 'bad' }, opts).email).toBeTruthy();
    expect(
      validateLead({ ...EMPTY_LEAD, firstName: 'A', email: 'a@b.co', vehicleYear: '21' }, opts)
        .vehicleYear,
    ).toBeTruthy();
    expect(
      validateLead({ ...EMPTY_LEAD, firstName: 'A', email: 'a@b.co', smsOptIn: true }, opts).phone,
    ).toBe('Add a mobile number to get texts.');
  });

  it('never turns consent on without the channel and passes the honeypot through', () => {
    const payload = buildLeadPayload(
      { ...EMPTY_LEAD, firstName: 'Bot', email: 'x@y.co', smsOptIn: true, website: 'spam.biz' },
      { askVehicle: false, askMessage: false },
      {},
    );
    expect(payload.sms_opt_in).toBe(false);
    expect(payload).not.toHaveProperty('vehicle');
    expect(payload).not.toHaveProperty('message');
    expect(payload.website).toBe('spam.biz');
  });

  it('titles a failed submission by what the server refused', () => {
    expect(
      leadSubmitErrorBanner({
        kind: 'rate_limited',
        code: 'PT429',
        message:
          'We already received your request; please call the shop if you need anything else.',
      }),
    ).toEqual({ tone: 'warning', title: 'We already have your request' });
    expect(
      leadSubmitErrorBanner({
        kind: 'rate_limited',
        code: 'PT429',
        message:
          'This form is receiving too many requests; please try again later or call the shop.',
      }).title,
    ).toBe('Your request wasn’t sent');
    expect(
      leadSubmitErrorBanner({
        kind: 'rate_limited',
        code: undefined,
        message: 'Too many attempts.',
      }).title,
    ).toBe('Your request wasn’t sent');
    expect(leadSubmitErrorBanner({ kind: 'validation', code: '22023', message: 'x' })).toEqual({
      tone: 'danger',
      title: 'We couldn’t send your request',
    });
  });
});
