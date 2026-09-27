import type { ReactNode } from 'react';
import { cn } from '@/lib/cn';

export type BadgeTone = 'neutral' | 'info' | 'success' | 'warning' | 'danger' | 'money';

const tones: Record<BadgeTone, string> = {
  neutral: 'bg-surface-2 text-muted ring-line',
  info: 'bg-primary-soft text-primary-ink ring-primary/25',
  success: 'bg-success-soft text-success-ink ring-success/25',
  warning: 'bg-warning-soft text-warning-ink ring-warning/25',
  danger: 'bg-danger-soft text-danger-ink ring-danger/25',
  money: 'bg-money-soft text-money-ink ring-money/30',
};

const dots: Record<BadgeTone, string> = {
  neutral: 'bg-subtle',
  info: 'bg-primary',
  success: 'bg-success',
  warning: 'bg-warning',
  danger: 'bg-danger',
  money: 'bg-money',
};

export interface BadgeProps {
  tone?: BadgeTone;
  children: ReactNode;
  dot?: boolean;
  className?: string;
}

export function Badge({ tone = 'neutral', children, dot = false, className }: BadgeProps) {
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium whitespace-nowrap ring-1 ring-inset',
        tones[tone],
        className,
      )}
    >
      {dot && <span aria-hidden="true" className={cn('size-1.5 rounded-full', dots[tone])} />}
      {children}
    </span>
  );
}
