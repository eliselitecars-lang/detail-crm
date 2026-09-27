import type { ComponentProps, ReactNode } from 'react';
import { cn } from '@/lib/cn';

export interface CardProps extends ComponentProps<'div'> {
  /** Adds default inner padding. */
  padded?: boolean;
  /** Renders as <section> (use when the card has a heading). */
  as?: 'div' | 'section' | 'article';
}

export function Card({ padded = false, as: Tag = 'div', className, ...props }: CardProps) {
  return (
    <Tag
      className={cn(
        'rounded-card border-line bg-surface shadow-card border',
        padded && 'p-4 sm:p-5',
        className,
      )}
      {...props}
    />
  );
}

export interface CardHeaderProps {
  title: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
  /** Heading level for document outline (default h2). */
  level?: 2 | 3;
  className?: string;
  id?: string;
}

export function CardHeader({
  title,
  description,
  actions,
  level = 2,
  className,
  id,
}: CardHeaderProps) {
  const Heading = level === 2 ? 'h2' : 'h3';
  return (
    <div
      className={cn(
        'border-line flex flex-wrap items-start justify-between gap-3 border-b px-4 py-3 sm:px-5',
        className,
      )}
    >
      <div className="min-w-0">
        <Heading id={id} className="text-ink text-sm font-semibold">
          {title}
        </Heading>
        {description && <p className="text-muted mt-0.5 text-xs">{description}</p>}
      </div>
      {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
    </div>
  );
}

export function CardBody({ className, ...props }: ComponentProps<'div'>) {
  return <div className={cn('px-4 py-4 sm:px-5', className)} {...props} />;
}

export function CardFooter({ className, ...props }: ComponentProps<'div'>) {
  return (
    <div
      className={cn(
        'border-line flex flex-wrap items-center justify-end gap-2 border-t px-4 py-3 sm:px-5',
        className,
      )}
      {...props}
    />
  );
}
