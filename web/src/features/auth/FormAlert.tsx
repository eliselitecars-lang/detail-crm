import { CircleAlert, CircleCheck } from 'lucide-react';
import type { ReactNode } from 'react';
import { cn } from '@/lib/cn';

/** Form-level message (submit errors, success notices) announced to SR. */
export function FormAlert({
  tone = 'error',
  children,
  className,
}: {
  tone?: 'error' | 'success';
  children: ReactNode;
  className?: string;
}) {
  return (
    <div
      role={tone === 'error' ? 'alert' : 'status'}
      className={cn(
        'rounded-control flex items-start gap-2 px-3 py-2.5 text-sm',
        tone === 'error' ? 'bg-danger-soft text-danger-ink' : 'bg-success-soft text-success-ink',
        className,
      )}
    >
      {tone === 'error' ? (
        <CircleAlert className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
      ) : (
        <CircleCheck className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
      )}
      <div className="min-w-0 break-words">{children}</div>
    </div>
  );
}
