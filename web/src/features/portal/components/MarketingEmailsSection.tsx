import { Mail } from 'lucide-react';
import { useState } from 'react';
import { ErrorState, SectionCard, Switch, useToast } from '@/components/ui';
import { toAppError } from '@/lib/errors';
import {
  emailChoiceErrorMessage,
  MARKETING_EMAILS_ARE,
  UNSUBSCRIBE_STILL_SENT,
} from '@/features/campaigns/model';
import { usePortalEmailMarketing, useSetEmailMarketing, type PortalEmailMarketing } from '../api';

/** The one-line explanation next to a shop's toggle (the same as the unsubscribe page's). */
function marketingEmailsDescription(row: PortalEmailMarketing): string {
  if (row.unsubscribed_scope === 'all') {
    return `You stopped all emails from ${row.shop_name}, including ${UNSUBSCRIBE_STILL_SENT}. Turning marketing emails on turns those back on too.`;
  }
  const what = MARKETING_EMAILS_ARE.charAt(0).toUpperCase() + MARKETING_EMAILS_ARE.slice(1);
  return `${what}. You get ${UNSUBSCRIBE_STILL_SENT} either way.`;
}

/**
 * Client portal: the customer's own marketing email choice with each shop
 * (0126: portal_email_marketing lists only records whose email is the
 * signed-in client's confirmed email; portal_set_email_marketing changes
 * them). The toggle always shows the server's state: it is read again after
 * every change. Hidden while the account's email is unconfirmed (42501: the
 * page's banner already asks to confirm it).
 */
export function MarketingEmailsSection({ userId }: { userId: string }) {
  const rows = usePortalEmailMarketing(userId, true);
  const setMarketing = useSetEmailMarketing(userId);
  const toast = useToast();
  const [failure, setFailure] = useState<{ customerId: string; message: string } | null>(null);

  if (rows.isPending) return null;
  if (rows.isError) {
    if (toAppError(rows.error).kind === 'permission') return null;
    return (
      <SectionCard title="Marketing emails">
        <ErrorState
          compact
          error={rows.error}
          title="Couldn’t load your email choices"
          onRetry={() => void rows.refetch()}
          retrying={rows.isFetching}
        />
      </SectionCard>
    );
  }
  if (rows.data.length === 0) return null;

  const toggle = async (row: PortalEmailMarketing, optIn: boolean) => {
    setFailure(null);
    try {
      const now = await setMarketing.mutateAsync({ customerId: row.customer_id, optIn });
      toast.success(
        now
          ? `Marketing emails from ${row.shop_name} are on`
          : `Marketing emails from ${row.shop_name} are off`,
      );
    } catch (error) {
      setFailure({
        customerId: row.customer_id,
        message:
          toAppError(error).kind === 'not_found'
            ? 'We couldn’t find that record any more. Reload the page and try again.'
            : emailChoiceErrorMessage(error),
      });
    }
  };

  return (
    <SectionCard title="Marketing emails" flush>
      <ul aria-label="Marketing emails" className="divide-line divide-y px-4 sm:px-5">
        {rows.data.map((row) => {
          const busy =
            setMarketing.isPending && setMarketing.variables.customerId === row.customer_id;
          return (
            <li key={row.customer_id} className="flex items-start gap-3 py-3">
              <span className="bg-surface-2 text-muted flex size-9 shrink-0 items-center justify-center rounded-full [&_svg]:size-4">
                <Mail aria-hidden="true" />
              </span>
              <div className="flex min-w-0 flex-1 flex-col gap-1">
                <Switch
                  checked={row.email_opt_in}
                  disabled={busy}
                  onCheckedChange={(next) => void toggle(row, next)}
                  label={`Marketing emails from ${row.shop_name}`}
                  description={marketingEmailsDescription(row)}
                />
                <p className="text-muted text-xs break-all">Sent to {row.email}</p>
                {failure?.customerId === row.customer_id && (
                  <p
                    role="alert"
                    className="bg-danger-soft text-danger-ink rounded-control px-3 py-2 text-sm"
                  >
                    {failure.message}
                  </p>
                )}
              </div>
            </li>
          );
        })}
      </ul>
    </SectionCard>
  );
}
