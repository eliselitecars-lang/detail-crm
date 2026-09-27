import { ChevronDown } from 'lucide-react';
import type { ComponentProps } from 'react';
import { cn } from '@/lib/cn';
import { controlClasses, useFormFieldControl } from './formFieldContext';

export interface SelectOption<V extends string = string> {
  value: V;
  label: string;
  disabled?: boolean;
}

export interface SelectProps extends Omit<ComponentProps<'select'>, 'size'> {
  options?: readonly SelectOption[];
  /** Adds a first empty option (value ""). */
  placeholder?: string;
  selectSize?: 'sm' | 'md' | 'lg';
}

const heights = { sm: 'h-8', md: 'h-9', lg: 'h-11 text-base' } as const;

/** Native <select> (best mobile UX + a11y); pass `options` or <option> children. */
export function Select({
  options,
  placeholder,
  selectSize = 'md',
  className,
  children,
  ref,
  ...props
}: SelectProps) {
  const { invalid: _invalid, ...field } = useFormFieldControl(props);
  return (
    <div className={cn('relative', className)}>
      <select
        ref={ref}
        {...props}
        {...field}
        className={cn(controlClasses, heights[selectSize], 'appearance-none pr-9')}
      >
        {placeholder !== undefined && <option value="">{placeholder}</option>}
        {options?.map((o) => (
          <option key={o.value} value={o.value} disabled={o.disabled}>
            {o.label}
          </option>
        ))}
        {children}
      </select>
      <ChevronDown
        className="text-subtle pointer-events-none absolute top-1/2 right-3 size-4 -translate-y-1/2"
        aria-hidden="true"
      />
    </div>
  );
}
