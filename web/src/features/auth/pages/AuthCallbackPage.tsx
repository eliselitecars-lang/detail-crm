import { useMutation, useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router';
import { AuthLayout } from '@/components/layout/AuthLayout';
import { Button, buttonClasses, ErrorState, LoadingState } from '@/components/ui';
import {
  forgetCallbackLink,
  jwtSubject,
  startupCallbackLink,
  type CallbackLink,
} from '@/lib/authUrlSession';
import { errorMessage } from '@/lib/errors';
import { publicKey } from '@/lib/queryKeys';
import { useAuth } from '../authContext';
import { acceptLinkSession, linkAccountEmail, signOutThisBrowser } from '../api';
import { FormAlert } from '../FormAlert';
import { loginPath, safeNext } from '../redirects';

const TITLE = 'Confirm your email';

/**
 * /auth/callback?next=… — where sign-up confirmation emails land. The link's
 * session is NOT saved automatically (anyone can build such a link from
 * their own account, lib/authUrlSession.ts): the page names the account and
 * signs in only when the visitor continues.
 */
export default function AuthCallbackPage() {
  const [params] = useSearchParams();
  const next = safeNext(params.get('next'));
  // Captured (and removed from the address bar) when the client started.
  const [link] = useState<CallbackLink | null>(() => startupCallbackLink());
  const { status } = useAuth();

  if (link?.error) {
    const expired = link.errorCode === 'otp_expired' || /expired|invalid/i.test(link.error);
    return (
      <AuthLayout
        title={TITLE}
        footer={
          <Link to={loginPath(next)} className="text-primary-ink font-medium hover:underline">
            Sign in
          </Link>
        }
      >
        <FormAlert>
          {expired
            ? 'This confirmation link is invalid or has expired. Sign in to get a new one, or sign up again.'
            : link.error.replace(/\+/g, ' ')}
        </FormAlert>
      </AuthLayout>
    );
  }

  if (!link?.accessToken || !link.refreshToken) {
    if (status === 'loading') {
      return (
        <AuthLayout title={TITLE}>
          <LoadingState label="Loading…" />
        </AuthLayout>
      );
    }
    if (status === 'signedIn') return <Navigate to={next} replace />;
    return (
      <AuthLayout title={TITLE}>
        <div className="flex flex-col gap-4">
          <FormAlert>
            This link has already been used or is incomplete. Sign in with your email and password
            to continue.
          </FormAlert>
          <Link
            to={loginPath(next)}
            className={buttonClasses({ variant: 'primary', fullWidth: true })}
          >
            Sign in
          </Link>
        </div>
      </AuthLayout>
    );
  }

  return (
    <ConfirmAccount accessToken={link.accessToken} refreshToken={link.refreshToken} next={next} />
  );
}

function ConfirmAccount({
  accessToken,
  refreshToken,
  next,
}: {
  accessToken: string;
  refreshToken: string;
  next: string;
}) {
  const navigate = useNavigate();
  const { status, user } = useAuth();
  const account = useQuery({
    queryKey: publicKey('auth-link-account', accessToken),
    queryFn: () => linkAccountEmail(accessToken),
    retry: false,
    staleTime: Infinity,
  });
  const signedInElsewhere =
    status === 'signedIn' && user !== null && user.id !== jwtSubject(accessToken);
  const accept = useMutation({
    // Another account signed in here is signed out first (its cached data
    // is cleared on SIGNED_OUT), never silently replaced.
    mutationFn: async () => {
      if (signedInElsewhere) await signOutThisBrowser();
      await acceptLinkSession({ accessToken, refreshToken });
    },
    onSuccess: async () => {
      forgetCallbackLink();
      await navigate(next, { replace: true });
    },
  });

  // Already signed in to this very account here: nothing to decide.
  if (status === 'signedIn' && user?.id === jwtSubject(accessToken)) {
    return <Navigate to={next} replace />;
  }
  if (account.isPending || status === 'loading') {
    return (
      <AuthLayout title={TITLE}>
        <LoadingState label="Checking your link…" />
      </AuthLayout>
    );
  }
  if (account.isError) {
    return (
      <AuthLayout
        title={TITLE}
        footer={
          <Link to={loginPath(next)} className="text-primary-ink font-medium hover:underline">
            Sign in
          </Link>
        }
      >
        <ErrorState
          compact
          title="Couldn’t check this link"
          error={account.error}
          onRetry={() => void account.refetch()}
          retrying={account.isFetching}
        />
      </AuthLayout>
    );
  }

  const email = account.data || 'this account';
  const decline = async () => {
    forgetCallbackLink();
    await navigate(status === 'signedIn' ? '/app' : loginPath(next), { replace: true });
  };

  return (
    <AuthLayout
      title="Your email is confirmed"
      description="Check the account before you continue."
    >
      <div className="flex flex-col gap-4">
        {accept.isError && <FormAlert>{errorMessage(accept.error)}</FormAlert>}
        <p className="text-ink text-sm">
          This link signs you in as <span className="font-semibold break-all">{email}</span>. Only
          continue if this is your email address.
        </p>
        {signedInElsewhere && user && (
          <p className="text-muted text-sm">
            You’re signed in here as{' '}
            <span className="text-ink font-medium break-all">{user.email}</span>. Continuing signs
            that account out in this browser.
          </p>
        )}
        <Button fullWidth size="lg" loading={accept.isPending} onClick={() => accept.mutate()}>
          Continue as {email}
        </Button>
        <Button
          variant="secondary"
          fullWidth
          disabled={accept.isPending}
          onClick={() => void decline()}
        >
          This isn’t me
        </Button>
      </div>
    </AuthLayout>
  );
}
