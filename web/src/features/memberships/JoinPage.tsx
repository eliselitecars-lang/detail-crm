import { BadgeCheck, CreditCard } from 'lucide-react';
import { useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router';
import { PublicLayout } from '@/components/layout/PublicLayout';
import {
  Badge,
  Button,
  Card,
  Checkbox,
  EmptyState,
  FormField,
  Input,
  SectionCard,
} from '@/components/ui';
import { errorMessage, toAppError } from '@/lib/errors';
import { formatBps, formatCents } from '@/lib/money';
import { normalizePhone } from '@/lib/phone';
import { Banner, PublicError, PublicLoading } from '@/features/public-docs/shared/PublicPage';
import { toBranding } from '@/features/public-docs/shared/schemas';
import { CUSTOMER_PORTAL_PATH } from '@/features/portal/paths';
import { billingLabel } from './api';
import {
  newRequestNonce,
  useJoinCheckout,
  usePublicMembershipPlans,
  type PublicPlan,
  type PublicPlans,
} from './publicApi';

const SLUG_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** /join/:slug — the shop's memberships sold online. */
export default function JoinPage() {
  const { slug = '' } = useParams();
  const normalized = slug.trim().toLowerCase();
  if (!SLUG_RE.test(normalized)) return <PublicError error={null} what="page" />;
  return <JoinView slug={normalized} />;
}

function JoinView({ slug }: { slug: string }) {
  const query = usePublicMembershipPlans(slug);
  if (query.isPending) return <PublicLoading label="Loading memberships…" />;
  if (query.isError) {
    return (
      <PublicError
        error={query.error}
        what="page"
        onRetry={() => void query.refetch()}
        retrying={query.isFetching}
      />
    );
  }
  return <JoinContent slug={slug} data={query.data} />;
}

function JoinContent({ slug, data }: { slug: string; data: PublicPlans }) {
  const [params] = useSearchParams();
  const joined = params.get('joined') === '1';
  const canceled = params.get('canceled') === '1';
  const [planId, setPlanId] = useState<string | null>(null);
  const plan = data.plans.find((p) => p.id === planId) ?? null;
  const branding = toBranding({ ...data.shop });

  return (
    <PublicLayout shop={branding} title="Memberships">
      <div className="flex flex-col gap-4 sm:gap-5">
        <div>
          <h1 className="text-ink text-xl font-semibold sm:text-2xl">Memberships</h1>
          <p className="text-muted mt-1 text-sm">
            Join a {data.shop.name} membership and pay by card.
          </p>
        </div>

        {joined && (
          <Banner tone="success" title="Welcome aboard!">
            Your payment went through and your membership is being set up. You’ll get a confirmation
            from {data.shop.name} shortly. To cancel or update your card later,{' '}
            <Link to={CUSTOMER_PORTAL_PATH} className="font-medium underline underline-offset-2">
              sign in to your account
            </Link>{' '}
            with the email you used at checkout.
          </Banner>
        )}
        {canceled && !joined && (
          <Banner tone="info" title="Checkout cancelled">
            You weren’t charged. Pick a plan whenever you’re ready.
          </Banner>
        )}

        {data.plans.length === 0 ? (
          <Card>
            <EmptyState
              icon={<BadgeCheck aria-hidden="true" />}
              title="No memberships are offered online right now"
              description={`Contact ${data.shop.name} to ask about memberships.`}
            />
          </Card>
        ) : (
          <ul aria-label="Membership plans" className="grid grid-cols-1 gap-3 md:grid-cols-2">
            {data.plans.map((p) => (
              <li key={p.id}>
                <PlanCard
                  plan={p}
                  currency={data.currency}
                  selected={p.id === planId}
                  onSelect={() => setPlanId(p.id)}
                />
              </li>
            ))}
          </ul>
        )}

        {plan && !joined && (
          <JoinForm key={plan.id} slug={slug} plan={plan} currency={data.currency} />
        )}
      </div>
    </PublicLayout>
  );
}

function PlanCard({
  plan,
  currency,
  selected,
  onSelect,
}: {
  plan: PublicPlan;
  currency: string;
  selected: boolean;
  onSelect: () => void;
}) {
  return (
    <Card
      padded
      className={
        selected ? 'ring-brand flex h-full flex-col gap-3 ring-2' : 'flex h-full flex-col gap-3'
      }
    >
      <div>
        <h2 className="text-ink text-base font-semibold">{plan.name}</h2>
        <p className="text-ink mt-1 text-lg font-semibold tabular-nums">
          {billingLabel(
            formatCents(plan.price_cents, { currency }),
            plan.interval,
            plan.interval_count,
          )}
        </p>
      </div>
      {plan.description && (
        <p className="text-muted text-sm whitespace-pre-line">{plan.description}</p>
      )}
      {plan.included_services.length > 0 && (
        <div>
          <p className="text-ink text-sm font-medium">
            Included
            {plan.uses_per_period !== null
              ? ` (${plan.uses_per_period} visit${plan.uses_per_period === 1 ? '' : 's'} per billing period)`
              : ''}
          </p>
          <ul className="text-muted mt-1 list-disc pl-5 text-sm">
            {plan.included_services.map((name) => (
              <li key={name}>{name}</li>
            ))}
          </ul>
        </div>
      )}
      {plan.discount_bps > 0 && (
        <p className="text-sm">
          <Badge tone="info">{formatBps(plan.discount_bps)} off</Badge>{' '}
          <span className="text-muted">other services</span>
        </p>
      )}
      <div className="mt-auto pt-1">
        <Button
          variant={selected ? 'primary' : 'secondary'}
          fullWidth
          aria-pressed={selected}
          onClick={onSelect}
        >
          {selected ? 'Selected' : `Choose ${plan.name}`}
        </Button>
      </div>
    </Card>
  );
}

interface Draft {
  firstName: string;
  lastName: string;
  email: string;
  phone: string;
  sms: boolean;
  emailOptIn: boolean;
  agree: boolean;
}

function validate(draft: Draft, hasTerms: boolean): Partial<Record<keyof Draft, string>> {
  const errors: Partial<Record<keyof Draft, string>> = {};
  if (!draft.firstName.trim()) errors.firstName = 'Enter your first name.';
  else if (draft.firstName.trim().length > 100) errors.firstName = 'Use 100 characters or fewer.';
  if (draft.lastName.trim().length > 100) errors.lastName = 'Use 100 characters or fewer.';
  if (!EMAIL_RE.test(draft.email.trim())) errors.email = 'Enter a valid email address.';
  if (draft.phone.trim() && normalizePhone(draft.phone) === null) {
    errors.phone = 'Enter a valid phone number.';
  }
  if (draft.sms && !draft.phone.trim()) errors.phone = 'Enter a phone number to get texts.';
  if (hasTerms && !draft.agree) errors.agree = 'Accept the membership terms to continue.';
  return errors;
}

function JoinForm({ slug, plan, currency }: { slug: string; plan: PublicPlan; currency: string }) {
  const checkout = useJoinCheckout(slug);
  const [draft, setDraft] = useState<Draft>({
    firstName: '',
    lastName: '',
    email: '',
    phone: '',
    sms: false,
    emailOptIn: false,
    agree: false,
  });
  const [submitted, setSubmitted] = useState(false);
  // One nonce per form: a retry after a network error reuses the open checkout.
  const [nonce, setNonce] = useState(newRequestNonce);
  const hasTerms = Boolean(plan.terms);
  const errors = submitted ? validate(draft, hasTerms) : {};

  const submit = () => {
    setSubmitted(true);
    if (Object.keys(validate(draft, hasTerms)).length > 0) return;
    const phone = draft.phone.trim() ? (normalizePhone(draft.phone) ?? draft.phone.trim()) : null;
    checkout.mutate(
      {
        planId: plan.id,
        requestNonce: nonce,
        customer: {
          first_name: draft.firstName.trim(),
          email: draft.email.trim().toLowerCase(),
          sms_opt_in: draft.sms,
          email_opt_in: draft.emailOptIn,
          ...(draft.lastName.trim() ? { last_name: draft.lastName.trim() } : {}),
          ...(phone ? { phone } : {}),
        },
      },
      {
        onError: (error) => {
          // A definitive refusal starts a fresh attempt next time.
          const kind = toAppError(error).kind;
          if (kind !== 'network' && kind !== 'server') setNonce(newRequestNonce());
        },
      },
    );
  };

  return (
    <SectionCard
      title={`Join ${plan.name}`}
      description="You’ll pay securely on Stripe’s checkout page."
    >
      <form
        noValidate
        className="flex flex-col gap-4"
        onSubmit={(event) => {
          event.preventDefault();
          submit();
        }}
      >
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <FormField label="First name" required error={errors.firstName}>
            <Input
              value={draft.firstName}
              autoComplete="given-name"
              maxLength={100}
              onChange={(e) => setDraft({ ...draft, firstName: e.target.value })}
            />
          </FormField>
          <FormField label="Last name" error={errors.lastName}>
            <Input
              value={draft.lastName}
              autoComplete="family-name"
              maxLength={100}
              onChange={(e) => setDraft({ ...draft, lastName: e.target.value })}
            />
          </FormField>
          <FormField label="Email" required error={errors.email}>
            <Input
              type="email"
              value={draft.email}
              autoComplete="email"
              maxLength={254}
              onChange={(e) => setDraft({ ...draft, email: e.target.value })}
            />
          </FormField>
          <FormField label="Mobile phone" error={errors.phone}>
            <Input
              type="tel"
              value={draft.phone}
              autoComplete="tel"
              maxLength={32}
              onChange={(e) => setDraft({ ...draft, phone: e.target.value })}
            />
          </FormField>
        </div>
        <div className="flex flex-col gap-2">
          <Checkbox
            label="Text me appointment updates and offers"
            description="Message and data rates may apply. Reply STOP to opt out."
            checked={draft.sms}
            onChange={(e) => setDraft({ ...draft, sms: e.target.checked })}
          />
          <Checkbox
            label="Email me offers and news"
            checked={draft.emailOptIn}
            onChange={(e) => setDraft({ ...draft, emailOptIn: e.target.checked })}
          />
        </div>
        {plan.terms && (
          <div className="border-line rounded-control flex flex-col gap-2 border p-3">
            <p className="text-ink text-sm font-medium">Membership terms</p>
            <p className="text-muted max-h-40 overflow-y-auto text-xs whitespace-pre-line">
              {plan.terms}
            </p>
            <Checkbox
              label="I accept the membership terms"
              checked={draft.agree}
              onChange={(e) => setDraft({ ...draft, agree: e.target.checked })}
            />
            {errors.agree && (
              <p role="alert" className="text-danger-ink text-xs font-medium">
                {errors.agree}
              </p>
            )}
          </div>
        )}
        {checkout.isError && (
          <Banner tone="danger" title="Couldn’t start checkout">
            {errorMessage(checkout.error)}
          </Banner>
        )}
        <p className="text-muted text-xs">
          Your card is charged{' '}
          {billingLabel(
            formatCents(plan.price_cents, { currency }),
            plan.interval,
            plan.interval_count,
          )}{' '}
          until you cancel. Cancel or update your card any time from{' '}
          <Link to={CUSTOMER_PORTAL_PATH} className="text-primary-ink hover:underline">
            your account
          </Link>
          . Card details are handled by Stripe and never stored by the shop.
        </p>
        <Button
          type="submit"
          variant="money"
          size="lg"
          fullWidth
          loading={checkout.isPending || checkout.isSuccess}
          leadingIcon={<CreditCard className="size-4" aria-hidden="true" />}
        >
          Continue to payment
        </Button>
      </form>
    </SectionCard>
  );
}
