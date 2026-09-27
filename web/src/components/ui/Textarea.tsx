import type { ComponentProps } from 'react';
import { cn } from '@/lib/cn';
import { controlClasses, useFormFieldControl } from './formFieldContext';

export type TextareaProps = ComponentProps<'textarea'>;

export function Textarea({ className, rows = 4, ref, ...props }: TextareaProps) {
  const { invalid: _invalid, ...field } = useFormFieldControl(props);
  return (
    <textarea
      ref={ref}
      rows={rows}
      {...props}
      {...field}
      className={cn(controlClasses, 'min-h-20 resize-y py-2 leading-relaxed', className)}
    />
  );
}
