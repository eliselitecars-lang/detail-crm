import type { ComponentProps } from 'react';
import { Input } from './Input';

export interface DateInputProps extends Omit<ComponentProps<'input'>, 'type' | 'size'> {
  /** "yyyy-MM-dd" (shop-local date; convert with lib/dates). */
  value?: string;
  inputSize?: 'sm' | 'md' | 'lg';
}

/** Native date picker. Values are shop-local "yyyy-MM-dd" strings. */
export function DateInput(props: DateInputProps) {
  return <Input {...props} type="date" />;
}

export interface TimeInputProps extends Omit<ComponentProps<'input'>, 'type' | 'size'> {
  /** "HH:mm" (24h, shop-local). */
  value?: string;
  inputSize?: 'sm' | 'md' | 'lg';
}

/** Native time picker. Values are shop-local "HH:mm" strings. */
export function TimeInput({ step = 300, ...props }: TimeInputProps) {
  return <Input {...props} type="time" step={step} />;
}
