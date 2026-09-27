import { createContext, use } from 'react';

export interface FormFieldContextValue {
  id: string;
  describedBy: string | undefined;
  invalid: boolean;
  required: boolean;
  disabled: boolean;
}

export const FormFieldContext = createContext<FormFieldContextValue | null>(null);

/**
 * Controls (Input, Select, MoneyInput…) call this to pick up the id,
 * aria-describedby, aria-invalid and required state from an enclosing
 * <FormField>. Explicit props on the control always win.
 */
export function useFormFieldControl<
  P extends {
    id?: string | undefined;
    'aria-describedby'?: string | undefined;
    'aria-invalid'?: boolean | 'true' | 'false' | 'grammar' | 'spelling' | undefined;
    required?: boolean | undefined;
    disabled?: boolean | undefined;
  },
>(props: P) {
  const ctx = use(FormFieldContext);
  const invalid = props['aria-invalid'] ?? (ctx?.invalid ? true : undefined);
  return {
    id: props.id ?? ctx?.id,
    'aria-describedby': props['aria-describedby'] ?? ctx?.describedBy,
    'aria-invalid': invalid,
    required: props.required ?? (ctx?.required || undefined),
    disabled: props.disabled ?? (ctx?.disabled || undefined),
    invalid: invalid === true || invalid === 'true',
  };
}

/** Shared control styling (inputs, selects, textareas, combobox). */
export const controlClasses =
  'block w-full rounded-control border border-line-strong bg-surface px-3 text-sm text-ink shadow-card placeholder:text-subtle transition-colors focus:border-primary focus:outline-none focus-visible:outline-2 focus-visible:outline-offset-0 focus-visible:outline-primary disabled:cursor-not-allowed disabled:bg-surface-2 disabled:text-muted aria-[invalid=true]:border-danger';
