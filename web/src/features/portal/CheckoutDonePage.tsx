import { BadgeCheck, CreditCard } from 'lucide-react';
import { Link, useParams, useSearchParams } from 'react-router';
import { PublicLayout } from '@/components/layout/PublicLayout';
import { Card, EmptyState } from '@/components/ui';
import { formatPhone } from '@/lib/phone';
import { useShopProfile } from '@/features/booking/api';
import { Banner, PublicError, PublicLoading } from '@/features/public-docs/shared/PublicPage';
import { toBranding } from '@/features/public-docs/shared/schemas';
import { CUSTOMER_PORTAL_PATH } from './paths';
import { checkoutOutcome, returnNotice, type CheckoutOutcome } from './returnNotice';

const SLUG_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

/**
 * /done/:slug?card=saved|canceled and ?membership=active|canceled — where a
 * customer lands after a Stripe Checkout a staff member sent them (the
 * payments function's setup_card_link and membership_checkout). Public: the
 * recipient of a texted link usually has no account. Shows the shop
 * (public_shop_profile, branding only) and the outcome; nothing here reads
 * the customer's data.
 */
export default function CheckoutDonePage() {
  const { slug = '' } = useParams();
  const [params] = useSearchParams();
  const normalized = slug.trim().toLowerCase();
  const outcome = checkoutOutcome(params);
  if (!SLUG_RE.test(normalized) || outcome === null) {
    return <PublicError error={null} what="page" />;
  }
  return <DoneView slug={normalized} outcome={outcome} />;
}

function DoneView({ slug, outcome }: { slug: string; outcome: CheckoutOutcome }) {
  const profile = useShopProfile(slug);
  if (profile.isPending) return <PublicLoading label="Loading…" width="narrow" />;
  // Branding only: Stripe already finished, so the outcome shows without it.
  const shop = profile.data ?? null;
  const shopName = shop?.name ?? null;
  const notice = returnNotice(outcome.kind, outcome.value, shopName);
  if (notice === null) return <PublicError error={null} what="page" />;
  const done = outcome.value !== 'canceled';
  const contact = shop?.phone ? ` at ${formatPhone(shop.phone)}` : '';
  const who = shopName ?? 'the shop';

  return (
    <PublicLayout shop={shop ? toBranding(shop) : null} title={notice.title} width="narrow">
      <Card padded className="flex flex-col gap-4">
        <Banner tone={notice.tone} title={notice.title} />
        {done ? (
          <EmptyState
            icon={
              outcome.kind === 'card' ? (
                <CreditCard aria-hidden="true" />
              ) : (
                <BadgeCheck aria-hidden="true" />
              )
            }
            title="You’re all set"
            description={
              outcome.kind === 'card'
                ? `You can close this page. Your card details stay with Stripe; ${who} only sees the brand and last four digits.`
                : 'You can close this page.'
            }
          />
        ) : (
          <p className="text-muted text-sm">
            If you meant to finish, open the link you were sent again, or contact {who}
            {contact}.
          </p>
        )}
        {outcome.kind === 'membership' && done && (
          <p className="text-muted text-sm">
            To cancel or update your card later,{' '}
            <Link to={CUSTOMER_PORTAL_PATH} className="font-medium underline underline-offset-2">
              sign in to your account
            </Link>{' '}
            with the email you used at checkout.
          </p>
        )}
      </Card>
    </PublicLayout>
  );
}
