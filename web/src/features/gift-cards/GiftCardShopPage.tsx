import { CreditCard, Gift } from 'lucide-react';
import { useState } from 'react';
import { useParams, useSearchParams } from 'react-router';
import { PublicLayout } from '@/components/layout/PublicLayout';
import {
  Button,
  Card,
  Checkbox,
  EmptyState,
  FormField,
  Input,
  MoneyInput,
  RadioGroup,
  SectionCard,
  Textarea,
} from '@/components/ui';
import { errorMessage, toAppError } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import { newRequestNonce } from '@/features/quotes/shared/format';
import { Banner, PublicError, PublicLoading } from '@/features/public-docs/shared/PublicPage';
import { toBranding } from '@/features/public-docs/shared/schemas';
import {
  expiryText,
  useGiftCheckout,
  useGiftShop,
  type GiftChoice,
  type GiftShop,
} from './publicApi';

const SLUG_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const CUSTOM = 'custom';

/** /gift/:slug — buy a gift card from the shop (paid on Stripe Checkout). */
export default function GiftCardShopPage() {
  const { slug = '' } = useParams();
  const normalized = slug.trim().toLowerCase();
  if (!SLUG_RE.test(normalized)) return <PublicError error={null} what="page" />;
  return <GiftShopView slug={normalized} />;
}

function GiftShopView({ slug }: { slug: string }) {
  const query = useGiftShop(slug);
  if (query.isPending) return <PublicLoading label="Loading gift cards…" />;
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
  return <GiftShopContent slug={slug} shop={query.data} />;
}

function GiftShopContent({ slug, shop }: { slug: string; shop: GiftShop }) {
  const [params] = useSearchParams();
  const canceled = params.get('canceled') === '1';
  const branding = toBranding(shop.shop);
  const currency = shop.currency;

  return (
    <PublicLayout shop={branding}>
      <div className="flex flex-col gap-4 sm:gap-5">
        <div>
          <h1 className="text-ink text-xl font-semibold sm:text-2xl">Gift cards</h1>
          <p className="text-muted mt-1 text-sm">
            Give a {shop.shop.name} gift card. It’s emailed to the recipient as soon as your payment
            goes through.
          </p>
        </div>
        {canceled && (
          <Banner tone="info" title="Checkout cancelled">
            You weren’t charged.
          </Banner>
        )}
        {!shop.enabled ? (
          <Card>
            <EmptyState
              icon={<Gift aria-hidden="true" />}
              title="Gift cards aren’t sold online right now"
              description={`Contact ${shop.shop.name} to buy one.`}
            />
          </Card>
        ) : (
          <GiftForm slug={slug} shop={shop} currency={currency} />
        )}
      </div>
    </PublicLayout>
  );
}

interface Draft {
  choice: string;
  custom: number | null;
  buyerName: string;
  buyerEmail: string;
  forMe: boolean;
  recipientName: string;
  recipientEmail: string;
  message: string;
  agree: boolean;
}

