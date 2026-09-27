import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Users } from 'lucide-react';
import { Link, useNavigate, useParams } from 'react-router';
import { AuthLayout } from '@/components/layout/AuthLayout';
import { Button, buttonClasses, KeyValueList, LoadingState } from '@/components/ui';
import { ROLE_LABELS } from '@/features/shop/permissions';
import { browserTimeZone, formatDate } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { publicKey, shellKeys } from '@/lib/queryKeys';
import { storageKeys, writeLocal } from '@/lib/storage';
import { useAuth } from '../authContext';
import { acceptInvite, getInvite, isInviteToken } from '../api';
import { FormAlert } from '../FormAlert';
import { loginPath, signupPath } from '../redirects';

const STATUS_TEXT = {
  accepted: 'This invite has already been used. Sign in to open the shop.',
  revoked: 'This invite was cancelled by the shop. Ask them to send a new one.',
  expired: 'This invite has expired. Ask the shop to send a new one.',
} as const;

export default function InvitePage() {
  const { token } = useParams();
  const validToken = isInviteToken(token);
  const { status, user, signOut } = useAuth();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const invite = useQuery({
    queryKey: publicKey('invite', token ?? ''),
    queryFn: () => getInvite(token ?? ''),
    enabled: validToken,
  });

  const accept = useMutation({
    mutationFn: () => acceptInvite(token ?? ''),
    onSuccess: async (shopId) => {
      if (user) {
        writeLocal(storageKeys.lastShop(user.id), shopId);
        await queryClient.invalidateQueries({ queryKey: shellKeys.memberships(user.id) });
      }
      await navigate('/app', { replace: true });
    },
  });

  const title = 'Join a shop';
  const here = `/invite/${token ?? ''}`;

  if (!validToken) {
    return (
      <AuthLayout title={title}>
        <FormAlert>This invite link is not valid. Check that you copied the whole link.</FormAlert>
      </AuthLayout>
    );
  }
  if (invite.isPending || status === 'loading') {
    return (
      <AuthLayout title={title}>
        <LoadingState label="Loading invite…" />
      </AuthLayout>
    );
  }
  if (invite.isError) {
    return (
      <AuthLayout title={title}>
        <FormAlert>{errorMessage(invite.error)}</FormAlert>
        <Button variant="secondary" className="mt-4" onClick={() => void invite.refetch()}>
          Try again
        </Button>
      </AuthLayout>
    );
  }
  const data = invite.data;
  if (!data) {
    return (
      <AuthLayout title={title}>
        <FormAlert>
          We couldn’t find this invite. It may have been replaced by a newer one.
        </FormAlert>
      </AuthLayout>
    );
  }

  const emailMismatch =
    user?.email !== undefined && user.email.toLowerCase() !== data.email.toLowerCase();

  return (
    <AuthLayout
      title={`Join ${data.shop_name}`}
      description={`You’ve been invited to join ${data.shop_name} on Detail CRM.`}
    >
      <div className="flex flex-col gap-4">
        <div className="rounded-card bg-surface-2 flex items-center gap-3 p-3">
          <Users className="text-primary size-5 shrink-0" aria-hidden="true" />
          <KeyValueList
            className="min-w-0 flex-1"
            items={[
              { key: 'role', label: 'Role', value: ROLE_LABELS[data.role] },
              { key: 'email', label: 'Invited email', value: data.email },
              ...(data.status === 'pending'
                ? [
                    {
                      key: 'exp',
                      label: 'Expires',
                      value: formatDate(data.expires_at, browserTimeZone()),
                    },
                  ]
                : []),
            ]}
          />
        </div>

        {data.status !== 'pending' ? (
          <>
            <FormAlert>{STATUS_TEXT[data.status]}</FormAlert>
            {status === 'signedIn' ? (
              <Link to="/app" className={buttonClasses({ variant: 'secondary', fullWidth: true })}>
                Go to the app
              </Link>
            ) : (
              <Link
                to="/login"
                className={buttonClasses({ variant: 'secondary', fullWidth: true })}
              >
                Sign in
              </Link>
            )}
          </>
        ) : status === 'signedOut' ? (
          <>
            <p className="text-muted text-sm break-words">
              Sign in or create an account with{' '}
              <span className="text-ink font-medium">{data.email}</span> to accept.
            </p>
            <Link
              to={`${signupPath(here)}${signupPath(here).includes('?') ? '&' : '?'}email=${encodeURIComponent(data.email)}`}
              className={buttonClasses({ fullWidth: true, size: 'lg' })}
            >
              Create account
            </Link>
            <Link
              to={loginPath(here)}
              className={buttonClasses({ variant: 'secondary', fullWidth: true })}
            >
              I already have an account
            </Link>
          </>
        ) : (
          <>
            {emailMismatch && (
              <FormAlert>
                This invite was sent to {data.email}, but you’re signed in as {user?.email}. Sign
                out and use the invited email.
              </FormAlert>
            )}
            {accept.isError && <FormAlert>{errorMessage(accept.error)}</FormAlert>}
            {emailMismatch ? (
              <Button variant="secondary" fullWidth onClick={() => void signOut()}>
                Sign out
              </Button>
            ) : (
              <Button
                fullWidth
                size="lg"
                loading={accept.isPending}
                onClick={() => accept.mutate()}
              >
                Accept invite
              </Button>
            )}
          </>
        )}
      </div>
    </AuthLayout>
  );
}
