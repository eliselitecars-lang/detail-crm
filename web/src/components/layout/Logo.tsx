import { cn } from '@/lib/cn';

/** Detail CRM mark + wordmark (original brand; Glacier + Amber). */
export function Logo({ className, showText = true }: { className?: string; showText?: boolean }) {
  return (
    <span className={cn('inline-flex items-center gap-2', className)}>
      <svg viewBox="0 0 32 32" className="size-7 shrink-0" aria-hidden="true">
        <rect width="32" height="32" rx="8" fill="#1F6FEB" />
        <path
          d="M9 21.5c2.2-5.6 5.6-9.4 10.5-11.5l3.5 1.4c-4.4 2.1-7.6 5.6-9.7 10.1H9Z"
          fill="#fff"
        />
        <circle cx="21.5" cy="20.5" r="2.5" fill="#E8A23A" />
      </svg>
      {showText && (
        <span className="text-ink text-base font-semibold tracking-tight">Detail CRM</span>
      )}
      {!showText && <span className="sr-only">Detail CRM</span>}
    </span>
  );
}
