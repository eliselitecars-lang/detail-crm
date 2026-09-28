import { screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { authValue, renderRoute, signedInAuth } from '@/test/render';
import { createBuilder, resetSupabaseMock, supabase } from '@/test/supabaseMock';
import { forgetCallbackLink, inspectStartupUrl } from '@/lib/authUrlSession';
import AuthCallbackPage from './AuthCallbackPage';
import ForgotPasswordPage from './ForgotPasswordPage';
import InvitePage from './InvitePage';
import LoginPage from './LoginPage';
import ResetPasswordPage from './ResetPasswordPage';
import SignupPage from './SignupPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const landing = (path: string, text: string) => ({ path, element: <p>{text}</p> });

beforeEach(() => resetSupabaseMock());

describe('LoginPage', () => {
  it('validates required fields', async () => {
    const { user } = renderRoute(<LoginPage />, {
      routePath: '/login',
      path: '/login',
      shop: null,
    });
    await user.click(screen.getByRole('button', { name: 'Sign in' }));
    expect(await screen.findByText('Email is required.')).toBeInTheDocument();
    expect(screen.getByText('Password is required.')).toBeInTheDocument();
    expect(screen.getByLabelText(/Email/)).toHaveAttribute('aria-invalid', 'true');
    expect(supabase.auth.signInWithPassword).not.toHaveBeenCalled();
  });

  it('confirms a deleted account', () => {
    renderRoute(<LoginPage />, {
      routePath: '/login',
      path: '/login?account=deleted',
      shop: null,
    });
    expect(screen.getByRole('status')).toHaveTextContent('Your account was deleted.');
  });

  it('signs in and goes to the safe `next` path', async () => {
    const { user } = renderRoute(<LoginPage />, {
      routePath: '/login',
      path: '/login?next=%2Fapp%2Fjobs',
      routes: [landing('/app/jobs', 'Jobs landing')],
      shop: null,
    });
    await user.type(screen.getByLabelText(/Email/), 'Owner@Example.com');
    await user.type(screen.getByLabelText(/^Password/), 'hunter22!');
    await user.click(screen.getByRole('button', { name: 'Sign in' }));
    expect(await screen.findByText('Jobs landing')).toBeInTheDocument();
    expect(supabase.auth.signInWithPassword).toHaveBeenCalledWith({
      email: 'owner@example.com',
      password: 'hunter22!',
    });
  });

  it('shows a friendly error for bad credentials', async () => {
    supabase.auth.signInWithPassword.mockResolvedValueOnce({
      data: {},
      error: {
        name: 'AuthApiError',
        code: 'invalid_credentials',
        message: 'Invalid login credentials',
        status: 400,
      },
    } as never);
    const { user } = renderRoute(<LoginPage />, {
      routePath: '/login',
      path: '/login',
      shop: null,
    });
    await user.type(screen.getByLabelText(/Email/), 'owner@example.com');
    await user.type(screen.getByLabelText(/^Password/), 'wrong');
    await user.click(screen.getByRole('button', { name: 'Sign in' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Email or password is incorrect.');
  });

  it('redirects a signed-in user away from the login page', async () => {
    renderRoute(<LoginPage />, {
      routePath: '/login',
      path: '/login',
      auth: signedInAuth(),
      routes: [landing('/app', 'App home')],
      shop: null,
    });
    expect(await screen.findByText('App home')).toBeInTheDocument();
  });
});

describe('SignupPage', () => {
  it('requires matching passwords of at least 8 characters', async () => {
    const { user } = renderRoute(<SignupPage />, {
      routePath: '/signup',
      path: '/signup',
      shop: null,
    });
    await user.type(screen.getByLabelText(/Your name/), 'Sam Shop');
    await user.type(screen.getByLabelText(/Email/), 'sam@example.com');
    await user.type(screen.getByLabelText(/^Password/), 'short');
    await user.type(screen.getByLabelText(/Confirm password/), 'different');
    await user.click(screen.getByRole('button', { name: 'Create account' }));
    expect(await screen.findByText('Use at least 8 characters.')).toBeInTheDocument();
    expect(screen.getByText('Passwords don’t match.')).toBeInTheDocument();
    expect(supabase.auth.signUp).not.toHaveBeenCalled();
  });

  it('asks the user to confirm their email when no session is returned', async () => {
    const { user } = renderRoute(<SignupPage />, {
      routePath: '/signup',
      path: '/signup?next=%2Finvite%2Fabc&email=sam%40example.com',
      shop: null,
    });
    expect(screen.getByLabelText(/Email/)).toHaveValue('sam@example.com');
    await user.type(screen.getByLabelText(/Your name/), 'Sam Shop');
    await user.type(screen.getByLabelText(/^Password/), 'correct-horse');
    await user.type(screen.getByLabelText(/Confirm password/), 'correct-horse');
    await user.click(screen.getByRole('button', { name: 'Create account' }));
    expect(await screen.findByRole('heading', { name: 'Check your email' })).toBeInTheDocument();
    expect(supabase.auth.signUp).toHaveBeenCalledWith({
      email: 'sam@example.com',
      password: 'correct-horse',
      options: {
        data: { full_name: 'Sam Shop' },
        // Via /auth/callback, which asks before signing in (login CSRF).
        emailRedirectTo: `${window.location.origin}/auth/callback?next=%2Finvite%2Fabc`,
      },
    });
  });
});

describe('SignupPage pricing link', () => {
  it('links someone setting up a shop to the plans', () => {
    renderRoute(<SignupPage />, { routePath: '/signup', path: '/signup', shop: null });
    expect(screen.getByRole('link', { name: 'plans and pricing' })).toHaveAttribute(
      'href',
      '/pricing',
    );
  });

  it('never shows platform pricing to a customer or an invited teammate', () => {
    renderRoute(<SignupPage />, {
      routePath: '/signup',
      path: '/signup?next=%2Fportal',
      shop: null,
    });
    expect(screen.queryByRole('link', { name: 'plans and pricing' })).toBeNull();
  });

  it('hides it for an invite sign-up too', () => {
    renderRoute(<SignupPage />, {
      routePath: '/signup',
      path: '/signup?next=%2Finvite%2Fabc',
      shop: null,
    });
    expect(screen.queryByRole('link', { name: 'plans and pricing' })).toBeNull();
  });
});

describe('ForgotPasswordPage', () => {
  it('sends a reset link that returns to /reset-password', async () => {
    const { user } = renderRoute(<ForgotPasswordPage />, { shop: null });
    await user.type(screen.getByLabelText(/Email/), 'owner@example.com');
    await user.click(screen.getByRole('button', { name: 'Send reset link' }));
    expect(await screen.findByRole('status')).toHaveTextContent(
      'If an account exists for owner@example.com',
    );
    expect(supabase.auth.resetPasswordForEmail).toHaveBeenCalledWith('owner@example.com', {
      redirectTo: `${window.location.origin}/reset-password`,
    });
  });
});

describe('ResetPasswordPage', () => {
  it('explains an invalid/expired link when there is no recovery session', () => {
    renderRoute(<ResetPasswordPage />, { auth: authValue({ status: 'signedOut' }), shop: null });
    expect(screen.getByRole('alert')).toHaveTextContent('invalid or has expired');
    expect(screen.getByRole('link', { name: 'Request a new reset link' })).toHaveAttribute(
      'href',
      '/forgot-password',
    );
  });

  it('updates the password for the recovery session', async () => {
    const { user } = renderRoute(<ResetPasswordPage />, {
      routePath: '/reset-password',
      path: '/reset-password',
      auth: { ...signedInAuth(), recovery: true },
      routes: [landing('/app', 'App home')],
      shop: null,
    });
    await user.type(screen.getByLabelText(/^New password/), 'new-secret-1');
    await user.type(screen.getByLabelText(/Confirm new password/), 'new-secret-1');
    await user.click(screen.getByRole('button', { name: 'Update password' }));
    expect(await screen.findByText('App home')).toBeInTheDocument();
    expect(supabase.auth.updateUser).toHaveBeenCalledWith({ password: 'new-secret-1' });
  });

  it('never offers the form to an ordinary signed-in session', () => {
    renderRoute(<ResetPasswordPage />, { auth: signedInAuth(), shop: null });
    expect(screen.getByRole('alert')).toHaveTextContent(
      'open the reset link from your latest email',
    );
    expect(screen.queryByLabelText(/^New password/)).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Request a new reset link' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Back to the app' })).toHaveAttribute('href', '/app');
  });

  it('waits for the reset link to be processed before deciding', () => {
    renderRoute(<ResetPasswordPage />, {
      auth: { ...signedInAuth(), recoveryChecking: true },
      shop: null,
    });
    expect(screen.getByText('Checking your reset link…')).toBeInTheDocument();
    expect(screen.queryByLabelText(/^New password/)).not.toBeInTheDocument();
  });

  it('shows an expired-link error even when a session already exists', () => {
    const previous = window.location.href;
    window.history.replaceState(
      null,
      '',
      '/reset-password#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired',
    );
    try {
      renderRoute(<ResetPasswordPage />, {
        auth: { ...signedInAuth(), recovery: true },
        shop: null,
      });
      expect(screen.getByRole('alert')).toHaveTextContent('invalid or has expired');
      expect(screen.queryByLabelText(/^New password/)).not.toBeInTheDocument();
    } finally {
      window.history.replaceState(null, '', previous);
    }
  });
});

describe('InvitePage', () => {
  const token = '6f1c2f7e-4c9b-4f55-9d7a-0b3e2a1c9d10';
  const invite = {
    shop_name: 'Glacier Detailing',
    shop_slug: 'glacier-detailing',
    role: 'technician',
    email: 'tech@example.com',
    expires_at: '2030-01-01T00:00:00Z',
    status: 'pending',
  };

  it('rejects malformed tokens without calling the API', () => {
    renderRoute(<InvitePage />, {
      routePath: '/invite/:token',
      path: '/invite/not-a-token',
      shop: null,
    });
    expect(screen.getByRole('alert')).toHaveTextContent('not valid');
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it('offers sign-up/sign-in (with the invited email) when signed out', async () => {
    supabase.rpc.mockReturnValueOnce(createBuilder({ data: [invite] }));
    renderRoute(<InvitePage />, {
      routePath: '/invite/:token',
      path: `/invite/${token}`,
      shop: null,
    });
    expect(
      await screen.findByRole('heading', { name: 'Join Glacier Detailing' }),
    ).toBeInTheDocument();
    expect(screen.getByText('Technician')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Create account' })).toHaveAttribute(
      'href',
      `/signup?next=${encodeURIComponent(`/invite/${token}`)}&email=tech%40example.com`,
    );
    expect(supabase.rpc).toHaveBeenCalledWith('public_get_invite', { p_token: token });
  });

  it('accepts the invite and opens the app in that shop', async () => {
    supabase.rpc
      .mockReturnValueOnce(createBuilder({ data: [invite] }))
      .mockReturnValueOnce(createBuilder({ data: { id: 'm1', shop_id: 'shop-9' } }));
    const { user } = renderRoute(<InvitePage />, {
      routePath: '/invite/:token',
      path: `/invite/${token}`,
      auth: signedInAuth('tech@example.com', 'user-7'),
      routes: [landing('/app', 'App home')],
      shop: null,
    });
    await user.click(await screen.findByRole('button', { name: 'Accept invite' }));
    expect(await screen.findByText('App home')).toBeInTheDocument();
    expect(supabase.rpc).toHaveBeenLastCalledWith('accept_invite', { p_token: token });
    expect(window.localStorage.getItem('detailcrm:lastShop:user-7')).toBe('shop-9');
  });

  it('warns when signed in with a different email', async () => {
    supabase.rpc.mockReturnValueOnce(createBuilder({ data: [invite] }));
    renderRoute(<InvitePage />, {
      routePath: '/invite/:token',
      path: `/invite/${token}`,
      auth: signedInAuth('someone@else.com'),
      shop: null,
    });
    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent('sent to tech@example.com'),
    );
    expect(screen.queryByRole('button', { name: 'Accept invite' })).not.toBeInTheDocument();
  });

  it('explains expired invites', async () => {
    supabase.rpc.mockReturnValueOnce(createBuilder({ data: [{ ...invite, status: 'expired' }] }));
    renderRoute(<InvitePage />, {
      routePath: '/invite/:token',
      path: `/invite/${token}`,
      shop: null,
    });
    expect(await screen.findByRole('alert')).toHaveTextContent('expired');
  });
});

function fakeJwt(sub: string): string {
  const part = (value: object) => btoa(JSON.stringify(value)).replace(/=+$/, '');
  return `${part({ alg: 'HS256' })}.${part({ sub })}.sig`;
}

/** Loads the page as if the app had just started on `path` (lib/authUrlSession). */
function startOn(path: string, storedUserId: string | null = null) {
  window.localStorage.clear();
  if (storedUserId) {
    window.localStorage.setItem(
      'sb-test-auth-token',
      JSON.stringify({ user: { id: storedUserId } }),
    );
  }
  window.history.replaceState(null, '', path);
  inspectStartupUrl('sb-test-auth-token');
}

describe('ResetPasswordPage — link for another account', () => {
  const previous = window.location.href;
  afterEach(() => {
    window.history.replaceState(null, '', previous);
    window.localStorage.clear();
  });

  it('keeps the signed-in account and says the link is for someone else', () => {
    startOn(
      `/reset-password#access_token=${fakeJwt('attacker')}&refresh_token=rt&type=recovery`,
      'user-1',
    );
    renderRoute(<ResetPasswordPage />, { auth: signedInAuth(), shop: null });
    expect(screen.getByRole('alert')).toHaveTextContent('for a different account');
    expect(screen.queryByLabelText(/^New password/)).not.toBeInTheDocument();
    expect(window.location.hash).toBe('');
  });

  it('names the account the new password is for', () => {
    startOn('/reset-password');
    renderRoute(<ResetPasswordPage />, {
      auth: { ...signedInAuth('sam@example.com'), recovery: true },
      shop: null,
    });
    expect(screen.getByText('sam@example.com')).toBeInTheDocument();
  });
});

describe('AuthCallbackPage', () => {
  const previous = window.location.href;
  afterEach(() => {
    window.history.replaceState(null, '', previous);
    window.localStorage.clear();
    forgetCallbackLink();
  });

  const confirmLink = (sub: string) =>
    `/auth/callback?next=%2Fapp#access_token=${fakeJwt(sub)}&refresh_token=rt-${sub}&expires_in=3600&token_type=bearer&type=signup`;

  it('signs in only after the visitor confirms the account', async () => {
    startOn(confirmLink('new-user'));
    supabase.auth.getUser.mockResolvedValueOnce({
      data: { user: { id: 'new-user', email: 'new@example.com' } },
      error: null,
    });
    const { user } = renderRoute(<AuthCallbackPage />, {
      routePath: '/auth/callback',
      path: '/auth/callback?next=%2Fapp',
      auth: authValue({ status: 'signedOut' }),
      routes: [landing('/app', 'App home')],
      shop: null,
    });
    expect(await screen.findByText('new@example.com')).toBeInTheDocument();
    expect(supabase.auth.getUser).toHaveBeenCalledWith(fakeJwt('new-user'));
    expect(supabase.auth.setSession).not.toHaveBeenCalled();
    await user.click(screen.getByRole('button', { name: 'Continue as new@example.com' }));
    expect(await screen.findByText('App home')).toBeInTheDocument();
    expect(supabase.auth.setSession).toHaveBeenCalledWith({
      access_token: fakeJwt('new-user'),
      refresh_token: 'rt-new-user',
    });
  });

  it('never replaces another signed-in account without asking, and can be declined', async () => {
    startOn(confirmLink('attacker'), 'user-1');
    supabase.auth.getUser.mockResolvedValueOnce({
      data: { user: { id: 'attacker', email: 'someone@evil.test' } },
      error: null,
    });
    const { user } = renderRoute(<AuthCallbackPage />, {
      routePath: '/auth/callback',
      path: '/auth/callback?next=%2Fapp',
      auth: signedInAuth(),
      routes: [landing('/app', 'App home')],
      shop: null,
    });
    expect(await screen.findByText('someone@evil.test')).toBeInTheDocument();
    expect(screen.getByText(/You’re signed in here as/)).toHaveTextContent('owner@example.com');
    await user.click(screen.getByRole('button', { name: 'This isn’t me' }));
    expect(await screen.findByText('App home')).toBeInTheDocument();
    expect(supabase.auth.setSession).not.toHaveBeenCalled();
    expect(supabase.auth.signOut).not.toHaveBeenCalled();
  });

  it('explains an expired confirmation link', () => {
    startOn(
      '/auth/callback?next=%2Fapp#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired',
    );
    renderRoute(<AuthCallbackPage />, {
      routePath: '/auth/callback',
      path: '/auth/callback?next=%2Fapp',
      auth: authValue({ status: 'signedOut' }),
      shop: null,
    });
    expect(screen.getByRole('alert')).toHaveTextContent('invalid or has expired');
    expect(supabase.auth.getUser).not.toHaveBeenCalled();
  });
});
