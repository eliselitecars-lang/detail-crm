import { CircleAlert, Inbox, RefreshCw } from 'lucide-react';
import type { ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { errorMessage } from '@/lib/errors';
import { Button } from './Button';
import { SkeletonRows } from './Skeleton';
import { Spinner } from './Spinner';

export interface EmptyStateProps {
  title: ReactNode;
  description?: ReactNode;
  icon?: ReactNode;
  action?: ReactNode;
  className?: string;
  /** Smaller padding for use inside cards. */
  compact?: boolean;
}

export function EmptyState({
  title,
  description,
  icon,
  action,
  className,
  compact = false,
}: EmptyStateProps) {
  return (
    <div
      className={cn(
        'flex flex-col items-center justify-center text-center',
        compact ? 'gap-2 px-4 py-8' : 'gap-3 px-6 py-14',
        className,
      )}
    >
      <div className="bg-surface-2 text-muted flex size-11 items-center justify-center rounded-full [&_svg]:size-5">
        {icon ?? <Inbox aria-hidden="true" />}
      </div>
      <div className="max-w-sm">
        <p className="text-ink text-sm font-semibold">{title}</p>
        {description && <p className="text-muted mt-1 text-sm">{description}</p>}
      </div>
      {action && <div className="mt-1">{action}</div>}
    </div>
  );
}

export interface ErrorStateProps {
  /** Any thrown value — mapped to a friendly message via lib/errors. */
  error?: unknown;
  title?: ReactNode;
  onRetry?: () => void;
  retrying?: boolean;
  className?: string;
  compact?: boolean;
}

export function ErrorState({
  error,
  title = 'Couldn’t load this',
  onRetry,
  retrying = false,
  className,
  compact = false,
}: ErrorStateProps) {
  return (
    <div
      role="alert"
      className={cn(
        'flex flex-col items-center justify-center text-center',
        compact ? 'gap-2 px-4 py-8' : 'gap-3 px-6 py-14',
        className,
      )}
    >
      <div className="bg-danger-soft text-danger flex size-11 items-center justify-center rounded-full [&_svg]:size-5">
        <CircleAlert aria-hidden="true" />
      </div>
      <div className="max-w-sm">
        <p className="text-ink text-sm font-semibold">{title}</p>
        <p className="text-muted mt-1 text-sm">
          {error === undefined ? 'Please try again.' : errorMessage(error)}
        </p>
      </div>
      {onRetry && (
        <Button
          variant="secondary"
          size="sm"
          loading={retrying}
          leadingIcon={<RefreshCw className="size-4" aria-hidden="true" />}
          onClick={onRetry}
        >
          Try again
        </Button>
      )}
    </div>
  );
}

export interface LoadingStateProps {
  label?: string;
  /** "spinner" (default) or "rows" skeleton for lists. */
  variant?: 'spinner' | 'rows';
  rows?: number;
  /** Fill the viewport (app boot, route transitions). */
  fullScreen?: boolean;
  className?: string;
}

export function LoadingState({
  label = 'Loading…',
  variant = 'spinner',
  rows,
  fullScreen = false,
  className,
}: LoadingStateProps) {
  return (
    <div
      role="status"
      aria-live="polite"
      aria-busy="true"
      className={cn(
        variant === 'spinner' &&
          'text-muted flex items-center justify-center gap-2.5 px-6 py-14 text-sm',
        fullScreen && 'min-h-dvh',
        className,
      )}
    >
      {variant === 'rows' ? (
        <>
          <span className="sr-only">{label}</span>
          <SkeletonRows {...(rows !== undefined ? { rows } : {})} />
        </>
      ) : (
        <>
          <Spinner className="text-primary size-5" />
          <span>{label}</span>
        </>
      )}
    </div>
  );
}
