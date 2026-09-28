import { Check, CreditCard, ExternalLink, ReceiptText } from 'lucide-react';
import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router';
import {
  Badge,
  Button,
  Card,
  EmptyState,
  ErrorState,
  KeyValueList,
  LoadingState,
  SectionCard,
  Spinner,
  useToast,
  type KeyValueItem,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { SettingsSectionLayout } from '@/features/settings/components/SettingsSectionLayout';
import { formatDate } from '@/lib/dates';
import {
  useBillingPlans,
  useOpenBillingPortal,
  useRefreshBilling,
  useShopBillingStatus,
  useShopEntitlement,
  useStartCheckout,
} from './api';
import {
  CONFIRM_TIMEOUT_MS,
  checkoutReturn,
  daysLeft,
  daysLeftText,
  hasLiveSubscription,
  LAPSED_PAUSED,
  LAPSED_STILL_WORKS,
  planPriceText,
  STATE_LABELS,
  STATE_TONES,
  standingText,
  subscriptionConfirmed,
  type BillingPlan,
  type CheckoutReturn,
  type Entitlement,
  type ShopBilling,
} from './model';
import { PlanCard } from './components/PlanCard';

/**
 * Settings > Billing (SPEC §3 / §4.10; docs/BILLING.md): this shop's Detail
 * CRM subscription. Owner, admin and manager see the standing; only the owner
 * chooses a plan (Stripe Checkout, via the billing function) and manages it
 * (Stripe Customer Portal). Plans and prices come from the server only.
 * Checkout returns here with ?checkout=success (re-read until Stripe's
 * webhook has recorded the subscription, for at most CONFIRM_TIMEOUT_MS) or
 * ?checkout=cancelled.
 */
export default function BillingPage() {
  const { shopId, role } = useShop();
  const owner = role === 'owner';
  const [params, setParams] = useSearchParams();
  const [returned] = useState<CheckoutReturn | null>(() => checkoutReturn(params));
  const [waitStarted, setWaitStarted] = useState<number | null>(() =>
    returned === 'success' ? Date.now() : null,
  );
  const [timedOut, setTimedOut] = useState(false);
  const waiting = waitStarted !== null && !timedOut;

  const entitlement = useShopEntitlement(shopId);
  const status = useShopBillingStatus(shopId, true, { pollUntilConfirmed: waiting });
  const refresh = useRefreshBilling(shopId);
  const confirmed = status.data ? subscriptionConfirmed(status.data.status) : false;

  // Drop ?checkout= from the URL (a reload must not start waiting again).
  const returnParam = checkoutReturn(params);
  useEffect(() => {
    if (returnParam === null) return;
    setParams(
      (current) => {
        const next = new URLSearchParams(current);
        next.delete('checkout');
        next.delete('billing');
        return next;
      },
      { replace: true },
    );
  }, [returnParam, setParams]);

  // Stop waiting after CONFIRM_TIMEOUT_MS; once confirmed, re-read the standing.
  useEffect(() => {
    if (!waiting || confirmed || waitStarted === null) return undefined;
    const timer = setTimeout(
      () => setTimedOut(true),
      Math.max(0, CONFIRM_TIMEOUT_MS - (Date.now() - waitStarted)),
    );
    return () => clearTimeout(timer);
  }, [waiting, confirmed, waitStarted]);
  // Once Stripe's confirmation is recorded, re-read the standing (plan, dates).
  const confirmedNow = returned === 'success' && confirmed;
  useEffect(() => {
    if (confirmedNow) void refresh();
  }, [confirmedNow, refresh]);

  const checkAgain = () => {
    setTimedOut(false);
    setWaitStarted(Date.now());
    void refresh();
  };

  return (
    <SettingsSectionLayout section="billing">
      {returned && (
        <ReturnNotice
          returned={returned}
          confirmed={confirmed}
          timedOut={timedOut}
          onCheckAgain={checkAgain}
        />
      )}
      {entitlement.isPending ? (
        <Card>
          <LoadingState label="Loading billing…" />
        </Card>
      ) : entitlement.isError ? (
        <Card>
          <ErrorState
            title="Couldn’t load billing"
            error={entitlement.error}
            onRetry={() => void entitlement.refetch()}
            retrying={entitlement.isRefetching}
          />
        </Card>
      ) : !entitlement.data?.billing_enabled ? (
        <Card>
          <EmptyState
            icon={<ReceiptText aria-hidden="true" />}
            title="Billing isn’t enabled"
            description="Subscriptions aren’t turned on for this service, so there’s nothing to set up or buy here. Every part of the app is available to this shop."
          />
        </Card>
      ) : (
        <>
          <StandingCard entitlement={entitlement.data} status={status.data ?? null} />
          {owner ? (
            <OwnerBilling
              entitlement={entitlement.data}
              status={status.data ?? null}
              statusLoading={status.isPending}
            />
          ) : (
            <p role="note" className="text-muted text-sm">
              Only the shop owner can choose a plan or change the subscription.
            </p>
          )}
        </>
      )}
    </SettingsSectionLayout>
  );
}

function ReturnNotice({
  returned,
  confirmed,
  timedOut,
  onCheckAgain,
}: {
  returned: CheckoutReturn;
  confirmed: boolean;
  timedOut: boolean;
  onCheckAgain: () => void;
}) {
  const base = 'rounded-card border px-3 py-2 text-sm';
  if (returned === 'cancelled') {
    return (
      <p role="status" className={`${base} border-line bg-surface-2 text-muted`}>
        Checkout was cancelled. No subscription was started.
      </p>
    );
  }
  if (confirmed) {
    return (
      <p
        role="status"
        className={`${base} border-success/25 bg-success-soft text-success-ink flex items-center gap-2`}
      >
        <Check className="size-4 shrink-0" aria-hidden="true" />
        Thanks! Stripe confirmed your subscription.
      </p>
    );
  }
  if (timedOut) {
    return (
      <div
        role="status"
        className={`${base} border-warning/30 bg-warning-soft text-warning-ink flex flex-wrap items-center gap-x-3 gap-y-2`}
      >
        <p className="min-w-0 flex-1">
          Stripe hasn’t confirmed the subscription yet. It usually takes a few seconds, but can take
          longer. Check again in a minute; if it still doesn’t show, contact support before paying
          again.
        </p>
        <Button size="sm" variant="secondary" onClick={onCheckAgain}>
          Check again
        </Button>
      </div>
    );
  }
  return (
    <p
      role="status"
      className={`${base} border-primary/25 bg-primary-soft text-primary-ink flex items-center gap-2`}
    >
      <Spinner className="shrink-0" />
      Confirming your subscription with Stripe…
    </p>
  );
}

function StandingCard({
  entitlement,
  status,
}: {
  entitlement: Entitlement;
  status: ShopBilling | null;
}) {
  const { timezone } = useShop();
  const items: KeyValueItem[] = [
    {
      key: 'status',
      label: 'Status',
      value: (
        <Badge tone={STATE_TONES[entitlement.state]} dot>
          {STATE_LABELS[entitlement.state]}
        </Badge>
      ),
    },
    { key: 'plan', label: 'Plan', value: entitlement.plan_name },
  ];
  if (entitlement.state === 'trialing' && entitlement.trial_ends_at) {
    const days = daysLeft(entitlement.trial_ends_at, timezone);
    items.push({
      key: 'trial',
      label: 'Trial ends',
      value: `${formatDate(entitlement.trial_ends_at, timezone)} (${daysLeftText(days)})`,
    });
  }
  if (entitlement.current_period_end && entitlement.state !== 'trialing') {
    const ending =
      entitlement.cancel_at_period_end ||
      (status !== null && !hasLiveSubscription(status.status)) ||
      entitlement.state === 'lapsed';
    items.push({
      key: 'period',
      label: ending
        ? new Date(entitlement.current_period_end) < new Date()
          ? 'Ended'
          : 'Ends'
        : 'Renews',
      value: formatDate(entitlement.current_period_end, timezone),
    });
  }
  if (entitlement.members_used !== null) {
    items.push({
      key: 'members',
      label: 'Team members',
      value:
        entitlement.max_members === null
          ? `${entitlement.members_used} (no limit)`
          : `${entitlement.members_used} of ${entitlement.max_members}`,
    });
  }
  return (
    <SectionCard title="Subscription" description={standingText(entitlement, timezone)}>
      <div className="flex flex-col gap-3">
        <KeyValueList items={items} />
        {entitlement.state === 'lapsed' && (
          <div className="bg-danger-soft text-danger-ink rounded-control flex flex-col gap-1 px-3 py-2 text-sm">
            <p>{LAPSED_PAUSED}</p>
            <p>{LAPSED_STILL_WORKS}</p>
          </div>
        )}
        {entitlement.max_members !== null &&
          entitlement.members_used !== null &&
          entitlement.members_used >= entitlement.max_members && (
            <p className="text-muted text-sm">
              The plan’s team limit is reached: active members and pending invites count.
            </p>
          )}
      </div>
    </SectionCard>
  );
}

function OwnerBilling({
  entitlement,
  status,
  statusLoading,
}: {
  entitlement: Entitlement;
  status: ShopBilling | null;
  statusLoading: boolean;
}) {
  const { shopId } = useShop();
  const toast = useToast();
  const portal = useOpenBillingPortal(shopId);
  const live = status !== null && hasLiveSubscription(status.status);
  const hadSubscription = status !== null && status.status !== 'none';

  const openPortal = () =>
    portal.mutate(undefined, {
      onError: (error) => toast.error(error),
    });

  return (
    <>
      {hadSubscription && (
        <SectionCard
          title="Manage billing"
          description={
            live
              ? 'Change plans, update the card, see invoices or cancel on Stripe’s secure page.'
              : 'See past invoices and billing details on Stripe’s secure page.'
          }
        >
          <div className="flex flex-col gap-3">
            {entitlement.state === 'past_due' && (
              <p className="text-warning-ink text-sm">
                Update the payment method there; Stripe retries the payment automatically.
              </p>
            )}
            <div>
              <Button
                variant="secondary"
                leadingIcon={<ExternalLink className="size-4" aria-hidden="true" />}
                loading={portal.isPending || portal.isSuccess}
                onClick={openPortal}
              >
                Manage billing
              </Button>
            </div>
          </div>
        </SectionCard>
      )}
      {!statusLoading && !live && <PlanPicker entitlement={entitlement} status={status} />}
    </>
  );
}

function PlanPicker({
  entitlement,
  status,
}: {
  entitlement: Entitlement;
  status: ShopBilling | null;
}) {
  const { shopId } = useShop();
  const toast = useToast();
  const plans = useBillingPlans();
  const checkout = useStartCheckout(shopId);
  const refresh = useRefreshBilling(shopId);
  const [pending, setPending] = useState<string | null>(null);

  const choose = (plan: BillingPlan) => {
    setPending(plan.id);
    checkout.mutate(plan.id, {
      // The server's own sentence (e.g. already subscribed, a plan no longer
      // offered, the billing account just set up by another request: try
      // again). Re-read the plans and the standing it may have changed.
      onError: (error) => {
        setPending(null);
        toast.error(error);
        void plans.refetch();
        void refresh();
      },
    });
  };

  const inTrial = entitlement.state === 'trialing' && entitlement.reason === 'trial';

  return (
    <SectionCard
      title="Choose a plan"
      description={
        inTrial
          ? 'Choosing a plan during the trial keeps the rest of it: the first payment is due when the trial ends (with less than two days left, the subscription starts right away).'
          : 'You pay on Stripe’s secure checkout page. Card details never touch this app.'
      }
    >
      {plans.isPending ? (
        <LoadingState variant="rows" rows={2} label="Loading plans…" />
      ) : plans.isError ? (
        <ErrorState
          compact
          title="Couldn’t load the plans"
          error={plans.error}
          onRetry={() => void plans.refetch()}
          retrying={plans.isRefetching}
        />
      ) : plans.data.length === 0 ? (
        <EmptyState
          compact
          icon={<CreditCard aria-hidden="true" />}
          title="No plans are available yet"
          description="Check back soon."
        />
      ) : (
        <ul aria-label="Plans" className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          {plans.data.map((plan) => (
            <li key={plan.id}>
              <PlanCard
                plan={plan}
                current={status?.plan_id === plan.id}
                action={
                  <Button
                    variant="money"
                    className="w-full"
                    loading={pending === plan.id}
                    disabled={pending !== null}
                    onClick={() => choose(plan)}
                    aria-label={`Choose ${plan.name}, ${planPriceText(plan)}`}
                  >
                    Choose plan
                  </Button>
                }
              />
            </li>
          ))}
        </ul>
      )}
    </SectionCard>
  );
}
