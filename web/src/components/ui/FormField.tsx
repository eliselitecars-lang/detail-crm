import { useId, type ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { FormFieldContext } from './formFieldContext';

export interface FormFieldProps {
  label: ReactNode;
  children: ReactNode;
  /** Help text under the control (hidden while an error shows). */
  help?: ReactNode;
  /** Error message; marks the control aria-invalid and announces politely. */
  error?: ReactNode;
  required?: boolean;
  disabled?: boolean;
  /** Visually hide the label (it stays available to screen readers). */
  hideLabel?: boolean;
  /** Supply when the control id must be known (e.g. tests); generated otherwise. */
  id?: string;
  className?: string;
  /** Right-aligned element in the label row (e.g. "Forgot password?"). */
  labelAside?: ReactNode;
}

export function FormField({
  label,
  children,
  help,
  error,
  required = false,
  disabled = false,
  hideLabel = false,
  id,
  className,
  labelAside,
}: FormFieldProps) {
  const autoId = useId();
  const controlId = id ?? `field-${autoId}`;
  const helpId = `${controlId}-help`;
  const errorId = `${controlId}-error`;
  const hasError = error !== undefined && error !== null && error !== false && error !== '';
  const describedBy = hasError ? errorId : help ? helpId : undefined;

  return (
    <FormFieldContext value={{ id: controlId, describedBy, invalid: hasError, required, disabled }}>
      <div className={cn('flex flex-col gap-1.5', className)}>
        <div className={cn('flex items-baseline justify-between gap-2', hideLabel && 'sr-only')}>
          <label htmlFor={controlId} className="text-ink text-sm font-medium">
            {label}
            {required && (
              <span className="text-danger-ink ml-0.5" aria-hidden="true">
                *
              </span>
            )}
          </label>
          {labelAside}
        </div>
        {children}
        {hasError ? (
          <p id={errorId} role="alert" className="text-danger-ink text-xs font-medium">
            {error}
          </p>
        ) : help ? (
          <p id={helpId} className="text-muted text-xs">
            {help}
          </p>
        ) : null}
      </div>
    </FormFieldContext>
  );
}
