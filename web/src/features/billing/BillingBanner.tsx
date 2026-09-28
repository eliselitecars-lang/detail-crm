import { CircleAlert, Clock, X } from 'lucide-react';
import { useState } from 'react';
import { Link, useLocation } from 'react-router';
import { IconButton } from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { cn } from '@/lib/cn';
import { formatDate } from '@/lib/dates';
import { useShopEntitlement } from './api';
import {
  BILLING_PATH,
  billingBanner,
  daysLeftText,
  GO_TO_BILLING,
  LAPSED_BANNER_DETAIL,
  LAPSED_MESSAGE,
  PAST_DUE_MESSAGE,
  type BillingBannerKind,
} from './model';

const DISMISS_KEY = 'detailcrm.billingBanner.dismissed';

function readDismissed(): string[] {
  try {
    const raw = window.sessionStorage.getItem(DISMISS_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed.filter((v): v is string => typeof v === 'string') : [];
  } catch {
    return [];
  }
}

function writeDismissed(keys: string[]) {
  try {
    window.sessionStorage.setItem(DISMISS_KEY, JSON.stringify(keys));
  } catch {
    // storage unavailable: dismissed until reload
  }
}

/**
 * The shop's subscription standing above every staff page (from
 * shop_entitlement): the owner's trial ending soon and a payment problem
 * (both dismissible for the browser session), and — for everyone, not
 * dismissible — a lapsed shop. Nothing while billing is off, active or
 * comped, or while the standing can't be read. It never blocks the page:
 * reading data keeps working.
 */
export function BillingBanner() {
  const { shopId, role, timezone } = useShop();
  const { pathname } = useLocation();
  const entitlement = useShopEntitlement(shopId);
  const [dismissed, setDismissed] = useState(readDismissed);
  const banner = billingBanner(entitlement.data, role, timezone);
  // Settings > Billing shows the same standing in full.
  if (!banner || pathname.startsWith(BILLING_PATH)) return null;
  const dismissKey = `${shopId}:${banner.kind}`;
  if (banner.kind !== 'lapsed' && dismissed.includes(dismissKey)) return null;

  const owner = role === 'owner';
  const trialEnd = entitlement.data?.trial_ends_at ?? null;
  const dismiss = () => {
    const next = [...dismissed, dismissKey];
    setDismissed(next);
    writeDismissed(next);
  };

  const tone: Record<BillingBannerKind, string> = {
    trial_ending: 'border-primary/25 bg-primary-soft text-primary-ink',
    past_due: 'border-warning/30 bg-warning-soft text-warning-ink',
    lapsed: 'border-danger/25 bg-danger-soft text-danger-ink',
  };

  let text: string;
  if (banner.kind === 'trial_ending') {
    text = `This shop’s trial ends ${daysLeftText(banner.days ?? 0)}${
      trialEnd ? ` (${formatDate(trialEnd, timezone)})` : ''
    }. Choose a plan to keep creating new work.`;
  } else if (banner.kind === 'past_due') {
    text = PAST_DUE_MESSAGE;
  } else {
    text = `${LAPSED_MESSAGE} ${LAPSED_BANNER_DETAIL}`;
  }

  return (
    <div
      role={banner.kind === 'lapsed' ? 'alert' : 'status'}
      aria-label="Subscription notice"
      className={cn(
        'rounded-card mb-4 flex items-start gap-3 border px-3 py-2.5 text-sm sm:px-4',
        tone[banner.kind],
      )}
    >
      {banner.kind === 'trial_ending' ? (
        <Clock className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
      ) : (
        <CircleAlert className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
      )}
      <p className="min-w-0 flex-1">
        {text}{' '}
        {owner ? (
          <Link to={BILLING_PATH} className="font-medium whitespace-nowrap underline">
            {GO_TO_BILLING}
          </Link>
        ) : (
          <span className="font-medium">Ask the shop owner to renew it.</span>
        )}
      </p>
      {banner.kind !== 'lapsed' && (
        <IconButton
          size="sm"
          label="Dismiss for now"
          icon={<X />}
          className="-my-1 -mr-1 text-current"
          onClick={dismiss}
        />
      )}
    </div>
  );
}
