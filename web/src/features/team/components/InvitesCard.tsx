import { Copy, MailPlus, RotateCw, X } from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  Button,
  ConfirmDialog,
  ErrorState,
  IconButton,
  LoadingState,
  SectionCard,
  useToast,
} from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { ROLE_LABELS } from '@/features/shop/permissions';
import { useShop } from '@/features/shop/shopContext';
import { usePendingInvites, useResendInvite, useRevokeInvite } from '../api';
import { isInviteExpired, type PendingInvite } from '../model';

/** Pending (not accepted / revoked) invites — owners and admins only. */
export function InvitesCard({ onInvite, now }: { onInvite: () => void; now: Date }) {
  const { timezone } = useShop();
  const toast = useToast();
  const invites = usePendingInvites();
  const resend = useResendInvite();
  const revoke = useRevokeInvite();
  const [revoking, setRevoking] = useState<PendingInvite | null>(null);

  const copyLink = async (invite: PendingInvite) => {
    const link = `${window.location.origin}/invite/${invite.token}`;
    try {
      await navigator.clipboard.writeText(link);
      toast.success('Invite link copied', 'Share it only with the person you invited.');
    } catch {
      toast.info('Copy this link', link);
    }
  };

  let body;
  if (invites.isPending) body = <LoadingState label="Loading invites…" variant="rows" rows={2} />;
  else if (invites.error)
    body = (
      <ErrorState
        error={invites.error}
        title="Couldn’t load invites"
        onRetry={() => void invites.refetch()}
        retrying={invites.isRefetching}
        compact
      />
    );
  else if (invites.data.length === 0)
    body = <p className="text-muted px-4 py-3 text-sm sm:px-5">No pending invites.</p>;
  else
    body = (
      <ul className="divide-line divide-y">
        {invites.data.map((invite) => {
          const expired = isInviteExpired(invite, now);
          return (
            <li
              key={invite.id}
              className="flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-3 sm:px-5"
            >
              {/* min-w-48: on narrow screens the badge and actions wrap below the text
                  instead of squeezing it to a sliver. */}
              <div className="min-w-48 flex-1">
                <p className="text-ink truncate text-sm font-medium">{invite.email}</p>
                <p className="text-muted text-xs">
                  {ROLE_LABELS[invite.role]} · sent {formatDate(invite.created_at, timezone)} ·{' '}
                  {expired ? 'expired' : 'expires'} {formatDate(invite.expires_at, timezone)}
                </p>
              </div>
              {expired && <Badge tone="warning">Expired</Badge>}
              <div className="flex items-center gap-1">
                <IconButton
                  label={`Copy invite link for ${invite.email}`}
                  icon={<Copy />}
                  disabled={expired}
                  onClick={() => void copyLink(invite)}
                />
                <Button
                  size="sm"
                  variant="secondary"
                  leadingIcon={<RotateCw />}
                  loading={resend.isPending && resend.variables === invite.id}
                  onClick={() => resend.mutate(invite.id)}
                  aria-label={`Resend invite to ${invite.email}`}
                >
                  Resend
                </Button>
                <IconButton
                  label={`Revoke invite for ${invite.email}`}
                  icon={<X />}
                  variant="danger"
                  onClick={() => setRevoking(invite)}
                />
              </div>
            </li>
          );
        })}
      </ul>
    );

  return (
    <SectionCard
      title="Pending invites"
      flush
      actions={
        <Button size="sm" variant="secondary" leadingIcon={<MailPlus />} onClick={onInvite}>
          Invite
        </Button>
      }
    >
      {body}
      <ConfirmDialog
        open={revoking !== null}
        onClose={() => setRevoking(null)}
        tone="danger"
        loading={revoke.isPending}
        title="Revoke this invite?"
        description={
          revoking ? `The link sent to ${revoking.email} stops working immediately.` : undefined
        }
        confirmLabel="Revoke invite"
        onConfirm={async () => {
          if (!revoking) return;
          try {
            await revoke.mutateAsync(revoking.id);
            toast.success('Invite revoked');
          } catch (error) {
            toast.error(error);
          } finally {
            setRevoking(null);
          }
        }}
      />
    </SectionCard>
  );
}
