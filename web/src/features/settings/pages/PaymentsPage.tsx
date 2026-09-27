import { useQueryClient } from '@tanstack/react-query';
import { CreditCard, ExternalLink, RefreshCw } from 'lucide-react';
import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router';
import { Badge, Button, SectionCard, useToast } from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { settingsKeys, useStripeLink, useStripeStatus, type StripeStatus } from '../api';
import { redirectTo } from '../externalRedirect';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';

type ReturnState = 'return' | 'refresh' | null;

/**
 * Stripe Connect (owner/admin; route guard shop.connectStripe). Status comes
 * from stripe-connect `refresh_status`; onboarding returns here with
 * ?stripe=return (finished or left) or ?stripe=refresh (link expired).
 */
export default function PaymentsPage() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  const [params, setParams] = useSearchParams();
  // Coming back from Stripe (?stripe=return|refresh): remember why for the
  // notice, re-read the account and drop the query param.
  const [returned] = useState<ReturnState>(() => {
    const state = params.get('stripe');
    return state === 'return' || state === 'refresh' ? state : null;
  });
  const stripeParam = params.get('stripe');
  useEffect(() => {
    if (stripeParam === null) return;
    void queryClient.invalidateQueries({ queryKey: settingsKeys.stripe(shopId) });
    setParams(
      (current) => {
        const next = new URLSearchParams(current);
        next.delete('stripe');
        return next;
      },
      { replace: true },
    );
  }, [stripeParam, setParams, queryClient, shopId]);

  const status = useStripeStatus(true);

  return (
    <SettingsSectionLayout section="payments">
      {returned && <ReturnNotice state={returned} status={status.data} />}
      <QueryView query={status} label="your Stripe status">
        {(data) => (
          <StripeCard
            status={data}
            refreshing={status.isFetching}
            onRefresh={() => void status.refetch()}
          />
        )}
      </QueryView>
    </SettingsSectionLayout>
  );
}

function ReturnNotice({
  state,
  status,
}: {
  state: 'return' | 'refresh';
  status: StripeStatus | undefined;
}) {
  let text: string;
  if (state === 'refresh') {
    text = 'Your Stripe setup link expired. Choose “Continue onboarding” to get a fresh one.';
  } else if (status?.charges_enabled) {
    text = 'Stripe is connected. You can take card payments and deposits.';
  } else if (status?.details_submitted) {
    text = 'Thanks! Stripe is reviewing your details. Card payments turn on once they’re verified.';
  } else {
    text = 'Stripe setup isn’t finished yet. Continue onboarding whenever you’re ready.';
  }
  return (
    <p
      role="status"
      className="rounded-card border-line bg-primary-soft text-primary-ink border px-3 py-2 text-sm"
    >
      {text}
    </p>
  );
}

function FlagBadge({ on, label }: { on: boolean; label: string }) {
  return (
    <Badge tone={on ? 'success' : 'warning'} dot>
      {label}: {on ? 'on' : 'off'}
    </Badge>
  );
}

function StripeCard({
  status,
  refreshing,
  onRefresh,
}: {
  status: StripeStatus;
  refreshing: boolean;
  onRefresh: () => void;
}) {
  const toast = useToast();
  const link = useStripeLink();
  const [pending, setPending] = useState<'create_account_link' | 'login_link' | null>(null);

  const go = (action: 'create_account_link' | 'login_link') => {
    setPending(action);
    link.mutate(action, {
      onSuccess: (url) => redirectTo(url),
      onError: (error) => {
        setPending(null);
        toast.error(error);
      },
    });
  };

  const ready = status.connected && status.charges_enabled && status.payouts_enabled;
  const needsOnboarding = !status.connected || !status.details_submitted || !status.charges_enabled;

  return (
    <SectionCard
      title="Stripe"
      description="Card payments, online deposits and memberships are processed by Stripe and paid out to your bank. Card details never touch this app."
      actions={
        status.connected && (
          <Button
            variant="ghost"
            size="sm"
            leadingIcon={<RefreshCw className="size-4" aria-hidden="true" />}
            loading={refreshing}
            onClick={onRefresh}
          >
            Refresh status
          </Button>
        )
      }
    >
      <div className="flex flex-col gap-4">
        <div className="flex items-start gap-3">
          <CreditCard className="text-primary mt-0.5 size-5 shrink-0" aria-hidden="true" />
          <div className="flex min-w-0 flex-col gap-2">
            <p className="text-ink text-sm font-medium">
              {!status.connected
                ? 'Not connected'
                : ready
                  ? 'Connected and ready to take payments'
                  : status.details_submitted
                    ? 'Details submitted — waiting on Stripe'
                    : 'Onboarding not finished'}
            </p>
            {status.connected && (
              <div className="flex flex-wrap gap-2">
                <FlagBadge on={status.charges_enabled} label="Charges" />
                <FlagBadge on={status.payouts_enabled} label="Payouts" />
                <FlagBadge on={status.details_submitted} label="Details submitted" />
              </div>
            )}
            {status.stripe_account_id && (
              <p className="text-muted text-xs">
                Account <span className="font-mono">{status.stripe_account_id}</span>
              </p>
            )}
          </div>
        </div>
        <div className="flex flex-wrap gap-2">
          {needsOnboarding && (
            <Button
              loading={pending === 'create_account_link'}
              disabled={pending !== null}
              onClick={() => go('create_account_link')}
            >
              {status.connected ? 'Continue onboarding' : 'Connect Stripe'}
            </Button>
          )}
          {status.connected && status.details_submitted && (
            <Button
              variant="secondary"
              leadingIcon={<ExternalLink className="size-4" aria-hidden="true" />}
              loading={pending === 'login_link'}
              disabled={pending !== null}
              onClick={() => go('login_link')}
            >
              Open Stripe dashboard
            </Button>
          )}
        </div>
        {!status.connected && (
          <p className="text-muted text-xs">
            You’ll be taken to Stripe to verify your business and bank account, then brought back
            here.
          </p>
        )}
      </div>
    </SectionCard>
  );
}
