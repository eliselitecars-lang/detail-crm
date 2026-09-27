import type { ComponentProps, ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { Spinner } from './Spinner';

export interface IconButtonProps extends Omit<ComponentProps<'button'>, 'children'> {
  /** Required accessible name (also used as the native tooltip). */
  label: string;
  icon: ReactNode;
  variant?: 'ghost' | 'secondary' | 'primary' | 'danger';
  size?: 'sm' | 'md' | 'lg';
  loading?: boolean;
}

const variants = {
  ghost: 'text-muted hover:bg-surface-2 hover:text-ink',
  secondary: 'border border-line-strong bg-surface text-ink hover:bg-surface-2',
  primary: 'bg-primary text-primary-fg hover:bg-primary-hover',
  danger: 'text-danger-ink hover:bg-danger-soft',
} as const;

const sizes = { sm: 'size-8', md: 'size-9', lg: 'size-11' } as const;

export function IconButton({
  label,
  icon,
  variant = 'ghost',
  size = 'md',
  loading = false,
  className,
  disabled,
  type = 'button',
  title,
  ref,
  ...rest
}: IconButtonProps) {
  return (
    <button
      ref={ref}
      type={type}
      aria-label={label}
      title={title ?? label}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      className={cn(
        'rounded-control focus-visible:outline-primary inline-flex shrink-0 items-center justify-center transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 disabled:cursor-not-allowed disabled:opacity-55 [&_svg]:size-[18px]',
        variants[variant],
        sizes[size],
        className,
      )}
      {...rest}
    >
      {loading ? <Spinner /> : icon}
    </button>
  );
}
