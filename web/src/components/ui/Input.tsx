import type { ComponentProps, ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { controlClasses, useFormFieldControl } from './formFieldContext';

export interface InputProps extends Omit<ComponentProps<'input'>, 'size'> {
  /** Icon or text rendered inside the left edge (decorative). */
  leading?: ReactNode;
  /** Element rendered inside the right edge (e.g. a clear button). */
  trailing?: ReactNode;
  inputSize?: 'sm' | 'md' | 'lg';
}

const heights = { sm: 'h-8', md: 'h-9', lg: 'h-11 text-base' } as const;

export function Input({
  leading,
  trailing,
  inputSize = 'md',
  className,
  ref,
  ...props
}: InputProps) {
  const { invalid: _invalid, ...field } = useFormFieldControl(props);
  const input = (
    <input
      ref={ref}
      {...props}
      {...field}
      className={cn(
        controlClasses,
        heights[inputSize],
        leading !== undefined && 'pl-9',
        trailing !== undefined && 'pr-10',
        !leading && !trailing && className,
      )}
    />
  );
  if (leading === undefined && trailing === undefined) return input;
  return (
    <div className={cn('relative', className)}>
      {leading !== undefined && (
        <span
          className="text-subtle pointer-events-none absolute inset-y-0 left-0 flex w-9 items-center justify-center [&_svg]:size-4"
          aria-hidden="true"
        >
          {leading}
        </span>
      )}
      {input}
      {trailing !== undefined && (
        <span className="absolute inset-y-0 right-0 flex items-center pr-1">{trailing}</span>
      )}
    </div>
  );
}
