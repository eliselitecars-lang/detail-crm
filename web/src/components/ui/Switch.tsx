import { useId, type ReactNode } from 'react';
import { cn } from '@/lib/cn';

export interface SwitchProps {
  checked: boolean;
  onCheckedChange: (checked: boolean) => void;
  label?: ReactNode;
  description?: ReactNode;
  /** Required when there is no visible label. */
  'aria-label'?: string;
  disabled?: boolean;
  id?: string;
  className?: string;
  name?: string;
}

/** role="switch" toggle; Space/Enter toggles (native button semantics). */
export function Switch({
  checked,
  onCheckedChange,
  label,
  description,
  disabled = false,
  id,
  className,
  name,
  ...aria
}: SwitchProps) {
  const autoId = useId();
  const switchId = id ?? `sw-${autoId}`;
  const labelId = label ? `${switchId}-label` : undefined;
  const descId = description ? `${switchId}-desc` : undefined;
  return (
    <div className={cn('flex items-start justify-between gap-4', className)}>
      {(label || description) && (
        <div className="flex flex-col">
          {label && (
            <label id={labelId} htmlFor={switchId} className="text-ink text-sm font-medium">
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
      <button
        id={switchId}
        type="button"
        role="switch"
        name={name}
        aria-checked={checked}
        aria-labelledby={labelId}
        aria-label={labelId ? undefined : aria['aria-label']}
        aria-describedby={descId}
        disabled={disabled}
        onClick={() => onCheckedChange(!checked)}
        className={cn(
          'focus-visible:outline-primary relative inline-flex h-6 w-10 shrink-0 cursor-pointer items-center rounded-full transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 disabled:cursor-not-allowed disabled:opacity-55',
          checked ? 'bg-primary' : 'bg-line-strong',
        )}
      >
        <span
          aria-hidden="true"
          className={cn(
            'shadow-card inline-block size-5 rounded-full bg-white transition-transform',
            checked ? 'translate-x-[18px]' : 'translate-x-0.5',
          )}
        />
      </button>
    </div>
  );
}
