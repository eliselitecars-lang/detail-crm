import { Gift, RefreshCw } from 'lucide-react';
import { useQueryClient } from '@tanstack/react-query';
import { Link, useParams, useSearchParams } from 'react-router';
import { PublicLayout } from '@/components/layout/PublicLayout';
import { Button, buttonClasses, Card, EmptyState } from '@/components/ui';
import { formatCents } from '@/lib/money';
import { publicKey } from '@/lib/queryKeys';
import { Banner, PublicError, PublicLoading } from '@/features/public-docs/shared/PublicPage';
import { isLinkToken } from '@/features/public-docs/shared/schemas';
import { ORDER_POLL_ATTEMPTS, useGiftOrderStatus, useGiftShop } from './publicApi';

/** /gift/:slug/done?order=<token> — after paying on Stripe Checkout. */
export default function GiftCardOrderDonePage() {
  const { slug = '' } = useParams();
  const [params] = useSearchParams();
  const token = params.get('order') ?? undefined;
  if (!isLinkToken(token)) return <PublicError error={null} what="gift card order" />;
  return <OrderView slug={slug.trim().toLowerCase()} token={token} />;
}

function OrderView({ slug, token }: { slug: string; token: string }) {
  const queryClient = useQueryClient();
  const order = useGiftOrderStatus(token);
  // Branding and the shop's currency: the order page works without it.
  const shop = useGiftShop(slug);
  const branding = shop.data
    ? {
        name: shop.data.shop.name,
        logoPath: shop.data.shop.logo_path,
        brandColor: shop.data.shop.brand_color,
      }
    : null;
  // The order status carries no currency; only the shop's offer does. Never
  // guess one (a non-USD shop's card must not read "$50.00"): wait for the
  // shop, and if it can't be loaded, leave the amount out.
  const currency = shop.data?.currency ?? null;

  if (order.isPending || shop.isPending) return <PublicLoading label="Checking your order…" />;
  if (order.isError) {
    return (
      <PublicError
        error={order.error}
        what="gift card order"
        shop={branding}
        onRetry={() => void order.refetch()}
        retrying={order.isFetching}
      />
    );
  }
  const data = order.data;
  const stillPending = data.status === 'pending';
  // Polling stops after ORDER_POLL_ATTEMPTS loads; then the visitor can check by hand.
  const loads = queryClient.getQueryState(publicKey('gift-order', token))?.dataUpdateCount ?? 0;
  const gaveUp = stillPending && loads >= ORDER_POLL_ATTEMPTS;
  const recipient = data.recipient_name ?? 'the recipient';

  return (
    <PublicLayout shop={branding} title="Gift card order">
      <Card padded className="flex flex-col gap-4">
        {data.status === 'paid' && (
          <EmptyState
            icon={<Gift aria-hidden="true" />}
            title="Thank you — your gift card is on its way"
            description={`A ${
              currency ? `${formatCents(data.value_cents, { currency })} ` : ''
            }gift card${data.last4 ? ` (ending ${data.last4})` : ''} is being emailed to ${recipient}.`}
          />
        )}
        {stillPending && (
          <Banner
            tone="info"
            title="Confirming your payment…"
            action={
              gaveUp ? (
                <Button
                  size="sm"
                  variant="secondary"
                  loading={order.isFetching}
                  leadingIcon={<RefreshCw className="size-4" aria-hidden="true" />}
                  onClick={() => void order.refetch()}
                >
                  Check again
                </Button>
              ) : undefined
            }
          >
            This usually takes a few seconds. You don’t need to pay again. The card is emailed once
            the payment is confirmed.
          </Banner>
        )}
        {data.status === 'refunded' && (
          <Banner tone="info" title="This order was refunded">
            The gift card was cancelled and your payment refunded.
          </Banner>
        )}
        {data.status === 'expired' && (
          <Banner tone="warning" title="This order wasn’t completed">
            The payment wasn’t finished, so no gift card was issued and you weren’t charged.
          </Banner>
        )}
        {slug && (
          <Link
            to={`/gift/${encodeURIComponent(slug)}`}
            className={buttonClasses({ variant: 'secondary', className: 'self-start' })}
          >
            Buy another gift card
          </Link>
        )}
      </Card>
    </PublicLayout>
  );
}
