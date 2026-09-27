import { useId, type ComponentProps, type ReactNode } from 'react';
import { cn } from '@/lib/cn';

export interface CheckboxProps extends Omit<ComponentProps<'input'>, 'type'> {
  label?: ReactNode;
  description?: ReactNode;
}

export function Checkbox({ label, description, className, id, ref, ...props }: CheckboxProps) {
  const autoId = useId();
  const inputId = id ?? `cb-${autoId}`;
  const descId = description ? `${inputId}-desc` : undefined;
  return (
    <div className={cn('flex items-start gap-2.5', className)}>
      <input
        ref={ref}
        id={inputId}
        type="checkbox"
        aria-describedby={descId}
        className="border-line-strong mt-0.5 size-4 shrink-0 cursor-pointer rounded accent-[var(--dc-primary)] disabled:cursor-not-allowed"
        {...props}
      />
      {(label || description) && (
        <div className="flex flex-col">
          {label && (
            <label htmlFor={inputId} className="text-ink cursor-pointer text-sm">
              {label}
            </label>
          )}
          {description && (
            <span id={descId} className="text-muted text-xs">
              {description}
            </span>
          )}
        </div>
      )}
    </div>
  );
}
