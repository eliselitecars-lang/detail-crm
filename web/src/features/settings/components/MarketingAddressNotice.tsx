import { CircleAlert } from 'lucide-react';
import type { ReactNode } from 'react';
import { Link } from 'react-router';
import { useCan } from '@/features/shop/useCan';
import { cn } from '@/lib/cn';
import { BUSINESS_PROFILE_PATH, MAILING_ADDRESS_REQUIRED } from '../marketingAddress';

/**
 * Marketing emails that are switched on but not sent because the shop has no
 * mailing address on file (0119). Owners and admins get the link to add it.
 */
export function MarketingAddressNotice({
  children,
  className,
}: {
  /** What isn't being sent, e.g. "Rebooking follow-up emails aren’t being sent." */
  children: ReactNode;
  className?: string;
}) {
  const canEditBusiness = useCan('settings.manage');
  return (
    <div
      role="status"
      aria-label="Marketing email needs your mailing address"
      className={cn(
        'rounded-card border-warning/30 bg-warning-soft text-warning-ink flex items-start gap-3 border px-3 py-2.5 text-sm sm:px-4',
        className,
      )}
    >
      <CircleAlert className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
      <p className="min-w-0 flex-1">
        {children} {MAILING_ADDRESS_REQUIRED}{' '}
        {canEditBusiness ? (
          <Link to={BUSINESS_PROFILE_PATH} className="font-medium whitespace-nowrap underline">
            Add the mailing address
          </Link>
        ) : (
          <span className="font-medium">
            Ask an owner or admin to add it in Settings → Business profile.
          </span>
        )}
      </p>
    </div>
  );
}
