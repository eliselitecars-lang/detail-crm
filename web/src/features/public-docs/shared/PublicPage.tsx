import { CircleAlert, CircleCheck, Info, SearchX, TriangleAlert } from 'lucide-react';
import type { ReactNode } from 'react';
import { PublicLayout, type PublicShopBranding } from '@/components/layout/PublicLayout';
import { Card, EmptyState, ErrorState, LoadingState } from '@/components/ui';
import { cn } from '@/lib/cn';
import { toAppError } from '@/lib/errors';

/** Loading frame for a public page (branding unknown yet). */
export function PublicLoading({ label, width }: { label: string; width?: 'narrow' | 'wide' }) {
  return (
    <PublicLayout shop={null} {...(width ? { width } : {})}>
      <Card>
        <LoadingState label={label} />
      </Card>
    </PublicLayout>
  );
}

/**
 * Error frame for a public page. A missing / malformed link gets a calm
 * "not found" explanation instead of a retry loop.
 */
export function PublicError({
  error,
  what,
  onRetry,
  retrying,
  shop = null,
  width,
}: {
  error: unknown;
  /** "booking", "quote", … */
  what: string;
  onRetry?: () => void;
  retrying?: boolean;
  shop?: PublicShopBranding | null;
  width?: 'narrow' | 'wide';
}) {
  const kind = error === null ? 'not_found' : toAppError(error).kind;
  return (
    <PublicLayout shop={shop} {...(width ? { width } : {})}>
      <Card>
        {kind === 'not_found' ? (
          <EmptyState
            icon={<SearchX aria-hidden="true" />}
            title={`We couldn’t find this ${what}`}
            description="The link may be incomplete or no longer valid. Check the link you were sent, or contact the shop."
          />
        ) : (
          <ErrorState
            error={error}
            title={`Couldn’t load this ${what}`}
            {...(onRetry ? { onRetry } : {})}
            retrying={retrying ?? false}
          />
        )}
      </Card>
    </PublicLayout>
  );
}

export type BannerTone = 'success' | 'info' | 'warning' | 'danger';

const bannerTones: Record<BannerTone, string> = {
  success: 'border-success/30 bg-success-soft text-success-ink',
  info: 'border-primary/25 bg-primary-soft text-primary-ink',
  warning: 'border-warning/30 bg-warning-soft text-warning-ink',
  danger: 'border-danger/30 bg-danger-soft text-danger-ink',
};

const bannerIcons: Record<BannerTone, ReactNode> = {
  success: <CircleCheck aria-hidden="true" className="size-5 shrink-0" />,
  info: <Info aria-hidden="true" className="size-5 shrink-0" />,
  warning: <TriangleAlert aria-hidden="true" className="size-5 shrink-0" />,
  danger: <CircleAlert aria-hidden="true" className="size-5 shrink-0" />,
};

/** Inline notice ("Payment received", "Cancelled"…). Announced politely. */
export function Banner({
  tone,
  title,
  children,
  action,
  className,
}: {
  tone: BannerTone;
  title: ReactNode;
  children?: ReactNode;
  action?: ReactNode;
  className?: string;
}) {
  return (
    <div
      role={tone === 'danger' ? 'alert' : 'status'}
      className={cn(
        'rounded-card flex gap-3 border px-4 py-3 print:hidden',
        bannerTones[tone],
        className,
      )}
    >
      {bannerIcons[tone]}
      <div className="min-w-0 flex-1">
        <p className="text-sm font-semibold">{title}</p>
        {children && <div className="mt-0.5 text-sm">{children}</div>}
      </div>
      {action && <div className="shrink-0 self-center">{action}</div>}
    </div>
  );
}

/** Page title block used by every public document. */
export function DocumentTitle({
  title,
  subtitle,
  badge,
  actions,
}: {
  title: ReactNode;
  subtitle?: ReactNode;
  badge?: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div className="min-w-0">
        <div className="flex flex-wrap items-center gap-2">
          <h1 className="text-ink text-xl font-semibold sm:text-2xl">{title}</h1>
          {badge}
        </div>
        {subtitle && <p className="text-muted mt-1 text-sm">{subtitle}</p>}
      </div>
      {actions && <div className="flex shrink-0 flex-wrap gap-2 print:hidden">{actions}</div>}
    </div>
  );
}
