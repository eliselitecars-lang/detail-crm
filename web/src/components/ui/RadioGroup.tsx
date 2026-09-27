import { useId, type ReactNode } from 'react';
import { cn } from '@/lib/cn';

export interface RadioOption<V extends string> {
  value: V;
  label: ReactNode;
  description?: ReactNode;
  disabled?: boolean;
}

export interface RadioGroupProps<V extends string> {
  /** Group label (rendered as <legend>). */
  label: ReactNode;
  hideLabel?: boolean;
  name?: string;
  value: V | null | undefined;
  onChange: (value: V) => void;
  options: readonly RadioOption<V>[];
  /** "cards" renders each option as a selectable card. */
  variant?: 'list' | 'cards';
  orientation?: 'vertical' | 'horizontal';
  error?: ReactNode;
  disabled?: boolean;
  className?: string;
}

/** Native radio inputs in a fieldset: arrow keys move selection for free. */
export function RadioGroup<V extends string>({
  label,
  hideLabel = false,
  name,
  value,
  onChange,
  options,
  variant = 'list',
  orientation = 'vertical',
  error,
  disabled = false,
  className,
}: RadioGroupProps<V>) {
  const autoId = useId();
  const groupName = name ?? `rg-${autoId}`;
  const errorId = error ? `${groupName}-error` : undefined;
  return (
    <fieldset
      className={cn('flex flex-col gap-2', className)}
      aria-describedby={errorId}
      aria-invalid={error ? true : undefined}
      disabled={disabled}
    >
      <legend className={cn('text-ink mb-1 text-sm font-medium', hideLabel && 'sr-only')}>
        {label}
      </legend>
      <div
        className={cn(
          'flex gap-2',
          orientation === 'vertical' ? 'flex-col' : 'flex-row flex-wrap',
          variant === 'cards' && orientation === 'horizontal' && 'grid grid-cols-1 sm:grid-cols-3',
        )}
      >
        {options.map((option) => {
          const id = `${groupName}-${option.value}`;
          const checked = value === option.value;
          return (
            <label
              key={option.value}
              htmlFor={id}
              className={cn(
                'flex cursor-pointer items-start gap-2.5',
                variant === 'cards' &&
                  'rounded-card bg-surface has-[:focus-visible]:outline-primary border p-3 transition-colors has-[:focus-visible]:outline-2',
                variant === 'cards' &&
                  (checked
                    ? 'border-primary bg-primary-soft'
                    : 'border-line hover:border-line-strong'),
                option.disabled && 'cursor-not-allowed opacity-55',
              )}
            >
              <input
                id={id}
                type="radio"
                name={groupName}
                value={option.value}
                checked={checked}
                disabled={option.disabled}
                onChange={() => onChange(option.value)}
                className={cn(
                  'mt-0.5 size-4 shrink-0 accent-[var(--dc-primary)]',
                  variant === 'cards' && 'sr-only',
                )}
              />
              <span className="flex flex-col">
                <span className="text-ink text-sm font-medium">{option.label}</span>
                {option.description && (
                  <span className="text-muted text-xs">{option.description}</span>
                )}
              </span>
            </label>
          );
        })}
      </div>
      {error && (
        <p id={errorId} role="alert" className="text-danger-ink text-xs font-medium">
          {error}
        </p>
      )}
    </fieldset>
  );
}
