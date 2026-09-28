import { use } from 'react';
import { Link } from 'react-router';
import { ShopContext } from '@/features/shop/shopContext';
import { cn } from '@/lib/cn';
import { isSubscriptionError } from '@/lib/errors';
import { BILLING_PATH, GO_TO_BILLING } from './model';

/**
 * Next to a subscription refusal (PT402 / HTTP 402, shown with the server's
 * own neutral text): owners get a link to Settings > Billing. Everyone else
 * sees only the server's message. Renders nothing for any other error.
 */
export function BillingErrorLink({ error, className }: { error: unknown; className?: string }) {
  const shop = use(ShopContext);
  if (error === null || error === undefined) return null;
  if (shop?.membership?.role !== 'owner' || !isSubscriptionError(error)) return null;
  return (
    <Link
      to={BILLING_PATH}
      className={cn('text-primary-ink ml-1 font-medium whitespace-nowrap underline', className)}
    >
      {GO_TO_BILLING}
    </Link>
  );
}
