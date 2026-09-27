import { Check } from 'lucide-react';
import { cn } from '@/lib/cn';
import { STEPS, type StepId } from '../model';

/** Progress through the wizard. Completed steps can be revisited. */
export function StepIndicator({
  current,
  reachable,
  onSelect,
}: {
  current: StepId;
  /** Steps the visitor may jump back to. */
  reachable: ReadonlySet<StepId>;
  onSelect: (step: StepId) => void;
}) {
  const currentIndex = STEPS.findIndex((s) => s.id === current);
  return (
    <nav aria-label="Booking steps" className="print:hidden">
      <ol className="flex items-center gap-1.5 overflow-x-auto pb-1 sm:gap-2">
        {STEPS.map((step, index) => {
          const done = index < currentIndex;
          const active = step.id === current;
          const canJump = !active && reachable.has(step.id) && index < currentIndex;
          const content = (
            <>
              <span
                aria-hidden="true"
                className={cn(
                  'flex size-6 shrink-0 items-center justify-center rounded-full text-xs font-semibold',
                  active && 'bg-brand text-brand-fg',
                  done && 'bg-primary-soft text-primary-ink',
                  !active && !done && 'bg-surface-2 text-muted',
                )}
              >
                {done ? <Check className="size-3.5" /> : index + 1}
              </span>
              <span
                className={cn('text-xs font-medium whitespace-nowrap', !active && 'max-sm:sr-only')}
              >
                {step.label}
              </span>
            </>
          );
          return (
            <li key={step.id} className="flex items-center gap-1.5 sm:gap-2">
              {index > 0 && <span aria-hidden="true" className="bg-line h-px w-3 sm:w-6" />}
              {canJump ? (
                <button
                  type="button"
                  onClick={() => onSelect(step.id)}
                  className="text-muted hover:text-ink focus-visible:outline-primary rounded-control flex items-center gap-1.5 focus-visible:outline-2 focus-visible:outline-offset-2"
                >
                  {content}
                  <span className="sr-only"> (completed — edit)</span>
                </button>
              ) : (
                <span
                  className={cn('flex items-center gap-1.5', active ? 'text-ink' : 'text-muted')}
                  aria-current={active ? 'step' : undefined}
                >
                  {content}
                </span>
              )}
            </li>
          );
        })}
      </ol>
    </nav>
  );
}