function GiftForm({ slug, shop, currency }: { slug: string; shop: GiftShop; currency: string }) {
  const checkout = useGiftCheckout(slug);
  const [draft, setDraft] = useState<Draft>({
    choice: shop.offers.length > 0 ? '0' : CUSTOM,
    custom: null,
    buyerName: '',
    buyerEmail: '',
    forMe: false,
    recipientName: '',
    recipientEmail: '',
    message: '',
    agree: false,
  });
  const [submitted, setSubmitted] = useState(false);
  const [nonce, setNonce] = useState(newRequestNonce);
  const min = shop.min_custom_cents ?? 0;
  const max = shop.max_custom_cents ?? 0;
  const set = <K extends keyof Draft>(key: K, value: Draft[K]) =>
    setDraft((prev) => ({ ...prev, [key]: value }));

  const choiceOf = (d: Draft): GiftChoice | null => {
    if (d.choice === CUSTOM) return d.custom !== null ? { amountCents: d.custom } : null;
    const index = Number(d.choice);
    return Number.isInteger(index) && shop.offers[index] ? { offerIndex: index } : null;
  };

  const problems = (d: Draft): Partial<Record<keyof Draft, string>> => {
    const out: Partial<Record<keyof Draft, string>> = {};
    if (d.choice === CUSTOM) {
      if (d.custom === null) out.custom = 'Enter an amount.';
      else if (d.custom < min || d.custom > max) {
        out.custom = `Choose an amount from ${formatCents(min, { currency })} to ${formatCents(max, { currency })}.`;
      }
    }
    if (!d.buyerName.trim()) out.buyerName = 'Enter your name.';
    else if (d.buyerName.trim().length > 120) out.buyerName = 'Use 120 characters or fewer.';
    if (!EMAIL_RE.test(d.buyerEmail.trim())) out.buyerEmail = 'Enter a valid email address.';
    if (!d.forMe) {
      if (!EMAIL_RE.test(d.recipientEmail.trim())) {
        out.recipientEmail = 'Enter the recipient’s email address.';
      }
      if (d.recipientName.trim().length > 120) out.recipientName = 'Use 120 characters or fewer.';
    }
    if (d.message.length > 500) out.message = 'Use 500 characters or fewer.';
    if (shop.terms && !d.agree) out.agree = 'Accept the gift card terms to continue.';
    return out;
  };

  const errors = submitted ? problems(draft) : {};
  const choice = choiceOf(draft);
  const offer = choice && 'offerIndex' in choice ? shop.offers[choice.offerIndex] : undefined;
  const priceCents = offer ? offer.price_cents : draft.choice === CUSTOM ? draft.custom : null;

  const submit = () => {
    setSubmitted(true);
    const selected = choiceOf(draft);
    if (!selected || Object.keys(problems(draft)).length > 0) return;
    const recipientName = draft.forMe ? draft.buyerName.trim() : draft.recipientName.trim();
    const recipientEmail = (draft.forMe ? draft.buyerEmail : draft.recipientEmail)
      .trim()
      .toLowerCase();
    checkout.mutate(
      {
        choice: selected,
        requestNonce: nonce,
        purchaser: { name: draft.buyerName.trim(), email: draft.buyerEmail.trim().toLowerCase() },
        recipient: {
          email: recipientEmail,
          ...(recipientName ? { name: recipientName } : {}),
          ...(draft.message.trim() ? { message: draft.message.trim() } : {}),
        },
      },
      {
        onError: (error) => {
          const kind = toAppError(error).kind;
          if (kind !== 'network' && kind !== 'server') setNonce(newRequestNonce());
        },
      },
    );
  };

  const options = [
    ...shop.offers.map((o, index) => ({
      value: String(index),
      label: formatCents(o.value_cents, { currency }),
      ...(o.price_cents < o.value_cents
        ? { description: `for ${formatCents(o.price_cents, { currency })}` }
        : {}),
    })),
    ...(shop.allow_custom_amount ? [{ value: CUSTOM, label: 'Other amount' }] : []),
  ];

  return (
    <SectionCard title="Choose a gift card">
      <form
        noValidate
        className="flex flex-col gap-5"
        onSubmit={(event) => {
          event.preventDefault();
          submit();
        }}
      >
        {options.length > 1 && (
          <RadioGroup<string>
            label="Amount"
            value={draft.choice}
            onChange={(value) => set('choice', value)}
            variant="cards"
            orientation="horizontal"
            className="[&>div]:grid-cols-2 [&>div]:sm:grid-cols-4"
            options={options}
          />
        )}
        {draft.choice === CUSTOM && (
          <FormField
            label={options.length > 1 ? 'Your amount' : 'Amount'}
            required
            error={errors.custom}
            help={`From ${formatCents(min, { currency })} to ${formatCents(max, { currency })}.`}
          >
            <MoneyInput value={draft.custom} onChange={(v) => set('custom', v)} maxCents={max} />
          </FormField>
        )}

        <fieldset className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <legend className="text-ink mb-2 text-sm font-medium">From</legend>
          <FormField label="Your name" required error={errors.buyerName}>
            <Input
              value={draft.buyerName}
              autoComplete="name"
              maxLength={140}
              onChange={(e) => set('buyerName', e.target.value)}
            />
          </FormField>
          <FormField label="Your email" required error={errors.buyerEmail} help="For your receipt.">
            <Input
              type="email"
              value={draft.buyerEmail}
              autoComplete="email"
              maxLength={254}
              onChange={(e) => set('buyerEmail', e.target.value)}
            />
          </FormField>
        </fieldset>

        <fieldset className="flex flex-col gap-4">
          <legend className="text-ink mb-2 text-sm font-medium">To</legend>
          <Checkbox
            label="It’s for me"
            checked={draft.forMe}
            onChange={(e) => set('forMe', e.target.checked)}
          />
          {!draft.forMe && (
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <FormField label="Recipient’s name" error={errors.recipientName}>
                <Input
                  value={draft.recipientName}
                  maxLength={140}
                  onChange={(e) => set('recipientName', e.target.value)}
                />
              </FormField>
              <FormField
                label="Recipient’s email"
                required
                error={errors.recipientEmail}
                help="The gift card code is sent here."
              >
                <Input
                  type="email"
                  value={draft.recipientEmail}
                  maxLength={254}
                  onChange={(e) => set('recipientEmail', e.target.value)}
                />
              </FormField>
            </div>
          )}
          <FormField label="Message (optional)" error={errors.message}>
            <Textarea
              rows={3}
              value={draft.message}
              maxLength={520}
              onChange={(e) => set('message', e.target.value)}
            />
          </FormField>
        </fieldset>

        <div className="text-muted flex flex-col gap-1 text-xs">
          <p>{expiryText(shop.expires_months)}</p>
          <p>
            Your email and the recipient’s are shared with {shop.shop.name} to deliver the card and
            send your receipt. You won’t be signed up for marketing.
          </p>
        </div>
        {shop.terms && (
          <div className="border-line rounded-control flex flex-col gap-2 border p-3">
            <p className="text-ink text-sm font-medium">Gift card terms</p>
            <p className="text-muted max-h-40 overflow-y-auto text-xs whitespace-pre-line">
              {shop.terms}
            </p>
            <Checkbox
              label="I accept the gift card terms"
              checked={draft.agree}
              onChange={(e) => set('agree', e.target.checked)}
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
        <Button
          type="submit"
          variant="money"
          size="lg"
          fullWidth
          loading={checkout.isPending || checkout.isSuccess}
          leadingIcon={<CreditCard className="size-4" aria-hidden="true" />}
        >
          {priceCents ? `Pay ${formatCents(priceCents, { currency })}` : 'Continue to payment'}
        </Button>
      </form>
    </SectionCard>
  );
}
