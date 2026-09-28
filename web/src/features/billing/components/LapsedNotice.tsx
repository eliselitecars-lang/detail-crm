import { CircleAlert } from 'lucide-react';
import type { ReactNode } from 'react';
import { Link } from 'react-router';
import { useShop } from '@/features/shop/shopContext';
import { cn } from '@/lib/cn';
import { useShopLapsed } from '../api';
import { BILLING_PATH, GO_TO_BILLING, LAPSED_AUTOMATIONS, lapsedFeatureNotice } from '../model';

/**
 * A feature page's notice that the shop's lapse turned it off (lead forms,
 * online sales, automations), so staff don't keep sending customers to a
 * page that answers "not available". The owner gets the billing link.
 */
export function LapsedNotice({ children, className }: { children: ReactNode; className?: string }) {
  const { role } = useShop();
  return (
    <div
      role="status"
      aria-label="Paused while the subscription is inactive"
      className={cn(
        'rounded-card border-warning/30 bg-warning-soft text-warning-ink mb-4 flex items-start gap-3 border px-3 py-2.5 text-sm sm:px-4',
        className,
      )}
    >
      <CircleAlert className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
      <p className="min-w-0 flex-1">
        {children}{' '}
        {role === 'owner' ? (
          <Link to={BILLING_PATH} className="font-medium whitespace-nowrap underline">
            {GO_TO_BILLING}
          </Link>
        ) : (
          <span className="font-medium">Ask the shop owner to renew it.</span>
        )}
      </p>
    </div>
  );
}

/**
 * For the automation settings (templates, follow-ups): enqueue_due_automations
 * skips a lapsed shop, so scheduled messages stop even for existing jobs.
 * Renders nothing unless the shop is lapsed.
 */
export function LapsedAutomationsNotice() {
  const { shopId } = useShop();
  const lapsed = useShopLapsed(shopId);
  if (!lapsed) return null;
  return (
    <LapsedNotice className="mb-0">
      {LAPSED_AUTOMATIONS} Messages about existing work, such as job updates and receipts, still go
      out.
    </LapsedNotice>
  );
}

/**
 * lapsedFeatureNotice for a settings page of a public surface the lapse turns
 * off (online booking, online gift card sales). Nothing unless lapsed.
 */
export function LapsedFeatureNotice({ subject, plural }: { subject: string; plural?: boolean }) {
  const { shopId } = useShop();
  const lapsed = useShopLapsed(shopId);
  if (!lapsed) return null;
  return (
    <LapsedNotice className="mb-0">
      {lapsedFeatureNotice(subject, plural === undefined ? {} : { plural })}
    </LapsedNotice>
  );
}
